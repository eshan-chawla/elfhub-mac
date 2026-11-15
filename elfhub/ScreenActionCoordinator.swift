//
//  ScreenActionCoordinator.swift
//  elfhub
//
//  Owns everything about elfhub actually acting on screen, so CompanionManager
//  stays a thin router. Holds the action-mode preferences, resolves each
//  action against the real UI, runs the consent gate, and drives the real
//  event posting via ScreenActionSynthesizer.
//
//  Consent model:
//   - Context is not consent: this coordinator is only ever handed actions when
//     action mode is on (CompanionManager only includes the action instructions
//     in the prompt then), and ConsentPolicy scopes each action to the user's
//     own words.
//   - Risk is judged from the REAL target (Accessibility title, password
//     fields, default buttons, the web page) and the frontmost app — never
//     from the label the model wrote, which on-screen text could manipulate.
//   - Approval is bound to what was shown: every action is re-checked against
//     the screen right before it fires. If the first target is no longer the
//     element the user approved, nothing fires; if an action turns out riskier
//     than when it was approved (an earlier click moved focus into Terminal),
//     the chain pauses and asks again.
//   - Show, then do: every targeted action is previewed with the pointer at
//     the exact spot before it fires.
//   - The user can always stop it: Esc (consumed) or simply touching the
//     mouse/keyboard halts the chain before the next event.
//   - Only the newest turn may act: starting a turn (voice or typed) stops
//     the previous chain and drops its pending card, and a turn that finishes
//     after a newer one started can't arm actions.
//   - Denial is a message, not an error: cancelling speaks what elfhub would
//     have done and never silently retries.
//   - Every decision and outcome is written to the local action log
//     (ComputerUseAuditLog), which never leaves the Mac.
//
//  Side effects it can't own (overlay events, speaking) are injected as
//  closures by CompanionManager, keeping this type free of overlay/TTS details.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

enum ScreenActionExecutionMode: String {
    /// Every turn shows a consent card before anything fires. Default.
    case confirmEachAction
    /// Standing per-session grant; fires without a card except for actions
    /// ConsentPolicy says need an explicit yes.
    case autoFire
}

/// Who or what allowed a chain of actions to run, recorded with every action
/// in the local action log.
enum ScreenActionApprovalProvenance: String, Codable {
    case userClickedConfirm
    case userSaidYes
    case userTypedYes
    case autoFireMode
}

/// Identifies one turn, so only the newest turn's actions may run.
typealias ScreenActionTurnToken = UUID

/// What happened to one action in a multi-step run.
enum ComputerUseActionOutcome: Equatable {
    case performed
    /// Not carried out, for a reason the model can work around (a key it
    /// couldn't press, the screen changed while waiting for the user).
    case notPerformed(reason: String)
    /// The user said no, or didn't answer in time: the run ends.
    case declinedByUser
    /// Esc, the user grabbing the mouse or keyboard, or a newer turn: the run ends.
    case stoppedByUser
    /// The user's own step (a password, a private app), or acting isn't
    /// possible right now: the run ends and the reason is said.
    case handedToUser(reason: String)

    var endsTheRun: Bool {
        switch self {
        case .performed, .notPerformed: return false
        case .declinedByUser, .stoppedByUser, .handedToUser: return true
        }
    }
}

/// What the user has allowed so far in one multi-step run: once they've
/// said go, ordinary steps in the same apps don't ask again; a step into
/// another app, or one ConsentPolicy says needs an explicit yes, still does.
@MainActor
final class ComputerUseRunApproval {
    /// A background task's run always shows the card before its first
    /// step, whatever the mode: it starts while the user may be doing
    /// something else.
    let asksBeforeFirstStep: Bool
    private(set) var approvalProvenance: ScreenActionApprovalProvenance?

    init(asksBeforeFirstStep: Bool = false) {
        self.asksBeforeFirstStep = asksBeforeFirstStep
    }
    private(set) var approvedApplicationBundleIdentifiers: Set<String> = []

    var isApproved: Bool { approvalProvenance != nil }

    func recordApproval(_ provenance: ScreenActionApprovalProvenance, applicationBundleIdentifier: String?) {
        if approvalProvenance == nil {
            approvalProvenance = provenance
        }
        if let applicationBundleIdentifier {
            approvedApplicationBundleIdentifiers.insert(applicationBundleIdentifier)
        }
    }

    func coversApplication(_ applicationBundleIdentifier: String?) -> Bool {
        guard let applicationBundleIdentifier else { return true }
        return approvedApplicationBundleIdentifiers.contains(applicationBundleIdentifier)
    }
}

/// One action with everything resolved before anything fires: where it lands,
/// what real element is there, and how much consent it needs.
struct ResolvedScreenAction {
    let action: CompanionScreenAction
    /// Where events are posted (Core Graphics global), snapped to the real
    /// control when Accessibility found one. Nil for type/key.
    let coreGraphicsTargetPoint: CGPoint?
    /// The same target in AppKit global coordinates, for the pointer preview.
    let appKitTargetPoint: CGPoint?
    let displayFrame: CGRect?
    /// The element the action lands on: under the target point for
    /// click/scroll, the focused element for type/key.
    let targetElementFacts: AccessibilityElementFacts?
    let frontmostApplicationBundleIdentifier: String?
    let consentDecision: ScreenActionConsentDecision
    /// The consequential effect (send, delete, …), if any — used to word the
    /// confirmation and to require the verb in a spoken yes.
    let consequentialEffect: ConsentSensitiveEffect?
    /// Where a drag lets go (Core Graphics global); nil for everything else.
    var coreGraphicsDragEndPoint: CGPoint? = nil
    /// What a drag would drop onto, when known.
    var dragDropTargetElementFacts: AccessibilityElementFacts? = nil
    /// The app an open step brings up (the app itself, or the browser a
    /// website opens in) — that's the app the step works in.
    var openedApplicationBundleIdentifier: String? = nil

    /// Plain-English description for the consent card and narration. Prefers
    /// the real element's title over the model's label.
    var humanReadableDescription: String {
        Self.description(of: action, targetName: targetElementFacts?.title.map { "“\($0)”" })
    }

    /// Prefers the real element's title over the model's label; keys held
    /// are named in front ("cmd+drag “Budget.numbers”").
    private static func description(of action: CompanionScreenAction, targetName: String?) -> String {
        switch action {
        case let .click(_, label, _):
            return "click " + (targetName ?? label.map { "the \($0)" } ?? "here")
        case let .doubleClick(_, label, _):
            return "double-click " + (targetName ?? label.map { "the \($0)" } ?? "here")
        case let .rightClick(_, label, _):
            return "right-click " + (targetName ?? label.map { "the \($0)" } ?? "here")
        case let .tripleClick(_, label, _):
            return "triple-click " + (targetName ?? label.map { "the \($0)" } ?? "here")
        case .drag:
            return "drag " + (targetName ?? "from here")
        case let .withModifierKeys(modifierNames, innerAction):
            return modifierNames.joined(separator: "+") + "+" + description(of: innerAction, targetName: targetName)
        default:
            return action.humanReadableDescription
        }
    }

