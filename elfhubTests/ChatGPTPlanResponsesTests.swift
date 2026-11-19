//
//  ChatGPTPlanResponsesTests.swift
//  elfhubTests
//
//  The Responses API provider used with a ChatGPT plan, without the
//  network: the request body follows the plan's preview rules (store off,
//  streaming on, no output-token cap, instructions instead of a system
//  message, tools in a namespace), assistant turns replay verbatim, the SSE
//  stream becomes text, tool calls and a stop reason, and OpenAI's plan
//  errors are recognised wherever they arrive.
//

import Foundation
import Testing
@testable import elfhub

struct ChatGPTPlanResponsesTests {

    private let pointTool = LanguageModelToolDefinition(
        name: "point_at",
        description: "Point at something",
        inputSchema: ["type": "object", "properties": ["x": ["type": "number"]]]
    )

    private func sampleRequest(withImage: Bool = true, tools: [LanguageModelToolDefinition] = []) -> LanguageModelRequest {
        LanguageModelRequest(
            systemPrompt: "you are elfhub",
            history: [LanguageModelHistoryTurn(userText: "hi", assistantText: "hey")],
            userText: "what's this?",
            images: withImage ? [LanguageModelImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), label: "screen 1")] : [],
            tools: tools,
            reasoningEffort: .low
        )
    }

    private func inputItems(of body: [String: Any]) -> [[String: Any]] {
        body["input"] as? [[String: Any]] ?? []
    }

    // MARK: - Request body

    @Test func bodyFollowsThePlanRules() {
        let body = OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "gpt-test", request: sampleRequest(), includeImages: true)
        #expect(body["model"] as? String == "gpt-test")
        #expect(body["instructions"] as? String == "you are elfhub")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        for forbiddenField in ["max_output_tokens", "temperature", "top_p", "metadata", "previous_response_id", "truncation", "user"] {
            #expect(body[forbiddenField] == nil, "\(forbiddenField) must not be sent with a ChatGPT plan")
        }
        // The system prompt never appears as a system message.
        #expect(!inputItems(of: body).contains(where: { $0["role"] as? String == "system" }))
    }

    @Test func historyAndNewestQuestionBecomeMessages() {
        let items = inputItems(of: OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: sampleRequest(), includeImages: true))
        #expect(items.count == 3)
        #expect(items[0]["role"] as? String == "user")
        #expect(((items[0]["content"] as? [[String: Any]])?.first)?["type"] as? String == "input_text")
        #expect(items[1]["role"] as? String == "assistant")
        let assistantContent = items[1]["content"] as? [[String: Any]]
        #expect(assistantContent?.first?["type"] as? String == "output_text")
        #expect(assistantContent?.first?["text"] as? String == "hey")
        let newestContent = items[2]["content"] as? [[String: Any]] ?? []
        #expect(newestContent.map { $0["type"] as? String } == ["input_image", "input_text", "input_text"])
        #expect((newestContent[0]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        // The image's label sits right after the image.
        #expect(newestContent[1]["text"] as? String == "screen 1")
        #expect(newestContent[2]["text"] as? String == "what's this?")
    }

    @Test func imagesAreLeftOutForTextOnlyModels() {
        let items = inputItems(of: OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: sampleRequest(), includeImages: false))
        let newestContent = items.last?["content"] as? [[String: Any]] ?? []
        #expect(newestContent.map { $0["type"] as? String } == ["input_text"])
    }

    @Test func toolsAreGroupedInOneNamespace() {
        let body = OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: sampleRequest(tools: [pointTool]), includeImages: true)
        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "namespace")
        #expect(tools[0]["name"] as? String == OpenAIResponsesLanguageModelProvider.guidanceToolNamespace)
        let namespacedTools = tools[0]["tools"] as? [[String: Any]] ?? []
        #expect(namespacedTools.first?["type"] as? String == "function")
        #expect(namespacedTools.first?["name"] as? String == "point_at")
        #expect(namespacedTools.first?["parameters"] != nil)
    }

    @Test func noToolsMeansNoToolsField() {
        let body = OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: sampleRequest(), includeImages: true)
        #expect(body["tools"] == nil)
    }

    @Test func followUpReplaysRawItemsAndSendsToolOutputs() {
        let rawReasoningItem = #"{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]}"#
        let rawFunctionCallItem = #"{"type":"function_call","call_id":"call_1","name":"point_at","arguments":"{\"x\":1}"}"#
        let followUpRequest = LanguageModelRequest(
            systemPrompt: "you are elfhub",
            messages: [
                LanguageModelMessage(role: .user, content: [.text("where is save?")]),
                LanguageModelMessage(role: .assistant, content: [
                    .toolCall(LanguageModelToolCall(toolCallIdentifier: "call_1", toolName: "point_at", argumentsJSON: #"{"x":1}"#)),
                    .openAIResponsesRawItem(rawReasoningItem),
                    .openAIResponsesRawItem(rawFunctionCallItem),
                ]),
                LanguageModelMessage(role: .user, content: [
                    .toolResult(toolCallIdentifier: "call_1", toolName: "point_at", resultText: "shown"),
                ]),
            ],
            tools: [pointTool]
        )
        let items = inputItems(of: OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: followUpRequest, includeImages: true))
        #expect(items.map { $0["type"] as? String ?? $0["role"] as? String } == ["message", "reasoning", "function_call", "function_call_output"])
        #expect(items[1]["encrypted_content"] as? String == "opaque")
        #expect(items[2]["call_id"] as? String == "call_1")
        #expect(items[3]["call_id"] as? String == "call_1")
        #expect(items[3]["output"] as? String == "shown")
    }

    @Test func assistantTurnWithoutRawItemsIsRebuilt() {
        let request = LanguageModelRequest(
            systemPrompt: "s",
            messages: [
                LanguageModelMessage(role: .user, content: [.text("q")]),
                LanguageModelMessage(role: .assistant, content: [
                    .text("look here"),
                    .toolCall(LanguageModelToolCall(toolCallIdentifier: "call_9", toolName: "point_at", argumentsJSON: "{}")),
                    .anthropicRawBlock(#"{"type":"thinking"}"#),
                ]),
                LanguageModelMessage(role: .user, content: [.toolResult(toolCallIdentifier: "call_9", toolName: "point_at", resultText: "ok")]),
            ]
        )
        let items = inputItems(of: OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: request, includeImages: true))
        #expect(items.count == 4)
        #expect(items[1]["role"] as? String == "assistant")
        #expect(items[2]["type"] as? String == "function_call")
        #expect(items[2]["name"] as? String == "point_at")
        #expect(items[3]["type"] as? String == "function_call_output")
    }

    // MARK: - Stream

    private func feed(_ dataLines: [String], into accumulator: OpenAIResponsesStreamAccumulator) -> [OpenAIResponsesStreamAccumulator.LineOutcome] {
        dataLines.map { accumulator.consume(sseLine: "data: \($0)") }
    }

    @Test func textDeltasStreamAndCompletionFinishes() {
        let accumulator = OpenAIResponsesStreamAccumulator()
        #expect(accumulator.consume(sseLine: "event: response.created") == .none)
        let outcomes = feed([
            #"{"type":"response.created","response":{"id":"resp_1"}}"#,
            #"{"type":"response.output_text.delta","delta":"Hello"}"#,
            #"{"type":"response.output_text.delta","delta":", world"}"#,
            #"{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Hello, world"}]}}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":3,"input_tokens_details":{"cached_tokens":4}}}}"#,
        ], into: accumulator)
        #expect(outcomes[1] == .textDelta("Hello"))
        #expect(outcomes[2] == .textDelta(", world"))
        #expect(outcomes[4] == .finished)
        #expect(accumulator.accumulatedText == "Hello, world")
        #expect(accumulator.hasFinished)
        #expect(accumulator.stopReason == .endOfTurn)
        // The 12 input tokens include the 4 cached ones, counted apart.
        #expect(accumulator.usage == LanguageModelUsage(inputTokens: 8, outputTokens: 3, cacheReadInputTokens: 4))
    }

    @Test func functionCallsAreCollectedAndKeptForReplayWithoutServerIDs() throws {
        let accumulator = OpenAIResponsesStreamAccumulator()
        _ = feed([
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","namespace":"elfhub_screen","name":"point_at","arguments":"{\"x\":10}","status":"completed"}}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
        ], into: accumulator)
        #expect(accumulator.toolCalls == [LanguageModelToolCall(toolCallIdentifier: "call_1", toolName: "point_at", argumentsJSON: #"{"x":10}"#)])
        #expect(accumulator.stopReason == .toolUse)
        #expect(accumulator.rawOutputItems.count == 2)
        // Reasoning keeps its id (it travels with its encrypted content);
        // other items lose theirs, because nothing is stored on the server.
        let reasoningItem = try #require(try JSONSerialization.jsonObject(with: Data(accumulator.rawOutputItems[0].utf8)) as? [String: Any])
        #expect(reasoningItem["id"] as? String == "rs_1")
        let functionCallItem = try #require(try JSONSerialization.jsonObject(with: Data(accumulator.rawOutputItems[1].utf8)) as? [String: Any])
        #expect(functionCallItem["id"] == nil)
        #expect(functionCallItem["call_id"] as? String == "call_1")
    }

    @Test func namespacePrefixedToolNamesAreUnwrapped() {
        #expect(OpenAIResponsesLanguageModelProvider.unqualifiedToolName("elfhub_screen.point_at") == "point_at")
        #expect(OpenAIResponsesLanguageModelProvider.unqualifiedToolName("elfhub_screen__annotate") == "annotate")
        #expect(OpenAIResponsesLanguageModelProvider.unqualifiedToolName("point_at") == "point_at")
    }

    @Test func incompleteResponseReportsTheOutputLimit() {
        let accumulator = OpenAIResponsesStreamAccumulator()
        let outcomes = feed([#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#], into: accumulator)
        #expect(outcomes == [.finished])
        #expect(accumulator.stopReason == .outputTokenLimit)
    }

    @Test func usageLimitMidStreamIsRecognised() {
        let accumulator = OpenAIResponsesStreamAccumulator()
        let outcomes = feed([
            #"{"type":"response.output_text.delta","delta":"Sure"}"#,
            #"{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"#,
        ], into: accumulator)
        #expect(outcomes[1] == .failed(code: "subscription_sharing_usage_limit_exceeded", message: "limit", parameter: nil))
        #expect(ChatGPTPlanUsageError.from(streamFailureCode: "subscription_sharing_usage_limit_exceeded", parameter: nil) == .usageLimitReached)
    }

    @Test func topLevelErrorEventFails() {
        let accumulator = OpenAIResponsesStreamAccumulator()
        #expect(feed([#"{"type":"error","code":"subscription_sharing_usage_unavailable","message":"try later"}"#], into: accumulator)
            == [.failed(code: "subscription_sharing_usage_unavailable", message: "try later", parameter: nil)])
    }

    @Test func unsupportedCapabilityMidStreamKeepsTheParameter() {
        let accumulator = OpenAIResponsesStreamAccumulator()
        let outcomes = feed([
            #"{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_unsupported_capability","message":"not here","param":"tools"}}}"#,
        ], into: accumulator)
        #expect(outcomes == [.failed(code: "subscription_sharing_unsupported_capability", message: "not here", parameter: "tools")])
    }

    // MARK: - Plan errors

    @Test func structuredPlanErrorsMapToTheirRecovery() {
        func error(_ statusCode: Int, _ body: String) -> ChatGPTPlanUsageError? {
            ChatGPTPlanUsageError.from(LanguageModelProviderError.httpError(statusCode: statusCode, body: body))
        }
        #expect(error(429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}"#) == .usageLimitReached)
        #expect(error(503, #"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#) == .usageTemporarilyUnavailable)
        #expect(error(503, #"{"error":{"code":"subscription_sharing_user_unavailable"}}"#) == .usageTemporarilyUnavailable)
        #expect(error(403, #"{"error":{"code":"subscription_sharing_user_not_eligible"}}"#) == .notEligible)
        #expect(error(400, #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"temperature"}}"#) == .unsupportedCapability(parameter: "temperature"))
        #expect(error(401, #"{"detail":"Unauthorized"}"#) == .credentialRejected)
        #expect(error(503, #"{"detail":"Direct routing unavailable"}"#) == .usageTemporarilyUnavailable)
        #expect(error(500, "oops") == nil)
    }

    @Test func signInProblemsDuringATurnCountAsPlanErrors() {
        // A revoked or expired session must reach the fallback, not fail the turn.
        #expect(ChatGPTPlanUsageError.from(ChatGPTPlanSignInError.signInRequired) == .credentialRejected)
        #expect(ChatGPTPlanUsageError.from(ChatGPTPlanSignInError.tokenRequestFailed(statusCode: 503)) == .usageTemporarilyUnavailable)
        #expect(ChatGPTPlanUsageError.from(ChatGPTPlanSignInError.discoveryFailed) == .usageTemporarilyUnavailable)
        #expect(ChatGPTPlanUsageError.from(ChatGPTPlanSignInError.signInRequired)?.switchesToFallbackModel == true)
    }

    @Test func onlyLimitEligibilityAndAvailabilitySwitchToTheFallback() {
        #expect(ChatGPTPlanUsageError.usageLimitReached.switchesToFallbackModel)
        #expect(ChatGPTPlanUsageError.notEligible.switchesToFallbackModel)
        #expect(ChatGPTPlanUsageError.usageTemporarilyUnavailable.switchesToFallbackModel)
        #expect(ChatGPTPlanUsageError.planUsageNotEnabled.switchesToFallbackModel)
        #expect(!ChatGPTPlanUsageError.unsupportedCapability(parameter: "x").switchesToFallbackModel)
    }

    @Test func planErrorsThatWontClearByRetryingAreNotRetried() {
        #expect(!OpenAIResponsesLanguageModelProvider.shouldRetry(statusCode: 429, responseBody: #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#))
        #expect(!OpenAIResponsesLanguageModelProvider.shouldRetry(statusCode: 403, responseBody: #"{"error":{"code":"subscription_sharing_user_not_eligible"}}"#))
        #expect(OpenAIResponsesLanguageModelProvider.shouldRetry(statusCode: 503, responseBody: #"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#))
        #expect(OpenAIResponsesLanguageModelProvider.shouldRetry(statusCode: 429, responseBody: #"{"error":{"code":"rate_limit_exceeded"}}"#))
        #expect(!OpenAIResponsesLanguageModelProvider.shouldRetry(statusCode: 400, responseBody: "{}"))
    }

    // MARK: - Models

    @Test func modelListKeepsPickerModelsInServerOrder() {
        let models = ChatGPTPlanModel.parseModelList(fromResponseData: Data(#"""
        {"models":[
          {"slug":"gpt-b","display_name":"GPT B","visibility":"list"},
          {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"},
          {"slug":"gpt-a","display_name":"","visibility":"list"}
        ]}
        """#.utf8))
        #expect(models == [
            ChatGPTPlanModel(slug: "gpt-b", displayName: "GPT B"),
            ChatGPTPlanModel(slug: "gpt-a", displayName: "gpt-a"),
        ])
    }
}
