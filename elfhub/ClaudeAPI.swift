//
//  ClaudeAPI.swift
//  elfhub
//
//  Claude Messages API client with SSE streaming, called directly at
//  api.anthropic.com (or an Anthropic-compatible base URL) with the user's
//  own key from the Keychain.
//
//  Streams text as deltas and assembles tool calls. Every assistant content
//  block (including thinking blocks) is also kept verbatim, so a follow-up
//  request after a tool call can replay the assistant turn unchanged — Claude
//  requires thinking blocks to come back exactly as produced.
//
//  On the Claude API itself (not other Anthropic-compatible endpoints) it also
//  marks prompt-cache breakpoints — after the stable tools + system prompt and
//  after the earlier conversation — so repeat turns re-read that prefix from
//  the cache (faster first token, cheaper input), and passes a reasoning
//  effort when the turn asks for one and the model supports it.
//

import Foundation

/// Claude API client with streaming for progressive text display.
final class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    static let anthropicVersionHeaderValue = "2023-06-01"
    /// Beta enabling `fallbacks: "default"` (server-side retry on refusal).
    static let serverSideFallbackBetaHeaderValue = "server-side-fallback-2026-07-01"

    private let messagesEndpointURL: URL
    /// The user's own key; nil only for Anthropic-compatible endpoints that
    /// need none.
    private let apiKey: String?
    var model: String
    private let session: URLSession

    /// - Parameters:
    ///   - messagesEndpointURL: e.g. `https://api.anthropic.com/v1/messages`.
    ///   - apiKey: the user's key.
    init(messagesEndpointURL: URL, apiKey: String?, model: String = "claude-opus-5-5") {
        self.messagesEndpointURL = messagesEndpointURL
        self.apiKey = apiKey
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    /// The Messages endpoint for a direct base URL ("https://api.anthropic.com"
    /// → ".../v1/messages"). Accepts a base that already ends in /v1/messages.
    static func directMessagesEndpointURL(forBaseURL baseURL: String) -> URL? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.hasSuffix("/v1/messages") {
            return URL(string: trimmedBaseURL)
        }
        return LanguageModelWireFormatSupport.url(byAppending: "/v1/messages", to: trimmedBaseURL)
    }

    /// Whether server-side refusal fallbacks are available for this model and
    /// route: the Claude API itself (not other Anthropic-compatible proxies)
    /// and not Haiku, which has no server-side fallback. Never for a run on
    /// the user's screen: the fallback model may not take the computer
    /// toolset, and a rejected request would end the run.
    static func shouldRequestServerSideFallback(model: String, isDirectToAnthropic: Bool, usesComputerToolset: Bool = false) -> Bool {
        guard isDirectToAnthropic, !usesComputerToolset else { return false }
        let lowercasedModel = model.lowercased()
        let fallbackCapableModelPrefixes = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5-5"]
        return fallbackCapableModelPrefixes.contains { lowercasedModel.hasPrefix($0) }
    }

    var isDirectToAnthropic: Bool {
        apiKey != nil && (messagesEndpointURL.host?.hasSuffix("anthropic.com") ?? false)
    }

    /// Whether this model accepts `output_config.effort`. Sending it to a
    /// model that doesn't is a 400, so unknown models never get it.
    static func supportsReasoningEffort(model: String) -> Bool {
        let lowercasedModel = model.lowercased()
        let effortCapableModelPrefixes = [
            "claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5",
            "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"
        ]
        return effortCapableModelPrefixes.contains { lowercasedModel.hasPrefix($0) }
    }

    /// The web search tool version for this model: the one that filters
    /// results with code before reading them where the model has it, else
    /// the basic one.
    static func webSearchToolType(model: String) -> String {
        let lowercasedModel = model.lowercased()
        let dynamicFilteringModelPrefixes = [
            "claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5",
            "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"
        ]
        return dynamicFilteringModelPrefixes.contains { lowercasedModel.hasPrefix($0) } ? "web_search_20260209" : "web_search_20250305"
    }

    /// Claude's computer toolset (GA, no beta header). Claude 5-family
    /// models take it — and the newest take only it — so older models use
    /// elfhub's own perform_screen_action function tool instead.
    static let computerToolsetType = "computer_toolset_20260801"

    static func supportsComputerToolset(model: String) -> Bool {
        let lowercasedModel = model.lowercased()
        let computerToolsetModelPrefixes = [
            "claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5"
        ]
        return computerToolsetModelPrefixes.contains { lowercasedModel.hasPrefix($0) }
    }

    /// Toolset members elfhub doesn't carry out, switched off so Claude
    /// never asks for them: pressing the left button or a key without
    /// letting go would leave the user's mouse or keyboard stuck if a run
    /// stopped halfway, and the middle button has no use on a Mac.
    static let computerToolsetDisabledMemberNames = ["middle_click", "left_mouse_down", "left_mouse_up", "hold_key"]

    static var computerToolsetEntry: [String: Any] {
        var configs: [String: Any] = [:]
        for disabledMemberName in computerToolsetDisabledMemberNames {
            configs[disabledMemberName] = ["enabled": false]
        }
        return ["type": computerToolsetType, "configs": configs]
    }

    /// The `anthropic-beta` header value: every beta this request needs,
    /// comma-separated (setting the header once per beta would keep only the last).
    static func anthropicBetaHeaderValue(forBetas betaNames: [String]) -> String? {
        betaNames.isEmpty ? nil : betaNames.joined(separator: ",")
    }

    private func makeAPIRequest(betaNames: [String]) -> URLRequest {
        var request = URLRequest(url: messagesEndpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersionHeaderValue, forHTTPHeaderField: "anthropic-version")
        }
        if let anthropicBetaHeaderValue = Self.anthropicBetaHeaderValue(forBetas: betaNames) {
            request.setValue(anthropicBetaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: messagesEndpointURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    // MARK: - Streaming request

    /// Streams one Messages request. Text arrives as deltas on `onStreamEvent`;
    /// the full text, tool calls and verbatim assistant content come back at the end.
    func streamMessages(
        _ languageModelRequest: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse {
        let startTime = Date()
        let requestsServerSideFallback = Self.shouldRequestServerSideFallback(
            model: model,
            isDirectToAnthropic: isDirectToAnthropic,
            usesComputerToolset: languageModelRequest.usesAnthropicComputerToolset && Self.supportsComputerToolset(model: model)
        )

        var betaNames: [String] = []
        if requestsServerSideFallback {
            betaNames.append(Self.serverSideFallbackBetaHeaderValue)
        }
        var request = makeAPIRequest(betaNames: betaNames)
        var body = Self.buildRequestBody(
            model: model,
            request: languageModelRequest,
            isDirectToAnthropic: isDirectToAnthropic
        )
        if requestsServerSideFallback {
            body["fallbacks"] = "default"
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMegabytes = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMegabytes))MB, \(languageModelRequest.tools.count) tool(s)")

        let byteStream = try await LanguageModelHTTPStreaming.openStream(request, using: session, providerName: "Claude")

        var streamAccumulator = AnthropicStreamAccumulator()
        streamLoop: for try await line in byteStream.lines {
            try Task.checkCancellation()
            switch streamAccumulator.consume(sseLine: line) {
            case .none:
                continue
            case let .textDelta(textDelta):
                onStreamEvent(.textDelta(textDelta))
            case let .toolCallCompleted(completedToolCall):
                onStreamEvent(.toolCallCompleted(completedToolCall))
            case .streamEnded:
                break streamLoop
            }
        }

        // An error event mid-stream (e.g. overloaded) means the reply is
        // incomplete; returning it as an answer would hide that.
        if let streamErrorMessage = streamAccumulator.streamErrorMessage {
            throw LanguageModelProviderError.streamFailed(streamErrorMessage)
        }

        // A refusal (after any server-side fallback) is a failed turn, not an
        // answer; partial text from a declined stream is discarded.
        if streamAccumulator.stopReason == "refusal" {
            throw ClaudeAPIError.refused
        }

        let normalizedStopReason = streamAccumulator.stopReason.map(Self.normalizedStopReason(fromAnthropicStopReason:))
        if normalizedStopReason == .outputTokenLimit {
            print("⚠️ Claude reply hit max_tokens (\(languageModelRequest.maxOutputTokens)); it may be cut off")
        }
        let usage = streamAccumulator.usage
        print("🌐 Claude usage: \(usage.inputTokens) input (\(usage.cacheReadInputTokens) from cache, \(usage.cacheCreationInputTokens) cached now), \(usage.outputTokens) output")

        return LanguageModelResponse(
            text: streamAccumulator.accumulatedText,
            toolCalls: streamAccumulator.toolCalls,
            assistantContent: streamAccumulator.assistantContentBlocks,
            duration: Date().timeIntervalSince(startTime),
            stopReason: normalizedStopReason,
            usage: usage,
            providerWebSearchCount: streamAccumulator.providerWebSearchCount,
            providerWebSearchResultURLs: streamAccumulator.providerWebSearchResultURLs
        )
    }

    static func normalizedStopReason(fromAnthropicStopReason anthropicStopReason: String) -> LanguageModelStopReason {
        switch anthropicStopReason {
        case "end_turn", "stop_sequence": return .endOfTurn
        case "tool_use": return .toolUse
        case "max_tokens", "model_context_window_exceeded": return .outputTokenLimit
        case "pause_turn": return .pausedByServer
        case "refusal": return .refusal
        default: return .other(anthropicStopReason)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Marks the end of a prompt prefix Claude may cache and re-read.
    static let ephemeralCacheControl: [String: Any] = ["type": "ephemeral"]

    /// Builds the Messages API body from the normalized request. Prompt-cache
    /// breakpoints and the effort setting are only added when talking to the
    /// Claude API itself, since other Anthropic-compatible endpoints may
    /// reject them.
    static func buildRequestBody(
        model: String,
        request: LanguageModelRequest,
        isDirectToAnthropic: Bool = false
    ) -> [String: Any] {
        var messagesJSON = request.messages.map(messageJSON)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
        ]

        if isDirectToAnthropic {
            // Breakpoint 1: tools + system prompt, identical on every turn.
            body["system"] = [[
                "type": "text",
                "text": request.systemPrompt,
                "cache_control": ephemeralCacheControl,
            ] as [String: Any]]
            // Breakpoint 2: the conversation before the newest user message
            // (the new screenshot always lands after it).
            if messagesJSON.count >= 2 {
                let lastEarlierMessageIndex = messagesJSON.count - 2
                messagesJSON[lastEarlierMessageIndex] = markingLastContentBlockForCaching(messagesJSON[lastEarlierMessageIndex])
            }
            if let reasoningEffort = request.reasoningEffort, supportsReasoningEffort(model: model) {
                body["output_config"] = ["effort": reasoningEffort.rawValue]
            }
        } else {
            body["system"] = request.systemPrompt
        }
        body["messages"] = messagesJSON

        var toolsJSON: [[String: Any]] = request.tools.map { toolDefinition in
            [
                "name": toolDefinition.name,
                "description": toolDefinition.description,
                "input_schema": toolDefinition.inputSchema,
            ] as [String: Any]
        }
        // Claude's own web search runs on Anthropic's servers; other
        // Anthropic-compatible endpoints may not have it.
        if isDirectToAnthropic, let providerWebSearch = request.providerWebSearch {
            toolsJSON.append([
                "type": webSearchToolType(model: model),
                "name": "web_search",
                "max_uses": providerWebSearch.maximumSearchesPerRequest,
            ])
        }
        // The computer toolset for a multi-step run on the user's screen —
        // only on Anthropic's own API, for models that take it.
        if isDirectToAnthropic, request.usesAnthropicComputerToolset, supportsComputerToolset(model: model) {
            toolsJSON.append(computerToolsetEntry)
        }
        if !toolsJSON.isEmpty {
            body["tools"] = toolsJSON
        }
        return body
    }

    /// Adds a cache breakpoint to a message's last content block. Thinking
    /// blocks can't carry one, so those messages are left as they are.
    private static func markingLastContentBlockForCaching(_ messageJSON: [String: Any]) -> [String: Any] {
        guard var contentBlocks = messageJSON["content"] as? [[String: Any]],
              var lastContentBlock = contentBlocks.last else { return messageJSON }
        let blockType = lastContentBlock["type"] as? String
        guard blockType != "thinking", blockType != "redacted_thinking" else { return messageJSON }
        lastContentBlock["cache_control"] = ephemeralCacheControl
        contentBlocks[contentBlocks.count - 1] = lastContentBlock
        var markedMessageJSON = messageJSON
        markedMessageJSON["content"] = contentBlocks
        return markedMessageJSON
    }

    private static func messageJSON(_ message: LanguageModelMessage) -> [String: Any] {
        let role = message.role == .user ? "user" : "assistant"
        let contentBlocks: [[String: Any]] = message.content.flatMap { contentBlock -> [[String: Any]] in
            switch contentBlock {
            case let .text(text):
                return [["type": "text", "text": text]]
            case let .image(image):
                let imageBlock: [String: Any] = [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": LanguageModelWireFormatSupport.detectImageMediaType(for: image.data),
                        "data": image.data.base64EncodedString(),
                    ],
                ]
                // The label says which screen this is and which coordinate
                // space to answer in, so it goes right after the image.
                guard !image.label.isEmpty else { return [imageBlock] }
                return [imageBlock, ["type": "text", "text": image.label]]
            case let .toolCall(toolCall):
                return [[
                    "type": "tool_use",
                    "id": toolCall.toolCallIdentifier,
                    "name": toolCall.toolName,
                    "input": toolCall.argumentsDictionary,
                ]]
            case let .toolResult(toolCallIdentifier, _, resultText):
                return [["type": "tool_result", "tool_use_id": toolCallIdentifier, "content": resultText]]
            case let .computerToolResult(computerToolResult):
                var resultContent: [[String: Any]] = [["type": "text", "text": computerToolResult.resultText]]
                if let image = computerToolResult.image {
                    resultContent.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": LanguageModelWireFormatSupport.detectImageMediaType(for: image.data),
                            "data": image.data.base64EncodedString(),
                        ],
                    ])
                }
                var resultBlock: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": computerToolResult.toolCallIdentifier,
                    "content": resultContent,
                ]
                // A computer toolset result must name its toolset, or the
                // API rejects the request.
                if let toolsetName = computerToolResult.toolsetName {
                    resultBlock["toolset_name"] = toolsetName
                }
                if computerToolResult.isError {
                    resultBlock["is_error"] = true
                }
                return [resultBlock]
            case let .anthropicRawBlock(rawBlockJSON):
                // Thinking and other blocks replayed exactly as Claude produced them.
                guard let rawBlockData = rawBlockJSON.data(using: .utf8),
                      let rawBlock = try? JSONSerialization.jsonObject(with: rawBlockData) as? [String: Any] else {
                    return []
                }
                return [rawBlock]
            case .openAIResponsesRawItem:
                return []
            }
        }
        return ["role": role, "content": contentBlocks]
    }
}

