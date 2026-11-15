//
//  AnthropicLanguageModelProvider.swift
//  elfhub
//
//  Adapts ClaudeAPI to the LanguageModelProvider protocol (direct calls with
//  the user's own key).
//

import Foundation

final class AnthropicLanguageModelProvider: LanguageModelProvider {
    let displayName: String
    let capabilities: LanguageModelCapabilities

    private let claudeAPI: ClaudeAPI

    init(claudeAPI: ClaudeAPI, displayName: String, capabilities: LanguageModelCapabilities) {
        self.claudeAPI = claudeAPI
        self.displayName = displayName
        self.capabilities = capabilities
    }

    /// Claude's web search tool runs on Anthropic's servers, so only when
    /// talking to the Claude API itself with the user's key.
    var supportsProviderWebSearch: Bool { claudeAPI.isDirectToAnthropic }

    func streamResponse(
        _ request: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse {
        try await claudeAPI.streamMessages(request, onStreamEvent: onStreamEvent)
    }
}
