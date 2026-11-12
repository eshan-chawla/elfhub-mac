//
//  LanguageModelProvider.swift
//  elfhub
//
//  A model-agnostic surface for chat/vision LLMs. CompanionManager talks only
//  to this protocol, so Anthropic, any OpenAI-compatible endpoint (OpenAI,
//  OpenRouter, vLLM, Ollama, LM Studio, llama.cpp), or Google Gemini are all
//  interchangeable — including local models, which are just an API at some
//  base URL.
//
//  Guidance (point / annotate / act) reaches elfhub one of two ways:
//   - native tool calls, for providers configured with tool calling, decoded
//     by ToolCallGuidanceDecoder; or
//   - plain-text tags in the reply, for everything else, decoded by
//     TagGuidanceDecoder.
//  Both produce the same ScreenGuidanceCommands.
//

import Foundation

// MARK: - Capabilities

struct LanguageModelCapabilities {
    /// Whether the model accepts images. When false, callers omit screenshots.
    let supportsVision: Bool
    /// Whether guidance should be requested as native tool calls instead of tags.
    let supportsToolCalling: Bool
    /// Screenshot size limits and coordinate convention for this model.
    let visionProfile: ModelVisionProfile
}

// MARK: - Normalized request model

/// One image handed to the model, with a human-readable label (e.g. the screen
/// description + coordinate space) that also becomes coordinate-space context.
struct LanguageModelImage {
    let data: Data
    let label: String
}

/// One prior plain exchange, replayed so the model has conversational memory.
struct LanguageModelHistoryTurn {
    let userText: String
    let assistantText: String
}

/// A tool the model may call. `inputSchema` is a JSON Schema object.
struct LanguageModelToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

/// A tool call the model made. Arguments stay as the raw JSON string the
/// provider returned and are parsed by the consumer.
struct LanguageModelToolCall: Equatable {
    let toolCallIdentifier: String
    let toolName: String
    let argumentsJSON: String

    /// The arguments as a dictionary, or empty when they aren't valid JSON.
    var argumentsDictionary: [String: Any] {
        guard let argumentsData = argumentsJSON.data(using: .utf8),
              let argumentsObject = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            return [:]
        }
        return argumentsObject
    }
}

/// One piece of a message's content.
enum LanguageModelContentBlock {
    case text(String)
    case image(LanguageModelImage)
    /// A tool call the assistant made (only in assistant messages).
    case toolCall(LanguageModelToolCall)
    /// The result elfhub returns for a tool call (only in user messages).
    case toolResult(toolCallIdentifier: String, toolName: String, resultText: String)
    /// A Claude content block kept verbatim (e.g. a signed thinking block) so a
    /// follow-up request can replay the assistant turn unchanged. Other
    /// providers ignore it.
    case anthropicRawBlock(String)
}

struct LanguageModelMessage {
    enum Role {
        case user
        case assistant
    }

    let role: Role
    let content: [LanguageModelContentBlock]
}

/// How hard a reasoning model should think before answering. Lower is
/// faster; providers that don't support it ignore it.
enum LanguageModelReasoningEffort: String {
    case low
    case medium
    case high
}

/// Everything needed for a single request, independent of any provider's wire format.
struct LanguageModelRequest {
    /// Room for the reply. Generous on purpose: reasoning models spend part of
    /// it thinking, and a reply cut off mid-sentence (or mid-tool-call) is
    /// worse than a slightly larger cap, which costs nothing unless used.
    static let defaultMaxOutputTokens = 8192

    let systemPrompt: String
    /// The whole conversation in order, ending with the newest user message.
    let messages: [LanguageModelMessage]
    /// Tools the model may call. Empty means tag-based guidance.
    let tools: [LanguageModelToolDefinition]
    let maxOutputTokens: Int
    /// Optional speed/depth trade-off for models that support it (Claude's
    /// `output_config.effort`). Nil leaves the model's default.
    var reasoningEffort: LanguageModelReasoningEffort?

