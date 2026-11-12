//
//  GeminiLanguageModelProvider.swift
//  elfhub
//
//  Talks to Google's Gemini API (generativelanguage.googleapis.com), whose
//  request/response shape differs from OpenAI's: a systemInstruction block,
//  "contents" with user/model roles, inline base64 images, function calling via
//  functionDeclarations / functionCall / functionResponse parts, and SSE
//  responses under candidates[].content.parts[].
//

import Foundation

final class GeminiLanguageModelProvider: LanguageModelProvider {
    let displayName: String
    let capabilities: LanguageModelCapabilities

    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: e.g. "https://generativelanguage.googleapis.com/v1beta".
    init(displayName: String, baseURL: String, apiKey: String, model: String, capabilities: LanguageModelCapabilities) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
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

        let endpoint = "\(baseURL)/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: endpoint) else {
            throw LanguageModelProviderError.missingConfiguration("invalid Gemini base URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body = Self.buildRequestBody(request: request, includeImages: capabilities.supportsVision)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let byteStream = try await LanguageModelHTTPStreaming.openStream(urlRequest, using: session, providerName: displayName)

        var accumulatedText = ""
        var toolCalls: [LanguageModelToolCall] = []
        var lastFinishReason: String?
        for try await line in byteStream.lines {
            try Task.checkCancellation()
            let parsedChunk = Self.parseStreamedChunk(fromSSELine: line)
            if let finishReason = Self.finishReason(fromSSELine: line) {
                lastFinishReason = finishReason
            }
            if let textDelta = parsedChunk.textDelta {
                accumulatedText += textDelta
                onStreamEvent(.textDelta(textDelta))
            }
            for functionCall in parsedChunk.functionCalls {
                // Gemini doesn't assign call ids; number them so results can be matched.
                toolCalls.append(LanguageModelToolCall(
                    toolCallIdentifier: "gemini_call_\(toolCalls.count)",
                    toolName: functionCall.name,
                    argumentsJSON: functionCall.argumentsJSON
                ))
            }
        }

        var assistantContent: [LanguageModelContentBlock] = []
        if !accumulatedText.isEmpty {
            assistantContent.append(.text(accumulatedText))
        }
        assistantContent.append(contentsOf: toolCalls.map { LanguageModelContentBlock.toolCall($0) })

        let normalizedStopReason = lastFinishReason.map(Self.normalizedStopReason(fromFinishReason:))
        if normalizedStopReason == .outputTokenLimit {
            print("⚠️ \(displayName) reply hit maxOutputTokens (\(request.maxOutputTokens)); it may be cut off")
        }

        return LanguageModelResponse(
            text: accumulatedText,
            toolCalls: toolCalls,
            assistantContent: assistantContent,
            duration: Date().timeIntervalSince(startTime),
            stopReason: normalizedStopReason
        )
    }

    static func normalizedStopReason(fromFinishReason finishReason: String) -> LanguageModelStopReason {
        switch finishReason {
        case "STOP": return .endOfTurn
        case "MAX_TOKENS": return .outputTokenLimit
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY": return .refusal
        default: return .other(finishReason)
        }
    }

    /// The candidate's `finishReason` on this SSE line, if it carries one.
    static func finishReason(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let payloadData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]] else { return nil }
        return candidates.first?["finishReason"] as? String
    }

    // MARK: - Pure helpers (unit-tested)

    static func buildRequestBody(request: LanguageModelRequest, includeImages: Bool) -> [String: Any] {
        let contents: [[String: Any]] = request.messages.compactMap { message in
            let parts = partsJSON(for: message, includeImages: includeImages)
            guard !parts.isEmpty else { return nil }
            return ["role": message.role == .user ? "user" : "model", "parts": parts]
        }

        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": request.systemPrompt]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": request.maxOutputTokens],
        ]
        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { toolDefinition in
                    [
                        "name": toolDefinition.name,
                        "description": toolDefinition.description,
                        "parameters": toolDefinition.inputSchema,
                    ] as [String: Any]
                },
            ]]
        }
        return body
    }

    private static func partsJSON(for message: LanguageModelMessage, includeImages: Bool) -> [[String: Any]] {
        message.content.flatMap { contentBlock -> [[String: Any]] in
            switch contentBlock {
            case let .text(text):
                return [["text": text]]
            case let .image(image):
                guard includeImages else { return [] }
                let imagePart: [String: Any] = [
                    "inline_data": [
                        "mime_type": LanguageModelWireFormatSupport.detectImageMediaType(for: image.data),
                        "data": image.data.base64EncodedString(),
                    ],
                ]
                // The label says which screen this is and that coordinates
                // are on the 0-999 grid, so it goes right after the image.
                guard !image.label.isEmpty else { return [imagePart] }
                return [imagePart, ["text": image.label]]
            case let .toolCall(toolCall):
                return [["functionCall": ["name": toolCall.toolName, "args": toolCall.argumentsDictionary]]]
            case let .toolResult(_, toolName, resultText):
                return [["functionResponse": ["name": toolName, "response": ["result": resultText]]]]
            case .anthropicRawBlock:
                return []
            }
        }
    }

    struct ParsedStreamChunk: Equatable {
        struct FunctionCall: Equatable {
            let name: String
            let argumentsJSON: String
        }

        let textDelta: String?
        let functionCalls: [FunctionCall]
    }

    /// Parses one Gemini SSE line into its text delta and any complete function calls.
    static func parseStreamedChunk(fromSSELine line: String) -> ParsedStreamChunk {
        let emptyChunk = ParsedStreamChunk(textDelta: nil, functionCalls: [])
        guard line.hasPrefix("data:") else { return emptyChunk }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let payloadData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return emptyChunk
        }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        let functionCalls: [ParsedStreamChunk.FunctionCall] = parts.compactMap { part in
            guard let functionCall = part["functionCall"] as? [String: Any],
                  let functionName = functionCall["name"] as? String else { return nil }
            let functionArguments = functionCall["args"] as? [String: Any] ?? [:]
            let argumentsData = (try? JSONSerialization.data(withJSONObject: functionArguments)) ?? Data("{}".utf8)
            return ParsedStreamChunk.FunctionCall(name: functionName, argumentsJSON: String(decoding: argumentsData, as: UTF8.self))
        }
        return ParsedStreamChunk(textDelta: text.isEmpty ? nil : text, functionCalls: functionCalls)
    }
}
