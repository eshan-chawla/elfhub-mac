//
//  ComputerUseSession.swift
//  elfhub
//
//  One multi-step run on the user's screen ("open settings and turn on
//  dark mode"). The agent loop hands it each model round's screen calls;
//  it carries them out in order and answers every call:
//   - a step that can't be done (refused, failed) stops the round there,
//     and the calls after it are answered "Not executed" (the toolset's rule);
//   - a round that acted or waited ends with one fresh screenshot of the
//     same display, taken once the screen has settled, plus whether
//     anything visibly changed;
//   - the user saying no, Esc, touching the mouse or keyboard, or a step
//     that's theirs to do (a password) ends the run at once — no more
//     model rounds;
//   - ComputerUseLoopGuard's stop (budgets, failures, going in circles)
//     leaves the model one round to sum up honestly, without acting.
//  Consent, previews and the actual events are ScreenActionCoordinator's
//  (through ComputerUseLiveScreen); this type only sequences them, so it is
//  tested against a pretend screen.
//

import AppKit
import CoreGraphics
import Foundation
import os

/// How a run ended early.
enum ComputerUseRunEnding: Equatable {
    /// The model gets one more round to say what it did, with no more steps.
    case summarize(reason: String)
    /// Stop now, without asking the model again; the reason (when there is
    /// one) is said to the user.
    case stopNow(spokenReason: String?)
}

struct ComputerUseStepResult {
    /// One result per screen call, in the order they were made.
    var resultBlocks: [LanguageModelContentBlock]
    var ending: ComputerUseRunEnding?
}

/// Runs a model round's screen calls (the agent loop's view of a run).
@MainActor
protocol ComputerUseStepExecutor: AnyObject {
    var hasEnded: Bool { get }
    func runStep(_ toolCalls: [LanguageModelToolCall]) async -> ComputerUseStepResult
    /// The same, a call at a time as the reply arrives.
    func beginRound()
    func runCallInCurrentRound(_ toolCall: LanguageModelToolCall) async
    func finishRound() async -> ComputerUseStepResult
}

/// The screen a run works on: capturing it and acting on it.
@MainActor
protocol ComputerUseScreen: AnyObject {
    func captureScreen() async throws -> CompanionScreenCapture
    /// After acting: waits until the screen stops changing, then captures it.
    func captureScreenAfterSettling(previousCapture: CompanionScreenCapture) async throws -> CompanionScreenCapture
    func captureZoomedRegion(_ regionInScreenshotPixels: CGRect, of capture: CompanionScreenCapture) async throws -> Data
    func perform(_ action: CompanionScreenAction, on capture: CompanionScreenCapture, stepDescription: String) async -> ComputerUseActionOutcome
    func pointerLocationInScreenshotPixels(on capture: CompanionScreenCapture) -> CGPoint?
    func wait(seconds: Double) async throws
    /// The window in front's controls, as text to send beside this
    /// screenshot (AccessibilitySnapshotFormatter), or nil.
    func describeInterface(on capture: CompanionScreenCapture) async -> String?
    /// Whether the part of the screen around this point changed a lot since
    /// `capture` was taken (false when that can't be told).
    func targetRegionChanged(since capture: CompanionScreenCapture, aroundScreenshotPixel screenshotPixel: CGPoint) async -> Bool
    /// The last performed step in words, naming the real element when known.
    var lastPerformedStepDescription: String? { get }
    /// The app the last performed step worked in, when known.
    var lastPerformedStepApplicationBundleIdentifier: String? { get }
}

@MainActor
final class ComputerUseSession: ComputerUseStepExecutor {

    static let notExecutedAfterFailureText = "Not executed: an earlier computer action in this turn failed."
    static let notExecutedAfterRunEndedText = "Not executed: this run on the screen has ended."
    /// Told to the model when the guard ends the run (in the last result and
    /// in the system prompt of its final round).
    static let runEndedInstruction = "this run on the screen is over: don't take any more steps. tell the user in a sentence or two what you did, whether it worked, and what's left for them."

