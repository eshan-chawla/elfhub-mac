//
//  OverlayWindow.swift
//  elfhub
//
//  System-wide transparent, click-through overlay. One OverlayWindow per
//  screen hosts ScreenGuidanceOverlayView, which draws only what elfhub is
//  actively showing: the pointer at its target, annotations, and the status
//  pill. There is no resting or mouse-following cursor — when nothing is
//  being shown, the overlay draws nothing.
//
//  Windows stay mounted while the app is ready (onboarded + permissions), so
//  pointing works from any surface (voice or text chat) without a hotkey
//  having to bring the overlay up first.
//

import AppKit
import SwiftUI

/// A non-activating panel, not a plain window: elfhub is a regular (Dock)
/// app, and macOS only shows a regular app's plain windows on its own
/// Spaces — even with `.fullScreenAuxiliary`. A non-activating panel is
/// what may float over another app's full-screen Space, so the status pill
/// (listening, thinking, acting) and the pointer show there too.
class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Transparent and click-through: the overlay must never intercept
        // the user's clicks or keyboard.
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Above menus, popovers and full-screen apps
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        // Keep the overlay out of the Accessibility tree so hit-tests by
        // AccessibilityElementLocator reach the user's real UI underneath.
        self.setAccessibilityElement(false)

        self.setFrame(screen.frame, display: true)
    }

    // Never take focus from the user's app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay Window Manager

