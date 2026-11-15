//
//  ComputerUseSessionTests.swift
//  elfhubTests
//
//  The multi-step run on the user's screen, against a pretend screen: each
//  model round's steps run in order and stop at the first failure (the rest
//  answered "Not executed"), a round that acted ends with one fresh
//  screenshot and whether the screen changed, the user saying no or taking
//  over ends the run at once, the guard's stop leaves one round to sum up,
//  and the agent loop sends every result back with the screenshot.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
final class FakeComputerUseScreen: ComputerUseScreen {
    var performedActions: [CompanionScreenAction] = []
    var performedStepDescriptions: [String] = []
    /// Outcomes handed out in order; once used up, every action is performed.
    var scriptedOutcomes: [ComputerUseActionOutcome] = []
    var screenChangesWhenActing = true
    var captureCount = 0
    var waitedSeconds: [Double] = []
    private var screenVersion = 0

    static func jpegData(withBoxAt boxOrigin: CGPoint?) -> Data {
        let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        if let boxOrigin {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: boxOrigin, size: CGSize(width: 120, height: 120)))
        }
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .jpeg, properties: [:])!
    }

    static func capture(imageData: Data) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: imageData,
            label: "user's screen",
            isCursorScreen: true,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayID: 1
        )
    }

    private func currentCapture() -> CompanionScreenCapture {
        captureCount += 1
        let boxOrigin = screenVersion == 0 ? nil : CGPoint(x: (screenVersion * 130) % 1100, y: 300)
        return Self.capture(imageData: Self.jpegData(withBoxAt: boxOrigin))
    }

    func captureScreen() async throws -> CompanionScreenCapture { currentCapture() }

    func captureScreenAfterSettling(previousCapture: CompanionScreenCapture) async throws -> CompanionScreenCapture {
        currentCapture()
    }

    func captureZoomedRegion(_ regionInScreenshotPixels: CGRect, of capture: CompanionScreenCapture) async throws -> Data {
        Self.jpegData(withBoxAt: nil)
    }

    func perform(_ action: CompanionScreenAction, on capture: CompanionScreenCapture, stepDescription: String) async -> ComputerUseActionOutcome {
        let outcome = scriptedOutcomes.isEmpty ? .performed : scriptedOutcomes.removeFirst()
        if outcome == .performed {
            performedActions.append(action)
            performedStepDescriptions.append(stepDescription)
            if screenChangesWhenActing { screenVersion += 1 }
        }
        return outcome
    }

    func pointerLocationInScreenshotPixels(on capture: CompanionScreenCapture) -> CGPoint? { CGPoint(x: 12, y: 34) }

    func wait(seconds: Double) async throws { waitedSeconds.append(seconds) }

    var interfaceDescriptionToReturn: String?
    func describeInterface(on capture: CompanionScreenCapture) async -> String? { interfaceDescriptionToReturn }
}

@MainActor
struct ComputerUseSessionTests {