    private let screen: ComputerUseScreen
    private let coordinateConvention: ModelCoordinateConvention
    private var loopGuard: ComputerUseLoopGuard
    private(set) var latestCapture: CompanionScreenCapture
    private(set) var hasEnded = false
    /// How the run ended early, when it did.
    private(set) var ending: ComputerUseRunEnding?
    /// Whether any step tried to act on the screen (so the end of the run
    /// tidies up: the pointer goes back, the pill stops saying it's acting).
    private(set) var didTryToAct = false
    /// What it did on the screen, in order ("click “Export”"), for the
    /// conversation history — typed text only as its length.
    private(set) var performedStepDescriptions: [String] = []
    /// The step the run stopped at because the user said no or didn't
    /// answer the approval in time; nil when it ended any other way.
    private(set) var stepLeftWaitingForApproval: String?
    /// The app each performed step worked in (nil when unknown), in order.
    private(set) var performedStepApplicationBundleIdentifiers: [String?] = []
    /// Click targets held back as changed; the same click asked again after
    /// the fresh screenshot goes through (something there keeps moving —
    /// a video, a terminal — and the model has now seen it).
    private var clickTargetsHeldBackAsChanged: [CGPoint] = []
    /// Whether the last finished round had a step that failed.
    private(set) var lastRoundHadFailure = false
    /// Told about each step as it's performed (its history description), so
    /// the chat lists the run's steps live — and a run stopped with Esc
    /// still shows how far it got.
    var onStepPerformed: (String) -> Void = { _ in }

    /// How long this run may go (Settings › Tools & capabilities when it started).
    var limits: ComputerUseRunLimits { loopGuard.limits }

    init(
        screen: ComputerUseScreen,
        firstCapture: CompanionScreenCapture,
        coordinateConvention: ModelCoordinateConvention,
        startedAt: Date = Date(),
        limits: ComputerUseRunLimits = .current()
    ) {
        self.screen = screen
        self.latestCapture = firstCapture
        self.coordinateConvention = coordinateConvention
        self.loopGuard = ComputerUseLoopGuard(startedAt: startedAt, limits: limits)
    }

    /// One model round's screen calls, in order: begin, each call, finish.
    func runStep(_ toolCalls: [LanguageModelToolCall]) async -> ComputerUseStepResult {
        beginRound()
        for toolCall in toolCalls {
            await runCallInCurrentRound(toolCall)
        }
        return await finishRound()
    }

    /// What one round has done so far. A round can be fed its calls one at
    /// a time while the model's reply is still arriving (each starts as
    /// soon as its call is complete), then finished once the reply is in.
    private struct RoundInProgress {
        var results: [(toolCall: LanguageModelToolCall, text: String, image: LanguageModelImage?, isError: Bool)] = []
        var performedActions: [CompanionScreenAction] = []
        var aStepFailed = false
        var ending: ComputerUseRunEnding?
        var needsFreshScreenshot = false
        /// It waited, and did nothing else (no acting, looking or zooming):
        /// such a round uses no step.
        var waited = false
        var didSomethingOtherThanWait = false
        let stepNumber: Int
        let fingerprintBeforeRound: ScreenshotFingerprint?
        /// The run had already ended when this round began: nothing runs.
        let runWasOverAtStart: Bool
        let startedAt = Date()
        var timeSpentActing: TimeInterval = 0
    }

    private var roundInProgress: RoundInProgress?

    func beginRound() {
        roundInProgress = RoundInProgress(
            stepNumber: loopGuard.stepsTaken + 1,
            fingerprintBeforeRound: ScreenshotFingerprint(jpegData: latestCapture.imageData),
            runWasOverAtStart: hasEnded
        )
    }

