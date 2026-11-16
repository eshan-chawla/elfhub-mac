//
//  GuidedTutorialController.swift
//  elfhub
//
//  The optional walkthrough offered at the end of onboarding ("Start tutorial",
//  checked by default) and from Settings. Each step asks the user to try one
//  thing for real — talk, get pointed at something, dismiss it, chat — and
//  completes by itself when it sees that happen on the event bus. Every step
//  can be skipped and the whole tutorial ended at any time.
//

import Combine
import Foundation

enum GuidedTutorialStep: String, CaseIterable, Identifiable {
    case pushToTalk
    case pointing
    case dismissWithEscape
    case textChat
    case screenActions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: return "Talk to elfhub"
        case .pointing: return "Let it point"
        case .dismissWithEscape: return "Clear the screen"
        case .textChat: return "Or type instead"
        case .screenActions: return "Let it act (optional)"
        }
    }

    func instruction(pushToTalkShortcutText: String) -> String {
        switch self {
        case .pushToTalk:
            return "Hold \(pushToTalkShortcutText), say \"hi, what can you do?\", then let go. elfhub answers out loud and in the pill at the top of your screen."
        case .pointing:
            return "Ask about something you can see, like \"where's the Apple menu?\" — a pointer appears right on it."
        case .dismissWithEscape:
            return "Press Esc. The pointer and any marks disappear. Esc also stops elfhub whenever it's listening, thinking, talking or acting for you."
        case .textChat:
            return "Open Chat in the sidebar and send a message. Chats are saved only on this Mac."
        case .screenActions:
            return "In Settings › Controls you can let elfhub click and type for you. It always shows where it will act first, asks before anything risky, and stops the moment you press Esc or touch the mouse."
        }
    }

    /// Steps that complete when the user reads them, not by doing something.
    var completesOnAcknowledgement: Bool {
        self == .screenActions
    }

    /// The short line shown in the on-screen status pill for this step.
    func statusPillHint(pushToTalkShortcutText: String) -> String? {
        switch self {
        case .pushToTalk: return "hold \(pushToTalkShortcutText) and say hi"
        case .pointing: return "ask: where's the apple menu?"
        case .dismissWithEscape: return "press esc to clear the pointer"
        case .textChat, .screenActions: return nil
        }
    }
}

@MainActor
final class GuidedTutorialController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var steps: [GuidedTutorialStep] = []
    @Published private(set) var currentStepIndex = 0
    @Published private(set) var completedSteps: Set<GuidedTutorialStep> = []
    /// True after the last step, until the user closes the tutorial.
    @Published private(set) var isFinished = false

    /// Shows a hint in the on-screen status pill.
    var showStatusPillHint: ((String) -> Void)?
    /// Current push-to-talk shortcut, read when instructions are shown.
    var pushToTalkShortcutText: () -> String = { BuddyPushToTalkShortcut.pushToTalkDisplayText }

    private var eventSubscription: AnyCancellable?

    init(companionEventBus: CompanionEventBus) {
        eventSubscription = companionEventBus.events.sink { [weak self] companionEvent in
            self?.handle(companionEvent)
        }
    }

    var currentStep: GuidedTutorialStep? {
        guard isActive, !isFinished, steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var isCurrentStepComplete: Bool {
        guard let currentStep else { return false }
        return completedSteps.contains(currentStep)
    }

    /// Starts from the first step. Voice and pointing steps are left out when
    /// they can't work with the user's setup (text-only input, or a model
    /// that can't see the screen).
    func start(includesVoiceStep: Bool, includesPointingSteps: Bool) {
        steps = GuidedTutorialStep.allCases.filter { tutorialStep in
            switch tutorialStep {
            case .pushToTalk: return includesVoiceStep
            case .pointing, .dismissWithEscape: return includesPointingSteps
            case .textChat, .screenActions: return true
            }
        }
        completedSteps = []
        currentStepIndex = 0
        isFinished = false
        isActive = true
        showHintForCurrentStep()
    }

    func goToNextStep() {
        guard isActive else { return }
        if currentStepIndex + 1 < steps.count {
            currentStepIndex += 1
            showHintForCurrentStep()
        } else {
            isFinished = true
        }
    }

    func skipCurrentStep() {
        goToNextStep()
    }

    func acknowledgeCurrentStep() {
        guard let currentStep else { return }
        completedSteps.insert(currentStep)
        goToNextStep()
    }

    func endTutorial() {
        isActive = false
        isFinished = false
        steps = []
        completedSteps = []
        currentStepIndex = 0
    }

    // MARK: - Progress signals

    /// A push-to-talk transcript arrived (called by CompanionManager).
    func noteVoiceTranscriptReceived() {
        markCompleted(.pushToTalk)
    }

    /// A chat message was sent (called by CompanionManager).
    func noteChatMessageSent() {
        markCompleted(.textChat)
    }

    private func handle(_ companionEvent: CompanionEvent) {
        guard isActive else { return }
        switch companionEvent {
        case let .guidancePlaced(pointer, annotations):
            if pointer != nil || !annotations.isEmpty {
                markCompleted(.pointing)
            }
        case .allGuidanceDismissed:
            // Esc only counts once there was something to dismiss.
            if completedSteps.contains(.pointing) {
                markCompleted(.dismissWithEscape)
            }
        default:
            break
        }
    }

    private func markCompleted(_ tutorialStep: GuidedTutorialStep) {
        guard isActive, steps.contains(tutorialStep) else { return }
        completedSteps.insert(tutorialStep)
    }

    private func showHintForCurrentStep() {
        guard let currentStep, let statusPillHint = currentStep.statusPillHint(pushToTalkShortcutText: pushToTalkShortcutText()) else { return }
        showStatusPillHint?(statusPillHint)
    }
}