    private func toolsetCall(_ identifier: String, _ memberName: String, _ argumentsJSON: String = "{}") -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: identifier, toolName: memberName, argumentsJSON: argumentsJSON, toolsetName: "computer")
    }

    private func makeSession(screen: FakeComputerUseScreen) -> ComputerUseSession {
        ComputerUseSession(
            screen: screen,
            firstCapture: FakeComputerUseScreen.capture(imageData: FakeComputerUseScreen.jpegData(withBoxAt: nil)),
            coordinateConvention: .imagePixels
        )
    }

    private func computerResults(_ stepResult: ComputerUseStepResult) -> [LanguageModelComputerToolResult] {
        stepResult.resultBlocks.compactMap { resultBlock in
            if case let .computerToolResult(computerToolResult) = resultBlock { return computerToolResult }
            return nil
        }
    }

    @Test func aRoundActsInOrderAndEndsWithOneFreshScreenshot() async {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        let stepResult = await session.runStep([
            toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#),
            toolsetCall("b", "type", #"{"text":"hello"}"#),
            toolsetCall("c", "key", #"{"text":"return"}"#),
        ])
        #expect(screen.performedActions.count == 3)
        #expect(screen.performedStepDescriptions.first?.hasPrefix("step 1 of \(ComputerUseLoopGuard.maximumSteps)") == true)
        let results = computerResults(stepResult)
        #expect(results.map(\.toolCallIdentifier) == ["a", "b", "c"])
        #expect(results.allSatisfy { $0.toolsetName == "computer" && !$0.isError })
        #expect(results.map { $0.image != nil } == [false, false, true])
        #expect(results.last?.resultText.contains("the screen changed") == true)
        #expect(stepResult.ending == nil)
        #expect(screen.captureCount == 1)
    }

    @Test func theWindowsControlsGoBesideEachFreshScreenshot() async {
        let screen = FakeComputerUseScreen()
        screen.interfaceDescriptionToReturn = "- button “Export” at (124, 98)"
        let session = makeSession(screen: screen)
        let stepResult = await session.runStep([toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#)])
        #expect(computerResults(stepResult).last?.resultText.hasSuffix("- button “Export” at (124, 98)") == true)
    }

    @Test func theRoundStopsAtTheFirstFailure() async {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        let stepResult = await session.runStep([
            toolsetCall("a", "left_click", #"{"coordinate":[9000,200]}"#),
            toolsetCall("b", "type", #"{"text":"hello"}"#),
        ])
        #expect(screen.performedActions.isEmpty)
        let results = computerResults(stepResult)
        #expect(results.map(\.isError) == [true, true])
        #expect(results.last?.resultText == ComputerUseSession.notExecutedAfterFailureText)
        #expect(stepResult.ending == nil)
    }

    @Test func lookingSteps() async {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        let stepResult = await session.runStep([
            toolsetCall("a", "screenshot"),
            toolsetCall("b", "zoom", #"{"region":[0,0,640,400]}"#),
            toolsetCall("c", "cursor_position"),
            toolsetCall("d", "wait", #"{"duration":2}"#),
        ])
        let results = computerResults(stepResult)
        #expect(results.map { $0.image != nil } == [true, true, false, true])
        #expect(results[2].resultText.contains("12") && results[2].resultText.contains("34"))
        #expect(screen.waitedSeconds == [2])
        #expect(screen.performedActions.isEmpty)
    }

    @Test func theUserSayingNoOrTakingOverEndsTheRunAtOnce() async {
        for (endingOutcome, expectedSpokenReason) in [
            (ComputerUseActionOutcome.declinedByUser, String?.none),
            (.stoppedByUser, nil),
            (.handedToUser(reason: "that's a password field, so please fill it in yourself."), "that's a password field, so please fill it in yourself."),
        ] {
            let screen = FakeComputerUseScreen()
            screen.scriptedOutcomes = [endingOutcome]
            let session = makeSession(screen: screen)
            let stepResult = await session.runStep([
                toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#),
                toolsetCall("b", "key", #"{"text":"return"}"#),
            ])
            #expect(stepResult.ending == .stopNow(spokenReason: expectedSpokenReason))
            #expect(screen.performedActions.isEmpty)
            #expect(session.hasEnded)
        }
    }

    @Test func aNotPerformedStepGoesBackToTheModelAsAnError() async {
        let screen = FakeComputerUseScreen()
        screen.scriptedOutcomes = [.notPerformed(reason: "the screen changed while waiting for the user's okay")]
        let session = makeSession(screen: screen)
        let stepResult = await session.runStep([toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#)])
        let results = computerResults(stepResult)
        #expect(results.first?.isError == true)
        #expect(results.first?.resultText.contains("screen changed") == true)
        #expect(stepResult.ending == nil)
    }

    @Test func theGuardsStopLeavesOneRoundToSumUp() async {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        var lastStepResult: ComputerUseStepResult?
        for stepNumber in 1...ComputerUseLoopGuard.maximumSteps {
            lastStepResult = await session.runStep([toolsetCall("s\(stepNumber)", "left_click", "{\"coordinate\":[\(stepNumber * 50),100]}")])
        }
        guard case .summarize = lastStepResult?.ending else {
            Issue.record("expected the last step to end the run")
            return
        }
        #expect(computerResults(lastStepResult!).last?.resultText.contains(ComputerUseSession.runEndedInstruction) == true)
        let afterTheEnd = await session.runStep([toolsetCall("late", "left_click", #"{"coordinate":[10,10]}"#)])
        #expect(computerResults(afterTheEnd).first?.resultText == ComputerUseSession.notExecutedAfterRunEndedText)
        #expect(screen.performedActions.count == ComputerUseLoopGuard.maximumSteps)
    }

    @Test func theTimeLimitStopsARoundBeforeItsNextAction() async {
        let screen = FakeComputerUseScreen()
        let session = ComputerUseSession(
            screen: screen,
            firstCapture: FakeComputerUseScreen.capture(imageData: FakeComputerUseScreen.jpegData(withBoxAt: nil)),
            coordinateConvention: .imagePixels,
            startedAt: Date().addingTimeInterval(-ComputerUseLoopGuard.maximumRunDurationInSeconds - 1)
        )
        let stepResult = await session.runStep([toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#)])
        #expect(screen.performedActions.isEmpty)
        guard case .summarize = stepResult.ending else {
            Issue.record("expected the run to end for time")
            return
        }
        #expect(computerResults(stepResult).first?.resultText.contains(ComputerUseSession.runEndedInstruction) == true)
    }

    @Test func stepsAskedForInTheLastRoundAreNotCarriedOut() async throws {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        let languageModelProvider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#)]),
            ScriptedLanguageModelProvider.toolCalls([toolsetCall("b", "left_click", #"{"coordinate":[300,200]}"#)], text: "one more click."),
        ])
        _ = try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(systemPrompt: "system", userText: "click twice"),
            languageModelProvider: languageModelProvider,
            toolRegistry: ElfToolRegistry(tools: []),
            toolContext: nil,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: 2,
            computerUseExecutor: session,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )
        // The model would never see what the second click did.
        #expect(screen.performedActions.count == 1)
    }

    // MARK: - When a turn acts in steps

    @Test func aTurnActsInStepsOnlyWithActionModeToolsAndVision() {
        #expect(CompanionTurnPipeline.actsInSteps(isActionModeEnabled: true, supportsToolCalling: true, supportsVision: true, hasScreenCapture: true))
        #expect(!CompanionTurnPipeline.actsInSteps(isActionModeEnabled: false, supportsToolCalling: true, supportsVision: true, hasScreenCapture: true))
        #expect(!CompanionTurnPipeline.actsInSteps(isActionModeEnabled: true, supportsToolCalling: false, supportsVision: true, hasScreenCapture: true))
        #expect(!CompanionTurnPipeline.actsInSteps(isActionModeEnabled: true, supportsToolCalling: true, supportsVision: false, hasScreenCapture: true))
        #expect(!CompanionTurnPipeline.actsInSteps(isActionModeEnabled: true, supportsToolCalling: true, supportsVision: true, hasScreenCapture: false))
    }

    @Test func theStepByStepPromptReplacesTheOneShotActionInstructions() {
        let stepPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels, guidanceEncoding: .nativeTools, includesScreenActions: true, actsInSteps: true
        )
        let oneShotPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels, guidanceEncoding: .nativeTools, includesScreenActions: true
        )
        #expect(stepPrompt.contains(CompanionPromptBuilder.stepByStepActionInstructions))
        #expect(!oneShotPrompt.contains(CompanionPromptBuilder.stepByStepActionInstructions))
    }

    // MARK: - In the agent loop

    @Test func theAgentLoopSendsStepResultsBackUntilTheModelAnswers() async throws {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        let languageModelProvider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#)], text: "opening it."),
            ScriptedLanguageModelProvider.toolCalls([toolsetCall("b", "type", #"{"text":"hi"}"#)]),
            ScriptedLanguageModelProvider.reply("done, it's open."),
        ])
        var initialRequest = LanguageModelRequest(systemPrompt: "system", userText: "open it and say hi")
        initialRequest.usesAnthropicComputerToolset = true
        let loopResult = try await ElfAgentLoop.run(
            initialRequest: initialRequest,
            languageModelProvider: languageModelProvider,
            toolRegistry: ElfToolRegistry(tools: []),
            toolContext: nil,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: 3 + ComputerUseLoopGuard.maximumSteps,
            computerUseExecutor: session,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )
        #expect(loopResult.replyText == "opening it. done, it's open.")
        #expect(screen.performedActions.count == 2)
        #expect(languageModelProvider.receivedRequests.count == 3)
        let everyRoundOfferedTheToolset = languageModelProvider.receivedRequests.allSatisfy { $0.usesAnthropicComputerToolset }
        #expect(everyRoundOfferedTheToolset)
        let secondRequestLastMessage = try #require(languageModelProvider.receivedRequests[1].messages.last)
        guard case let .computerToolResult(firstStepResult) = secondRequestLastMessage.content.first else {
            Issue.record("expected the step's result in the next request")
            return
        }
        #expect(firstStepResult.toolCallIdentifier == "a")
        #expect(firstStepResult.image != nil)
        #expect(loopResult.guidanceToolCalls.isEmpty)
    }

    @Test func theAgentLoopStopsWithoutAskingTheModelAgainWhenTheUserStops() async throws {
        let screen = FakeComputerUseScreen()
        screen.scriptedOutcomes = [.handedToUser(reason: "that's a password field, so please fill it in yourself.")]
        let session = makeSession(screen: screen)
        let languageModelProvider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#)], text: "logging in."),
            ScriptedLanguageModelProvider.reply("should never be asked"),
        ])
        var spokenText = ""
        let loopResult = try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(systemPrompt: "system", userText: "log me in"),
            languageModelProvider: languageModelProvider,
            toolRegistry: ElfToolRegistry(tools: []),
            toolContext: nil,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: 3 + ComputerUseLoopGuard.maximumSteps,
            computerUseExecutor: session,
            onReplyTextDelta: { textDelta in spokenText += textDelta },
            onModelRoundEnded: {}
        )
        #expect(languageModelProvider.receivedRequests.count == 1)
        #expect(loopResult.replyText.hasSuffix("that's a password field, so please fill it in yourself."))
        #expect(spokenText.hasSuffix("that's a password field, so please fill it in yourself."))
    }

    @Test func afterTheGuardStopsTheModelGetsOneRoundToSumUp() async throws {
        let screen = FakeComputerUseScreen()
        let session = makeSession(screen: screen)
        var scriptedResponses = (1...ComputerUseLoopGuard.maximumSteps).map { stepNumber in
            ScriptedLanguageModelProvider.toolCalls([toolsetCall("s\(stepNumber)", "left_click", "{\"coordinate\":[\(stepNumber * 50),100]}")])
        }
        // It tries once more anyway; that call isn't carried out and the loop ends.
        scriptedResponses.append(ScriptedLanguageModelProvider.toolCalls([toolsetCall("extra", "left_click", #"{"coordinate":[5,5]}"#)], text: "i got most of the way."))
        let languageModelProvider = ScriptedLanguageModelProvider(scriptedResponses: scriptedResponses)
        let loopResult = try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(systemPrompt: "system", userText: "do the long thing"),
            languageModelProvider: languageModelProvider,
            toolRegistry: ElfToolRegistry(tools: []),
            toolContext: nil,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: 3 + ComputerUseLoopGuard.maximumSteps,
            computerUseExecutor: session,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )
        #expect(languageModelProvider.receivedRequests.count == ComputerUseLoopGuard.maximumSteps + 1)
        #expect(languageModelProvider.receivedRequests.last?.systemPrompt.contains(ComputerUseSession.runEndedInstruction) == true)
        #expect(screen.performedActions.count == ComputerUseLoopGuard.maximumSteps)
        #expect(loopResult.replyText == "i got most of the way.")
    }
}