    /// Runs one call of the current round (after the ones before it).
    func runCallInCurrentRound(_ toolCall: LanguageModelToolCall) async {
        if roundInProgress == nil { beginRound() }
        guard var round = roundInProgress else { return }
        defer { roundInProgress = round }
        if round.runWasOverAtStart {
            round.results.append((toolCall, Self.notExecutedAfterRunEndedText, nil, true))
            return
        }
        if round.aStepFailed {
            round.results.append((toolCall, Self.notExecutedAfterFailureText, nil, true))
            return
        }
        if round.ending != nil || Task.isCancelled {
            round.ending = round.ending ?? .stopNow(spokenReason: nil)
            round.results.append((toolCall, Self.notExecutedAfterRunEndedText, nil, true))
            return
        }
        // The time limit holds within a round too (cards add up; waits the
        // model asked for don't count).
        if loopGuard.hasRunOutOfActiveTime(now: Date()) {
            let timeLimitReason = loopGuard.outOfTimeReason
            round.ending = .summarize(reason: timeLimitReason)
            round.results.append((toolCall, Self.notExecutedAfterRunEndedText + " the run stopped because \(timeLimitReason). " + Self.runEndedInstruction, nil, true))
            return
        }

        let stepCommand = ComputerUseToolCallTranslator.command(
            for: toolCall,
            convention: coordinateConvention,
            sentImageSize: latestCapture.sentImageSize
        )
        if case .wait = stepCommand {} else {
            round.didSomethingOtherThanWait = true
        }
        switch stepCommand {
        case let .refuse(reason):
            round.aStepFailed = true
            round.results.append((toolCall, "Error: " + reason, nil, true))

        case .screenshot:
            do {
                latestCapture = try await screen.captureScreen()
                let interfaceDescription = await screen.describeInterface(on: latestCapture)
                round.results.append((toolCall, "the screen now." + (interfaceDescription.map { "\n\n" + $0 } ?? ""), screenshotImage(of: latestCapture), false))
                round.needsFreshScreenshot = false
            } catch {
                round.aStepFailed = true
                round.results.append((toolCall, "Error: couldn't take a screenshot (\(error.localizedDescription)).", nil, true))
            }

        case let .zoom(regionInScreenshotPixels):
            do {
                let zoomedImageData = try await screen.captureZoomedRegion(regionInScreenshotPixels, of: latestCapture)
                round.results.append((
                    toolCall,
                    "zoomed in. coordinates still refer to the full screenshot, not this zoomed image.",
                    LanguageModelImage(data: zoomedImageData, label: "zoomed-in part of the screen; keep using the full screenshot's coordinates"),
                    false
                ))
            } catch {
                round.aStepFailed = true
                round.results.append((toolCall, "Error: couldn't zoom (\(error.localizedDescription)).", nil, true))
            }

        case let .wait(seconds):
            if let waitRefusal = loopGuard.refusalForWait(seconds: seconds) {
                round.aStepFailed = true
                round.results.append((toolCall, "Error: " + waitRefusal, nil, true))
                break
            }
            let waitStartedAt = Date()
            do {
                try await screen.wait(seconds: seconds)
                // A finished wait counts as the time asked for.
                loopGuard.recordWait(seconds: seconds)
                round.results.append((toolCall, "waited \(seconds.formatted()) seconds.", nil, false))
                round.needsFreshScreenshot = true
                round.waited = true
            } catch {
                // Stopped partway (Esc): only the time that passed.
                loopGuard.recordWait(seconds: Date().timeIntervalSince(waitStartedAt))
                round.ending = .stopNow(spokenReason: nil)
                round.results.append((toolCall, Self.notExecutedAfterRunEndedText, nil, true))
            }

        case .cursorPosition:
            let pointerText = screen.pointerLocationInScreenshotPixels(on: latestCapture).map { pointerPixel in
                let modelPoint = ScreenshotGeometry.modelCoordinate(
                    fromScreenshotPixel: pointerPixel,
                    convention: coordinateConvention,
                    sentImageSize: latestCapture.sentImageSize
                )
                return "[\(Int(modelPoint.x.rounded())), \(Int(modelPoint.y.rounded()))]"
            } ?? "the pointer isn't on this screen."
            round.results.append((toolCall, pointerText, nil, false))

        case let .act(action, repeatCount):
            // A click aimed at something that has since changed (a
            // dialog opened over it) would land on what the model never saw.
            if let targetPixel = Self.clickTargetPixel(of: action),
               !clickTargetsHeldBackAsChanged.contains(where: { hypot($0.x - targetPixel.x, $0.y - targetPixel.y) <= Self.sameClickTargetDistanceInPixels }),
               await screen.targetRegionChanged(since: latestCapture, aroundScreenshotPixel: targetPixel) {
                clickTargetsHeldBackAsChanged.append(targetPixel)
                round.aStepFailed = true
                round.needsFreshScreenshot = true
                round.results.append((toolCall, "Error: that part of the screen changed since your screenshot (something opened or moved), so nothing was done. look at the fresh screenshot before trying again.", nil, true))
                return
            }
            let stepDescription = "step \(round.stepNumber) of \(loopGuard.limits.maximumSteps) · \(action.humanReadableDescription)"
            var lastOutcome = ComputerUseActionOutcome.performed
            didTryToAct = true
            let actingStartedAt = Date()
            for _ in 0..<repeatCount {
                lastOutcome = await screen.perform(action, on: latestCapture, stepDescription: stepDescription)
                guard lastOutcome == .performed else { break }
            }
            round.timeSpentActing += Date().timeIntervalSince(actingStartedAt)
            switch lastOutcome {
            case .performed:
                round.performedActions.append(action)
                let performedDescription: String
                if case let .type(typedText) = action.withoutModifierKeys {
                    performedDescription = "type \(typedText.count) characters"
                } else {
                    performedDescription = screen.lastPerformedStepDescription ?? action.humanReadableDescription
                }
                let stepDescription = repeatCount > 1 ? "\(performedDescription) ×\(repeatCount)" : performedDescription
                performedStepDescriptions.append(stepDescription)
                onStepPerformed(stepDescription)
                performedStepApplicationBundleIdentifiers.append(screen.lastPerformedStepApplicationBundleIdentifier)
                round.needsFreshScreenshot = true
                round.results.append((toolCall, "OK.", nil, false))
            case let .notPerformed(reason):
                round.aStepFailed = true
                round.needsFreshScreenshot = true
                round.results.append((toolCall, "Error: " + reason, nil, true))
            case .declinedByUser:
                // Remembered for the history: a later "continue" then knows
                // which step was waiting for the user's okay.
                // Typed text only as its length, as for performed steps.
                if case let .type(typedText) = action.withoutModifierKeys {
                    stepLeftWaitingForApproval = "type \(typedText.count) characters"
                } else {
                    stepLeftWaitingForApproval = action.humanReadableDescription
                }
                round.ending = .stopNow(spokenReason: nil)
                round.results.append((toolCall, "Not executed: the user stopped this.", nil, true))
            case .stoppedByUser:
                round.ending = .stopNow(spokenReason: nil)
                round.results.append((toolCall, "Not executed: the user stopped this.", nil, true))
            case let .handedToUser(reason):
                round.ending = .stopNow(spokenReason: reason)
                round.results.append((toolCall, "Not executed: " + reason, nil, true))
            }
        }
    }

