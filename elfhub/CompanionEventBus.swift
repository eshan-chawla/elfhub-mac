//
//  CompanionEventBus.swift
//  elfhub
//
//  A typed, in-process event channel between the turn pipeline (which knows
//  what happened) and the on-screen surfaces (which decide how to show it).
//  CompanionManager and ScreenActionCoordinator emit events; the overlay model
//  below subscribes. Keeping the overlay off CompanionManager's internals means
//  a future multi-step agent loop can drive the same pointer, annotations and
//  status pill just by emitting the same events.
//

import AppKit
import Combine
import Foundation

enum CompanionEvent {
    /// A new push-to-talk or chat turn began. Clears the previous turn's
    /// pointer and annotations. The frame is the primary-focus screen.
    case turnStarted(primaryFocusScreenFrame: CGRect?)
    case listeningStarted
    case processingStarted
    /// The reply text (tags stripped) that is being spoken or shown.
    case responseCaptionAvailable(String)
    case guidancePlaced(pointer: PlacedPointer?, annotations: [PlacedAnnotation])
    case speechStarted
    case speechFinished
    /// The pointer moved to where an action is about to land.
    case actionPreviewed(PlacedPointer)
    case actionsStarted(summary: String)
    case actionsFinished
    case turnFinished
    /// The user pressed Esc or otherwise dismissed elfhub's marks.
    case allGuidanceDismissed
    /// A short instruction shown in the status pill (e.g. during onboarding).
    case hintRequested(String)
    /// The user is drawing on the screen while holding push-to-talk; every
    /// stroke so far, for the live trailing line.
    case userInkChanged([UserInkStroke])
    /// The shortcut was released, so drawing is done. The ink stays while
    /// elfhub answers, then fades like annotations do.
    case userInkFinished
    /// A reply started writing a notepad: a new, empty one replaces any
    /// notepad on screen. It stays until the user closes it — turns, Esc
    /// and the overlay's timers never touch it.
    case notepadOpened(title: String)
    /// The next line (markdown) of the open notepad, shown as elfhub starts
    /// the sentence about it.
    case notepadLineWritten(String)
}

@MainActor
final class CompanionEventBus {
    private let eventSubject = PassthroughSubject<CompanionEvent, Never>()

    var events: AnyPublisher<CompanionEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    func emit(_ event: CompanionEvent) {
        eventSubject.send(event)
    }
}

// MARK: - Overlay Model

/// What the status pill at the top of the screen is showing.
enum CompanionStatusPillPhase: Equatable {
    case hidden
    case listening
    case thinking
    case speaking(caption: String)
    case acting(summary: String)
    case hint(String)
}

/// State for every overlay window: the pointer, annotations and status pill.
/// Turns events into state and owns all the "how long does this stay on
/// screen" rules, so views stay declarative.
@MainActor
final class ScreenGuidanceOverlayModel: ObservableObject {
    @Published private(set) var statusPillPhase: CompanionStatusPillPhase = .hidden
    /// The screen the pill appears on (AppKit global frame).
    @Published private(set) var statusPillScreenFrame: CGRect?
    @Published private(set) var activePointer: PlacedPointer?
    @Published private(set) var activeAnnotations: [PlacedAnnotation] = []
    /// What the user drew while holding push-to-talk.
    @Published private(set) var activeUserInkStrokes: [UserInkStroke] = []
    /// Live microphone level for the listening waveform.
    @Published private(set) var audioPowerLevel: CGFloat = 0

    /// True while the pointer or any annotation is on screen. Drives whether
    /// Esc is watched for dismissing them.
    var hasVisibleGuidance: Bool {
        activePointer != nil || !activeAnnotations.isEmpty || !activeUserInkStrokes.isEmpty
    }

    // MARK: Timing rules

    /// The pointer stays at least this long so the user can find it.
    private static let minimumPointerDisplaySeconds: TimeInterval = 3
    /// After speech ends, the pointer lingers this long.
    private static let pointerLingerAfterSpeechSeconds: TimeInterval = 1
    /// Annotations stay longer than the pointer — they're meant to be read.
    private static let annotationLingerAfterSpeechSeconds: TimeInterval = 8
    private static let pillLingerAfterTurnSeconds: TimeInterval = 2.5
    private static let hintDisplaySeconds: TimeInterval = 8
    /// Upper bound for the user's ink when no reply follows (e.g. nothing
    /// was heard); a normal reply hides it with the annotations instead.
    private static let userInkMaximumSecondsWithoutReply: TimeInterval = 20

    private var pointerPlacedDate: Date?
    private var isSpeaking = false
    private var isActing = false
    private var isListening = false
    private var pointerHideTask: Task<Void, Never>?
    private var annotationsHideTask: Task<Void, Never>?
    private var userInkHideTask: Task<Void, Never>?
    private var statusPillHideTask: Task<Void, Never>?
    private var eventSubscription: AnyCancellable?
    private var audioPowerLevelSubscription: AnyCancellable?

