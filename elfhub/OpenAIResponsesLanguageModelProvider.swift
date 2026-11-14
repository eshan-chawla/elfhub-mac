//
//  OpenAIResponsesLanguageModelProvider.swift
//  elfhub
//
//  Talks to OpenAI's Responses API (POST /v1/responses) with the access token
//  from "Continue with ChatGPT", so requests use the user's ChatGPT plan
//  instead of an API key. The plan route is a preview with strict rules,
//  all applied in `buildRequestBody`:
//   - `store: false` and `stream: true` on every request; the whole
//     conversation goes in `input` each time (no previous_response_id);
//   - the system prompt goes in `instructions` (system messages are refused);
//   - no `max_output_tokens`, `temperature`, `top_p`, `metadata`,
//     `truncation` or `user`;
//   - function tools are grouped in a namespace.
//  A reply only counts once `response.completed` arrives; the plan's usage
//  limit can arrive as `response.failed` after text has already streamed.
//

import Foundation

// MARK: - Plan errors

/// The ChatGPT-plan errors elfhub reacts to, from an HTTP error body or a
/// `response.failed` / `error` stream event.
enum ChatGPTPlanUsageError: LocalizedError, Equatable {
    /// The plan's (or this app's) usage limit is used up.
    case usageLimitReached
    /// OpenAI couldn't check usage or reach the account right now.
    case usageTemporarilyUnavailable
    /// This account, workspace or plan can't be used by apps.
    case notEligible
    /// The request used something the plan route doesn't allow.
    case unsupportedCapability(parameter: String?)
    /// Signed in, but elfhub wasn't allowed to use the plan.
    case planUsageNotEnabled
    /// The sign-in wasn't accepted, even after renewing the token.
    case credentialRejected
    /// The request's permissions or route were refused.
    case requestNotAuthorized(code: String)

    var errorDescription: String? {
        switch self {
        case .usageLimitReached:
            return "Usage limit reached on your ChatGPT plan. You can review it in ChatGPT's settings, under Usage."
        case .usageTemporarilyUnavailable:
            return "ChatGPT couldn't check your plan's usage right now. Please try again in a moment."
        case .notEligible:
            return "Your ChatGPT plan or workspace can't be used in apps like elfhub."
        case let .unsupportedCapability(parameter):
            return "Your ChatGPT plan doesn't support part of this request\(parameter.map { " (\($0))" } ?? "")."
        case .planUsageNotEnabled:
            return "elfhub isn't allowed to use your ChatGPT plan yet. Continue with ChatGPT again in Settings, under Models, to allow it."
        case .credentialRejected:
            return "ChatGPT didn't accept the sign-in. Try signing in again in Settings, under Models."
        case let .requestNotAuthorized(code):
            return "ChatGPT refused this request (\(code))."
        }
    }

    /// Whether this turn should be answered by the fallback model instead.
    var switchesToFallbackModel: Bool {
        switch self {
        case .usageLimitReached, .usageTemporarilyUnavailable, .notEligible, .planUsageNotEnabled, .credentialRejected:
            return true
        case .unsupportedCapability, .requestNotAuthorized:
            return false
        }
    }

    static func from(streamFailureCode code: String?, parameter: String?) -> ChatGPTPlanUsageError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimitReached
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .usageTemporarilyUnavailable
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_unsupported_capability": return .unsupportedCapability(parameter: parameter)
        case "subscription_sharing_invalid_user": return .credentialRejected
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .requestNotAuthorized(code: code ?? "")
        default: return nil
        }
    }

    /// Reads a plan error out of an HTTP error, or nil when it isn't one.
    static func from(_ error: Error) -> ChatGPTPlanUsageError? {
        if let planUsageError = error as? ChatGPTPlanUsageError { return planUsageError }
        // Getting a token for the request can fail too. A session that can't
        // be renewed any more is a rejected sign-in; a renewal that failed
        // for now means the plan isn't reachable right now. Both must reach
        // the fallback model rather than fail the turn.
        if let signInError = error as? ChatGPTPlanSignInError {
            switch signInError {
            case .signInRequired: return .credentialRejected
            case .tokenRequestFailed, .discoveryFailed, .invalidTokenResponse: return .usageTemporarilyUnavailable
            default: return nil
            }
        }
        guard case let LanguageModelProviderError.httpError(statusCode, body) = error else { return nil }
        let errorObject = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? [String: Any]
        if let structuredError = from(
            streamFailureCode: errorObject?["code"] as? String,
            parameter: errorObject?["param"] as? String
        ) {
            return structuredError
        }
        // Admission errors carry only {"detail": "..."}; the status says it all.
        switch statusCode {
        case 401: return .credentialRejected
        case 503: return .usageTemporarilyUnavailable
        default: return nil
        }
    }
}

