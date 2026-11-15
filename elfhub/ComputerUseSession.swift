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

    init(
        screen: ComputerUseScreen,
        firstCapture: CompanionScreenCapture,
        coordinateConvention: ModelCoordinateConvention,
        startedAt: Date = Date()
    ) {
        self.screen = screen
        self.latestCapture = firstCapture
        self.coordinateConvention = coordinateConvention
        self.loopGuard = ComputerUseLoopGuard(startedAt: startedAt)
    }

    func runStep(_ toolCalls: [LanguageModelToolCall]) async -> ComputerUseStepResult {
        guard !hasEnded else {
            return ComputerUseStepResult(
                resultBlocks: toolCalls.map { Self.resultBlock(for: $0, text: Self.notExecutedAfterRunEndedText, image: nil, isError: true) },
                ending: nil
            )
        }

        var results: [(toolCall: LanguageModelToolCall, text: String, image: LanguageModelImage?, isError: Bool)] = []
        var performedActions: [CompanionScreenAction] = []
        var aStepFailed = false
        var ending: ComputerUseRunEnding?
        var needsFreshScreenshot = false
        let stepNumber = loopGuard.stepsTaken + 1
        let fingerprintBeforeRound = ScreenshotFingerprint(jpegData: latestCapture.imageData)

        for toolCall in toolCalls {
            if aStepFailed {
                results.append((toolCall, Self.notExecutedAfterFailureText, nil, true))
                continue
            }
            if ending != nil || Task.isCancelled {
                ending = ending ?? .stopNow(spokenReason: nil)
                results.append((toolCall, Self.notExecutedAfterRunEndedText, nil, true))
                continue
            }

            let stepCommand = ComputerUseToolCallTranslator.command(
                for: toolCall,
                convention: coordinateConvention,
                sentImageSize: latestCapture.sentImageSize
            )
            switch stepCommand {
            case let .refuse(reason):
                aStepFailed = true
                results.append((toolCall, "Error: " + reason, nil, true))

            case .screenshot:
                do {
                    latestCapture = try await screen.captureScreen()
                    results.append((toolCall, "the screen now.", screenshotImage(of: latestCapture), false))
                    needsFreshScreenshot = false
                } catch {
                    aStepFailed = true
                    results.append((toolCall, "Error: couldn't take a screenshot (\(error.localizedDescription)).", nil, true))
                }

            case let .zoom(regionInScreenshotPixels):
                do {
                    let zoomedImageData = try await screen.captureZoomedRegion(regionInScreenshotPixels, of: latestCapture)
                    results.append((
                        toolCall,
                        "zoomed in. coordinates still refer to the full screenshot, not this zoomed image.",
                        LanguageModelImage(data: zoomedImageData, label: "zoomed-in part of the screen; keep using the full screenshot's coordinates"),
                        false
                    ))
                } catch {
                    aStepFailed = true
                    results.append((toolCall, "Error: couldn't zoom (\(error.localizedDescription)).", nil, true))
                }

            case let .wait(seconds):
                do {
                    try await screen.wait(seconds: seconds)
                    results.append((toolCall, "waited \(seconds.formatted()) seconds.", nil, false))
                    needsFreshScreenshot = true
                } catch {
                    ending = .stopNow(spokenReason: nil)
                    results.append((toolCall, Self.notExecutedAfterRunEndedText, nil, true))
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
                results.append((toolCall, pointerText, nil, false))

            case let .act(action, repeatCount):
                let stepDescription = "step \(stepNumber) of \(ComputerUseLoopGuard.maximumSteps) · \(action.humanReadableDescription)"
                var lastOutcome = ComputerUseActionOutcome.performed
                for _ in 0..<repeatCount {
                    lastOutcome = await screen.perform(action, on: latestCapture, stepDescription: stepDescription)
                    guard lastOutcome == .performed else { break }
                }
                switch lastOutcome {
                case .performed:
                    performedActions.append(action)
                    needsFreshScreenshot = true
                    results.append((toolCall, "OK.", nil, false))
                case let .notPerformed(reason):
                    aStepFailed = true
                    needsFreshScreenshot = true
                    results.append((toolCall, "Error: " + reason, nil, true))
                case .declinedByUser, .stoppedByUser:
                    ending = .stopNow(spokenReason: nil)
                    results.append((toolCall, "Not executed: the user stopped this.", nil, true))
                case let .handedToUser(reason):
                    ending = .stopNow(spokenReason: reason)
                    results.append((toolCall, "Not executed: " + reason, nil, true))
                }
            }
        }

        // One fresh look at the screen after acting, on the last result, so
        // the model sees what its steps did without asking for it.
        var screenChanged: Bool?
        if needsFreshScreenshot, ending == nil, !results.isEmpty {
            do {
                latestCapture = try await screen.captureScreenAfterSettling(previousCapture: latestCapture)
                if let fingerprintBeforeRound, let fingerprintAfterRound = ScreenshotFingerprint(jpegData: latestCapture.imageData) {
                    screenChanged = fingerprintAfterRound.differs(from: fingerprintBeforeRound)
                }
                let lastIndex = results.count - 1
                let changeNote = screenChanged.map { $0 ? " the screen changed." : " nothing visible changed on the screen." } ?? ""
                results[lastIndex].text += changeNote + " here's the screen now."
                results[lastIndex].image = screenshotImage(of: latestCapture)
            } catch {
                results[results.count - 1].text += " (couldn't take a screenshot afterwards: \(error.localizedDescription))"
            }
        }

        if ending == nil {
            switch loopGuard.recordStep(actions: performedActions, anyStepFailed: aStepFailed, screenChanged: screenChanged, now: Date()) {
            case let .keepGoing(note):
                if let note, !results.isEmpty {
                    results[results.count - 1].text += "\n\n" + note
                }
            case let .stopAndSummarize(reason):
                ending = .summarize(reason: reason)
                if !results.isEmpty {
                    results[results.count - 1].text += "\n\nthe run stopped because \(reason). " + Self.runEndedInstruction
                }
            }
        }
        hasEnded = ending != nil

        return ComputerUseStepResult(
            resultBlocks: results.map { Self.resultBlock(for: $0.toolCall, text: $0.text, image: $0.image, isError: $0.isError) },
            ending: ending
        )
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
    static let firstSettleDelaySeconds = 0.35
    static let settleCheckIntervalSeconds = 0.2
    static let maximumSettleSeconds = 1.5

    private let screenActionCoordinator: ScreenActionCoordinator
    private let visionProfile: ModelVisionProfile
    private let displayID: CGDirectDisplayID
    private let userUtterance: String
    private let turnToken: ScreenActionTurnToken
    private let runApproval = ComputerUseRunApproval()

    init(
        screenActionCoordinator: ScreenActionCoordinator,
        visionProfile: ModelVisionProfile,
        displayID: CGDirectDisplayID,
        userUtterance: String,
        turnToken: ScreenActionTurnToken
    ) {
        self.screenActionCoordinator = screenActionCoordinator
        self.visionProfile = visionProfile
        self.displayID = displayID
        self.userUtterance = userUtterance
        self.turnToken = turnToken
    }

    func captureScreen() async throws -> CompanionScreenCapture {
        try await CompanionScreenCaptureUtility.captureDisplayAsJPEG(displayID: displayID, visionProfile: visionProfile)
    }

    func captureScreenAfterSettling(previousCapture: CompanionScreenCapture) async throws -> CompanionScreenCapture {
        try await Task.sleep(nanoseconds: UInt64(Self.firstSettleDelaySeconds * 1_000_000_000))
        var latestCapture = try await captureScreen()
        let settleDeadline = Date().addingTimeInterval(Self.maximumSettleSeconds - Self.firstSettleDelaySeconds)
        while Date() < settleDeadline {
            try await Task.sleep(nanoseconds: UInt64(Self.settleCheckIntervalSeconds * 1_000_000_000))
            let nextCapture = try await captureScreen()
            defer { latestCapture = nextCapture }
            guard let latestFingerprint = ScreenshotFingerprint(jpegData: latestCapture.imageData),
                  let nextFingerprint = ScreenshotFingerprint(jpegData: nextCapture.imageData),
                  latestFingerprint.differs(from: nextFingerprint) else { break }
        }
        return latestCapture
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

    func wait(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