    /// Ends the current round: one fresh look at the screen after acting
    /// (on the last result), the guard's verdict, and every call's result.
    func finishRound() async -> ComputerUseStepResult {
        guard var round = roundInProgress else {
            return ComputerUseStepResult(resultBlocks: [], ending: nil)
        }
        roundInProgress = nil
        guard !round.runWasOverAtStart else {
            return ComputerUseStepResult(
                resultBlocks: round.results.map { Self.resultBlock(for: $0.toolCall, text: $0.text, image: $0.image, isError: $0.isError) },
                ending: nil
            )
        }

        var screenChanged: Bool?
        let lookingStartedAt = Date()
        if round.needsFreshScreenshot, round.ending == nil, !round.results.isEmpty {
            do {
                latestCapture = try await screen.captureScreenAfterSettling(previousCapture: latestCapture)
                if let fingerprintBeforeRound = round.fingerprintBeforeRound,
                   let fingerprintAfterRound = ScreenshotFingerprint(jpegData: latestCapture.imageData) {
                    screenChanged = fingerprintAfterRound.differs(from: fingerprintBeforeRound)
                }
                let lastIndex = round.results.count - 1
                let changeNote = screenChanged.map { $0 ? " the screen changed." : " nothing visible changed on the screen." } ?? ""
                round.results[lastIndex].text += changeNote + " here's the screen now."
                round.results[lastIndex].image = screenshotImage(of: latestCapture)
                if let interfaceDescription = await screen.describeInterface(on: latestCapture) {
                    round.results[lastIndex].text += "\n\n" + interfaceDescription
                }
            } catch {
                round.results[round.results.count - 1].text += " (couldn't take a screenshot afterwards: \(error.localizedDescription))"
            }
        }
        let timeSpentLooking = Date().timeIntervalSince(lookingStartedAt)

        if round.ending == nil {
            let onlyWaited = round.waited && !round.didSomethingOtherThanWait && !round.aStepFailed
            switch loopGuard.recordStep(
                actions: round.performedActions,
                anyStepFailed: round.aStepFailed,
                screenChanged: screenChanged,
                onlyWaited: onlyWaited,
                now: Date()
            ) {
            case let .keepGoing(note):
                if let note, !round.results.isEmpty {
                    round.results[round.results.count - 1].text += "\n\n" + note
                }
            case let .stopAndSummarize(reason):
                round.ending = .summarize(reason: reason)
                if !round.results.isEmpty {
                    round.results[round.results.count - 1].text += "\n\nthe run stopped because \(reason). " + Self.runEndedInstruction
                }
            }
        }
        hasEnded = round.ending != nil
        ending = ending ?? round.ending
        lastRoundHadFailure = round.aStepFailed

        // Where a step's time goes, for tuning (never what's on screen).
        companionLogger.info("Computer use step \(round.stepNumber, privacy: .public): \(round.results.count, privacy: .public) calls, acting \(Int(round.timeSpentActing * 1000), privacy: .public) ms, settling and looking \(Int(timeSpentLooking * 1000), privacy: .public) ms, whole step \(Int(Date().timeIntervalSince(round.startedAt) * 1000), privacy: .public) ms")

        return ComputerUseStepResult(
            resultBlocks: round.results.map { Self.resultBlock(for: $0.toolCall, text: $0.text, image: $0.image, isError: $0.isError) },
            ending: round.ending
        )
    }

