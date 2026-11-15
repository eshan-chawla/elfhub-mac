//
//  ElfAgentLoop.swift
//  elfhub
//
//  Lets the model use its tools within one turn. Each round streams the
//  model's reply; calls to the elf's own tools are run and their results
//  sent back for another round, and guidance calls (point, annotate, act)
//  are collected to be drawn once at the end, answered with "shown". The
//  loop stops when the model has answered and needs no result back, or at
//  the round cap, where it's told to answer with what it has. Every round's
//  text goes to the same reply; cancellation (Esc) is checked before every
//  round and every tool.
//
//  When the user picked "the model's own search" in Settings › Tools, an
//  elf with the web on searches inside the model call (Claude's web search
//  tool, run by Anthropic) when its model has one, instead of the stand-in
//  web_search. That's decided once per run so every
//  round sends the same tools; a search it ran counts as using the web, and
//  a turn the server paused during its searches is sent back to continue.
//

import Foundation

/// Limits for a long run (a background task): stop when the time is up or
/// the model has written this many output tokens.
struct ElfAgentLoopBudget {
    var maximumOutputTokens: Int
    var deadline: Date
}

enum ElfAgentLoopError: LocalizedError, Equatable {
    case budgetExceeded

    var errorDescription: String? {
        switch self {
        case .budgetExceeded: return "it ran out of time or room for this task"
        }
    }
}

struct ElfAgentLoopResult {
    /// The text of every round, joined.
    var replyText: String
    /// Guidance calls from every round, in order, for the pipeline to draw.
    var guidanceToolCalls: [LanguageModelToolCall]
    var toolOutcomes: [ElfToolOutcome]
    var roundsUsed: Int
    var outputTokensUsed: Int = 0
}

@MainActor
enum ElfAgentLoop {
    /// Added to the system prompt of the last allowed round.
    static let answerNowInstruction = "you've used all your tool rounds for this reply. answer now with what you have."

    /// What a guidance call "returns" to the model.
    static let guidanceToolResultText = "shown to the user on their screen"

    /// Searches the model may run itself within one request.
    static let providerWebSearchesPerRequest = 5

    /// The model's own web search for this run, or nil. Only when the user
    /// picked it in Settings › Tools, the elf has the web on (its web tools
    /// are in the registry and the switch is still on), the model can
    /// search, and the run can't also reach the user's folders — unless the
    /// elf allows both: what the server searches can't be stopped halfway
    /// like our own tools.
    static func providerWebSearch(
        toolRegistry: ElfToolRegistry,
        toolContext: ElfToolContext?,
        languageModelProvider: LanguageModelProvider
    ) -> LanguageModelProviderWebSearch? {
        guard let toolContext,
              languageModelProvider.supportsProviderWebSearch,
              toolRegistry.prefersModelsOwnWebSearch,
              ElfWebTools.isWebStillOn(for: toolContext) else { return nil }
        let allowsWebAndUserFoldersTogether = toolContext.elf.configuration.capabilities.allowsWebAndUserFoldersTogether
        let mayReachUserFolders = toolRegistry.containsTool(inGroup: .userFolders) || toolContext.usedResources.contains(.userFolders)
        if mayReachUserFolders && !allowsWebAndUserFoldersTogether { return nil }
        return LanguageModelProviderWebSearch(maximumSearchesPerRequest: providerWebSearchesPerRequest)
    }

    /// Adds the assistant's turn, continuing the previous assistant message
    /// when the server paused it (one turn, not two in a row).
    private static func appendAssistantContent(_ assistantContent: [LanguageModelContentBlock], to messages: inout [LanguageModelMessage]) {
        if let lastMessage = messages.last, lastMessage.role == .assistant {
            messages[messages.count - 1] = LanguageModelMessage(role: .assistant, content: lastMessage.content + assistantContent)
        } else {
            messages.append(LanguageModelMessage(role: .assistant, content: assistantContent))
        }
    }