/// Mounts one overlay window per connected screen and rebuilds them when the
/// display configuration changes (monitor plugged in, resolution changed).
@MainActor
final class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var mountedOverlayModel: ScreenGuidanceOverlayModel?

    var isOverlayMounted: Bool {
        mountedOverlayModel != nil
    }

    func mountOverlay(overlayModel: ScreenGuidanceOverlayModel) {
        guard mountedOverlayModel == nil else { return }
        mountedOverlayModel = overlayModel
        rebuildOverlayWindows()

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildOverlayWindows()
            }
        }

        // Entering or leaving a full-screen Space: bring the overlay back to
        // the front of that Space so nothing full screen covers the pill.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bringOverlayWindowsToFront()
            }
        }
    }

    func unmountOverlay() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        removeOverlayWindows()
        mountedOverlayModel = nil
    }

    private func rebuildOverlayWindows() {
        guard let mountedOverlayModel else { return }
        removeOverlayWindows()

        for screen in NSScreen.screens {
            let overlayWindow = OverlayWindow(screen: screen)
            let overlayView = ScreenGuidanceOverlayView(
                screenFrame: screen.frame,
                topInsetForStatusPill: Self.topInset(of: screen),
                overlayModel: mountedOverlayModel
            )
            let hostingView = NSHostingView(rootView: overlayView)
            hostingView.frame = screen.frame
            hostingView.setAccessibilityElement(false)
            overlayWindow.contentView = hostingView

            overlayWindows.append(overlayWindow)
            overlayWindow.orderFrontRegardless()
        }
    }

    private func bringOverlayWindowsToFront() {
        for overlayWindow in overlayWindows {
            overlayWindow.orderFrontRegardless()
        }
    }

    private func removeOverlayWindows() {
        for overlayWindow in overlayWindows {
            overlayWindow.orderOut(nil)
            overlayWindow.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Height of the menu bar (and notch) at the top of a screen, so the
    /// status pill sits just below it.
    private static func topInset(of screen: NSScreen) -> CGFloat {
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return max(menuBarHeight, screen.safeAreaInsets.top)
    }
}

// MARK: - Per-Screen Overlay View

/// Everything elfhub draws on one screen. Each piece only renders when its
/// target is on this screen.
struct ScreenGuidanceOverlayView: View {
    let screenFrame: CGRect
    let topInsetForStatusPill: CGFloat
    @ObservedObject var overlayModel: ScreenGuidanceOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The user's own ink, under elfhub's marks. Every screen draws
            // all strokes; anything off this screen falls outside the window.
            if !overlayModel.activeUserInkStrokes.isEmpty {
                UserInkStrokesView(userInkStrokes: overlayModel.activeUserInkStrokes, screenFrame: screenFrame)
                    .transition(.opacity)
            }

            // Annotations sit under the pointer.
            ForEach(annotationsOnThisScreen) { placedAnnotation in
                ScreenAnnotationShapeView(
                    placedAnnotation: placedAnnotation,
                    screenFrame: screenFrame
                )
                .transition(.opacity)
            }

            if let activePointer = overlayModel.activePointer, isOnThisScreen(activePointer.displayFrame) {
                PointerAtTargetView(placedPointer: activePointer, screenFrame: screenFrame)
                    .id(activePointer.id)
                    .transition(.opacity)
            }

            // The status pill, and under it the caption panel (live captions
            // or an unspoken reply), on the screen the turn started on.
            VStack(spacing: 8) {
                if isStatusPillOnThisScreen {
                    CompanionStatusPillView(
                        statusPillPhase: overlayModel.statusPillPhase,
                        audioPowerLevel: overlayModel.audioPowerLevel
                    )
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
                if let liveCaptionTranscript = overlayModel.liveCaptionTranscript, isCaptionPanelOnThisScreen {
                    LiveCaptionPanel(transcript: liveCaptionTranscript)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .padding(.top, topInsetForStatusPill + 8)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: overlayModel.activePointer?.id)
        .animation(.easeOut(duration: 0.4), value: overlayModel.activeAnnotations.map(\.id))
        .animation(.easeOut(duration: 0.4), value: overlayModel.activeUserInkStrokes.isEmpty)
        .animation(DS.Motion.base, value: overlayModel.statusPillPhase)
        .animation(DS.Motion.base, value: overlayModel.liveCaptionTranscript == nil)
    }

    private var annotationsOnThisScreen: [PlacedAnnotation] {
        overlayModel.activeAnnotations.filter { isOnThisScreen($0.displayFrame) }
    }

    private var isStatusPillOnThisScreen: Bool {
        guard overlayModel.statusPillPhase != .hidden,
              let statusPillScreenFrame = overlayModel.statusPillScreenFrame else { return false }
        return isOnThisScreen(statusPillScreenFrame)
    }

    private var isCaptionPanelOnThisScreen: Bool {
        guard let statusPillScreenFrame = overlayModel.statusPillScreenFrame else { return false }
        return isOnThisScreen(statusPillScreenFrame)
    }

    private func isOnThisScreen(_ displayFrame: CGRect) -> Bool {
        displayFrame == screenFrame || screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
    }
}

// MARK: - User Ink

/// What the user is drawing while holding push-to-talk: a solid line that
/// trails the cursor along the exact path, in the user's blue (an Elf's
/// own marks are orange). A white under-stroke keeps it readable anywhere.
struct UserInkStrokesView: View {
    let userInkStrokes: [UserInkStroke]
    let screenFrame: CGRect

    var body: some View {
        let inkPath = Path { path in
            for userInkStroke in userInkStrokes {
                let localPoints = userInkStroke.points.map { $0.overlayLocalPoint(inScreenFrame: screenFrame) }
                guard let firstLocalPoint = localPoints.first else { continue }
                path.move(to: firstLocalPoint)
                if localPoints.count == 1 {
                    // A click without a drag shows as a dot.
                    path.addLine(to: CGPoint(x: firstLocalPoint.x + 0.1, y: firstLocalPoint.y))
                } else {
                    path.addLines(localPoints)
                }
            }
        }
        ZStack {
            inkPath.stroke(
                Color.white.opacity(0.8),
                style: StrokeStyle(lineWidth: UserInkAppearance.inkLineWidthInPoints + 3, lineCap: .round, lineJoin: .round)
            )
            inkPath.stroke(
                DS.Colors.overlayUserInk,
                style: StrokeStyle(lineWidth: UserInkAppearance.inkLineWidthInPoints, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
    }
}

// MARK: - Local Coordinate Conversion

extension CGPoint {
    /// Converts an AppKit global point (bottom-left origin) into the top-left
    /// local coordinates of the overlay view covering `screenFrame`.
    func overlayLocalPoint(inScreenFrame screenFrame: CGRect) -> CGPoint {
        CGPoint(x: x - screenFrame.minX, y: screenFrame.maxY - y)
    }
}

extension CGRect {
    /// Converts an AppKit global rect into the overlay view's local space.
    func overlayLocalRect(inScreenFrame screenFrame: CGRect) -> CGRect {
        CGRect(
            x: minX - screenFrame.minX,
            y: screenFrame.maxY - maxY,
            width: width,
            height: height
        )
    }
}

// MARK: - Pointer

/// Classic pointer arrow whose tip is at the top-left corner of its frame, so
/// positioning the frame's corner on the target puts the tip exactly there.
struct PointerArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.86))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.64))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.47, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.93))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.58))
        path.closeSubpath()
        return path
    }
}