    /// Clicks this close count as the same click (in screenshot pixels).
    static let sameClickTargetDistanceInPixels: CGFloat = 12

    /// Where a click-like action lands (a drag: where it picks up). Scrolls,
    /// pointer moves, typing, keys and opening things aren't checked.
    static func clickTargetPixel(of action: CompanionScreenAction) -> CGPoint? {
        switch action {
        case let .click(screenshotPixel, _, _), let .doubleClick(screenshotPixel, _, _),
             let .rightClick(screenshotPixel, _, _), let .tripleClick(screenshotPixel, _, _):
            return screenshotPixel
        case let .drag(startPixel, _, _):
            return startPixel
        case let .withModifierKeys(_, innerAction):
            return clickTargetPixel(of: innerAction)
        case .scroll, .moveMouse, .type, .key, .openApplication, .openWebsite:
            return nil
        }
    }

    private func screenshotImage(of capture: CompanionScreenCapture) -> LanguageModelImage {
        LanguageModelImage(
            data: capture.imageData,
            label: "the user's screen now" + coordinateConvention.screenshotLabelSuffix(
                sentImageWidthInPixels: capture.screenshotWidthInPixels,
                sentImageHeightInPixels: capture.screenshotHeightInPixels
            )
        )
    }

    private static func resultBlock(for toolCall: LanguageModelToolCall, text: String, image: LanguageModelImage?, isError: Bool) -> LanguageModelContentBlock {
        .computerToolResult(LanguageModelComputerToolResult(
            toolCallIdentifier: toolCall.toolCallIdentifier,
            toolName: toolCall.toolName,
            resultText: text,
            image: image,
            isError: isError,
            toolsetName: toolCall.toolsetName
        ))
    }
}

