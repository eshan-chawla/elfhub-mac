//
//  ProviderConfiguration.swift
//  elfhub
//
//  User-editable description of one LLM endpoint. Everything the app needs to
//  build a LanguageModelProvider except the secret key, which lives in the
//  Keychain (keyed by this config's id) rather than in plain UserDefaults.
//  elfhub has no server of its own: every endpoint here is either a cloud API
//  the user has a key for, or a model server running on their Mac.
//

import Foundation

enum LanguageModelProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible
    case gemini

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompatible: return "OpenAI-compatible"
        case .gemini: return "Google Gemini"
        }
    }

    /// Placeholder base URL shown in the settings form to guide the user.
    var exampleBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://openrouter.ai/api/v1  (or http://localhost:11434/v1)"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    /// Whether guidance should use native tool calls by default. Cloud APIs
    /// support it reliably; local servers vary by model, so it's opt-in there.
    var defaultSupportsToolCalling: Bool {
        switch self {
        case .anthropic, .gemini: return true
        case .openAICompatible: return false
        }
    }

    /// The coordinate space models of this kind answer in by default. Gemini
    /// uses a 0–999 grid; Anthropic and most OpenAI-compatible models use the
    /// sent image's pixels. Local VLMs that differ (e.g. Qwen-VL's 0–1000) are
    /// set per configuration.
    var defaultCoordinateConvention: ModelCoordinateConvention {
        switch self {
        case .anthropic, .openAICompatible: return .imagePixels
        case .gemini: return .normalizedTo999
        }
    }
}

struct ProviderConfiguration: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: LanguageModelProviderKind
    var displayName: String
    var baseURL: String
    var model: String
    var supportsVision: Bool
    /// The coordinate space this model answers in when it points, annotates,
    /// or clicks. Drives both screenshot labeling and coordinate conversion.
    var coordinateConvention: ModelCoordinateConvention
    /// Whether to request guidance as native tool calls (true) or text tags.
    var supportsToolCalling: Bool
    /// The catalog preset this configuration was created from (see
    /// `LanguageModelProviderCatalog`), so settings can show its "get a key"
    /// link and setup hint. Nil for custom endpoints.
    var presetIdentifier: String?

    init(
        id: UUID = UUID(),
        kind: LanguageModelProviderKind,
        displayName: String,
        baseURL: String,
        model: String,
        supportsVision: Bool,
        coordinateConvention: ModelCoordinateConvention? = nil,
        supportsToolCalling: Bool? = nil,
        presetIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.supportsVision = supportsVision
        self.coordinateConvention = coordinateConvention ?? kind.defaultCoordinateConvention
        self.supportsToolCalling = supportsToolCalling ?? kind.defaultSupportsToolCalling
        self.presetIdentifier = presetIdentifier
    }

    // Custom decoding so configurations saved by earlier builds still load:
    // missing newer fields fall back to the kind's defaults, and the old
    // hosted-proxy flag is ignored.
    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, baseURL, model, supportsVision, coordinateConvention, supportsToolCalling, presetIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(LanguageModelProviderKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        supportsVision = try container.decode(Bool.self, forKey: .supportsVision)
        coordinateConvention = try container.decodeIfPresent(ModelCoordinateConvention.self, forKey: .coordinateConvention)
            ?? kind.defaultCoordinateConvention
        supportsToolCalling = try container.decodeIfPresent(Bool.self, forKey: .supportsToolCalling)
            ?? kind.defaultSupportsToolCalling
        presetIdentifier = try container.decodeIfPresent(String.self, forKey: .presetIdentifier)
    }

    /// Screenshot size limits and coordinate convention for this endpoint.
    /// Anthropic models use their known image limits; everything else uses a
    /// conservative size with the configured convention.
    var visionProfile: ModelVisionProfile {
        switch kind {
        case .anthropic:
            return ModelVisionProfile.forAnthropicModel(identifier: model)
        case .openAICompatible, .gemini:
            return ModelVisionProfile.genericVisionModel(coordinateConvention: coordinateConvention)
        }
    }

    var languageModelCapabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(
            supportsVision: supportsVision,
            supportsToolCalling: supportsToolCalling,
            visionProfile: visionProfile
        )
    }

    /// Whether this configuration needs a key: local servers usually need
    /// none; cloud APIs always do.
    var requiresAPIKey: Bool {
        switch kind {
        case .anthropic, .gemini: return true
        case .openAICompatible: return !LocalModelServerPreset.isLocalBaseURL(baseURL)
        }
    }

    /// True when the model runs on this Mac or the local network, so prompts
    /// and screenshots never reach a cloud API.
    var runsLocally: Bool {
        LocalModelServerPreset.isLocalBaseURL(baseURL)
    }

    /// A direct Claude configuration for the user's own Anthropic key.
    static func directAnthropic() -> ProviderConfiguration {
        LanguageModelProviderCatalog.preset(withIdentifier: "anthropic")!.makeConfiguration()
    }

    /// A configuration for a local OpenAI-compatible model server.
    static func localServer(_ localModelServerPreset: LocalModelServerPreset) -> ProviderConfiguration {
        ProviderConfiguration(
            kind: .openAICompatible,
            displayName: localModelServerPreset.displayName,
            baseURL: localModelServerPreset.defaultBaseURL,
            model: "",
            supportsVision: true,
            presetIdentifier: localModelServerPreset.rawValue
        )
    }
}

// MARK: - Local Model Servers

/// Popular servers that expose an OpenAI-compatible API on localhost.
enum LocalModelServerPreset: String, CaseIterable, Identifiable {
    case ollama
    case lmStudio
    case llamaCpp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .lmStudio: return "LM Studio (local)"
        case .llamaCpp: return "llama.cpp server (local)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .llamaCpp: return "http://localhost:8080/v1"
        }
    }

    /// True for endpoints on this Mac, which need no API key.
    static func isLocalBaseURL(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}