// MARK: - Provider

final class OpenAIResponsesLanguageModelProvider: LanguageModelProvider {
    let displayName: String
    let capabilities: LanguageModelCapabilities

    /// The namespace elfhub's guidance tools are grouped under (the plan
    /// route only accepts function tools inside a namespace).
    static let guidanceToolNamespace = "elfhub_screen"
    static let responsesEndpointURL = URL(string: "\(ChatGPTPlanOAuthConstants.resource)/responses")!

    /// Returns a usable access token; `forcingRefresh` renews it first.
    typealias AccessTokenSource = @MainActor (_ forcingRefresh: Bool) async throws -> String

    private let model: String
    private let accessTokenSource: AccessTokenSource
    private let session: URLSession

    init(displayName: String, model: String, capabilities: LanguageModelCapabilities, accessTokenSource: @escaping AccessTokenSource) {
        self.displayName = displayName
        self.model = model
        self.capabilities = capabilities
        self.accessTokenSource = accessTokenSource

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func streamResponse(
        _ request: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse {
        let startTime = Date()
        let body = Self.buildRequestBody(model: model, request: request, includeImages: capabilities.supportsVision)
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let byteStream: URLSession.AsyncBytes
        do {
            byteStream = try await openStream(bodyData: bodyData, accessToken: try await accessTokenSource(false))
        } catch LanguageModelProviderError.httpError(statusCode: 401, body: _) {
            // The token may have been revoked or expired early: renew once.
            do {
                byteStream = try await openStream(bodyData: bodyData, accessToken: try await accessTokenSource(true))
            } catch {
                throw ChatGPTPlanUsageError.from(error) ?? error
            }
        } catch {
            throw ChatGPTPlanUsageError.from(error) ?? error
        }

        let streamAccumulator = OpenAIResponsesStreamAccumulator()
        for try await line in byteStream.lines {
            try Task.checkCancellation()
            switch streamAccumulator.consume(sseLine: line) {
            case let .textDelta(textDelta):
                onStreamEvent(.textDelta(textDelta))
            case let .failed(code, message, parameter):
                if let planUsageError = ChatGPTPlanUsageError.from(streamFailureCode: code, parameter: parameter) {
                    throw planUsageError
                }
                throw LanguageModelProviderError.streamFailed(message ?? code ?? "unknown error")
            case .none, .finished:
                break
            }
            if streamAccumulator.hasFinished { break }
        }
        guard streamAccumulator.hasFinished else {
            throw LanguageModelProviderError.streamFailed("the reply ended before it was complete")
        }

        if streamAccumulator.stopReason == .outputTokenLimit {
            print("⚠️ \(displayName) reply hit the output limit; it may be cut off")
        }

        // The rebuilt text and tool calls are what the rest of elfhub reads;
        // the raw items are what the follow-up request replays.
        var assistantContent: [LanguageModelContentBlock] = []
        if !streamAccumulator.accumulatedText.isEmpty {
            assistantContent.append(.text(streamAccumulator.accumulatedText))
        }
        assistantContent.append(contentsOf: streamAccumulator.toolCalls.map { LanguageModelContentBlock.toolCall($0) })
        assistantContent.append(contentsOf: streamAccumulator.rawOutputItems.map { LanguageModelContentBlock.openAIResponsesRawItem($0) })

        return LanguageModelResponse(
            text: streamAccumulator.accumulatedText,
            toolCalls: streamAccumulator.toolCalls,
            assistantContent: assistantContent,
            duration: Date().timeIntervalSince(startTime),
            stopReason: streamAccumulator.stopReason,
            usage: streamAccumulator.usage
        )
    }

    private func openStream(bodyData: Data, accessToken: String) async throws -> URLSession.AsyncBytes {
        var urlRequest = URLRequest(url: Self.responsesEndpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = bodyData
        return try await LanguageModelHTTPStreaming.openStream(
            urlRequest,
            using: session,
            providerName: displayName,
            shouldRetryErrorResponse: Self.shouldRetry(statusCode:responseBody:)
        )
    }

    /// Plan errors that waiting a second won't fix (the usage limit is a
    /// 429) are never retried; temporary ones follow the shared policy.
    static func shouldRetry(statusCode: Int, responseBody: String) -> Bool {
        if let planUsageError = ChatGPTPlanUsageError.from(LanguageModelProviderError.httpError(statusCode: statusCode, body: responseBody)),
           planUsageError != .usageTemporarilyUnavailable {
            return false
        }
        return LanguageModelRetryPolicy.shouldRetry(statusCode: statusCode)
    }

    // MARK: - Pure helpers (unit-tested)

    static func buildRequestBody(model: String, request: LanguageModelRequest, includeImages: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": request.systemPrompt,
            "input": request.messages.flatMap { inputItems(for: $0, includeImages: includeImages) },
            "store": false,
            "stream": true,
            // Nothing is stored on OpenAI's side, so reasoning comes back
            // encrypted and is sent back with the tool follow-up.
            "include": ["reasoning.encrypted_content"],
        ]
        if let reasoningEffort = request.reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort.rawValue]
        }
        if !request.tools.isEmpty {
            body["tools"] = [[
                "type": "namespace",
                "name": guidanceToolNamespace,
                "description": "Show things on the user's screen (point, annotate and, when allowed, act) and work with your own notes, files and skills.",
                "tools": request.tools.map { toolDefinition in
                    [
                        "type": "function",
                        "name": toolDefinition.name,
                        "description": toolDefinition.description,
                        "parameters": toolDefinition.inputSchema,
                    ] as [String: Any]
                },
            ] as [String: Any]]
        }
        return body
    }

