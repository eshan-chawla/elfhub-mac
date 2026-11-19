//
//  ComputerUseContextPrunerTests.swift
//  elfhubTests
//
//  A long run on the screen keeps only its newest screenshots: older ones
//  become notes (with their controls lists), in batches so the start of the
//  conversation stays the same between prunes, and every tool call keeps
//  its result.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ComputerUseContextPrunerTests {

    private let screenshotImage = LanguageModelImage(data: Data([0xFF, 0xD8, 0xFF]), label: "the user's screen now")

    private func stepRound(_ stepNumber: Int, controlsList: String? = nil) -> [LanguageModelMessage] {
        let toolCall = LanguageModelToolCall(
            toolCallIdentifier: "call-\(stepNumber)",
            toolName: "left_click",
            argumentsJSON: "{}",
            toolsetName: "computer"
        )
        var resultText = "clicked step \(stepNumber). the screen changed."
        if let controlsList { resultText += "\n\n" + controlsList }
        return [
            LanguageModelMessage(role: .assistant, content: [.toolCall(toolCall)]),
            LanguageModelMessage(role: .user, content: [.computerToolResult(LanguageModelComputerToolResult(
                toolCallIdentifier: toolCall.toolCallIdentifier,
                toolName: toolCall.toolName,
                resultText: resultText,
                image: screenshotImage,
                isError: false,
                toolsetName: "computer"
            ))]),
        ]
    }

    private func conversation(stepCount: Int, controlsList: String? = nil) -> [LanguageModelMessage] {
        var messages = [LanguageModelMessage(role: .user, content: [.image(screenshotImage), .text("book the flight")])]
        for stepNumber in 1...max(1, stepCount) where stepCount > 0 {
            messages += stepRound(stepNumber, controlsList: controlsList)
        }
        return messages
    }

    private func computerResults(in messages: [LanguageModelMessage]) -> [LanguageModelComputerToolResult] {
        messages.flatMap(\.content).compactMap { block in
            if case let .computerToolResult(computerToolResult) = block { return computerToolResult }
            return nil
        }
    }

    @Test func nothingIsPrunedUntilEnoughScreenshotsBuildUp() {
        // The question's screenshot plus five steps: six in all.
        let messages = conversation(stepCount: 5)
        #expect(ComputerUseContextPruner.screenshotCount(in: messages) == 6)
        let prunedMessages = ComputerUseContextPruner.prunedMessages(messages)
        #expect(ComputerUseContextPruner.screenshotCount(in: prunedMessages) == 6)
    }

    @Test func oncePruningStartsOnlyTheNewestScreenshotsStay() {
        let messages = conversation(stepCount: 6)
        let prunedMessages = ComputerUseContextPruner.prunedMessages(messages)
        #expect(ComputerUseContextPruner.screenshotCount(in: prunedMessages) == ComputerUseContextPruner.screenshotsKeptInFull)

        // The question's own screenshot became a note; its text stayed.
        guard case let .text(questionNote) = prunedMessages[0].content[0] else {
            Issue.record("expected the question's screenshot to become a note")
            return
        }
        #expect(questionNote == ComputerUseContextPruner.removedQuestionScreenshotNote)
        guard case let .text(questionText) = prunedMessages[0].content[1] else {
            Issue.record("expected the question's text to stay")
            return
        }
        #expect(questionText == "book the flight")

        let results = computerResults(in: prunedMessages)
        #expect(results.prefix(3).allSatisfy { $0.image == nil && $0.resultText.contains(ComputerUseContextPruner.removedScreenshotNote) })
        #expect(results.suffix(3).allSatisfy { $0.image != nil })
        // What each step did is still there.
        #expect(results[0].resultText.hasPrefix("clicked step 1."))
    }

    @Test func everyToolCallKeepsItsResult() {
        let prunedMessages = ComputerUseContextPruner.prunedMessages(conversation(stepCount: 12))
        let callIdentifiers = prunedMessages.flatMap(\.content).compactMap { block -> String? in
            if case let .toolCall(toolCall) = block { return toolCall.toolCallIdentifier }
            return nil
        }
        let resultIdentifiers = computerResults(in: prunedMessages).map(\.toolCallIdentifier)
        #expect(callIdentifiers == resultIdentifiers)
        #expect(callIdentifiers.count == 12)
        #expect(prunedMessages.count == conversation(stepCount: 12).count)
    }

    @Test func aPrunedStepLosesItsControlsListButKeepsWhatHappened() {
        let controlsList = AccessibilitySnapshotFormatter.controlsListIntroduction + ", read from the screen:\n<elements-x>\n- button “Book” at (10, 20)\n</elements-x>"
        let prunedMessages = ComputerUseContextPruner.prunedMessages(conversation(stepCount: 8, controlsList: controlsList))
        let results = computerResults(in: prunedMessages)
        let oldestResult = results[0]
        #expect(!oldestResult.resultText.contains("button “Book”"))
        #expect(oldestResult.resultText.contains(ComputerUseContextPruner.removedControlsListNote))
        #expect(oldestResult.resultText.hasPrefix("clicked step 1. the screen changed."))
        // The newest steps keep their lists: they describe the screenshots still there.
        #expect(results.last?.resultText.contains("button “Book”") == true)
    }

    @Test func betweenPrunesTheStartOfTheConversationStaysTheSame() {
        // Prune once, then add steps: the pruned part must not change again
        // until the next batch, so the provider's prompt cache keeps working.
        var messages = ComputerUseContextPruner.prunedMessages(conversation(stepCount: 6))
        let prunedPrefixDescription = String(describing: messages.map(\.content).map { $0.map(blockSummary) })
        for stepNumber in 7...9 {
            messages += stepRound(stepNumber)
            messages = ComputerUseContextPruner.prunedMessages(messages)
            let currentPrefix = Array(messages.prefix(13))
            #expect(String(describing: currentPrefix.map(\.content).map { $0.map(blockSummary) }) == prunedPrefixDescription)
        }
        // A fourth new screenshot brings the count to seven: the next batch.
        messages += stepRound(10)
        messages = ComputerUseContextPruner.prunedMessages(messages)
        #expect(ComputerUseContextPruner.screenshotCount(in: messages) == ComputerUseContextPruner.screenshotsKeptInFull)
    }

    private func blockSummary(_ block: LanguageModelContentBlock) -> String {
        switch block {
        case let .text(text): return "text:" + text
        case .image: return "image"
        case let .toolCall(toolCall): return "call:" + toolCall.toolCallIdentifier
        case let .computerToolResult(result): return "result:\(result.toolCallIdentifier):\(result.image != nil):\(result.resultText)"
        default: return "other"
        }
    }

    @Test func aLongRunInTheAgentLoopNeverSendsMoreThanABatchOfScreenshots() async throws {
        let screen = FakeComputerUseScreen()
        let session = ComputerUseSession(
            screen: screen,
            firstCapture: FakeComputerUseScreen.capture(imageData: FakeComputerUseScreen.jpegData(withBoxAt: nil)),
            coordinateConvention: .imagePixels,
            limits: ComputerUseRunLimits(maximumSteps: 50)
        )
        let stepCount = 30
        var scriptedResponses: [LanguageModelResponse] = (1...stepCount).map { stepNumber in
            ScriptedLanguageModelProvider.toolCalls([LanguageModelToolCall(
                toolCallIdentifier: "step-\(stepNumber)",
                toolName: "left_click",
                argumentsJSON: #"{"coordinate":[\#(100 + stepNumber * 10),200]}"#,
                toolsetName: "computer"
            )])
        }
        scriptedResponses.append(ScriptedLanguageModelProvider.reply("all done."))
        let languageModelProvider = ScriptedLanguageModelProvider(scriptedResponses: scriptedResponses)
        let screenshotImage = LanguageModelImage(data: FakeComputerUseScreen.jpegData(withBoxAt: nil), label: "screen")

        let loopResult = try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(systemPrompt: "system", userText: "do a long job", images: [screenshotImage]),
            languageModelProvider: languageModelProvider,
            toolRegistry: ElfToolRegistry(tools: []),
            toolContext: nil,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: stepCount + 5,
            computerUseExecutor: session,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )

        #expect(loopResult.replyText.contains("all done."))
        #expect(screen.performedActions.count == stepCount)
        let screenshotsPerRequest = languageModelProvider.receivedRequests.map { ComputerUseContextPruner.screenshotCount(in: $0.messages) }
        #expect(screenshotsPerRequest.max()! < ComputerUseContextPruner.screenshotCountThatTriggersPruning)
        // Every step's call is still answered in the last request.
        let lastRequestMessages = languageModelProvider.receivedRequests.last!.messages
        #expect(computerResults(in: lastRequestMessages).count == stepCount)
    }
}