    init(eventBus: CompanionEventBus, audioPowerLevelPublisher: AnyPublisher<CGFloat, Never>) {
        eventSubscription = eventBus.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handle(event)
            }
        audioPowerLevelSubscription = audioPowerLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.audioPowerLevel = powerLevel
            }
    }

    // MARK: Event handling

    private func handle(_ event: CompanionEvent) {
        switch event {
        case let .turnStarted(primaryFocusScreenFrame):
            cancelAllHideTasks()
            activePointer = nil
            activeAnnotations = []
            activeUserInkStrokes = []
            isSpeaking = false
            isActing = false
            statusPillScreenFrame = primaryFocusScreenFrame ?? Self.screenFrameContainingMouse()

        case .listeningStarted:
            isListening = true
            statusPillHideTask?.cancel()
            statusPillPhase = .listening

        case .processingStarted:
            isListening = false
            statusPillHideTask?.cancel()
            if statusPillScreenFrame == nil {
                statusPillScreenFrame = Self.screenFrameContainingMouse()
            }
            statusPillPhase = .thinking

        case let .responseCaptionAvailable(caption):
            let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCaption.isEmpty && !isActing {
                statusPillPhase = .speaking(caption: trimmedCaption)
            }

        case let .guidancePlaced(pointer, annotations):
            if let pointer {
                activePointer = pointer
                pointerPlacedDate = Date()
            }
            activeAnnotations = annotations
            if !isSpeaking {
                scheduleGuidanceHides()
            }

        case .speechStarted:
            isSpeaking = true
            pointerHideTask?.cancel()
            annotationsHideTask?.cancel()
            userInkHideTask?.cancel()
            statusPillHideTask?.cancel()

        case .speechFinished:
            isSpeaking = false
            scheduleGuidanceHides()
            scheduleStatusPillHideIfIdle()

        case let .actionPreviewed(pointer):
            pointerHideTask?.cancel()
            activePointer = pointer
            pointerPlacedDate = Date()

        case let .actionsStarted(summary):
            isActing = true
            statusPillHideTask?.cancel()
            if statusPillScreenFrame == nil {
                statusPillScreenFrame = Self.screenFrameContainingMouse()
            }
            statusPillPhase = .acting(summary: summary)

        case .actionsFinished:
            isActing = false
            schedulePointerHide(afterSeconds: 0.8)
            scheduleStatusPillHideIfIdle()

        case .turnFinished:
            isListening = false
            if !isSpeaking {
                scheduleGuidanceHides()
            }
            scheduleStatusPillHideIfIdle()

        case .allGuidanceDismissed:
            cancelAllHideTasks()
            activePointer = nil
            activeAnnotations = []
            activeUserInkStrokes = []
            if !isListening {
                statusPillPhase = .hidden
            }

        case let .hintRequested(hintText):
            statusPillHideTask?.cancel()
            statusPillScreenFrame = Self.screenFrameContainingMouse()
            statusPillPhase = .hint(hintText)
            statusPillHideTask = delayedTask(seconds: Self.hintDisplaySeconds) { [weak self] in
                guard let self, case .hint = self.statusPillPhase else { return }
                self.statusPillPhase = .hidden
            }

        case let .userInkChanged(userInkStrokes):
            userInkHideTask?.cancel()
            activeUserInkStrokes = userInkStrokes

        case .userInkFinished:
            userInkHideTask?.cancel()
            guard !activeUserInkStrokes.isEmpty else { return }
            userInkHideTask = delayedTask(seconds: Self.userInkMaximumSecondsWithoutReply) { [weak self] in
                self?.activeUserInkStrokes = []
            }

        case .notepadOpened, .notepadLineWritten:
            // The notepad has its own window (NotepadPanelManager).
            break
        }
    }

    // MARK: Hide scheduling

    private func scheduleGuidanceHides() {
        let secondsSincePointerPlaced = pointerPlacedDate.map { Date().timeIntervalSince($0) } ?? 0
        let remainingMinimumDisplaySeconds = max(0, Self.minimumPointerDisplaySeconds - secondsSincePointerPlaced)
        schedulePointerHide(afterSeconds: max(remainingMinimumDisplaySeconds, Self.pointerLingerAfterSpeechSeconds))

        // The user's ink fades with the annotations: once the reply is done.
        if !activeUserInkStrokes.isEmpty {
            userInkHideTask?.cancel()
            userInkHideTask = delayedTask(seconds: Self.annotationLingerAfterSpeechSeconds) { [weak self] in
                self?.activeUserInkStrokes = []
            }
        }

        annotationsHideTask?.cancel()
        guard !activeAnnotations.isEmpty else { return }
        annotationsHideTask = delayedTask(seconds: Self.annotationLingerAfterSpeechSeconds) { [weak self] in
            self?.activeAnnotations = []
        }
    }

    private func schedulePointerHide(afterSeconds delaySeconds: TimeInterval) {
        pointerHideTask?.cancel()
        guard activePointer != nil else { return }
        pointerHideTask = delayedTask(seconds: delaySeconds) { [weak self] in
            guard let self, !self.isActing else { return }
            self.activePointer = nil
        }
    }

    private func scheduleStatusPillHideIfIdle() {
        guard !isSpeaking, !isActing, !isListening else { return }
        statusPillHideTask?.cancel()
        statusPillHideTask = delayedTask(seconds: Self.pillLingerAfterTurnSeconds) { [weak self] in
            guard let self, !self.isSpeaking, !self.isActing, !self.isListening else { return }
            self.statusPillPhase = .hidden
        }
    }

    private func cancelAllHideTasks() {
        pointerHideTask?.cancel()
        annotationsHideTask?.cancel()
        userInkHideTask?.cancel()
        statusPillHideTask?.cancel()
    }

    private func delayedTask(seconds: TimeInterval, perform action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// The screen under the mouse right now. Read once when a turn starts to
    /// pick where the pill appears — never tracked continuously.
    private static func screenFrameContainingMouse() -> CGRect? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }?.frame ?? NSScreen.main?.frame
    }
}
