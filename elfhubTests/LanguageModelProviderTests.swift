//
//  LanguageModelProviderTests.swift
//  elfhubTests
//
//  Unit tests for the model-agnostic provider adapters.
//  These cover the pure request-building and SSE-parsing logic — the parts that
//  differ per provider — without any network access: text deltas, streamed
//  tool calls, tool definitions and tool results on the wire.
//

import Foundation
import Testing
@testable import elfhub

struct LanguageModelProviderTests {

    private func sampleRequest(withImage: Bool, tools: [LanguageModelToolDefinition] = []) -> LanguageModelRequest {
        LanguageModelRequest(
            systemPrompt: "you are elfhub",
            history: [LanguageModelHistoryTurn(userText: "hi", assistantText: "hey")],
            userText: "what's this?",
            images: withImage ? [LanguageModelImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), label: "screen 1")] : [],
            tools: tools
        )
    }

    private let sampleToolCall = LanguageModelToolCall(
        toolCallIdentifier: "call_1",
        toolName: "point_at",
        argumentsJSON: #"{"x":10,"y":20,"label":"save"}"#
    )

    // MARK: - Anthropic body

    @Test func anthropicBodyHasSystemMessagesAndTools() {
        let body = ClaudeAPI.buildRequestBody(
            model: "claude-opus-5-5",
            request: sampleRequest(withImage: true, tools: [GuidanceToolDefinitions.pointToolDefinition])
        )
        #expect(body["system"] as? String == "you are elfhub")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 3)
        let finalContent = messages.last!["content"] as! [[String: Any]]
        #expect(finalContent.first?["type"] as? String == "image")
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools.first?["name"] as? String == "point_at")
        #expect(tools.first?["input_schema"] != nil)
    }

    @Test func anthropicBodyEncodesToolUseAndResultAndReplaysRawBlocks() {
        let rawThinkingBlock = #"{"type":"thinking","thinking":"","signature":"sig"}"#
        let request = LanguageModelRequest(
            systemPrompt: "s",
            messages: [
                LanguageModelMessage(role: .user, content: [.text("point at save")]),
                LanguageModelMessage(role: .assistant, content: [.anthropicRawBlock(rawThinkingBlock), .toolCall(sampleToolCall)]),
                LanguageModelMessage(role: .user, content: [.toolResult(toolCallIdentifier: "call_1", toolName: "point_at", resultText: "shown")]),
            ]
        )
        let messages = ClaudeAPI.buildRequestBody(model: "m", request: request)["messages"] as! [[String: Any]]
        let assistantContent = messages[1]["content"] as! [[String: Any]]
        #expect(assistantContent[0]["type"] as? String == "thinking")
        #expect(assistantContent[0]["signature"] as? String == "sig")
        #expect(assistantContent[1]["type"] as? String == "tool_use")
        #expect((assistantContent[1]["input"] as? [String: Any])?["label"] as? String == "save")
        let toolResult = (messages[2]["content"] as! [[String: Any]])[0]
        #expect(toolResult["type"] as? String == "tool_result")
        #expect(toolResult["tool_use_id"] as? String == "call_1")
    }

    @Test func directAnthropicEndpointAppendsMessagesPath() {
        #expect(ClaudeAPI.directMessagesEndpointURL(forBaseURL: "https://api.anthropic.com")?.absoluteString
                == "https://api.anthropic.com/v1/messages")
        #expect(ClaudeAPI.directMessagesEndpointURL(forBaseURL: "https://api.anthropic.com/")?.absoluteString
                == "https://api.anthropic.com/v1/messages")
        #expect(ClaudeAPI.directMessagesEndpointURL(forBaseURL: "https://proxy.example/v1/messages")?.absoluteString
                == "https://proxy.example/v1/messages")
    }

    @Test func serverSideFallbackOnlyForDirectFallbackCapableModels() {
        #expect(ClaudeAPI.shouldRequestServerSideFallback(model: "claude-opus-5-5", isDirectToAnthropic: true))
        #expect(ClaudeAPI.shouldRequestServerSideFallback(model: "claude-sonnet-5-5", isDirectToAnthropic: true))
        #expect(!ClaudeAPI.shouldRequestServerSideFallback(model: "claude-haiku-5-5", isDirectToAnthropic: true))
        #expect(!ClaudeAPI.shouldRequestServerSideFallback(model: "claude-opus-5-5", isDirectToAnthropic: false))
    }

    // MARK: - Anthropic stream

    @Test func anthropicStreamAssemblesTextAndToolCalls() {
        var accumulator = AnthropicStreamAccumulator()
        let lines = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"it's "}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"here."}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"point_at","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"x\":10,"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"y\":20}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]
        var textDeltas: [String] = []
        for line in lines {
            if case let .textDelta(textDelta) = accumulator.consume(sseLine: line) {
                textDeltas.append(textDelta)
            }
        }
        #expect(textDeltas == ["it's ", "here."])
        #expect(accumulator.accumulatedText == "it's here.")
        #expect(accumulator.stopReason == "tool_use")
        #expect(accumulator.toolCalls.count == 1)
        #expect(accumulator.toolCalls.first?.toolName == "point_at")
        #expect(accumulator.toolCalls.first?.argumentsDictionary["y"] as? Int == 20)
        #expect(accumulator.assistantContentBlocks.count == 2)
        #expect(accumulator.consume(sseLine: #"data: {"type":"message_stop"}"#) == .streamEnded)
    }

    @Test func anthropicStreamKeepsSignedThinkingBlockVerbatim() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#)
        guard case let .anthropicRawBlock(rawBlockJSON) = accumulator.assistantContentBlocks.first else {
            Issue.record("expected a raw thinking block")
            return
        }
        #expect(rawBlockJSON.contains("\"signature\":\"abc\""))
    }

    @Test func anthropicFallbackBlockDiscardsDeclinedPartialOutput() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback"}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"fresh answer"}}"#)
        #expect(accumulator.accumulatedText == "fresh answer")
    }

    @Test func anthropicRecordsRefusal() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        #expect(accumulator.stopReason == "refusal")
    }

    // MARK: - OpenAI-compatible body

    @Test func openAIBodyIncludesSystemHistoryAndImage() {
        let body = OpenAICompatibleLanguageModelProvider.buildRequestBody(
            model: "gpt-4o", request: sampleRequest(withImage: true), includeImages: true
        )

        #expect(body["model"] as? String == "gpt-4o")
        #expect(body["stream"] as? Bool == true)

        let messages = body["messages"] as! [[String: Any]]
        #expect((messages.first?["role"] as? String) == "system")
        // system + (user,assistant history) + final user = 4
        #expect(messages.count == 4)

        let finalMessage = messages.last!
        #expect(finalMessage["role"] as? String == "user")
        let contentParts = finalMessage["content"] as! [[String: Any]]
        #expect(contentParts.contains { $0["type"] as? String == "image_url" })
        #expect(contentParts.contains { $0["type"] as? String == "text" })
    }

    @Test func openAIBodyOmitsImageForTextOnlyModel() {
        let body = OpenAICompatibleLanguageModelProvider.buildRequestBody(
            model: "llama3", request: sampleRequest(withImage: true), includeImages: false
        )
        let messages = body["messages"] as! [[String: Any]]
        // Final user message is a plain string, not a content-part array.
        #expect(messages.last?["content"] as? String == "what's this?")
    }

    @Test func openAIBodyEncodesToolsCallsAndResults() {
        let request = LanguageModelRequest(
            systemPrompt: "s",
            messages: [
                LanguageModelMessage(role: .user, content: [.text("point at save")]),
                LanguageModelMessage(role: .assistant, content: [.toolCall(sampleToolCall)]),
                LanguageModelMessage(role: .user, content: [.toolResult(toolCallIdentifier: "call_1", toolName: "point_at", resultText: "shown")]),
            ],
            tools: [GuidanceToolDefinitions.pointToolDefinition]
        )
        let body = OpenAICompatibleLanguageModelProvider.buildRequestBody(model: "m", request: request, includeImages: false)
        let messages = body["messages"] as! [[String: Any]]
        let assistantToolCalls = messages[2]["tool_calls"] as! [[String: Any]]
        #expect((assistantToolCalls[0]["function"] as? [String: Any])?["name"] as? String == "point_at")
        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools.first?["type"] as? String == "function")
    }

    // MARK: - OpenAI-compatible stream

    @Test func openAIStreamParsesTextAndStitchesToolCalls() {
        var accumulator = OpenAIStreamAccumulator()
        #expect(accumulator.consume(sseLine: #"data: {"choices":[{"delta":{"content":"hel"}}]}"#) == .textDelta("hel"))
        _ = accumulator.consume(sseLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"annotate","arguments":"{\"shape\":"}}]}}]}"#)
        _ = accumulator.consume(sseLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"circle\"}"}}]}}]}"#)
        #expect(accumulator.consume(sseLine: "data: [DONE]") == .streamEnded)
        #expect(accumulator.accumulatedText == "hel")
        #expect(accumulator.toolCalls == [LanguageModelToolCall(toolCallIdentifier: "c1", toolName: "annotate", argumentsJSON: #"{"shape":"circle"}"#)])
    }

    @Test func openAIIgnoresNonDataLines() {
        var accumulator = OpenAIStreamAccumulator()
        #expect(accumulator.consume(sseLine: "") == .none)
        #expect(accumulator.consume(sseLine: ": keep-alive") == .none)
    }

    // MARK: - Gemini

    @Test func geminiBodyHasSystemInstructionContentsAndFunctionDeclarations() {
        let body = GeminiLanguageModelProvider.buildRequestBody(
            request: sampleRequest(withImage: true, tools: [GuidanceToolDefinitions.annotateToolDefinition]),
            includeImages: true
        )

        let systemInstruction = body["system_instruction"] as! [String: Any]
        let systemParts = systemInstruction["parts"] as! [[String: Any]]
        #expect(systemParts.first?["text"] as? String == "you are elfhub")

        let contents = body["contents"] as! [[String: Any]]
        // (user, model history) + final user = 3
        #expect(contents.count == 3)
        #expect(contents.last?["role"] as? String == "user")
        let finalParts = contents.last?["parts"] as! [[String: Any]]
        #expect(finalParts.contains { $0["inline_data"] != nil })

        let tools = body["tools"] as! [[String: Any]]
        let functionDeclarations = tools.first?["functionDeclarations"] as! [[String: Any]]
        #expect(functionDeclarations.first?["name"] as? String == "annotate")
    }

    @Test func geminiBodyOmitsImageForTextOnlyModel() {
        let body = GeminiLanguageModelProvider.buildRequestBody(
            request: sampleRequest(withImage: true), includeImages: false
        )
        let contents = body["contents"] as! [[String: Any]]
        let finalParts = contents.last?["parts"] as! [[String: Any]]
        #expect(finalParts.contains { $0["inline_data"] != nil } == false)
    }

    @Test func geminiParsesTextAndFunctionCalls() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"world"},{"functionCall":{"name":"point_at","args":{"x":1,"y":2,"label":"a"}}}]}}]}"#
        let parsedChunk = GeminiLanguageModelProvider.parseStreamedChunk(fromSSELine: line)
        #expect(parsedChunk.textDelta == "world")
        #expect(parsedChunk.functionCalls.first?.name == "point_at")
    }

    @Test func geminiIgnoresEmptyOrNonData() {
        #expect(GeminiLanguageModelProvider.parseStreamedChunk(fromSSELine: "data: {}").textDelta == nil)
        #expect(GeminiLanguageModelProvider.parseStreamedChunk(fromSSELine: "event: ping").functionCalls.isEmpty)
    }

    // MARK: - Local server discovery

    @Test func parsesModelListAndDetectsLocalURLs() {
        let modelsResponse = Data(#"{"data":[{"id":"qwen2.5vl:7b"},{"id":"llava:13b"}]}"#.utf8)
        #expect(LocalModelServerDiscovery.parseModelIdentifiers(fromModelsResponse: modelsResponse) == ["llava:13b", "qwen2.5vl:7b"])
        #expect(LocalModelServerPreset.isLocalBaseURL("http://localhost:11434/v1"))
        #expect(LocalModelServerPreset.isLocalBaseURL("http://127.0.0.1:1234/v1"))
        #expect(!LocalModelServerPreset.isLocalBaseURL("https://openrouter.ai/api/v1"))
    }
}