    private static func inputItems(for message: LanguageModelMessage, includeImages: Bool) -> [[String: Any]] {
        switch message.role {
        case .user:
            var toolOutputItems: [[String: Any]] = []
            var contentParts: [[String: Any]] = []
            for contentBlock in message.content {
                switch contentBlock {
                case let .text(text):
                    contentParts.append(["type": "input_text", "text": text])
                case let .image(image):
                    guard includeImages else { continue }
                    let mediaType = LanguageModelWireFormatSupport.detectImageMediaType(for: image.data)
                    contentParts.append([
                        "type": "input_image",
                        "image_url": "data:\(mediaType);base64,\(image.data.base64EncodedString())",
                    ])
                    // The label says which screen this is and which
                    // coordinate space to answer in, so it follows the image.
                    if !image.label.isEmpty {
                        contentParts.append(["type": "input_text", "text": image.label])
                    }
                case let .toolResult(toolCallIdentifier, _, resultText):
                    toolOutputItems.append(["type": "function_call_output", "call_id": toolCallIdentifier, "output": resultText])
                case .toolCall, .anthropicRawBlock, .openAIResponsesRawItem:
                    continue
                }
            }
            var items = toolOutputItems
            if !contentParts.isEmpty {
                items.append(["type": "message", "role": "user", "content": contentParts])
            }
            return items

        case .assistant:
            // A turn this provider produced is replayed exactly as it came
            // back (reasoning included); anything else is rebuilt.
            let rawItems: [[String: Any]] = message.content.compactMap { contentBlock in
                guard case let .openAIResponsesRawItem(rawItemJSON) = contentBlock else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(rawItemJSON.utf8)) as? [String: Any]
            }
            if !rawItems.isEmpty { return rawItems }

            var items: [[String: Any]] = []
            let assistantText = message.content.compactMap { contentBlock -> String? in
                if case let .text(text) = contentBlock { return text }
                return nil
            }.joined()
            if !assistantText.isEmpty {
                items.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": assistantText]]])
            }
            for contentBlock in message.content {
                if case let .toolCall(toolCall) = contentBlock {
                    items.append([
                        "type": "function_call",
                        "call_id": toolCall.toolCallIdentifier,
                        "name": toolCall.toolName,
                        "arguments": toolCall.argumentsJSON,
                    ])
                }
            }
            return items
        }
    }

    /// Tool names may come back qualified by their namespace; elfhub's
    /// decoders know them by their plain names.
    static func unqualifiedToolName(_ toolName: String) -> String {
        for separator in [".", "__"] {
            let namespacePrefix = guidanceToolNamespace + separator
            if toolName.hasPrefix(namespacePrefix) {
                return String(toolName.dropFirst(namespacePrefix.count))
            }
        }
        return toolName
    }
}