enum ClaudeAPIError: LocalizedError {
    case refused

    var errorDescription: String? {
        switch self {
        case .refused:
            return "Claude declined this request."
        }
    }
}

// MARK: - Stream accumulation

/// Incrementally parses Anthropic SSE lines. Pure value type so it is unit-tested
/// with recorded lines instead of a network.
struct AnthropicStreamAccumulator {

    enum ConsumeOutcome: Equatable {
        case none
        case textDelta(String)
        /// A computer toolset call is complete (its input fully arrived).
        case toolCallCompleted(LanguageModelToolCall)
        case streamEnded
    }

    private(set) var accumulatedText = ""
    private(set) var stopReason: String?
    /// Token counts from message_start (input, cache) and message_delta (output).
    private(set) var usage = LanguageModelUsage()
    /// Set when the server sends an `error` event mid-stream (e.g. overloaded).
    private(set) var streamErrorMessage: String?
    /// Content blocks keyed by their stream index, in arrival order.
    private var contentBlocksByIndex: [Int: [String: Any]] = [:]
    private var contentBlockOrder: [Int] = []
    /// Partial JSON for tool_use inputs, keyed by block index.
    private var partialToolInputJSONByIndex: [Int: String] = [:]

    mutating func consume(sseLine line: String) -> ConsumeOutcome {
        guard line.hasPrefix("data:") else { return .none }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .streamEnded }

