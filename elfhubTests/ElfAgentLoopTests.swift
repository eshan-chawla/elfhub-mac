//
//  ElfAgentLoopTests.swift
//  elfhubTests
//
//  The loop that lets a model use its tools within one turn: results fed
//  back, stopping when it has answered, a round cap that forces an answer,
//  guidance from every round kept, cancellation between tools, and a turn
//  restarted on the fallback model that doesn't repeat its writes.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfAgentLoopTests {

    private func makeToolContext(
        userUtterance: String = "note that I prefer metric",
        turnEffectLedger: ElfTurnEffectLedger? = nil,
        home existingHome: ElfHome? = nil
    ) throws -> (toolContext: ElfToolContext, home: ElfHome) {
        let home = existingHome ?? ElfHome(directory: FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true))
        try home.createIfNeeded()
        let toolContext = ElfToolContext(
            elf: Elf(id: "main", home: home, configuration: home.readConfiguration()),
            changeLog: ElfChangeLog(home: home),
            origin: .turn(conversationIdentifier: nil),
            userUtterance: userUtterance,
            turnEffectLedger: turnEffectLedger ?? ElfTurnEffectLedger()
        )
        return (toolContext, home)
    }

    private func runLoop(
        provider: ScriptedLanguageModelProvider,
        toolContext: ElfToolContext,
        maximumRounds: Int = 3,
        onModelRoundEnded: @escaping @MainActor () -> Void = {}
    ) async throws -> ElfAgentLoopResult {
        let initialRequest = LanguageModelRequest(
            systemPrompt: "you're an elf",
            userText: "note that I prefer metric",
            tools: GuidanceToolDefinitions.toolDefinitions(includingScreenActions: false)
                + ElfToolRegistry.standard().toolDefinitions(for: .mainForeground, configuration: toolContext.elf.configuration)
        )
        return try await ElfAgentLoop.run(
            initialRequest: initialRequest,
            languageModelProvider: provider,
            toolRegistry: ElfToolRegistry.standard(),
            toolContext: toolContext,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: maximumRounds,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: onModelRoundEnded
        )
    }

    @Test func stopsWhenTheModelAnswersWithoutTools() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("metric it is.")])
        let loopResult = try await runLoop(provider: provider, toolContext: toolContext)
        #expect(loopResult.replyText == "metric it is.")
        #expect(loopResult.roundsUsed == 1)
        #expect(provider.receivedRequests.count == 1)
    }

    @Test func toolResultsAreFedBack() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let readCall = ScriptedLanguageModelProvider.toolCall("read_file", ["path": "user.md"])
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([readCall], text: "let me check."),
            ScriptedLanguageModelProvider.reply("you haven't told me yet."),
        ])
        let loopResult = try await runLoop(provider: provider, toolContext: toolContext)
        #expect(loopResult.roundsUsed == 2)
        let followUpMessages = try #require(provider.receivedRequests.last?.messages)
        let toolResultTexts = followUpMessages.last?.content.compactMap { contentBlock -> String? in
            if case let .toolResult(toolCallIdentifier, _, resultText) = contentBlock, toolCallIdentifier == readCall.toolCallIdentifier {
                return resultText
            }
            return nil
        }
        #expect(toolResultTexts?.first?.contains("# user") == true)
        #expect(loopResult.replyText == "let me check. you haven't told me yet.")
    }

    @Test func aWriteWithASpokenReplyEndsTheTurn() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls(
                [ScriptedLanguageModelProvider.toolCall("write_file", ["path": "user.md", "content": "# user\n\n- metric"])],
                text: "noted, metric from now on."
            ),
        ])
        let loopResult = try await runLoop(provider: provider, toolContext: toolContext)
        #expect(loopResult.roundsUsed == 1)
        #expect(loopResult.toolOutcomes.flatMap(\.fileChanges).map(\.path) == ["user.md"])
    }

    @Test func roundCapForcesAnAnswer() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let listCall = { ScriptedLanguageModelProvider.toolCall("list_files", [:]) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([listCall()]),
            ScriptedLanguageModelProvider.toolCalls([listCall()]),
            ScriptedLanguageModelProvider.toolCalls([listCall()], text: "here's what I have."),
            ScriptedLanguageModelProvider.reply("never asked"),
        ])
        let loopResult = try await runLoop(provider: provider, toolContext: toolContext, maximumRounds: 3)
        #expect(loopResult.roundsUsed == 3)
        #expect(provider.receivedRequests.count == 3)
        // Told in the newest message, so the system prompt — and the prompt
        // cache behind it — stays the same every round.
        let lastRoundMessageText = provider.receivedRequests.last?.messages.last?.content.compactMap { block -> String? in
            if case let .text(text) = block { return text }
            return nil
        }.joined() ?? ""
        #expect(lastRoundMessageText.contains(ElfAgentLoop.answerNowInstruction))
        let everyRoundHasTheSameSystemPrompt = Set(provider.receivedRequests.map(\.systemPrompt)).count == 1
        #expect(everyRoundHasTheSameSystemPrompt)
        #expect(loopResult.replyText == "here's what I have.")
    }

    @Test func guidanceFromEveryRoundIsMergedAndAToolsOnlyReplyIsAskedOnceMore() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let pointCall = ScriptedLanguageModelProvider.toolCall(GuidanceToolDefinitions.pointToolName, ["x": 10, "y": 20, "label": "save"])
        let annotateCall = ScriptedLanguageModelProvider.toolCall(GuidanceToolDefinitions.annotateToolName, ["shape": "circle", "x": 5, "y": 5])
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([pointCall, ScriptedLanguageModelProvider.toolCall("list_files", [:])]),
            ScriptedLanguageModelProvider.toolCalls([annotateCall], text: "that's the save button."),
        ])
        let loopResult = try await runLoop(provider: provider, toolContext: toolContext)
        #expect(loopResult.guidanceToolCalls.map(\.toolName) == [GuidanceToolDefinitions.pointToolName, GuidanceToolDefinitions.annotateToolName])
        #expect(loopResult.replyText == "that's the save button.")
    }

    @Test func cancellationStopsBeforeTheNextTool() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([
                ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/a.md", "content": "a"]),
            ], text: "saving."),
        ])
        let loopTask = Task { @MainActor in
            try await runLoop(provider: provider, toolContext: toolContext)
        }
        provider.beforeEachResponse = { loopTask.cancel() }
        await #expect(throws: CancellationError.self) { try await loopTask.value }
        #expect(!FileManager.default.fileExists(atPath: home.filesDirectory.appendingPathComponent("a.md").path))
    }

    @Test func aRestartedTurnDoesNotRepeatItsEffects() async throws {
        let turnEffectLedger = ElfTurnEffectLedger()
        let (firstToolContext, home) = try makeToolContext(turnEffectLedger: turnEffectLedger)
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let writeResponse = {
            ScriptedLanguageModelProvider.toolCalls(
                [ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/trip.md", "content": "lisbon"])],
                text: "saved your trip."
            )
        }
        _ = try await runLoop(provider: ScriptedLanguageModelProvider(scriptedResponses: [writeResponse()]), toolContext: firstToolContext)
        let (restartedToolContext, _) = try makeToolContext(turnEffectLedger: turnEffectLedger, home: home)
        let restartedResult = try await runLoop(provider: ScriptedLanguageModelProvider(scriptedResponses: [writeResponse()]), toolContext: restartedToolContext)
        #expect(ElfChangeLog(home: home).entries().count == 1)
        #expect(restartedResult.toolOutcomes.flatMap(\.fileChanges).isEmpty)
        // The change the first try made is still the turn's, for chat's Undo.
        #expect(turnEffectLedger.recordedFileChanges.map(\.path) == ["files/trip.md"])
    }

    @Test func eachFileChangeIsReportedAsItHappens() async throws {
        var reportedPaths: [String] = []
        let turnEffectLedger = ElfTurnEffectLedger(onFileChanged: { fileChange in reportedPaths.append(fileChange.path) })
        let (toolContext, home) = try makeToolContext(turnEffectLedger: turnEffectLedger)
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([
                ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/a.md", "content": "a"]),
                ScriptedLanguageModelProvider.toolCall("list_files", [:]),
            ], text: "saved."),
        ])
        let loopTask = Task { @MainActor in try await runLoop(provider: provider, toolContext: toolContext) }
        // Esc while the second round is streaming: the first round's file
        // change was reported already.
        provider.beforeEachResponse = { if provider.receivedRequests.count == 2 { loopTask.cancel() } }
        await #expect(throws: CancellationError.self) { try await loopTask.value }
        #expect(reportedPaths == ["files/a.md"])
    }

    @Test func aWriteRepeatedAfterADeleteInTheSameTurnIsWrittenAgain() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([
                ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/a.md", "content": "a"]),
                ScriptedLanguageModelProvider.toolCall("delete_file", ["path": "files/a.md"]),
                ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/a.md", "content": "a"]),
            ], text: "done."),
        ])
        _ = try await runLoop(provider: provider, toolContext: toolContext)
        #expect(FileManager.default.fileExists(atPath: home.filesDirectory.appendingPathComponent("a.md").path))
    }

    @Test func eachModelRoundIsMarkedSoHeldBackSpeechIsFlushed() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        var endedRoundCount = 0
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("list_files", [:])], text: "let me look"),
            ScriptedLanguageModelProvider.reply("nothing there yet."),
        ])
        _ = try await runLoop(provider: provider, toolContext: toolContext, onModelRoundEnded: { endedRoundCount += 1 })
        #expect(endedRoundCount == 2)

        var sentenceSegmenter = SpokenSentenceSegmenter()
        #expect(sentenceSegmenter.append("let me look").isEmpty)
        #expect(sentenceSegmenter.endOfModelRound().map(\.text) == ["let me look"])
        _ = sentenceSegmenter.append("nothing there yet.")
        #expect(sentenceSegmenter.finish().map(\.text) == ["nothing there yet."])
    }

    @Test func historyGetsAFootnoteOfWhatTheTurnChanged() throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let fileChange = try toolContext.changeLog.recordWrite(path: "files/trip.md", newText: "x", origin: .hub, influencedBy: [])
        let historyText = CompanionTurnPipeline.assistantTextForHistory(
            spokenText: "saved it.",
            notepad: nil,
            fileChanges: [fileChange]
        )
        #expect(historyText == "saved it.\n\n(you saved files/trip.md)")
        #expect(CompanionTurnPipeline.assistantTextForHistory(spokenText: "hi.", notepad: nil, fileChanges: []) == "hi.")
    }

    @Test func anOutputTokenBudgetStopsTheRun() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        var expensiveResponse = ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("list_files", [:])])
        expensiveResponse.usage = LanguageModelUsage(outputTokens: 900)
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [expensiveResponse, expensiveResponse, expensiveResponse])
        await #expect(throws: ElfAgentLoopError.budgetExceeded) {
            _ = try await ElfAgentLoop.run(
                initialRequest: LanguageModelRequest(systemPrompt: "s", userText: "work"),
                languageModelProvider: provider,
                toolRegistry: ElfToolRegistry.standard(),
                toolContext: toolContext,
                guidanceToolNames: [],
                maximumRounds: 25,
                budget: ElfAgentLoopBudget(maximumOutputTokens: 1_500, deadline: Date(timeIntervalSinceNow: 60)),
                onReplyTextDelta: { _ in },
                onModelRoundEnded: {}
            )
        }
        #expect(provider.receivedRequests.count == 2)
    }

    @Test func aTimeBudgetStopsTheRunBeforeTheNextRound() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("x")])
        await #expect(throws: ElfAgentLoopError.budgetExceeded) {
            _ = try await ElfAgentLoop.run(
                initialRequest: LanguageModelRequest(systemPrompt: "s", userText: "work"),
                languageModelProvider: provider,
                toolRegistry: ElfToolRegistry.standard(),
                toolContext: toolContext,
                guidanceToolNames: [],
                maximumRounds: 25,
                budget: ElfAgentLoopBudget(maximumOutputTokens: 1_000, deadline: Date(timeIntervalSinceNow: -1)),
                onReplyTextDelta: { _ in },
                onModelRoundEnded: {}
            )
        }
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test func aToolThatEndsTheRunStopsTheLoop() async throws {
        let (toolContext, home) = try makeToolContext()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let endingTool = RunEndingTestTool()
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("end_run", [:])]),
            ScriptedLanguageModelProvider.reply("never asked"),
        ])
        let loopResult = try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(systemPrompt: "s", userText: "work"),
            languageModelProvider: provider,
            toolRegistry: ElfToolRegistry(tools: [endingTool]),
            toolContext: toolContext,
            guidanceToolNames: [],
            maximumRounds: 25,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )
        #expect(loopResult.roundsUsed == 1)
        #expect(provider.receivedRequests.count == 1)
    }
}

/// A tool whose outcome ends the run (like finish_task or ask_user).
@MainActor
private struct RunEndingTestTool: ElfTool {
    let definition = LanguageModelToolDefinition(name: "end_run", description: "ends the run", inputSchema: ["type": "object"])
    let group = ElfToolGroup.worker
    let resultFeedsBackToModel = true
    func isAvailable(for role: ElfPromptRole, configuration: ElfConfiguration) -> Bool { true }
    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        ElfToolOutcome(resultText: "done", endsTheRun: true)
    }
}