/// The real screen: captures the display the run started on and acts
/// through ScreenActionCoordinator (consent, preview, Esc, the action log).
@MainActor
final class ComputerUseLiveScreen: ComputerUseScreen {
    /// Wait this long after acting before the first look, then until two
    /// looks this far apart match (at most `maximumSettleSeconds`).
    static let firstSettleDelaySeconds = 0.25
    static let settleCheckIntervalSeconds = 0.15
    static let maximumSettleSeconds = 1.5

    private let screenActionCoordinator: ScreenActionCoordinator
    private let visionProfile: ModelVisionProfile
    private var coordinateConvention: ModelCoordinateConvention { visionProfile.coordinateConvention }
    private let displayID: CGDirectDisplayID
    private let userUtterance: String
    private let turnToken: ScreenActionTurnToken
    private let runApproval: ComputerUseRunApproval

    init(
        screenActionCoordinator: ScreenActionCoordinator,
        visionProfile: ModelVisionProfile,
        displayID: CGDirectDisplayID,
        userUtterance: String,
        turnToken: ScreenActionTurnToken,
        asksBeforeFirstStep: Bool = false
    ) {
        self.runApproval = ComputerUseRunApproval(asksBeforeFirstStep: asksBeforeFirstStep)
        self.screenActionCoordinator = screenActionCoordinator
        self.visionProfile = visionProfile
        self.displayID = displayID
        self.userUtterance = userUtterance
        self.turnToken = turnToken
    }

    private func uncheckedFrame() async throws -> CompanionScreenCapture {
        try await CompanionScreenCaptureUtility.captureDisplayAsJPEG(displayID: displayID, visionProfile: visionProfile, appliesPrivacyChecks: false)
    }

    /// The window's controls read at the same moment as a screenshot, for
    /// that screenshot — reading them alongside the capture (its privacy
    /// checks take a moment) instead of after it saves up to 0.3 s a step.
    private var interfaceSnapshotForCapture: (capturedImageData: Data, snapshot: AccessibilitySnapshot?)?

    func captureScreen() async throws -> CompanionScreenCapture {
        async let interfaceSnapshot = AccessibilitySnapshotter.snapshotOfFrontmostWindow()
        let sentCapture = try await CompanionScreenCaptureUtility.captureDisplayAsJPEG(displayID: displayID, visionProfile: visionProfile)
        interfaceSnapshotForCapture = (sentCapture.imageData, await interfaceSnapshot)
        return sentCapture
    }

    func targetRegionChanged(since capture: CompanionScreenCapture, aroundScreenshotPixel screenshotPixel: CGPoint) async -> Bool {
        // The screenshot the model saw, before masking, against the screen now
        // with the same windows left out.
        guard let comparisonImageData = capture.comparisonImageData,
              let currentFrameData = try? await CompanionScreenCaptureUtility.captureComparisonFrame(like: capture) else { return false }
        let pixelsPerPoint = CGFloat(capture.screenshotWidthInPixels) / CGFloat(max(capture.displayWidthInPoints, 1))
        return ScreenshotRegionComparison.isStale(
            beforeJPEG: comparisonImageData,
            afterJPEG: currentFrameData,
            aroundScreenshotPixel: screenshotPixel,
            regionRadiusInPixels: ScreenshotRegionComparison.regionRadiusInPoints * pixelsPerPoint
        )
    }

    /// The real element the last step acted on, in words ("click “Export”").
    var lastPerformedStepDescription: String? {
        screenActionCoordinator.lastFiredActionDescription
    }

    var lastPerformedStepApplicationBundleIdentifier: String? {
        screenActionCoordinator.lastFiredActionApplicationBundleIdentifier
    }

