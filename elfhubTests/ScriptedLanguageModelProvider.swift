//
//  ScriptedLanguageModelProvider.swift
//  elfhubTests
//
//  A language model for tests: answers each request with the next scripted
//  response (streaming its text as one delta) and keeps every request it
//  was sent, so a test can check what the model saw.
//

import Foundation
@testable import elfhub

final class ScriptedLanguageModelProvider: LanguageModelProvider {
    let displayName = "Scripted model"
    let capabilities: LanguageModelCapabilities
    private var scriptedResponses: [LanguageModelResponse]
    private(set) var receivedRequests: [LanguageModelRequest] = []
    /// Runs before each response is returned (e.g. to cancel the task).
    var beforeEachResponse: (() -> Void)?
    /// How long each answer takes (to test time limits).
    var responseDelayInSeconds: Double = 0

    init(scriptedResponses: [LanguageModelResponse], supportsToolCalling: Bool = true) {
        self.scriptedResponses = scriptedResponses
        self.capabilities = LanguageModelCapabilities(
            supportsVision: false,
            supportsToolCalling: supportsToolCalling,
            visionProfile: .genericVisionModel(coordinateConvention: .imagePixels)
        )
    }

    func streamResponse(
        _ request: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse {
        receivedRequests.append(request)
        beforeEachResponse?()
        if responseDelayInSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelayInSeconds * 1_000_000_000))
        }
        guard !scriptedResponses.isEmpty else {
            return Self.reply("(no more scripted replies)")
        }
        let scriptedResponse = scriptedResponses.removeFirst()
        if !scriptedResponse.text.isEmpty {
            onStreamEvent(.textDelta(scriptedResponse.text))
        }
        return scriptedResponse
    }

    /// A plain text reply.
    static func reply(_ replyText: String) -> LanguageModelResponse {
        LanguageModelResponse(text: replyText, toolCalls: [], assistantContent: [.text(replyText)], duration: 0, stopReason: .endOfTurn)
    }

    /// A reply that calls tools (with optional text before the calls).
    static func toolCalls(_ toolCalls: [LanguageModelToolCall], text replyText: String = "") -> LanguageModelResponse {
        let textBlocks: [LanguageModelContentBlock] = replyText.isEmpty ? [] : [.text(replyText)]
        return LanguageModelResponse(
            text: replyText,
            toolCalls: toolCalls,
            assistantContent: textBlocks + toolCalls.map { LanguageModelContentBlock.toolCall($0) },
            duration: 0,
            stopReason: .toolUse
        )
    }

    static func toolCall(_ toolName: String, _ arguments: [String: Any]) -> LanguageModelToolCall {
        let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return LanguageModelToolCall(toolCallIdentifier: "call-\(UUID().uuidString.prefix(8))", toolName: toolName, argumentsJSON: argumentsJSON)
    }
}