    init(
        systemPrompt: String,
        messages: [LanguageModelMessage],
        tools: [LanguageModelToolDefinition] = [],
        maxOutputTokens: Int = LanguageModelRequest.defaultMaxOutputTokens,
        reasoningEffort: LanguageModelReasoningEffort? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
    }

    /// Convenience for the common turn shape: prior plain exchanges, then one
    /// user message made of labeled images followed by the user's text.
    init(
        systemPrompt: String,
        history: [LanguageModelHistoryTurn] = [],
        userText: String,
        images: [LanguageModelImage] = [],
        tools: [LanguageModelToolDefinition] = [],
        maxOutputTokens: Int = LanguageModelRequest.defaultMaxOutputTokens,
        reasoningEffort: LanguageModelReasoningEffort? = nil
    ) {
        var messages: [LanguageModelMessage] = []
        for historyTurn in history {
            messages.append(LanguageModelMessage(role: .user, content: [.text(historyTurn.userText)]))
            messages.append(LanguageModelMessage(role: .assistant, content: [.text(historyTurn.assistantText)]))
        }
        let imageBlocks = images.map { LanguageModelContentBlock.image($0) }
        messages.append(LanguageModelMessage(role: .user, content: imageBlocks + [.text(userText)]))
        self.init(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools,
            maxOutputTokens: maxOutputTokens,
            reasoningEffort: reasoningEffort
        )
    }
}

// MARK: - Streaming & response

enum LanguageModelStreamEvent: Equatable {
    /// New text since the previous event — always a delta, never accumulated.
    case textDelta(String)
}

/// Why the model stopped, normalized across providers.
enum LanguageModelStopReason: Equatable {
    /// Finished its reply.
    case endOfTurn
    /// Stopped to wait for tool results.
    case toolUse
    /// Ran out of output tokens: the reply (or a tool call) may be cut off.
    case outputTokenLimit
    /// The server paused a long turn; sending the turn back continues it.
    case pausedByServer
    /// Declined to answer (safety filter or refusal).
    case refusal
    /// Anything else the provider reported, kept for the log.
    case other(String)
}

/// Token counts for one request, when the provider reports them. Cache
/// counts show whether prompt caching is working.
struct LanguageModelUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadInputTokens = 0
    var cacheCreationInputTokens = 0
}

struct LanguageModelResponse {
    /// The full reply text.
    let text: String
    /// Tool calls the model made, in order.
    let toolCalls: [LanguageModelToolCall]
    /// The assistant turn as the provider produced it, for replaying in a
    /// follow-up request (e.g. after returning tool results).
    let assistantContent: [LanguageModelContentBlock]
    let duration: TimeInterval
    /// Why the model stopped; nil when the provider didn't say.
    var stopReason: LanguageModelStopReason? = nil
    var usage: LanguageModelUsage? = nil

    /// True when the reply hit the output limit and may be cut off.
    var wasCutOffByOutputLimit: Bool { stopReason == .outputTokenLimit }
}

// MARK: - Provider protocol

protocol LanguageModelProvider {
    /// Shown in the picker, e.g. "Claude Sonnet" or "Llama 3 (local)".
    var displayName: String { get }
    var capabilities: LanguageModelCapabilities { get }

    /// Streams the model's reply. `onStreamEvent` fires on the main actor as
    /// text arrives (deltas only); the full text and any tool calls are
    /// returned at the end.
    func streamResponse(
        _ request: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse
}

extension LanguageModelProvider {
    var supportsVision: Bool { capabilities.supportsVision }
}

// MARK: - Shared helpers

enum LanguageModelWireFormatSupport {
    /// The API rejects requests whose declared media type doesn't match the
    /// bytes: screen captures are JPEG, pasted images may be PNG.
    static func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngSignature { return "image/png" }
        }
        return "image/jpeg"
    }

    /// Joins a base URL and a path, tolerating a trailing slash on the base.
    static func url(byAppending path: String, to baseURL: String) -> URL? {
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: trimmedBaseURL + path)
    }
}

// MARK: - Shared error

