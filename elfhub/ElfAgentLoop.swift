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

import Foundation

struct ElfAgentLoopResult {
    /// The text of every round, joined.
    var replyText: String
    /// Guidance calls from every round, in order, for the pipeline to draw.
    var guidanceToolCalls: [LanguageModelToolCall]
    var toolOutcomes: [ElfToolOutcome]
    var roundsUsed: Int
}

@MainActor
enum ElfAgentLoop {
    /// Added to the system prompt of the last allowed round.
    static let answerNowInstruction = "you've used all your tool rounds for this reply. answer now with what you have."

    /// What a guidance call "returns" to the model.
    static let guidanceToolResultText = "shown to the user on their screen"

    static func run(
        initialRequest: LanguageModelRequest,
        languageModelProvider: LanguageModelProvider,
        toolRegistry: ElfToolRegistry,
        toolContext: ElfToolContext?,
        guidanceToolNames: Set<String>,
        maximumRounds: Int,
        onReplyTextDelta: @escaping @MainActor @Sendable (String) -> Void,
        onModelRoundEnded: @MainActor () -> Void
    ) async throws -> ElfAgentLoopResult {
        var messages = initialRequest.messages
        var roundReplyTexts: [String] = []
        var guidanceToolCalls: [LanguageModelToolCall] = []
        var toolOutcomes: [ElfToolOutcome] = []
        var roundsUsed = 0

        for roundNumber in 1...max(1, maximumRounds) {
            try Task.checkCancellation()
            // The tools stay defined on the last round (providers refuse a
            // conversation with tool calls but no tools); the model is told
            // to answer instead.
            let isLastAllowedRound = roundNumber == maximumRounds && roundNumber > 1
            let roundRequest = LanguageModelRequest(
                systemPrompt: isLastAllowedRound
                    ? initialRequest.systemPrompt + "\n\n" + answerNowInstruction
                    : initialRequest.systemPrompt,
                messages: messages,
                tools: initialRequest.tools,
                maxOutputTokens: initialRequest.maxOutputTokens,
                reasoningEffort: initialRequest.reasoningEffort
            )
            let roundResponse = try await languageModelProvider.streamResponse(roundRequest) { streamEvent in
                if case let .textDelta(textDelta) = streamEvent {
                    onReplyTextDelta(textDelta)
                }
            }
            try Task.checkCancellation()
            roundsUsed = roundNumber
            onModelRoundEnded()

            let trimmedRoundText = roundResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRoundText.isEmpty {
                roundReplyTexts.append(trimmedRoundText)
            }
            guidanceToolCalls += roundResponse.toolCalls.filter { guidanceToolNames.contains($0.toolName) }
            guard !roundResponse.toolCalls.isEmpty else { break }

            var toolResultBlocks: [LanguageModelContentBlock] = []
            var needsAnotherRound = trimmedRoundText.isEmpty
            for toolCall in roundResponse.toolCalls {
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
                if toolOutcome.isFailure || calledTool?.resultFeedsBackToModel == true {
                    needsAnotherRound = true
                }
                toolResultBlocks.append(.toolResult(
                    toolCallIdentifier: toolCall.toolCallIdentifier,
                    toolName: toolCall.toolName,
                    resultText: toolOutcome.resultText
                ))
            }
            // Calls in the last round still run (a file the model says it
            // saved is saved); there's just no round after it.
            guard needsAnotherRound, roundNumber < maximumRounds else { break }
            messages.append(LanguageModelMessage(role: .assistant, content: roundResponse.assistantContent))
            messages.append(LanguageModelMessage(role: .user, content: toolResultBlocks))
        }

        return ElfAgentLoopResult(
            replyText: roundReplyTexts.joined(separator: " "),
            guidanceToolCalls: guidanceToolCalls,
            toolOutcomes: toolOutcomes,
            roundsUsed: roundsUsed
        )
    }
}
