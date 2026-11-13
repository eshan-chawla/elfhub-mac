//
//  OpenAICompatibleLanguageModelProvider.swift
//  elfhub
//
//  Talks to any endpoint implementing OpenAI's /chat/completions API: OpenAI
//  itself, OpenRouter, and local servers like Ollama, LM Studio, llama.cpp and
//  vLLM. The only difference between them is the base URL and key, so one
//  adapter covers them all — including local models (base URL on localhost,
//  key often blank).
//

import Foundation

final class OpenAICompatibleLanguageModelProvider: LanguageModelProvider {
    let displayName: String
    let capabilities: LanguageModelCapabilities

    private let chatCompletionsURL: URL
    private let apiKey: String?
    private let model: String
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: e.g. "https://openrouter.ai/api/v1" or "http://localhost:11434/v1".
    ///   - apiKey: sent as a Bearer token; omit for keyless local servers.
    init(displayName: String, baseURL: String, apiKey: String?, model: String, capabilities: LanguageModelCapabilities) throws {
        guard let chatCompletionsURL = LanguageModelWireFormatSupport.url(byAppending: "/chat/completions", to: baseURL) else {
            throw LanguageModelProviderError.missingConfiguration("invalid base URL \"\(baseURL)\"")
        }
        self.chatCompletionsURL = chatCompletionsURL
        self.apiKey = apiKey
        self.model = model
        self.displayName = displayName
        self.capabilities = capabilities

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func streamResponse(
        _ request: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse {
        let startTime = Date()

        var urlRequest = URLRequest(url: chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = Self.buildRequestBody(model: model, request: request, includeImages: capabilities.supportsVision)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let byteStream = try await LanguageModelHTTPStreaming.openStream(urlRequest, using: session, providerName: displayName)

        var streamAccumulator = OpenAIStreamAccumulator()
        streamLoop: for try await line in byteStream.lines {
            try Task.checkCancellation()
            switch streamAccumulator.consume(sseLine: line) {
            case .none:
                continue
            case let .textDelta(textDelta):
                onStreamEvent(.textDelta(textDelta))
            case .streamEnded:
                break streamLoop
            }
        }

        let toolCalls = streamAccumulator.toolCalls
        var assistantContent: [LanguageModelContentBlock] = []
        if !streamAccumulator.accumulatedText.isEmpty {
            assistantContent.append(.text(streamAccumulator.accumulatedText))
        }
        assistantContent.append(contentsOf: toolCalls.map { LanguageModelContentBlock.toolCall($0) })

        let normalizedStopReason = streamAccumulator.finishReason.map(Self.normalizedStopReason(fromFinishReason:))
        if normalizedStopReason == .outputTokenLimit {
            print("⚠️ \(displayName) reply hit max_tokens (\(request.maxOutputTokens)); it may be cut off")
        }

        return LanguageModelResponse(
            text: streamAccumulator.accumulatedText,
            toolCalls: toolCalls,
            assistantContent: assistantContent,
            duration: Date().timeIntervalSince(startTime),
            stopReason: normalizedStopReason
        )
    }

    static func normalizedStopReason(fromFinishReason finishReason: String) -> LanguageModelStopReason {
        switch finishReason {
        case "stop": return .endOfTurn
        case "tool_calls", "function_call": return .toolUse
        case "length": return .outputTokenLimit
        case "content_filter": return .refusal
        default: return .other(finishReason)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Builds the /chat/completions request body. When `includeImages` is false
    /// (text-only model), images are dropped and user messages are plain strings.
    static func buildRequestBody(model: String, request: LanguageModelRequest, includeImages: Bool) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": request.systemPrompt]]

        for message in request.messages {
            switch message.role {
            case .user:
                messages.append(contentsOf: userMessagesJSON(message, includeImages: includeImages))
            case .assistant:
                messages.append(assistantMessageJSON(message))
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
            "messages": messages,
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { toolDefinition in
                [
                    "type": "function",
                    "function": [
                        "name": toolDefinition.name,
                        "description": toolDefinition.description,
                        "parameters": toolDefinition.inputSchema,
                    ] as [String: Any],
                ] as [String: Any]
            }
        }
        return body
    }

    /// A user message, plus one "tool" message per tool result (OpenAI puts
    /// tool results in their own role rather than inside the user turn).
    private static func userMessagesJSON(_ message: LanguageModelMessage, includeImages: Bool) -> [[String: Any]] {
        var toolResultMessages: [[String: Any]] = []
        var contentParts: [[String: Any]] = []
        var includesImage = false

        for contentBlock in message.content {
            switch contentBlock {
            case let .text(text):
                contentParts.append(["type": "text", "text": text])
            case let .image(image):
                guard includeImages else { continue }
                includesImage = true
                let mediaType = LanguageModelWireFormatSupport.detectImageMediaType(for: image.data)
                let dataURI = "data:\(mediaType);base64,\(image.data.base64EncodedString())"
                contentParts.append(["type": "image_url", "image_url": ["url": dataURI]])
                contentParts.append(["type": "text", "text": image.label])
            case let .toolResult(toolCallIdentifier, _, resultText):
                toolResultMessages.append(["role": "tool", "tool_call_id": toolCallIdentifier, "content": resultText])
            case .toolCall, .anthropicRawBlock, .openAIResponsesRawItem:
                continue
            }
        }

        guard !contentParts.isEmpty else { return toolResultMessages }

        // Text-only messages go as a plain string: some local servers reject
        // content-part arrays without images.
        let userContent: Any = includesImage
            ? contentParts
            : contentParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return toolResultMessages + [["role": "user", "content": userContent]]
    }

    private static func assistantMessageJSON(_ message: LanguageModelMessage) -> [String: Any] {
        var textParts: [String] = []
        var toolCallsJSON: [[String: Any]] = []
        for contentBlock in message.content {
            switch contentBlock {
            case let .text(text):
                textParts.append(text)
            case let .toolCall(toolCall):
                toolCallsJSON.append([
                    "id": toolCall.toolCallIdentifier,
                    "type": "function",
                    "function": ["name": toolCall.toolName, "arguments": toolCall.argumentsJSON],
                ])
            case .image, .toolResult, .anthropicRawBlock, .openAIResponsesRawItem:
                continue
            }
        }

        var assistantMessage: [String: Any] = ["role": "assistant", "content": textParts.joined(separator: "\n")]
        if !toolCallsJSON.isEmpty {
            assistantMessage["tool_calls"] = toolCallsJSON
        }
        return assistantMessage
    }
}

// MARK: - Stream accumulation

/// Incrementally parses /chat/completions SSE lines: text deltas plus tool
/// calls, which arrive split across chunks and are stitched together by index.
struct OpenAIStreamAccumulator {

    enum ConsumeOutcome: Equatable {
        case none
        case textDelta(String)
        case streamEnded
    }

    private struct PartialToolCall {
        var toolCallIdentifier: String?
        var toolName = ""
        var argumentsJSON = ""
    }

    private(set) var accumulatedText = ""
    /// The last `finish_reason` the server sent ("stop", "length", …).
    private(set) var finishReason: String?
    private var partialToolCallsByIndex: [Int: PartialToolCall] = [:]

    mutating func consume(sseLine line: String) -> ConsumeOutcome {
        guard line.hasPrefix("data:") else { return .none }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .streamEnded }

        guard let payloadData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            return .none
        }
        if let reportedFinishReason = firstChoice["finish_reason"] as? String {
            finishReason = reportedFinishReason
        }
        guard let delta = firstChoice["delta"] as? [String: Any] else {
            return .none
        }

        if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
            for toolCallDelta in toolCallDeltas {
                let toolCallIndex = toolCallDelta["index"] as? Int ?? 0
                var partialToolCall = partialToolCallsByIndex[toolCallIndex] ?? PartialToolCall()
                if let toolCallIdentifier = toolCallDelta["id"] as? String {
                    partialToolCall.toolCallIdentifier = toolCallIdentifier
                }
                if let function = toolCallDelta["function"] as? [String: Any] {
                    partialToolCall.toolName += function["name"] as? String ?? ""
                    partialToolCall.argumentsJSON += function["arguments"] as? String ?? ""
                }
                partialToolCallsByIndex[toolCallIndex] = partialToolCall
            }
        }

        if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
            accumulatedText += textChunk
            return .textDelta(textChunk)
        }
        return .none
    }

    /// Completed tool calls in index order. Servers that omit ids get a stable
    /// generated one so tool results can still be matched.
    var toolCalls: [LanguageModelToolCall] {
        partialToolCallsByIndex.keys.sorted().compactMap { toolCallIndex in
            guard let partialToolCall = partialToolCallsByIndex[toolCallIndex], !partialToolCall.toolName.isEmpty else {
                return nil
            }
            return LanguageModelToolCall(
                toolCallIdentifier: partialToolCall.toolCallIdentifier ?? "call_\(toolCallIndex)",
                toolName: partialToolCall.toolName,
                argumentsJSON: partialToolCall.argumentsJSON.isEmpty ? "{}" : partialToolCall.argumentsJSON
            )
        }
    }
}
