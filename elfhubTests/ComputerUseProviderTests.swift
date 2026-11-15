//
//  ComputerUseProviderTests.swift
//  elfhubTests
//
//  The multi-step screen loop's wire formats: Claude gets its computer
//  toolset (no name, members it can't use switched off) and its calls'
//  `toolset_name` is kept and echoed on every result; a result carries a
//  screenshot; models whose tool results can't hold images get the image in
//  a user message right after.
//

import Foundation
import Testing
@testable import elfhub

struct ComputerUseProviderTests {

    private let screenshotJPEGData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])

    private func computerToolResult(isError: Bool = false, withImage: Bool = true, toolsetName: String? = "computer") -> LanguageModelComputerToolResult {
        LanguageModelComputerToolResult(
            toolCallIdentifier: "toolu_1",
            toolName: "left_click",
            resultText: "OK. the screen changed.",
            image: withImage ? LanguageModelImage(data: screenshotJPEGData, label: "screen after the step") : nil,
            isError: isError,
            toolsetName: toolsetName
        )
    }

    private func followUpRequest(result: LanguageModelComputerToolResult, usesToolset: Bool = false) -> LanguageModelRequest {
        let toolCall = LanguageModelToolCall(toolCallIdentifier: "toolu_1", toolName: "left_click", argumentsJSON: #"{"coordinate":[10,20]}"#)
        var request = LanguageModelRequest(
            systemPrompt: "system",
            messages: [
                LanguageModelMessage(role: .user, content: [.text("open settings")]),
                LanguageModelMessage(role: .assistant, content: [.toolCall(toolCall)]),
                LanguageModelMessage(role: .user, content: [.computerToolResult(result)]),
            ]
        )
        request.usesAnthropicComputerToolset = usesToolset
        return request
    }

    // MARK: - Claude

    @Test func claudeGetsTheComputerToolsetOnlyDirectAndOnModelsThatTakeIt() throws {
        let request = followUpRequest(result: computerToolResult(), usesToolset: true)
        let directBody = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: request, isDirectToAnthropic: true)
        let tools = try #require(directBody["tools"] as? [[String: Any]])
        let toolsetEntry = try #require(tools.first { $0["type"] as? String == "computer_toolset_20260801" })
        #expect(toolsetEntry["name"] == nil)
        let configs = try #require(toolsetEntry["configs"] as? [String: [String: Bool]])
        for disabledMemberName in ["middle_click", "left_mouse_down", "left_mouse_up", "hold_key"] {
            #expect(configs[disabledMemberName]?["enabled"] == false)
        }
        #expect(configs["zoom"] == nil)

        let proxiedBody = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: request, isDirectToAnthropic: false)
        #expect(proxiedBody["tools"] == nil)

        #expect(ClaudeAPI.supportsComputerToolset(model: "claude-opus-5-5"))
        #expect(ClaudeAPI.supportsComputerToolset(model: "claude-sonnet-5-5"))
        #expect(ClaudeAPI.supportsComputerToolset(model: "claude-haiku-5-5"))
        #expect(ClaudeAPI.supportsComputerToolset(model: "claude-fable-5-2"))
        #expect(!ClaudeAPI.supportsComputerToolset(model: "claude-sonnet-4-6"))
    }

    @Test func claudeResultsEchoTheToolsetNameAndCarryTheScreenshot() throws {
        let body = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: followUpRequest(result: computerToolResult(isError: true)), isDirectToAnthropic: false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let resultBlocks = try #require(messages.last?["content"] as? [[String: Any]])
        let resultBlock = try #require(resultBlocks.first)
        #expect(resultBlock["type"] as? String == "tool_result")
        #expect(resultBlock["tool_use_id"] as? String == "toolu_1")
        #expect(resultBlock["toolset_name"] as? String == "computer")
        #expect(resultBlock["is_error"] as? Bool == true)
        let resultContent = try #require(resultBlock["content"] as? [[String: Any]])
        #expect(resultContent.map { $0["type"] as? String } == ["text", "image"])

        let functionResultBody = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: followUpRequest(result: computerToolResult(toolsetName: nil)), isDirectToAnthropic: false)
        let functionResultBlock = try #require(((functionResultBody["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first)
        #expect(functionResultBlock["toolset_name"] == nil)
        #expect(functionResultBlock["is_error"] == nil)
    }

    @Test func claudeToolsetCallsKeepTheirToolsetName() {
        var accumulator = AnthropicStreamAccumulator()
        let streamLines = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"left_click","toolset_name":"computer","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"coordinate\":[5,6]}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ]
        for streamLine in streamLines {
            _ = accumulator.consume(sseLine: streamLine)
        }
        #expect(accumulator.toolCalls.first?.toolsetName == "computer")
        #expect(accumulator.toolCalls.first?.toolName == "left_click")
    }

    // MARK: - Other providers

    @Test func openAICompatibleSendsTheScreenshotInAUserMessageAfterTheToolMessage() throws {
        let body = OpenAICompatibleLanguageModelProvider.buildRequestBody(model: "m", request: followUpRequest(result: computerToolResult()), includeImages: true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let lastTwoMessages = Array(messages.suffix(2))
        #expect(lastTwoMessages.first?["role"] as? String == "tool")
        #expect(lastTwoMessages.first?["content"] as? String == "OK. the screen changed.")
        #expect(lastTwoMessages.last?["role"] as? String == "user")
        let imageParts = try #require(lastTwoMessages.last?["content"] as? [[String: Any]])
        #expect(imageParts.contains { $0["type"] as? String == "image_url" })

        let textOnlyBody = OpenAICompatibleLanguageModelProvider.buildRequestBody(model: "m", request: followUpRequest(result: computerToolResult()), includeImages: false)
        let textOnlyMessages = try #require(textOnlyBody["messages"] as? [[String: Any]])
        #expect(textOnlyMessages.last?["role"] as? String == "tool")
    }

    @Test func geminiPutsTheScreenshotNextToTheFunctionResponse() throws {
        let body = GeminiLanguageModelProvider.buildRequestBody(request: followUpRequest(result: computerToolResult()), includeImages: true)
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.last?["parts"] as? [[String: Any]])
        #expect(parts.first?["functionResponse"] != nil)
        #expect(parts.contains { $0["inline_data"] != nil })
    }

    @Test func responsesSendsTheOutputThenTheScreenshot() throws {
        let body = OpenAIResponsesLanguageModelProvider.buildRequestBody(model: "m", request: followUpRequest(result: computerToolResult()), includeImages: true)
        let inputItems = try #require(body["input"] as? [[String: Any]])
        let outputIndex = try #require(inputItems.firstIndex { $0["type"] as? String == "function_call_output" })
        #expect(inputItems[outputIndex]["output"] as? String == "OK. the screen changed.")
        let imageMessage = inputItems[outputIndex + 1]
        #expect(imageMessage["role"] as? String == "user")
        let imageParts = try #require(imageMessage["content"] as? [[String: Any]])
        #expect(imageParts.contains { $0["type"] as? String == "input_image" })
    }
}