    var requiresExplicitConfirmation: Bool {
        if case .requiresExplicitConfirmation = consentDecision { return true }
        return false
    }

    /// True when the element under the target is still the one that was
    /// shown to the user: same role, title and app. Keystroke actions have
    /// no target point, so they always match here (they're re-judged by the
    /// focused element instead).
    func targetsSameElement(as shownResolvedAction: ResolvedScreenAction) -> Bool {
        guard appKitTargetPoint != nil || shownResolvedAction.appKitTargetPoint != nil else { return true }
        let currentFacts = targetElementFacts
        let shownFacts = shownResolvedAction.targetElementFacts
        if currentFacts == nil && shownFacts == nil { return true }
        guard let currentFacts, let shownFacts else { return false }
        return currentFacts.role == shownFacts.role
            && currentFacts.title == shownFacts.title
            && currentFacts.owningApplicationBundleIdentifier == shownFacts.owningApplicationBundleIdentifier
    }
}

/// A set of actions waiting on the user's explicit go-ahead. Rendered by the
/// consent card in the menu bar panel.
struct PendingScreenActionConsent: Identifiable, Equatable {
    let id = UUID()
    let resolvedActions: [ResolvedScreenAction]
    /// One-line plain-English summary, e.g. "click “Save”, then press cmd+s".
    let summary: String
    /// True when at least one action is consequential (send, delete, …).
    let includesHighRiskAction: Bool
    /// The screenshots the actions' coordinates refer to, kept so every
    /// action can be re-checked against the live screen when it fires.
    let screenCaptures: [CompanionScreenCapture]
    /// What the user asked for, which scopes what they authorized.
    let userUtterance: String

    /// Consequential effects in this batch that still need the user's
    /// explicit yes. A spoken yes must name one of them ("yes, send it").
    var confirmationEffects: [ConsentSensitiveEffect] {
        var uniqueEffects: [ConsentSensitiveEffect] = []
        for resolvedAction in resolvedActions where resolvedAction.requiresExplicitConfirmation {
            if let effect = resolvedAction.consequentialEffect, !uniqueEffects.contains(effect) {
                uniqueEffects.append(effect)
            }
        }
        return uniqueEffects
    }

    /// Words that name those effects, for SpokenConfirmationParser.
    var requiredConfirmationVerbKeywords: [String] {
        confirmationEffects.flatMap { ConsentPolicy.utteranceKeywordsByEffect[$0] ?? [] }
    }

    static func == (lhs: PendingScreenActionConsent, rhs: PendingScreenActionConsent) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ScreenActionCoordinator: ObservableObject {

    // MARK: - Injected side effects

    /// Sends overlay events (pointer previews, acting state) to the event bus.
    var emitCompanionEvent: ((CompanionEvent) -> Void)?
    /// Speaks a short line through the normal TTS path.
    var speak: ((String) -> Void)?
    /// Live Accessibility check; posting synthetic events is impossible without it.
    var hasAccessibilityPermission: (() -> Bool)?

    // MARK: - Preferences (persisted)

    @Published private(set) var isActionModeEnabled: Bool =
        UserDefaults.standard.bool(forKey: ScreenActionCoordinator.actionModeEnabledKey)

    @Published private(set) var executionMode: ScreenActionExecutionMode = {
        let stored = UserDefaults.standard.string(forKey: ScreenActionCoordinator.executionModeKey)
        return stored.flatMap(ScreenActionExecutionMode.init(rawValue:)) ?? .confirmEachAction
    }()

    private static let actionModeEnabledKey = "isScreenActionModeEnabled"
    private static let executionModeKey = "screenActionExecutionMode"

    func setActionModeEnabled(_ enabled: Bool) {
        isActionModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.actionModeEnabledKey)
        if !enabled {
            cancelPendingActions(speakDenial: false)
            stopRunningActions(spokenReason: nil)
        }
    }