    static func run(
        initialRequest: LanguageModelRequest,
        languageModelProvider: LanguageModelProvider,
        toolRegistry: ElfToolRegistry,
        toolContext: ElfToolContext?,
        guidanceToolNames: Set<String>,
        maximumRounds: Int,
        budget: ElfAgentLoopBudget? = nil,
        textOnlyRoundNudge: String? = nil,
        maximumTextOnlyRoundNudges: Int = 2,
        computerUseExecutor: ComputerUseStepExecutor? = nil,
        onReplyTextDelta: @escaping @MainActor @Sendable (String) -> Void,
        onModelRoundEnded: @MainActor () -> Void
    ) async throws -> ElfAgentLoopResult {
        var messages = initialRequest.messages
        var roundReplyTexts: [String] = []
        var guidanceToolCalls: [LanguageModelToolCall] = []
        var toolOutcomes: [ElfToolOutcome] = []
        var roundsUsed = 0
        var outputTokensUsed = 0
        var textOnlyRoundNudgesUsed = 0
        // Set when a run on the screen was stopped by its guard: the next
        // round is the model's last, to sum up without acting.
        var isComputerUseSummaryRound = false
        let providerWebSearch = providerWebSearch(
            toolRegistry: toolRegistry,
            toolContext: toolContext,
            languageModelProvider: languageModelProvider
        )

        for roundNumber in 1...max(1, maximumRounds) {
            try Task.checkCancellation()
            if let budget, Date() >= budget.deadline { throw ElfAgentLoopError.budgetExceeded }
            // The tools stay defined on the last round (providers refuse a
            // conversation with tool calls but no tools); the model is told
            // to answer instead.
            let isLastAllowedRound = roundNumber == maximumRounds && roundNumber > 1
            var roundSystemPrompt = initialRequest.systemPrompt
            if isComputerUseSummaryRound {
                roundSystemPrompt += "\n\n" + ComputerUseSession.runEndedInstruction
            } else if isLastAllowedRound {
                roundSystemPrompt += "\n\n" + answerNowInstruction
            }
            var roundRequest = LanguageModelRequest(
                systemPrompt: roundSystemPrompt,
                messages: messages,
                // The model's own search replaces the stand-in web_search
                // (the same name can't be two tools).
                tools: providerWebSearch == nil ? initialRequest.tools : initialRequest.tools.filter { $0.name != "web_search" },
                maxOutputTokens: initialRequest.maxOutputTokens,
                reasoningEffort: initialRequest.reasoningEffort
            )
            roundRequest.providerWebSearch = providerWebSearch
            roundRequest.usesAnthropicComputerToolset = initialRequest.usesAnthropicComputerToolset
            let roundResponse = try await languageModelProvider.streamResponse(roundRequest) { streamEvent in
                if case let .textDelta(textDelta) = streamEvent {
                    onReplyTextDelta(textDelta)
                }
            }
            try Task.checkCancellation()
            roundsUsed = roundNumber
            outputTokensUsed += roundResponse.usage?.outputTokens ?? 0
            if let budget, outputTokensUsed > budget.maximumOutputTokens { throw ElfAgentLoopError.budgetExceeded }
            onModelRoundEnded()

            // A search the model ran itself is using the web: its results
            // may be opened with fetch_page, what it writes next carries the
            // web warning, and the user's folders stay off.
            if roundResponse.providerWebSearchCount > 0, let toolContext {
                toolContext.usedResources.insert(.web)
                toolContext.influencedBy.insert(.web)
                toolContext.fetchPageURLPolicy.recordSearchResults(roundResponse.providerWebSearchResultURLs)
            }

            let trimmedRoundText = roundResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRoundText.isEmpty {
                roundReplyTexts.append(trimmedRoundText)
            }
            // Steps on the screen (in a run) are carried out below, not drawn later.
            let computerUseToolCalls = computerUseExecutor == nil
                ? []
                : roundResponse.toolCalls.filter(ComputerUseToolCallTranslator.isComputerUseCall)
            // Steps asked for in the last round would run unseen (no round
            // after it shows the model what they did), so they don't run.
            let isFinalRound = roundNumber == maximumRounds
            let computerUseToolCallIdentifiers = Set(computerUseToolCalls.map(\.toolCallIdentifier))
            guidanceToolCalls += roundResponse.toolCalls.filter { toolCall in
                guidanceToolNames.contains(toolCall.toolName) && !computerUseToolCallIdentifiers.contains(toolCall.toolCallIdentifier)
            }
            // The server paused a long turn (its own searches): sending the
            // turn back as it is lets it carry on.
            if roundResponse.stopReason == .pausedByServer, roundResponse.toolCalls.isEmpty, roundNumber < maximumRounds {
                appendAssistantContent(roundResponse.assistantContent, to: &messages)
                continue
            }
            guard !roundResponse.toolCalls.isEmpty else {
                // A worker that only talked hasn't finished: remind it how to
                // (finish, ask, or keep working) a couple of times.
                if let textOnlyRoundNudge, textOnlyRoundNudgesUsed < maximumTextOnlyRoundNudges, roundNumber < maximumRounds {
                    textOnlyRoundNudgesUsed += 1
                    appendAssistantContent(roundResponse.assistantContent, to: &messages)
                    messages.append(LanguageModelMessage(role: .user, content: [.text(textOnlyRoundNudge)]))
                    continue
                }
                break
            }

            var toolResultBlocks: [LanguageModelContentBlock] = []
            var needsAnotherRound = trimmedRoundText.isEmpty
            var aToolEndedTheRun = false
            for toolCall in roundResponse.toolCalls where !computerUseToolCallIdentifiers.contains(toolCall.toolCallIdentifier) {
                if guidanceToolNames.contains(toolCall.toolName) {
                    toolResultBlocks.append(.toolResult(
                        toolCallIdentifier: toolCall.toolCallIdentifier,
                        toolName: toolCall.toolName,
                        resultText: guidanceToolResultText
                    ))
                    continue
                }
                try Task.checkCancellation()
                let toolOutcome: ElfToolOutcome
                let calledTool = toolRegistry.tool(named: toolCall.toolName)
                if let calledTool, let toolContext {
                    toolOutcome = try await calledTool.run(argumentsJSON: toolCall.argumentsJSON, context: toolContext)
                } else {
                    toolOutcome = .failure("there's no tool called \(toolCall.toolName).")
                }
                toolOutcomes.append(toolOutcome)
                aToolEndedTheRun = aToolEndedTheRun || toolOutcome.endsTheRun
                if toolOutcome.isFailure || calledTool?.resultFeedsBackToModel == true {
                    needsAnotherRound = true
                }
                toolResultBlocks.append(.toolResult(
                    toolCallIdentifier: toolCall.toolCallIdentifier,
                    toolName: toolCall.toolName,
                    resultText: toolOutcome.resultText
                ))
            }
            // The round's steps on the screen, in order, each answered (with
            // a fresh screenshot after acting).
            if let computerUseExecutor, !computerUseToolCalls.isEmpty, !isFinalRound {
                try Task.checkCancellation()
                let wasAlreadyOver = computerUseExecutor.hasEnded
                let computerUseStepResult = await computerUseExecutor.runStep(computerUseToolCalls)
                toolResultBlocks += computerUseStepResult.resultBlocks
                try Task.checkCancellation()
                switch computerUseStepResult.ending {
                case let .stopNow(spokenReason):
                    // The user stopped it, said no, or it's their step: no
                    // more rounds. Their step's reason is said and kept.
                    if let spokenReason {
                        onReplyTextDelta((roundReplyTexts.isEmpty ? "" : " ") + spokenReason)
                        roundReplyTexts.append(spokenReason)
                    }
                    aToolEndedTheRun = true
                case .summarize:
                    isComputerUseSummaryRound = true
                    needsAnotherRound = true
                case nil:
                    // Calls after the run ended aren't carried out, and the
                    // model doesn't get another round.
                    if wasAlreadyOver {
                        aToolEndedTheRun = true
                    } else {
                        needsAnotherRound = true
                    }
                }
            }
            // Calls in the last round still run (a file the model says it
            // saved is saved); there's just no round after it. A tool that
            // ends the run (finishing a task, asking the user) ends it here.
            guard needsAnotherRound, roundNumber < maximumRounds, !aToolEndedTheRun else { break }
            appendAssistantContent(roundResponse.assistantContent, to: &messages)
            messages.append(LanguageModelMessage(role: .user, content: toolResultBlocks))
        }

        return ElfAgentLoopResult(
            replyText: roundReplyTexts.joined(separator: " "),
            guidanceToolCalls: guidanceToolCalls,
            toolOutcomes: toolOutcomes,
            roundsUsed: roundsUsed,
            outputTokensUsed: outputTokensUsed
        )
    }
}