/// The pointer, appearing directly at its target with a pulse, an optional
/// ring around the real element, and a short label.
struct PointerAtTargetView: View {
    let placedPointer: PlacedPointer
    let screenFrame: CGRect
    /// False when redrawing a saved pointer in chat: shown at rest, without
    /// the spring-in or the repeating pulse.
    var animatesAppearance: Bool = true

    @State private var hasAppeared = false
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pointerSize = CGSize(width: 20, height: 26)
    private let labelBubbleMaximumWidth: CGFloat = 240

    var body: some View {
        let targetPoint = placedPointer.appKitGlobalPoint.overlayLocalPoint(inScreenFrame: screenFrame)

        ZStack(alignment: .topLeading) {
            if let highlightedElementFrame = placedPointer.highlightedElementFrame {
                let localElementFrame = highlightedElementFrame.overlayLocalRect(inScreenFrame: screenFrame)
                // The pen's rounded outline around the real element, with a
                // light outer edge so it reads on any background.
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.elfPenEdge, lineWidth: 4)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.elfPen, lineWidth: 2)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .frame(width: localElementFrame.width + 6, height: localElementFrame.height + 6)
                    .position(x: localElementFrame.midX, y: localElementFrame.midY)
                    .opacity(hasAppeared ? 1 : 0)
            }

            // One expanding ring as the pointer lands, so the eye finds the
            // target — once, not looping (one calm hand).
            if animatesAppearance && !reduceMotion {
                Circle()
                    .stroke(DS.Colors.elfPen.opacity(isPulsing ? 0 : 0.6), lineWidth: 2)
                    .frame(width: isPulsing ? 56 : 10, height: isPulsing ? 56 : 10)
                    .position(targetPoint)
            }

            PointerArrowShape()
                .fill(DS.Colors.elfPen)
                .overlay(PointerArrowShape().stroke(DS.Colors.elfPenEdge, lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
                .frame(width: pointerSize.width, height: pointerSize.height)
                .scaleEffect(hasAppeared ? 1 : 0.8, anchor: .topLeading)
                .position(x: targetPoint.x + pointerSize.width / 2, y: targetPoint.y + pointerSize.height / 2)

            if let pointerLabel = placedPointer.label, !pointerLabel.isEmpty {
                labelBubble(text: pointerLabel, targetPoint: targetPoint)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            guard animatesAppearance, !reduceMotion else {
                hasAppeared = true
                return
            }
            // The brand's one easing — a quick start and a soft landing, no
            // spring overshoot.
            withAnimation(DS.Motion.base) {
                hasAppeared = true
            }
            withAnimation(.easeOut(duration: 1.0)) {
                isPulsing = true
            }
        }
    }

    /// Label to the lower right of the tip, flipped to the left near the
    /// right edge of the screen so it never runs off-screen.
    private func labelBubble(text: String, targetPoint: CGPoint) -> some View {
        let placesBubbleOnLeft = targetPoint.x > screenFrame.width - labelBubbleMaximumWidth - 40
        let horizontalOffset: CGFloat = placesBubbleOnLeft ? -(labelBubbleMaximumWidth / 2 + 8) : (labelBubbleMaximumWidth / 2 + pointerSize.width)
        let bubbleCenterY = min(targetPoint.y + pointerSize.height + 10, screenFrame.height - 20)

        return Text(text)
            .font(DS.Typography.interface(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            // A note beside a mark: white text on an orange pill.
            .background(Capsule().fill(DS.Colors.elfPen))
            .overlay(Capsule().strokeBorder(DS.Colors.elfPenEdge, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.2), radius: 3, x: 0, y: 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: labelBubbleMaximumWidth, alignment: placesBubbleOnLeft ? .trailing : .leading)
            .position(x: targetPoint.x + horizontalOffset, y: bubbleCenterY)
    }
}