    func setExecutionMode(_ mode: ScreenActionExecutionMode) {
        executionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.executionModeKey)
    }

    // MARK: - Pending consent state (drives the consent card)

    @Published private(set) var pendingConsent: PendingScreenActionConsent?

    /// Auto-cancels a consent card the user never answers, so a stale prompt
    /// doesn't fire much later against a screen that has since changed.
    private var pendingConsentTimeoutTask: Task<Void, Never>?
    /// Set while a multi-step run waits on the consent card: confirming or
    /// cancelling answers the run instead of firing a stored chain.
    private var pendingRunApprovalContinuation: CheckedContinuation<ScreenActionApprovalProvenance?, Never>?
    /// Where the pointer was when the current run started, so it goes back
    /// there at the end if the user hasn't moved it.
    private var pointerLocationBeforeComputerUseRun: CGPoint?
    private var isFiringComputerUseRunStep = false
    /// The last run step fired, in words naming the real element — for the
    /// conversation history (typed text is replaced there by its length).
    private(set) var lastFiredActionDescription: String?
    /// The run in progress; an older run finishing late can't end it.
    private var currentComputerUseRunIdentifier: UUID?
    /// When the run's last step ended (or the user last okayed one): input
    /// from the user after this means they've taken over.
    private var computerUseRunLastStepEndedAt: Date?

    /// True from the start of a multi-step run to its end, including while
    /// the model thinks between steps — so Esc is watched the whole time.
    @Published private(set) var isComputerUseRunActive = false
    /// True while a multi-step run is paused for the user's yes or no — a
    /// push-to-talk then answers it rather than cancelling the run.
    var isComputerUseRunAwaitingApproval: Bool { pendingRunApprovalContinuation != nil }
    private static let pendingConsentTimeout: TimeInterval = 20

    // MARK: - Execution state

    @Published private(set) var isRunningActions = false
    private var isStopRequested = false
    private var actionExecutionTask: Task<Void, Never>?
    private let userInterruptionMonitor = UserInterruptionMonitor()

    /// The newest turn. Only its actions may be armed or fired.
    private var currentTurnToken: ScreenActionTurnToken?

    /// How long the pointer sits on a target before the action fires, so the
    /// user always sees where it will land.
    private static let previewBeforeFiringNanoseconds: UInt64 = 350_000_000
    /// Gap between chained actions so the target UI can settle.
    private static let gapBetweenActionsNanoseconds: UInt64 = 150_000_000

    // MARK: - Turns

    /// Called when a turn (voice or typed) starts. Stops whatever the
    /// previous turn was doing, drops its unanswered card, and makes this the
    /// only turn whose actions may run — so a voice turn and a chat turn that
    /// overlap can never both act.
    func beginTurn() -> ScreenActionTurnToken {
        cancelPendingActions(speakDenial: false)
        stopRunningActions(spokenReason: nil)
        let turnToken = ScreenActionTurnToken()
        currentTurnToken = turnToken
        return turnToken
    }

    // MARK: - Arming

    /// Entry point after a reply is decoded. Resolves each action against the
    /// real UI, applies ConsentPolicy, then fires (auto-fire, nothing
    /// consequential) or arms the consent card. Returns true if it took
    /// ownership of these actions.
    @discardableResult
    func handleParsedActions(
        _ actions: [CompanionScreenAction],
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String,
        turnToken: ScreenActionTurnToken
    ) async -> Bool {
        guard isActionModeEnabled, !actions.isEmpty else { return false }
        guard turnToken == currentTurnToken else {
            print("🛑 Screen actions: ignoring actions from a turn that a newer turn replaced")
            return false
        }

        guard hasAccessibilityPermission?() == true else {
            speak?("i'd need accessibility permission to actually do that. you can turn it on from my menu bar panel.")
            return true
        }

        let resolvedActions = await resolve(actions, screenCaptures: screenCaptures, userUtterance: userUtterance)
        // A newer turn may have started while the Accessibility lookups ran.
        guard turnToken == currentTurnToken else { return false }

        // Anything that's the user's own step blocks the whole batch: acting
        // halfway (e.g. clicking into a password field, then stopping) is worse
        // than not acting.
        for resolvedAction in resolvedActions {
            if case let .usersStep(reason) = resolvedAction.consentDecision {
                previewTarget(of: resolvedAction)
                speak?(reason)
                recordAuditEntry(for: resolvedAction, approvalProvenance: nil, outcome: .handedToUser)
                return true
            }
        }

        let includesHighRisk = resolvedActions.contains { $0.requiresExplicitConfirmation }

        if executionMode == .autoFire && !includesHighRisk {
            fireActions(
                resolvedActions,
                screenCaptures: screenCaptures,
                userUtterance: userUtterance,
                approvalProvenance: .autoFireMode
            )
            return true
        }

        armPendingConsent(
            resolvedActions: resolvedActions,
            screenCaptures: screenCaptures,
            userUtterance: userUtterance,
            spokenIntroduction: nil
        )
        return true
    }

    /// Shows the consent card for these actions and asks out loud.
    private func armPendingConsent(
        resolvedActions: [ResolvedScreenAction],
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String,
        spokenIntroduction: String?
    ) {
        let newPendingConsent = PendingScreenActionConsent(
            resolvedActions: resolvedActions,
            summary: summarize(resolvedActions),
            includesHighRiskAction: resolvedActions.contains { $0.requiresExplicitConfirmation },
            screenCaptures: screenCaptures,
            userUtterance: userUtterance
        )
        pendingConsent = newPendingConsent
        if let firstTargetedAction = resolvedActions.first(where: { $0.appKitTargetPoint != nil }) {
            previewTarget(of: firstTargetedAction)
        }

        let request: String
        if let firstConfirmationEffect = newPendingConsent.confirmationEffects.first {
            // Consequential: a reflexive "yes" isn't enough, the verb must be said back.
            request = "i can \(newPendingConsent.summary). that would \(firstConfirmationEffect.spokenVerb) something, so say \"yes, \(firstConfirmationEffect.spokenVerb) it\" or hit confirm."
        } else if newPendingConsent.includesHighRiskAction {
            request = "i can \(newPendingConsent.summary). say go or hit confirm and i'll do it. this one's a bigger deal, so double check."
        } else {
            request = "i can \(newPendingConsent.summary). say go or hit confirm and i'll do it."
        }
        speak?((spokenIntroduction ?? "") + request)

        startPendingConsentTimeout(for: newPendingConsent.id)
    }

    private func startPendingConsentTimeout(for consentID: UUID?) {
        pendingConsentTimeoutTask?.cancel()
        pendingConsentTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.pendingConsentTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only cancel if it's still the SAME pending card (the user didn't
            // already confirm/cancel or arm a newer one).
            guard pendingConsent?.id == consentID else { return }
            // A run waiting on this card stops; say so rather than go quiet.
            if pendingRunApprovalContinuation != nil {
                speak?("i didn't hear a yes, so i stopped there.")
            }
            cancelPendingActions(speakDenial: false)
        }
    }

    // MARK: - Confirm / Cancel

    /// Called by the consent card's Confirm button, or when the user says
    /// "go" (for a consequential action: "yes, send it"). The actions are
    /// re-checked against the live screen as they fire.
    func confirmPendingActions(approvalProvenance: ScreenActionApprovalProvenance = .userClickedConfirm) {
        guard let pendingConsent else { return }
        if let pendingRunApprovalContinuation {
            self.pendingRunApprovalContinuation = nil
            clearPending()
            pendingRunApprovalContinuation.resume(returning: approvalProvenance)
            return
        }
        clearPending()
        fireActions(
            pendingConsent.resolvedActions,
            screenCaptures: pendingConsent.screenCaptures,
            userUtterance: pendingConsent.userUtterance,
            approvalProvenance: approvalProvenance
        )
    }

    /// The user said a bare "yes" to a consequential action. Ask them to name
    /// it, and give them the full time again to answer.
    func askToRestateConsequentialVerb() {
        guard let pendingConsent else { return }
        let verb = pendingConsent.confirmationEffects.first?.spokenVerb ?? "do"
        speak?("just to be sure, say \"\(verb) it\" and i'll do it, or say no.")
        startPendingConsentTimeout(for: pendingConsent.id)
    }

    /// Called by the consent card's Cancel button, a new push-to-talk, or a
    /// timeout. When speakDenial is true, speaks what elfhub would have done —
    /// denial is a message, not an error. Pass false
    /// when the user is simply moving on to a new request or turning the mode off.
    func cancelPendingActions(reason: String? = nil, speakDenial: Bool = true) {
        guard let pendingConsent else {
            clearPending()
            return
        }
        if speakDenial {
            speak?(reason ?? "okay, i won't. i was going to \(pendingConsent.summary).")
        }
        for resolvedAction in pendingConsent.resolvedActions {
            recordAuditEntry(for: resolvedAction, approvalProvenance: nil, outcome: .declinedOrDropped)
        }
        clearPending()
        if let pendingRunApprovalContinuation {
            self.pendingRunApprovalContinuation = nil
            pendingRunApprovalContinuation.resume(returning: nil)
        }
    }

    private func clearPending() {
        pendingConsentTimeoutTask?.cancel()
        pendingConsentTimeoutTask = nil
        pendingConsent = nil
    }

    // MARK: - Execution

    /// Halts a running action chain before its next event. Called on Esc,
    /// when the user grabs the mouse/keyboard, or when a new turn starts.
    func stopRunningActions(spokenReason: String?) {
        guard isRunningActions, !isStopRequested else { return }
        isStopRequested = true
        if let spokenReason {
            speak?(spokenReason)
        }
    }

    /// Fires the approved actions in order. Each one is re-resolved against
    /// the live screen first, because earlier actions (and time) change what
    /// is under the pointer and which app has focus.
    private func fireActions(
        _ approvedActions: [ResolvedScreenAction],
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String,
        approvalProvenance: ScreenActionApprovalProvenance
    ) {
        guard hasAccessibilityPermission?() == true else { return }

        // One chain at a time, and the newest wins. A chain that was just told
        // to stop (beginTurn does that) may still be finishing its current
        // step, so the new chain waits for it instead of being dropped.
        let previousActionExecutionTask = actionExecutionTask
        stopRunningActions(spokenReason: nil)

        actionExecutionTask = Task { @MainActor in
            await previousActionExecutionTask?.value
            await runActionChain(
                approvedActions,
                screenCaptures: screenCaptures,
                userUtterance: userUtterance,
                approvalProvenance: approvalProvenance
            )
        }
    }

    /// Runs one approved chain from start to finish. Only ever runs after the
    /// previous chain has fully ended (see fireActions).
    private func runActionChain(
        _ approvedActions: [ResolvedScreenAction],
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String,
        approvalProvenance: ScreenActionApprovalProvenance
    ) async {
        isStopRequested = false
        isRunningActions = true
        emitCompanionEvent?(.actionsStarted(summary: summarize(approvedActions)))

        userInterruptionMonitor.onEscapePressed = { [weak self] in
            self?.stopRunningActions(spokenReason: "stopped.")
        }
        userInterruptionMonitor.onUserTookControl = { [weak self] in
            self?.stopRunningActions(spokenReason: "okay, you've got it.")
        }
        userInterruptionMonitor.start(mode: .stopActionsOnEscapeOrUserInput)

        // The pointer goes back here afterwards if the user hasn't touched it,
        // so elfhub borrowing the mouse doesn't leave it somewhere unexpected.
        let pointerLocationBeforeChain = ScreenActionSynthesizer.currentPointerLocation()

        var actionsNeedingFreshApproval: [ResolvedScreenAction] = []

        for (actionIndex, approvedAction) in approvedActions.enumerated() {
            if isStopRequested {
                recordAuditEntry(for: approvedAction, approvalProvenance: approvalProvenance, outcome: .stoppedByUser)
                break
            }

            let currentAction = await resolveSingleAction(
                approvedAction.action,
                screenCaptures: screenCaptures,
                userUtterance: userUtterance
            )
            if isStopRequested {
                recordAuditEntry(for: currentAction, approvalProvenance: approvalProvenance, outcome: .stoppedByUser)
                break
            }

            // The first target is the one the user saw and approved. If
            // something else is under the pointer now, don't fire.
            if actionIndex == 0 && !currentAction.targetsSameElement(as: approvedAction) {
                speak?("the screen changed since i checked, so i stopped before doing anything. ask me again if you still want it.")
                recordAuditEntry(for: currentAction, approvalProvenance: approvalProvenance, outcome: .screenChanged)
                break
            }

            if case let .usersStep(reason) = currentAction.consentDecision {
                previewTarget(of: currentAction)
                speak?(reason)
                recordAuditEntry(for: currentAction, approvalProvenance: approvalProvenance, outcome: .handedToUser)
                break
            }

            // Riskier than when it was approved: pause and ask again for
            // this action and everything after it.
            if ConsentPolicy.requiresFreshApproval(
                approvedDecision: approvedAction.consentDecision,
                currentDecision: currentAction.consentDecision
            ) {
                actionsNeedingFreshApproval = [currentAction] + approvedActions.dropFirst(actionIndex + 1)
                recordAuditEntry(for: currentAction, approvalProvenance: approvalProvenance, outcome: .pausedForFreshApproval)
                break
            }

            // Show, then do: the pointer lands on the exact target first.
            if currentAction.appKitTargetPoint != nil {
                previewTarget(of: currentAction)
                try? await Task.sleep(nanoseconds: Self.previewBeforeFiringNanoseconds)
                if isStopRequested {
                    recordAuditEntry(for: currentAction, approvalProvenance: approvalProvenance, outcome: .stoppedByUser)
                    break
                }
            }

            let didPerformAction = await perform(currentAction)
            recordAuditEntry(
                for: currentAction,
                approvalProvenance: approvalProvenance,
                outcome: didPerformAction ? .performed : .notPerformed
            )
            guard didPerformAction else { break }

            try? await Task.sleep(nanoseconds: Self.gapBetweenActionsNanoseconds)
        }

        let wasStoppedByUser = isStopRequested
        if let pointerLocationBeforeChain {
            ScreenActionSynthesizer.restorePointerIfUntouched(to: pointerLocationBeforeChain)
        }
        userInterruptionMonitor.stop()
        isRunningActions = false
        isStopRequested = false
        emitCompanionEvent?(.actionsFinished)

        if !actionsNeedingFreshApproval.isEmpty && !wasStoppedByUser {
            armPendingConsent(
                resolvedActions: actionsNeedingFreshApproval,
                screenCaptures: screenCaptures,
                userUtterance: userUtterance,
                spokenIntroduction: "before i keep going: "
            )
        }
    }

    /// Posts the real events for one action. Returns false if the chain
    /// should stop (e.g. typing would go into a password field).
    private func perform(_ resolvedAction: ResolvedScreenAction) async -> Bool {
        await perform(resolvedAction.action, of: resolvedAction, mayPressWithAccessibility: true)
    }

    /// `action` is the resolved action's own, or (keys held) the action
    /// inside it; Accessibility presses ignore held keys, so they're off then.
    private func perform(_ action: CompanionScreenAction, of resolvedAction: ResolvedScreenAction, mayPressWithAccessibility: Bool) async -> Bool {
        switch action {
        case let .withModifierKeys(modifierNames, innerAction):
            // Keys are only ever held around a click, drag or scroll.
            guard action.isPointerActionWithKeysHeld else { return false }
            return await ScreenActionSynthesizer.performWithModifierKeysHeld(modifierNames) {
                await perform(innerAction, of: resolvedAction, mayPressWithAccessibility: false)
            }
        case .click:
            guard let coreGraphicsTargetPoint = resolvedAction.coreGraphicsTargetPoint else { return false }
            // Most precise channel first: a native button is pressed through
            // Accessibility (no pointer move, no focus steal). If that isn't
            // possible, a real click does it.
            if mayPressWithAccessibility,
               AccessibilityElementActions.shouldPressWithAccessibility(resolvedAction.targetElementFacts),
               await AccessibilityElementActions.pressElement(
                   atCoreGraphicsGlobalPoint: coreGraphicsTargetPoint,
                   expectedRole: resolvedAction.targetElementFacts?.role,
                   expectedTitle: resolvedAction.targetElementFacts?.title
               ) {
                return true
            }
            await ScreenActionSynthesizer.performSingleClick(at: coreGraphicsTargetPoint)
        case .doubleClick:
            guard let coreGraphicsTargetPoint = resolvedAction.coreGraphicsTargetPoint else { return false }
            await ScreenActionSynthesizer.performDoubleClick(at: coreGraphicsTargetPoint)
        case let .scroll(_, direction, _, amountInTenthsOfScreen):
            guard let coreGraphicsTargetPoint = resolvedAction.coreGraphicsTargetPoint else { return false }
            let displayHeightInPoints = resolvedAction.displayFrame?.height ?? CGDisplayBounds(CGMainDisplayID()).height
            await ScreenActionSynthesizer.performScroll(
                at: coreGraphicsTargetPoint,
                direction: direction,
                distanceInPoints: ScreenActionSynthesizer.scrollDistanceInPoints(
                    amountInTenthsOfScreen: amountInTenthsOfScreen,
                    displayHeightInPoints: displayHeightInPoints
                ),
                shouldContinue: { [weak self] in !(self?.isStopRequested ?? true) }
            )
        case let .type(text):
            // Focus is only known now (an earlier click may have moved it), so
            // the password rules are re-checked at the moment of typing.
            if IsSecureEventInputEnabled() {
                speak?("secure keyboard entry is on right now, usually because a password field is active, so please type that part yourself.")
                return false
            }
            let focusedElementFacts = await AccessibilityElementLocator.focusedElementFacts()
            if focusedElementFacts?.isSecureTextField == true {
                speak?("that's a password field, so please fill it in yourself.")
                return false
            }
            // Long text goes into a native field in one step; anything else
            // (or a field that refuses) is typed character by character.
            if AccessibilityElementActions.shouldInsertTextWithAccessibility(text, into: focusedElementFacts),
               await AccessibilityElementActions.insertTextIntoFocusedElement(text) {
                return true
            }
            return await ScreenActionSynthesizer.typeText(text, shouldContinue: { [weak self] in
                !(self?.isStopRequested ?? true)
            })
        case let .key(comboString):
            let didPressKeyCombo = await ScreenActionSynthesizer.performKeyCombo(comboString: comboString)
            if !didPressKeyCombo {
                // In a run the model hears about it in the step's result
                // and can try another way.
                if !isFiringComputerUseRunStep {
                    speak?("i couldn't work out how to press \(comboString), so i stopped there.")
                }
                return false
            }
        case .rightClick:
            guard let coreGraphicsTargetPoint = resolvedAction.coreGraphicsTargetPoint else { return false }
            await ScreenActionSynthesizer.performRightClick(at: coreGraphicsTargetPoint)
        case .tripleClick:
            guard let coreGraphicsTargetPoint = resolvedAction.coreGraphicsTargetPoint else { return false }
            await ScreenActionSynthesizer.performTripleClick(at: coreGraphicsTargetPoint)
        case .drag:
            guard let coreGraphicsStartPoint = resolvedAction.coreGraphicsTargetPoint,
                  let coreGraphicsEndPoint = resolvedAction.coreGraphicsDragEndPoint else { return false }
            await ScreenActionSynthesizer.performDrag(from: coreGraphicsStartPoint, to: coreGraphicsEndPoint, shouldContinue: { [weak self] in
                !(self?.isStopRequested ?? true)
            })
        case .moveMouse:
            guard let coreGraphicsTargetPoint = resolvedAction.coreGraphicsTargetPoint else { return false }
            ScreenActionSynthesizer.movePointer(to: coreGraphicsTargetPoint)
        case let .openApplication(name):
            return await ApplicationLocator.openApplication(named: name)
        case let .openWebsite(url):
            return await ApplicationLocator.openWebsite(url)
        }
        return true
    }

    // MARK: - Multi-step runs (computer use)

    /// Called when a multi-step run starts: remembers where the pointer is.
    /// Returns the run's identifier, which `finishComputerUseRun` needs.
    @discardableResult
    func beginComputerUseRun(watchesForTakeoverFromStart: Bool = false) -> UUID {
        let runIdentifier = UUID()
        currentComputerUseRunIdentifier = runIdentifier
        pointerLocationBeforeComputerUseRun = ScreenActionSynthesizer.currentPointerLocation()
        // Moving the mouse after asking, before elfhub has acted, is normal;
        // only input after a step counts as taking over. A background
        // task's run starts on its own, so the user's input counts from
        // the start.
        computerUseRunLastStepEndedAt = watchesForTakeoverFromStart ? Date() : nil
        isComputerUseRunActive = true
        return runIdentifier
    }

    /// Called when the run ends however it ends: the pointer goes back if
    /// the user hasn't touched it, and the pill stops saying it's acting.
    /// Does nothing for a run a newer one replaced.
    func finishComputerUseRun(_ runIdentifier: UUID, didTryToAct: Bool = true) {
        guard runIdentifier == currentComputerUseRunIdentifier else { return }
        currentComputerUseRunIdentifier = nil
        computerUseRunLastStepEndedAt = nil
        isComputerUseRunActive = false
        if didTryToAct {
            if let pointerLocationBeforeComputerUseRun {
                ScreenActionSynthesizer.restorePointerIfUntouched(to: pointerLocationBeforeComputerUseRun)
            }
            emitCompanionEvent?(.actionsFinished)
        }
        pointerLocationBeforeComputerUseRun = nil
    }

    /// Esc: every run on the screen stops before its next step (a waiting
    /// card is dropped). Later turns get a new token from beginTurn.
    func stopComputerUseRuns() {
        guard isComputerUseRunActive || pendingRunApprovalContinuation != nil else { return }
        cancelPendingActions(speakDenial: false)
        stopRunningActions(spokenReason: nil)
        currentTurnToken = nil
    }

    /// Whether the user used the mouse or keyboard after the run's last
    /// step ended. Events in the first moment after a step are elfhub's
    /// own still arriving, so they don't count.
    nonisolated static func userTookOverBetweenSteps(secondsSinceLastPhysicalInput: Double, secondsSinceLastStep: Double) -> Bool {
        let ownEventsSettlingSeconds = 0.25
        return secondsSinceLastPhysicalInput < secondsSinceLastStep - ownEventsSettlingSeconds
    }

    /// The same, read from the system now.
    private func userTookOverSinceLastComputerUseStep() -> Bool {
        guard let computerUseRunLastStepEndedAt, let anyInputEventType = CGEventType(rawValue: ~0) else { return false }
        let secondsSinceLastPhysicalInput = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
        return Self.userTookOverBetweenSteps(
            secondsSinceLastPhysicalInput: secondsSinceLastPhysicalInput,
            secondsSinceLastStep: Date().timeIntervalSince(computerUseRunLastStepEndedAt)
        )
    }

    /// One action of a multi-step run, resolved against the screen as it is
    /// now and judged like any other: the user's own step ends the run; an
    /// action ConsentPolicy flags, the first step (when every action needs
    /// a yes), and a step into an app the user hasn't okayed wait for the
    /// card; then it's previewed with the pointer and fired, stoppable with
    /// Esc or by touching the mouse or keyboard.
    func performActionInComputerUseRun(
        _ action: CompanionScreenAction,
        screenCapture: CompanionScreenCapture,
        userUtterance: String,
        turnToken: ScreenActionTurnToken,
        runApproval: ComputerUseRunApproval,
        stepDescription: String
    ) async -> ComputerUseActionOutcome {
        guard isActionModeEnabled else {
            return .handedToUser(reason: "acting on the screen is switched off.")
        }
        guard turnToken == currentTurnToken else { return .stoppedByUser }
        guard hasAccessibilityPermission?() == true else {
            return .handedToUser(reason: "i'd need accessibility permission to actually do that. you can turn it on from my menu bar panel.")
        }
        // The user moving the mouse or typing while the model was thinking
        // means they've taken over, just like during a step.
        if userTookOverSinceLastComputerUseStep() {
            speak?("okay, you've got it.")
            return .stoppedByUser
        }

        let screenCaptures = [screenCapture]
        var resolvedAction = await resolveSingleAction(action, screenCaptures: screenCaptures, userUtterance: userUtterance)
        guard turnToken == currentTurnToken, !Task.isCancelled else { return .stoppedByUser }

        if case let .usersStep(reason) = resolvedAction.consentDecision {
            previewTarget(of: resolvedAction)
            recordAuditEntry(for: resolvedAction, approvalProvenance: runApproval.approvalProvenance, outcome: .handedToUser)
            return .handedToUser(reason: reason)
        }

        let targetApplicationBundleIdentifier = resolvedAction.openedApplicationBundleIdentifier
            ?? resolvedAction.targetElementFacts?.owningApplicationBundleIdentifier
            ?? resolvedAction.frontmostApplicationBundleIdentifier
        // A drag into another app (onto the Dock's Trash, say) leaves too.
        let dropApplicationBundleIdentifier = resolvedAction.dragDropTargetElementFacts?.owningApplicationBundleIdentifier
        let stepLeavesApprovedApplications = runApproval.isApproved
            && (!runApproval.coversApplication(targetApplicationBundleIdentifier) || !runApproval.coversApplication(dropApplicationBundleIdentifier))
        let needsApproval = resolvedAction.requiresExplicitConfirmation
            || (!runApproval.isApproved && runApproval.asksBeforeFirstStep)
            || (executionMode == .confirmEachAction && (!runApproval.isApproved || stepLeavesApprovedApplications))

        if needsApproval {
            let approvalProvenance = await requestApprovalInComputerUseRun(
                for: resolvedAction,
                screenCaptures: screenCaptures,
                userUtterance: userUtterance,
                spokenIntroduction: stepLeavesApprovedApplications ? "this next step is in another app. " : nil
            )
            guard let approvalProvenance else { return .declinedByUser }
            guard turnToken == currentTurnToken, !Task.isCancelled else { return .stoppedByUser }
            runApproval.recordApproval(approvalProvenance, applicationBundleIdentifier: targetApplicationBundleIdentifier)
            runApproval.recordApproval(approvalProvenance, applicationBundleIdentifier: dropApplicationBundleIdentifier)
            // Clicking Confirm or holding push-to-talk to answer isn't taking over.
            if computerUseRunLastStepEndedAt != nil {
                computerUseRunLastStepEndedAt = Date()
            }

            // Approval is bound to what was shown: the target is checked
            // again now, since waiting for an answer takes time.
            let freshlyResolvedAction = await resolveSingleAction(action, screenCaptures: screenCaptures, userUtterance: userUtterance)
            guard freshlyResolvedAction.targetsSameElement(as: resolvedAction) else {
                recordAuditEntry(for: freshlyResolvedAction, approvalProvenance: approvalProvenance, outcome: .screenChanged)
                return .notPerformed(reason: "the screen changed while waiting for the user's okay, so nothing was done. take a new screenshot.")
            }
            if case let .usersStep(reason) = freshlyResolvedAction.consentDecision {
                recordAuditEntry(for: freshlyResolvedAction, approvalProvenance: approvalProvenance, outcome: .handedToUser)
                return .handedToUser(reason: reason)
            }
            resolvedAction = freshlyResolvedAction
        } else if !runApproval.isApproved {
            // Firing without a card: the standing "do it without asking" mode.
            runApproval.recordApproval(.autoFireMode, applicationBundleIdentifier: targetApplicationBundleIdentifier)
        } else {
            runApproval.recordApproval(runApproval.approvalProvenance ?? .autoFireMode, applicationBundleIdentifier: targetApplicationBundleIdentifier)
        }

        return await fireActionInComputerUseRun(
            resolvedAction,
            approvalProvenance: runApproval.approvalProvenance ?? .autoFireMode,
            stepDescription: stepDescription,
            turnToken: turnToken
        )
    }

    /// Shows the consent card for one run step and waits for the answer:
    /// the provenance of a yes, or nil for no, a timeout, a newer turn or
    /// the run being cancelled.
    private func requestApprovalInComputerUseRun(
        for resolvedAction: ResolvedScreenAction,
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String,
        spokenIntroduction: String?
    ) async -> ScreenActionApprovalProvenance? {
        guard !Task.isCancelled else { return nil }
        // An older card (a run can't have two) is dropped first.
        cancelPendingActions(speakDenial: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingRunApprovalContinuation = continuation
                armPendingConsent(
                    resolvedActions: [resolvedAction],
                    screenCaptures: screenCaptures,
                    userUtterance: userUtterance,
                    spokenIntroduction: spokenIntroduction
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingActions(speakDenial: false)
            }
        }
    }

    /// Previews and fires one approved run step with the stop monitor on.
    private func fireActionInComputerUseRun(
        _ resolvedAction: ResolvedScreenAction,
        approvalProvenance: ScreenActionApprovalProvenance,
        stepDescription: String,
        turnToken: ScreenActionTurnToken
    ) async -> ComputerUseActionOutcome {
        // A newer turn may have started during the Accessibility lookups.
        guard turnToken == currentTurnToken, !Task.isCancelled else { return .stoppedByUser }
        isStopRequested = false
        isRunningActions = true
        isFiringComputerUseRunStep = true
        emitCompanionEvent?(.actionsStarted(summary: stepDescription))
        userInterruptionMonitor.onEscapePressed = { [weak self] in
            self?.stopRunningActions(spokenReason: "stopped.")
        }
        userInterruptionMonitor.onUserTookControl = { [weak self] in
            self?.stopRunningActions(spokenReason: "okay, you've got it.")
        }
        userInterruptionMonitor.start(mode: .stopActionsOnEscapeOrUserInput)
        defer {
            userInterruptionMonitor.stop()
            isRunningActions = false
            isFiringComputerUseRunStep = false
            computerUseRunLastStepEndedAt = Date()
        }

        if resolvedAction.appKitTargetPoint != nil {
            previewTarget(of: resolvedAction)
            try? await Task.sleep(nanoseconds: Self.previewBeforeFiringNanoseconds)
        }
        if isStopRequested || Task.isCancelled || turnToken != currentTurnToken {
            recordAuditEntry(for: resolvedAction, approvalProvenance: approvalProvenance, outcome: .stoppedByUser)
            return .stoppedByUser
        }

        let didPerformAction = await perform(resolvedAction)
        lastFiredActionDescription = resolvedAction.humanReadableDescription
        if isStopRequested {
            recordAuditEntry(for: resolvedAction, approvalProvenance: approvalProvenance, outcome: .stoppedByUser)
            return .stoppedByUser
        }
        recordAuditEntry(
            for: resolvedAction,
            approvalProvenance: approvalProvenance,
            outcome: didPerformAction ? .performed : .notPerformed
        )
        return didPerformAction
            ? .performed
            : .notPerformed(reason: "\(resolvedAction.humanReadableDescription) didn't go through.")
    }

    // MARK: - Resolution

    private func resolve(
        _ actions: [CompanionScreenAction],
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String
    ) async -> [ResolvedScreenAction] {
        var resolvedActions: [ResolvedScreenAction] = []
        for action in actions {
            resolvedActions.append(await resolveSingleAction(action, screenCaptures: screenCaptures, userUtterance: userUtterance))
        }
        return resolvedActions
    }

    /// Resolves one action against the screen as it is right now: where it
    /// lands, which real element is there (or has keyboard focus, for
    /// keystrokes), which app is in front, and how much consent it needs.
    private func resolveSingleAction(
        _ action: CompanionScreenAction,
        screenCaptures: [CompanionScreenCapture],
        userUtterance: String
    ) async -> ResolvedScreenAction {
        let frontmostApplicationBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var coreGraphicsTargetPoint: CGPoint?
        var appKitTargetPoint: CGPoint?
        var displayFrame: CGRect?
        var targetElementFacts: AccessibilityElementFacts?
        var coreGraphicsDragEndPoint: CGPoint?
        var dragDropTargetElementFacts: AccessibilityElementFacts?
        if case let .drag(_, toScreenshotPixel, screenNumber) = action.withoutModifierKeys,
           let dragEndCapture = CompanionScreenCapture.targetCapture(screenNumber: screenNumber, in: screenCaptures) {
            let dragEndPoint = dragEndCapture.coreGraphicsGlobalPoint(fromScreenshotPixel: toScreenshotPixel)
            coreGraphicsDragEndPoint = dragEndPoint
            dragDropTargetElementFacts = await AccessibilityElementLocator.elementFacts(atCoreGraphicsGlobalPoint: dragEndPoint)
        }

        if let actionTarget = Self.targetScreenshotPixel(of: action),
           let targetCapture = CompanionScreenCapture.targetCapture(screenNumber: actionTarget.screenNumber, in: screenCaptures) {
            let modelCoreGraphicsPoint = targetCapture.coreGraphicsGlobalPoint(fromScreenshotPixel: actionTarget.screenshotPixel)
            targetElementFacts = await AccessibilityElementLocator.elementFacts(atCoreGraphicsGlobalPoint: modelCoreGraphicsPoint)
            let resolvedCoreGraphicsPoint = Self.snappedClickPoint(
                for: action,
                modelCoreGraphicsPoint: modelCoreGraphicsPoint,
                targetElementFacts: targetElementFacts,
                displayBounds: CGDisplayBounds(targetCapture.displayID)
            ) ?? modelCoreGraphicsPoint
            coreGraphicsTargetPoint = resolvedCoreGraphicsPoint
            appKitTargetPoint = GlobalCoordinateSpaceConversion.appKitPoint(fromCoreGraphicsGlobalPoint: resolvedCoreGraphicsPoint)
            displayFrame = targetCapture.displayFrame
        } else if Self.isKeystrokeAction(action) {
            // Typed text and key presses land in the focused element, so
            // that's the element consent judges (password field, web page, app).
            targetElementFacts = await AccessibilityElementLocator.focusedElementFacts()
        }

        // Opening an app or a website works in that app (or the browser).
        var openedApplicationBundleIdentifier: String?
        var openedWebsiteHost: String?
        switch action {
        case let .openApplication(name):
            openedApplicationBundleIdentifier = ApplicationLocator.bundleIdentifier(ofApplicationNamed: name)
        case let .openWebsite(url):
            openedApplicationBundleIdentifier = ApplicationLocator.defaultBrowserBundleIdentifier(for: url)
            openedWebsiteHost = url.host
        default:
            break
        }

        let screenCapturePrivacyBlocklist = ScreenCapturePrivacyBlocklist.shared
        let isOpenStep = openedApplicationBundleIdentifier != nil || openedWebsiteHost != nil
        // An open step works in the app it opens, not the one in front.
        let isTargetApplicationPrivacyBlocked = isOpenStep
            ? screenCapturePrivacyBlocklist.isBlocked(bundleIdentifier: openedApplicationBundleIdentifier)
            : screenCapturePrivacyBlocklist.isBlocked(bundleIdentifier: targetElementFacts?.owningApplicationBundleIdentifier)
                || screenCapturePrivacyBlocklist.isBlocked(bundleIdentifier: frontmostApplicationBundleIdentifier)

        let consentContext = ScreenActionConsentContext(
            action: action,
            targetElementFacts: targetElementFacts,
            frontmostApplicationBundleIdentifier: isOpenStep ? openedApplicationBundleIdentifier : frontmostApplicationBundleIdentifier,
            isTargetApplicationPrivacyBlocked: isTargetApplicationPrivacyBlocked,
            userUtterance: userUtterance,
            isSecureEventInputActive: IsSecureEventInputEnabled(),
            dragDropTargetElementFacts: dragDropTargetElementFacts,
            isTargetWebsitePrivate: PrivateWebsiteList.shared.isPrivate(host: targetElementFacts?.webPageHost)
                || PrivateWebsiteList.shared.isPrivate(host: dragDropTargetElementFacts?.webPageHost)
                || PrivateWebsiteList.shared.isPrivate(host: openedWebsiteHost)
        )

        return ResolvedScreenAction(
            action: action,
            coreGraphicsTargetPoint: coreGraphicsTargetPoint,
            appKitTargetPoint: appKitTargetPoint,
            displayFrame: displayFrame,
            targetElementFacts: targetElementFacts,
            frontmostApplicationBundleIdentifier: frontmostApplicationBundleIdentifier,
            consentDecision: ConsentPolicy.evaluate(consentContext),
            consequentialEffect: ConsentPolicy.consequentialEffect(of: consentContext),
            coreGraphicsDragEndPoint: coreGraphicsDragEndPoint,
            dragDropTargetElementFacts: dragDropTargetElementFacts,
            openedApplicationBundleIdentifier: openedApplicationBundleIdentifier
        )
    }

    private static func isKeystrokeAction(_ action: CompanionScreenAction) -> Bool {
        switch action {
        case .type, .key: return true
        case .click, .doubleClick, .scroll, .rightClick, .tripleClick, .drag, .moveMouse, .openApplication, .openWebsite: return false
        case let .withModifierKeys(_, innerAction): return isKeystrokeAction(innerAction)
        }
    }

    private static func targetScreenshotPixel(of action: CompanionScreenAction) -> (screenshotPixel: CGPoint, screenNumber: Int?)? {
        switch action {
        case let .click(screenshotPixel, _, screenNumber),
             let .doubleClick(screenshotPixel, _, screenNumber),
             let .scroll(screenshotPixel, _, screenNumber, _),
             let .rightClick(screenshotPixel, _, screenNumber),
             let .tripleClick(screenshotPixel, _, screenNumber),
             let .moveMouse(screenshotPixel, screenNumber):
            return (screenshotPixel, screenNumber)
        // A drag is judged by where it starts: that's what it picks up.
        case let .drag(fromScreenshotPixel, _, screenNumber):
            return (fromScreenshotPixel, screenNumber)
        case .type, .key, .openApplication, .openWebsite:
            return nil
        case let .withModifierKeys(_, innerAction):
            return targetScreenshotPixel(of: innerAction)
        }
    }

    /// Clicks snap to the center of the real control they fall inside; scrolls
    /// never snap (where you scroll inside a list doesn't need to be precise).
    private static func snappedClickPoint(
        for action: CompanionScreenAction,
        modelCoreGraphicsPoint: CGPoint,
        targetElementFacts: AccessibilityElementFacts?,
        displayBounds: CGRect
    ) -> CGPoint? {
        switch action.withoutModifierKeys {
        case .click, .doubleClick, .rightClick, .tripleClick:
            guard let targetElementFacts,
                  let elementFrame = targetElementFacts.frameInCoreGraphicsGlobalCoordinates,
                  AccessibilitySnapping.isElementUsableForSnapping(
                      elementFrame: elementFrame,
                      role: targetElementFacts.role,
                      displayBounds: displayBounds
                  ) else { return nil }
            return AccessibilitySnapping.snappedTargetPoint(
                modelPoint: modelCoreGraphicsPoint,
                elementFrame: elementFrame,
                role: targetElementFacts.role
            )
        default:
            return nil
        }
    }

    // MARK: - Preview & summaries

    private func previewTarget(of resolvedAction: ResolvedScreenAction) {
        guard let appKitTargetPoint = resolvedAction.appKitTargetPoint,
              let displayFrame = resolvedAction.displayFrame else { return }
        let highlightedElementFrame = resolvedAction.targetElementFacts?.frameInCoreGraphicsGlobalCoordinates
            .flatMap { elementFrame -> CGRect? in
                let displayBounds = CGRect(origin: .zero, size: displayFrame.size)
                guard AccessibilitySnapping.isElementUsableForSnapping(
                    elementFrame: elementFrame,
                    role: resolvedAction.targetElementFacts?.role,
                    displayBounds: displayBounds
                ) else { return nil }
                return GlobalCoordinateSpaceConversion.appKitRect(fromCoreGraphicsGlobalRect: elementFrame)
            }
        emitCompanionEvent?(.actionPreviewed(PlacedPointer(
            appKitGlobalPoint: appKitTargetPoint,
            displayFrame: displayFrame,
            label: resolvedAction.targetElementFacts?.title ?? Self.modelLabel(of: resolvedAction.action),
            highlightedElementFrame: highlightedElementFrame
        )))
    }

    private static func modelLabel(of action: CompanionScreenAction) -> String? {
        switch action {
        case let .click(_, label, _), let .doubleClick(_, label, _),
             let .rightClick(_, label, _), let .tripleClick(_, label, _):
            return label
        case .scroll:
            return "scroll here"
        case .drag:
            return "drag from here"
        case .moveMouse:
            return "pointer"
        case .type, .key, .openApplication, .openWebsite:
            return nil
        case let .withModifierKeys(_, innerAction):
            return modelLabel(of: innerAction)
        }
    }

    private func summarize(_ resolvedActions: [ResolvedScreenAction]) -> String {
        resolvedActions.map { $0.humanReadableDescription }.joined(separator: ", then ")
    }

    // MARK: - Action log

    private func recordAuditEntry(
        for resolvedAction: ResolvedScreenAction,
        approvalProvenance: ScreenActionApprovalProvenance?,
        outcome: ComputerUseAuditOutcome
    ) {
        ComputerUseAuditLog.shared.record(ComputerUseAuditEntry(
            resolvedAction: resolvedAction,
            approvalProvenance: approvalProvenance,
            outcome: outcome
        ))
    }
}
