//
//  LanguageModelReliabilityTests.swift
//  elfhubTests
//
//  What keeps model calls fast and honest: retrying only failures that
//  happen before anything streams, prompt-cache breakpoints and effort on
//  the Claude API, image labels reaching every provider, stream errors and
//  output-limit cut-offs surfacing instead of passing as complete replies.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct LanguageModelReliabilityTests {

    private func sampleRequest(reasoningEffort: LanguageModelReasoningEffort? = nil) -> LanguageModelRequest {
        LanguageModelRequest(
            systemPrompt: "you are elfhub",
            history: [LanguageModelHistoryTurn(userText: "hi", assistantText: "hey")],
            userText: "what's this?",
            images: [LanguageModelImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), label: "screen 1, image 1280x800")],
            tools: [GuidanceToolDefinitions.pointToolDefinition],
            reasoningEffort: reasoningEffort
        )
    }

    // MARK: - Retry policy

    @Test func retriesOnlyTransientServerFailures() {
        #expect(LanguageModelRetryPolicy.shouldRetry(statusCode: 429))
        #expect(LanguageModelRetryPolicy.shouldRetry(statusCode: 529))
        #expect(LanguageModelRetryPolicy.shouldRetry(statusCode: 503))
        #expect(!LanguageModelRetryPolicy.shouldRetry(statusCode: 400))
        #expect(!LanguageModelRetryPolicy.shouldRetry(statusCode: 401))
        #expect(!LanguageModelRetryPolicy.shouldRetry(statusCode: 404))
        #expect(LanguageModelRetryPolicy.isRetryableTransportError(URLError(.networkConnectionLost)))
        #expect(!LanguageModelRetryPolicy.isRetryableTransportError(URLError(.cancelled)))
        #expect(!LanguageModelRetryPolicy.isRetryableTransportError(CancellationError()))
    }

    @Test func backsOffAndHonorsRetryAfterWithinACap() {
        #expect(LanguageModelRetryPolicy.delayBeforeRetry(afterAttempt: 1, retryAfterHeaderValue: nil) == 0.5)
        #expect(LanguageModelRetryPolicy.delayBeforeRetry(afterAttempt: 2, retryAfterHeaderValue: nil) == 1.5)
        #expect(LanguageModelRetryPolicy.delayBeforeRetry(afterAttempt: 1, retryAfterHeaderValue: "3") == 3)
        #expect(LanguageModelRetryPolicy.delayBeforeRetry(afterAttempt: 1, retryAfterHeaderValue: "120") == LanguageModelRetryPolicy.maximumDelayBeforeRetryInSeconds)
    }

    // MARK: - Claude request body

    @Test func directClaudeRequestsMarkCacheBreakpoints() {
        let body = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: sampleRequest(), isDirectToAnthropic: true)

        let systemBlocks = body["system"] as! [[String: Any]]
        #expect(systemBlocks.first?["text"] as? String == "you are elfhub")
        #expect((systemBlocks.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // The earlier conversation (ending with the history assistant turn)
        // is cached; the newest message with the fresh screenshot is not.
        let messages = body["messages"] as! [[String: Any]]
        let historyAssistantContent = messages[1]["content"] as! [[String: Any]]
        #expect(historyAssistantContent.last?["cache_control"] != nil)
        let newestContent = messages[2]["content"] as! [[String: Any]]
        #expect(newestContent.allSatisfy { $0["cache_control"] == nil })
    }

    @Test func otherAnthropicCompatibleEndpointsGetAPlainBody() {
        let body = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: sampleRequest(reasoningEffort: .low))
        #expect(body["system"] as? String == "you are elfhub")
        #expect(body["output_config"] == nil)
    }

    @Test func effortIsSentOnlyToModelsThatAcceptIt() {
        let supportedBody = ClaudeAPI.buildRequestBody(
            model: "claude-opus-5-5",
            request: sampleRequest(reasoningEffort: .low),
            isDirectToAnthropic: true
        )
        #expect((supportedBody["output_config"] as? [String: Any])?["effort"] as? String == "low")

        let olderModelBody = ClaudeAPI.buildRequestBody(
            model: "claude-haiku-4-5",
            request: sampleRequest(reasoningEffort: .low),
            isDirectToAnthropic: true
        )
        #expect(olderModelBody["output_config"] == nil)

        let noEffortBody = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: sampleRequest(), isDirectToAnthropic: true)
        #expect(noEffortBody["output_config"] == nil)
    }

    @Test func claudeAndGeminiReceiveTheImageLabel() {
        let claudeMessages = ClaudeAPI.buildRequestBody(model: "m", request: sampleRequest())["messages"] as! [[String: Any]]
        let claudeNewestContent = claudeMessages.last!["content"] as! [[String: Any]]
        #expect(claudeNewestContent[0]["type"] as? String == "image")
        #expect(claudeNewestContent[1]["text"] as? String == "screen 1, image 1280x800")

        let geminiContents = GeminiLanguageModelProvider.buildRequestBody(request: sampleRequest(), includeImages: true)["contents"] as! [[String: Any]]
        let geminiNewestParts = geminiContents.last!["parts"] as! [[String: Any]]
        #expect(geminiNewestParts[0]["inline_data"] != nil)
        #expect(geminiNewestParts[1]["text"] as? String == "screen 1, image 1280x800")
    }

    @Test func betaHeaderJoinsEveryBeta() {
        #expect(ClaudeAPI.anthropicBetaHeaderValue(forBetas: []) == nil)
        #expect(ClaudeAPI.anthropicBetaHeaderValue(forBetas: ["a-2026", "b-2026"]) == "a-2026,b-2026")
    }

    // MARK: - Claude stream

    @Test func claudeStreamReportsUsageAndStopReason() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"cache_read_input_tokens":3400,"cache_creation_input_tokens":0,"output_tokens":1}}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":8192}}"#)
        #expect(accumulator.usage == LanguageModelUsage(inputTokens: 1200, outputTokens: 8192, cacheReadInputTokens: 3400, cacheCreationInputTokens: 0))
        #expect(accumulator.stopReason.map(ClaudeAPI.normalizedStopReason(fromAnthropicStopReason:)) == .outputTokenLimit)
    }

    @Test func claudeStreamErrorEndsTheStreamAndIsRemembered() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half an ans"}}"#)
        let outcome = accumulator.consume(sseLine: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        #expect(outcome == .streamEnded)
        #expect(accumulator.streamErrorMessage == "overloaded_error: Overloaded")
    }

    @Test func stopReasonsNormalizeAcrossProviders() {
        #expect(ClaudeAPI.normalizedStopReason(fromAnthropicStopReason: "end_turn") == .endOfTurn)
        #expect(ClaudeAPI.normalizedStopReason(fromAnthropicStopReason: "tool_use") == .toolUse)
        #expect(ClaudeAPI.normalizedStopReason(fromAnthropicStopReason: "pause_turn") == .pausedByServer)
        #expect(OpenAICompatibleLanguageModelProvider.normalizedStopReason(fromFinishReason: "length") == .outputTokenLimit)
        #expect(OpenAICompatibleLanguageModelProvider.normalizedStopReason(fromFinishReason: "tool_calls") == .toolUse)
        #expect(GeminiLanguageModelProvider.normalizedStopReason(fromFinishReason: "MAX_TOKENS") == .outputTokenLimit)
        #expect(GeminiLanguageModelProvider.normalizedStopReason(fromFinishReason: "SAFETY") == .refusal)
    }

    @Test func openAIAndGeminiStreamsCaptureTheFinishReason() {
        var openAIAccumulator = OpenAIStreamAccumulator()
        _ = openAIAccumulator.consume(sseLine: #"data: {"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}"#)
        _ = openAIAccumulator.consume(sseLine: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        #expect(openAIAccumulator.finishReason == "length")

        let geminiLine = #"data: {"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"MAX_TOKENS"}]}"#
        #expect(GeminiLanguageModelProvider.finishReason(fromSSELine: geminiLine) == "MAX_TOKENS")
    }

    // MARK: - Effort per turn

    @Test func spokenQuestionsThinkLessAndActingNeverDropsBelowTheDefault() {
        #expect(CompanionTurnPipeline.reasoningEffort(isActionModeEnabled: false, isSpokenTurn: true) == .low)
        #expect(CompanionTurnPipeline.reasoningEffort(isActionModeEnabled: true, isSpokenTurn: true) == .medium)
        #expect(CompanionTurnPipeline.reasoningEffort(isActionModeEnabled: false, isSpokenTurn: false) == nil)
    }

    @Test func requestsLeaveRoomForThinking() {
        #expect(sampleRequest().maxOutputTokens == LanguageModelRequest.defaultMaxOutputTokens)
        #expect(LanguageModelRequest.defaultMaxOutputTokens >= 8192)
    }
}
