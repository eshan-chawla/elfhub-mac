//
//  UserInterruptionMonitor.swift
//  elfhub
//
//  Lets the user interrupt elfhub instantly. Two modes:
//
//  - While elfhub is ACTING (clicking/typing for the user), an active event
//    tap consumes Esc as a kill switch and treats any real (untagged) mouse
//    click, scroll, keypress or significant mouse movement as the user taking
//    back control. Synthetic events elfhub posts are tagged by
//    ScreenActionSynthesizer and ignored here.
//  - While elfhub is listening, thinking or talking, or the pointer/annotations
//    are VISIBLE, a listen-only tap watches for Esc to stop all of it — without
//    swallowing Esc, so the user's app still receives it.
//
//  Kept separate from the push-to-talk tap, which stays listen-only always.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
final class UserInterruptionMonitor {

    enum MonitoringMode: Equatable {
        /// Actions are running: consume Esc; any real input means takeover.
        case stopActionsOnEscapeOrUserInput
        /// Listening, thinking, talking or showing marks: observe Esc (to stop
        /// all of it), never consume it.
        case watchEscapeWithoutConsuming
    }

    /// Called when Esc is pressed in either mode.
    var onEscapePressed: (() -> Void)?
    /// Called when the user physically uses the mouse/keyboard while acting.
    var onUserTookControl: (() -> Void)?

    private(set) var activeMonitoringMode: MonitoringMode?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    /// Where the pointer was when acting started (or where elfhub last moved
    /// it), to measure deliberate movement by the user.
    private var mouseLocationWhenMonitoringStarted: CGPoint?

    /// A nudge of the mouse shouldn't abort a task; a deliberate move should.
    private static let mouseMovementTakeoverDistance: CGFloat = 40

    /// Starts (or switches) monitoring. No-op if already in this mode.
    func start(mode: MonitoringMode) {
        guard activeMonitoringMode != mode else { return }
        stop()

        let monitoredEventTypes: [CGEventType]
        let tapOptions: CGEventTapOptions
        switch mode {
        case .stopActionsOnEscapeOrUserInput:
            monitoredEventTypes = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
            // Must be an active (default) tap to be able to swallow Esc.
            tapOptions = .defaultTap
        case .watchEscapeWithoutConsuming:
            monitoredEventTypes = [.keyDown]
            tapOptions = .listenOnly
        }

        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let userInterruptionMonitor = Unmanaged<UserInterruptionMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return userInterruptionMonitor.handleEventTap(eventType: eventType, event: event)
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: tapOptions,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ User interruption monitor: couldn't create CGEvent tap")
            return
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0) else {
            CFMachPortInvalidate(createdEventTap)
            return
        }

        eventTap = createdEventTap
        eventTapRunLoopSource = createdRunLoopSource
        activeMonitoringMode = mode
        mouseLocationWhenMonitoringStarted = CGEvent(source: nil)?.location

        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        activeMonitoringMode = nil
        mouseLocationWhenMonitoringStarted = nil
    }

    /// While elfhub holds modifier keys (a cmd-click), the user's own key
    /// or click would get them too — their "w" would arrive as cmd+W. Those
    /// presses are swallowed; they still count as taking over.
    nonisolated static func shouldSwallowUsersEvent(eventType: CGEventType, isHoldingModifierKeys: Bool) -> Bool {
        guard isHoldingModifierKeys else { return false }
        return [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel].contains(eventType)
    }

    private func handleEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // elfhub's own clicks/keys must never count as the user interrupting.
        // When elfhub moves the pointer itself, re-anchor the movement baseline
        // there, so a small real nudge afterwards isn't mistaken for a takeover.
        if ScreenActionSynthesizer.isSyntheticEvent(event) {
            if eventType == .mouseMoved || eventType == .leftMouseDragged {
                mouseLocationWhenMonitoringStarted = event.location
            }
            return Unmanaged.passUnretained(event)
        }

        let isEscapeKeyDown = eventType == .keyDown
            && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)

        switch activeMonitoringMode {
        case .stopActionsOnEscapeOrUserInput:
            if isEscapeKeyDown {
                onEscapePressed?()
                // Swallow it: this Esc was meant for elfhub, not the app.
                return nil
            }
            if eventType == .mouseMoved || eventType == .leftMouseDragged {
                if let mouseLocationWhenMonitoringStarted,
                   hypot(event.location.x - mouseLocationWhenMonitoringStarted.x,
                         event.location.y - mouseLocationWhenMonitoringStarted.y) > Self.mouseMovementTakeoverDistance {
                    onUserTookControl?()
                }
                return Unmanaged.passUnretained(event)
            }
            onUserTookControl?()
            if Self.shouldSwallowUsersEvent(eventType: eventType, isHoldingModifierKeys: ScreenActionSynthesizer.isHoldingModifierKeys) {
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .watchEscapeWithoutConsuming:
            if isEscapeKeyDown {
                onEscapePressed?()
            }
            return Unmanaged.passUnretained(event)

        case nil:
            return Unmanaged.passUnretained(event)
        }
    }
}