enum LanguageModelProviderError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case missingConfiguration(String)
    /// The server reported an error partway through a streamed reply (for
    /// example "overloaded"), so what arrived is incomplete.
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The model returned an invalid response."
        case let .httpError(statusCode, body):
            return "Model API error (\(statusCode)): \(body)"
        case let .missingConfiguration(detail):
            return "Model provider is not configured: \(detail)"
        case let .streamFailed(detail):
            return "The model's reply was interrupted: \(detail)"
        }
    }
}

// MARK: - Retrying a request before anything streams

/// When and how long to wait before retrying a request that failed before
/// any reply arrived: rate limits, overloaded or briefly unavailable
/// servers, and dropped connections. Once text has streamed to the user, a
/// failure is never retried — the user would hear the start twice.
enum LanguageModelRetryPolicy {

    /// The first try plus two retries.
    static let maximumAttemptCount = 3
    /// Never wait longer than this between tries, whatever the server asks.
    static let maximumDelayBeforeRetryInSeconds: Double = 8

    static func shouldRetry(statusCode: Int) -> Bool {
        [408, 409, 429, 500, 502, 503, 504, 529].contains(statusCode)
    }

    static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
            .contains(urlError.code)
    }

    /// Seconds to wait before attempt `attemptNumber + 1` (attempts count
    /// from 1). Honors a numeric `retry-after` header when the server sends
    /// one, otherwise backs off 0.5 s, then 1.5 s.
    static func delayBeforeRetry(afterAttempt attemptNumber: Int, retryAfterHeaderValue: String?) -> Double {
        if let retryAfterHeaderValue,
           let retryAfterSeconds = Double(retryAfterHeaderValue.trimmingCharacters(in: .whitespaces)),
           retryAfterSeconds >= 0 {
            return min(retryAfterSeconds, maximumDelayBeforeRetryInSeconds)
        }
        let backoffSeconds = 0.5 * pow(3, Double(max(attemptNumber - 1, 0)))
        return min(backoffSeconds, maximumDelayBeforeRetryInSeconds)
    }
}

enum LanguageModelHTTPStreaming {

    /// Opens a streaming request, retrying (per LanguageModelRetryPolicy)
    /// while the server answers with a retryable status or the connection
    /// fails before any byte of the reply arrives. A non-retryable error
    /// status throws `httpError` with the server's message.
    static func openStream(
        _ urlRequest: URLRequest,
        using session: URLSession,
        providerName: String
    ) async throws -> URLSession.AsyncBytes {
        var attemptNumber = 1
        while true {
            try Task.checkCancellation()
            let byteStream: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (byteStream, response) = try await session.bytes(for: urlRequest)
            } catch {
                guard attemptNumber < LanguageModelRetryPolicy.maximumAttemptCount,
                      LanguageModelRetryPolicy.isRetryableTransportError(error) else { throw error }
                let delayInSeconds = LanguageModelRetryPolicy.delayBeforeRetry(afterAttempt: attemptNumber, retryAfterHeaderValue: nil)
                print("🔁 \(providerName): connection failed (\(error.localizedDescription)); retrying in \(delayInSeconds)s")
                try await Task.sleep(nanoseconds: UInt64(delayInSeconds * 1_000_000_000))
                attemptNumber += 1
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LanguageModelProviderError.invalidResponse
            }
            if (200...299).contains(httpResponse.statusCode) {
                return byteStream
            }

            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            let errorBody = errorBodyLines.joined(separator: "\n")

            guard attemptNumber < LanguageModelRetryPolicy.maximumAttemptCount,
                  LanguageModelRetryPolicy.shouldRetry(statusCode: httpResponse.statusCode) else {
                throw LanguageModelProviderError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
            }
            let delayInSeconds = LanguageModelRetryPolicy.delayBeforeRetry(
                afterAttempt: attemptNumber,
                retryAfterHeaderValue: httpResponse.value(forHTTPHeaderField: "retry-after")
            )
            print("🔁 \(providerName): HTTP \(httpResponse.statusCode); retrying in \(delayInSeconds)s")
            try await Task.sleep(nanoseconds: UInt64(delayInSeconds * 1_000_000_000))
            attemptNumber += 1
        }
    }
}