        guard let payloadData = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let eventType = event["type"] as? String else {
            return .none
        }

        switch eventType {
        case "content_block_start":
            guard let blockIndex = event["index"] as? Int,
                  var contentBlock = event["content_block"] as? [String: Any] else { return .none }
            // A server-side fallback restarts the answer on another model: drop
            // the declined model's partial output rather than splicing the two.
            if contentBlock["type"] as? String == "fallback" {
                resetForFallback()
                return .none
            }
            // Its own tool calls and the searches it runs on the server both
            // stream their input as JSON pieces.
            if ["tool_use", "server_tool_use"].contains(contentBlock["type"] as? String) {
                contentBlock["input"] = [String: Any]()
                partialToolInputJSONByIndex[blockIndex] = ""
            }
            contentBlocksByIndex[blockIndex] = contentBlock
            contentBlockOrder.append(blockIndex)
            return .none

        case "content_block_delta":
            guard let blockIndex = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return .none }
            switch deltaType {
            case "text_delta":
                guard let textChunk = delta["text"] as? String else { return .none }
                accumulatedText += textChunk
                let previousText = contentBlocksByIndex[blockIndex]?["text"] as? String ?? ""
                contentBlocksByIndex[blockIndex]?["text"] = previousText + textChunk
                return .textDelta(textChunk)
            case "input_json_delta":
                partialToolInputJSONByIndex[blockIndex, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                let previousThinking = contentBlocksByIndex[blockIndex]?["thinking"] as? String ?? ""
                contentBlocksByIndex[blockIndex]?["thinking"] = previousThinking + (delta["thinking"] as? String ?? "")
            case "citations_delta":
                // Where a sentence came from (a search result), kept so the
                // turn is replayed exactly as Claude wrote it.
                guard let citation = delta["citation"] else { return .none }
                let previousCitations = contentBlocksByIndex[blockIndex]?["citations"] as? [Any] ?? []
                contentBlocksByIndex[blockIndex]?["citations"] = previousCitations + [citation]
            case "signature_delta":
                let previousSignature = contentBlocksByIndex[blockIndex]?["signature"] as? String ?? ""
                contentBlocksByIndex[blockIndex]?["signature"] = previousSignature + (delta["signature"] as? String ?? "")
            default:
                break
            }
            return .none

        case "content_block_stop":
            guard let blockIndex = event["index"] as? Int,
                  let partialToolInputJSON = partialToolInputJSONByIndex[blockIndex] else { return .none }
            let parsedToolInput = partialToolInputJSON.isEmpty
                ? [String: Any]()
                : (try? JSONSerialization.jsonObject(with: Data(partialToolInputJSON.utf8)) as? [String: Any]) ?? [:]
            contentBlocksByIndex[blockIndex]?["input"] = parsedToolInput
            // Every complete call is announced, in order, so screen steps can
            // start while the rest of the reply arrives (the agent loop starts
            // only those, and only in a run, which never has a server-side
            // fallback that could restart the reply on another model). All of
            // them, not just the toolset's: an open step written before a
            // click must still run first.
            if let completedToolCall = toolCall(atBlockIndex: blockIndex) {
                return .toolCallCompleted(completedToolCall)
            }
            return .none

        case "message_start":
            if let message = event["message"] as? [String: Any], let reportedUsage = message["usage"] as? [String: Any] {
                usage.inputTokens = reportedUsage["input_tokens"] as? Int ?? usage.inputTokens
                usage.cacheReadInputTokens = reportedUsage["cache_read_input_tokens"] as? Int ?? usage.cacheReadInputTokens
                usage.cacheCreationInputTokens = reportedUsage["cache_creation_input_tokens"] as? Int ?? usage.cacheCreationInputTokens
                usage.outputTokens = reportedUsage["output_tokens"] as? Int ?? usage.outputTokens
            }
            return .none

        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reportedStopReason = delta["stop_reason"] as? String {
                stopReason = reportedStopReason
            }
            if let reportedUsage = event["usage"] as? [String: Any], let outputTokens = reportedUsage["output_tokens"] as? Int {
                usage.outputTokens = outputTokens
            }
            return .none

        case "message_stop":
            return .streamEnded

        case "error":
            let errorDetails = event["error"] as? [String: Any]
            let errorType = errorDetails?["type"] as? String ?? "error"
            let errorMessage = errorDetails?["message"] as? String ?? "the stream reported an error"
            streamErrorMessage = "\(errorType): \(errorMessage)"
            return .streamEnded

        default:
            return .none
        }
    }

    private mutating func resetForFallback() {
        accumulatedText = ""
        stopReason = nil
        contentBlocksByIndex = [:]
        contentBlockOrder = []
        partialToolInputJSONByIndex = [:]
    }

    /// Tool calls in the order Claude made them.
    var toolCalls: [LanguageModelToolCall] {
        contentBlockOrder.compactMap(toolCall(atBlockIndex:))
    }

    private func toolCall(atBlockIndex blockIndex: Int) -> LanguageModelToolCall? {
        guard let contentBlock = contentBlocksByIndex[blockIndex],
              contentBlock["type"] as? String == "tool_use",
              let toolCallIdentifier = contentBlock["id"] as? String,
              let toolName = contentBlock["name"] as? String else { return nil }
        let toolInput = contentBlock["input"] as? [String: Any] ?? [:]
        let argumentsData = (try? JSONSerialization.data(withJSONObject: toolInput)) ?? Data("{}".utf8)
        return LanguageModelToolCall(
            toolCallIdentifier: toolCallIdentifier,
            toolName: toolName,
            argumentsJSON: String(decoding: argumentsData, as: UTF8.self),
            toolsetName: contentBlock["toolset_name"] as? String
        )
    }

    /// Web searches Claude ran on Anthropic's servers this reply.
    var providerWebSearchCount: Int {
        contentBlockOrder.filter { blockIndex in
            let contentBlock = contentBlocksByIndex[blockIndex]
            return contentBlock?["type"] as? String == "server_tool_use" && contentBlock?["name"] as? String == "web_search"
        }.count
    }

    /// The addresses those searches found (a failed search has none).
    var providerWebSearchResultURLs: [URL] {
        contentBlockOrder.flatMap { blockIndex -> [URL] in
            guard let contentBlock = contentBlocksByIndex[blockIndex],
                  contentBlock["type"] as? String == "web_search_tool_result",
                  let searchResults = contentBlock["content"] as? [[String: Any]] else { return [] }
            return searchResults.compactMap { searchResult in (searchResult["url"] as? String).flatMap(URL.init(string:)) }
        }
    }

    /// The assistant turn exactly as produced, for replaying in a follow-up.
    var assistantContentBlocks: [LanguageModelContentBlock] {
        contentBlockOrder.compactMap { blockIndex in
            guard let contentBlock = contentBlocksByIndex[blockIndex],
                  let rawBlockData = try? JSONSerialization.data(withJSONObject: contentBlock) else { return nil }
            return .anthropicRawBlock(String(decoding: rawBlockData, as: UTF8.self))
        }
    }
}