    func captureScreenAfterSettling(previousCapture: CompanionScreenCapture) async throws -> CompanionScreenCapture {
        // Frames compared while waiting skip the privacy checks (they're
        // only compared, never sent); the one that's sent is taken after.
        func settleCheckFrame() async throws -> CompanionScreenCapture {
            try await uncheckedFrame()
        }
        try await Task.sleep(nanoseconds: UInt64(Self.firstSettleDelaySeconds * 1_000_000_000))
        var latestFrame = try await settleCheckFrame()
        let settleDeadline = Date().addingTimeInterval(Self.maximumSettleSeconds - Self.firstSettleDelaySeconds)
        while Date() < settleDeadline {
            try await Task.sleep(nanoseconds: UInt64(Self.settleCheckIntervalSeconds * 1_000_000_000))
            let nextFrame = try await settleCheckFrame()
            defer { latestFrame = nextFrame }
            guard let latestFingerprint = ScreenshotFingerprint(jpegData: latestFrame.imageData),
                  let nextFingerprint = ScreenshotFingerprint(jpegData: nextFrame.imageData),
                  latestFingerprint.differs(from: nextFingerprint) else { break }
        }
        return try await captureScreen()
    }

    func captureZoomedRegion(_ regionInScreenshotPixels: CGRect, of capture: CompanionScreenCapture) async throws -> Data {
        try await CompanionScreenCaptureUtility.captureZoomedRegionAsJPEG(of: capture, regionInScreenshotPixels: regionInScreenshotPixels)
    }

    func perform(_ action: CompanionScreenAction, on capture: CompanionScreenCapture, stepDescription: String) async -> ComputerUseActionOutcome {
        await screenActionCoordinator.performActionInComputerUseRun(
            action,
            screenCapture: capture,
            userUtterance: userUtterance,
            turnToken: turnToken,
            runApproval: runApproval,
            stepDescription: stepDescription
        )
    }

    func pointerLocationInScreenshotPixels(on capture: CompanionScreenCapture) -> CGPoint? {
        let pointerLocation = NSEvent.mouseLocation
        guard capture.displayFrame.contains(pointerLocation) else { return nil }
        return capture.screenshotPixel(fromAppKitGlobalPoint: pointerLocation)
    }

    /// Waits as long as the model asked, with the pill saying so; Esc (the
    /// turn's cancellation) ends it at once.
    func wait(seconds: Double) async throws {
        screenActionCoordinator.showComputerUseRunWaiting(summary: Self.waitingSummary(seconds: seconds))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// "waiting 45 s for the screen", "waiting 2 min for the screen".
    nonisolated static func waitingSummary(seconds: Double) -> String {
        let roundedSeconds = Int(seconds.rounded())
        if roundedSeconds >= 60 {
            let minutes = Double(roundedSeconds) / 60
            let minutesText = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
            return "waiting \(minutesText) min for the screen"
        }
        return "waiting \(roundedSeconds) s for the screen"
    }

    func describeInterface(on capture: CompanionScreenCapture) async -> String? {
        if let interfaceSnapshotForCapture, interfaceSnapshotForCapture.capturedImageData == capture.imageData {
            return interfaceSnapshotForCapture.snapshot.flatMap { Self.promptText(for: $0, on: capture, convention: coordinateConvention) }
        }
        return await Self.interfaceDescription(on: capture, convention: coordinateConvention)
    }

    /// The window in front's controls as text for the model, or nil when
    /// they can't be read (or none are on this screen).
    static func interfaceDescription(on capture: CompanionScreenCapture, convention: ModelCoordinateConvention) async -> String? {
        guard let snapshot = await AccessibilitySnapshotter.snapshotOfFrontmostWindow() else { return nil }
        return promptText(for: snapshot, on: capture, convention: convention)
    }

    private static func promptText(for snapshot: AccessibilitySnapshot, on capture: CompanionScreenCapture, convention: ModelCoordinateConvention) -> String? {
        let promptText = AccessibilitySnapshotFormatter.promptText(
            for: snapshot,
            screenCapture: capture,
            convention: convention,
            fenceMarker: AccessibilitySnapshotFormatter.makeFenceMarker(),
            hidesPersonalNumbers: ScreenshotSensitiveContentMasker.isEnabled
        )
        return promptText.isEmpty ? nil : promptText
    }
}