// MARK: - Stream accumulator

/// Turns Responses API SSE lines into text deltas, tool calls, verbatim
/// output items, a stop reason and usage.
final class OpenAIResponsesStreamAccumulator {

    enum LineOutcome: Equatable {
        case none
        case textDelta(String)
        /// `response.completed` or `response.incomplete`: the reply is over.
        case finished
        /// `response.failed` or an `error` event.
        case failed(code: String?, message: String?, parameter: String?)
    }

    private(set) var accumulatedText = ""
    private(set) var toolCalls: [LanguageModelToolCall] = []
    /// Output items as JSON, ready to replay in a follow-up request.
    private(set) var rawOutputItems: [String] = []
    private(set) var hasFinished = false
    private(set) var usage: LanguageModelUsage?
    private var incompleteReason: String?

    var stopReason: LanguageModelStopReason? {
        guard hasFinished else { return nil }
        if let incompleteReason {
            switch incompleteReason {
            case "max_output_tokens": return .outputTokenLimit
            case "content_filter": return .refusal
            default: return .other(incompleteReason)
            }
        }
        return toolCalls.isEmpty ? .endOfTurn : .toolUse
    }

    func consume(sseLine line: String) -> LineOutcome {
        guard line.hasPrefix("data:") else { return .none }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let payloadData = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let eventType = event["type"] as? String else {
            return .none
        }

        switch eventType {
        case "response.output_text.delta":
            guard let textDelta = event["delta"] as? String, !textDelta.isEmpty else { return .none }
            accumulatedText += textDelta
            return .textDelta(textDelta)

        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any] else { return .none }
            recordOutputItem(item)
            return .none

        case "response.completed", "response.incomplete":
            let response = event["response"] as? [String: Any]
            if eventType == "response.incomplete" {
                let incompleteDetails = response?["incomplete_details"] as? [String: Any]
                incompleteReason = incompleteDetails?["reason"] as? String ?? "incomplete"
            }
            usage = Self.usage(from: response?["usage"] as? [String: Any])
            hasFinished = true
            return .finished

        case "response.failed":
            let responseError = (event["response"] as? [String: Any])?["error"] as? [String: Any]
            return .failed(
                code: responseError?["code"] as? String,
                message: responseError?["message"] as? String,
                parameter: responseError?["param"] as? String
            )

        case "error":
            let nestedError = event["error"] as? [String: Any]
            return .failed(
                code: event["code"] as? String ?? nestedError?["code"] as? String,
                message: event["message"] as? String ?? nestedError?["message"] as? String,
                parameter: event["param"] as? String ?? nestedError?["param"] as? String
            )

        default:
            return .none
        }
    }

    private func recordOutputItem(_ item: [String: Any]) {
        let itemType = item["type"] as? String
        var replayableItem = item
        // Nothing is stored server-side (`store: false`), so ids of messages
        // and calls point at nothing and would be refused on replay.
        // Reasoning keeps its id, which travels with its encrypted content.
        if itemType != "reasoning" {
            replayableItem.removeValue(forKey: "id")
        }
        if let itemData = try? JSONSerialization.data(withJSONObject: replayableItem) {
            rawOutputItems.append(String(decoding: itemData, as: UTF8.self))
        }

        if itemType == "function_call",
           let callIdentifier = item["call_id"] as? String,
           let toolName = item["name"] as? String {
            let argumentsJSON = (item["arguments"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
            toolCalls.append(LanguageModelToolCall(
                toolCallIdentifier: callIdentifier,
                toolName: OpenAIResponsesLanguageModelProvider.unqualifiedToolName(toolName),
                argumentsJSON: argumentsJSON
            ))
        }
    }

    private static func usage(from usageJSON: [String: Any]?) -> LanguageModelUsage? {
        guard let usageJSON else { return nil }
        let inputTokenDetails = usageJSON["input_tokens_details"] as? [String: Any]
        return LanguageModelUsage(
            inputTokens: usageJSON["input_tokens"] as? Int ?? 0,
            outputTokens: usageJSON["output_tokens"] as? Int ?? 0,
            cacheReadInputTokens: inputTokenDetails?["cached_tokens"] as? Int ?? 0
        )
    }
}
