//
//  LanguageModelProviderCatalog.swift
//  elfhub
//
//  Ready-made presets for the model providers people actually use, so adding
//  one is "pick it, paste a key, pick a model" instead of hunting for base
//  URLs and wire formats. Each preset fills in a ProviderConfiguration; the
//  user can still change every field under "Advanced".
//
//  Model ids change often, so most presets leave the model empty and the
//  settings screen lists what the account actually has ("Detect models").
//

import Foundation

/// Where a preset's model runs — shown as separate groups when adding one.
enum LanguageModelProviderPresetCategory: String, CaseIterable, Identifiable {
    case cloudAPI
    case onThisMac

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .cloudAPI: return "Cloud APIs (your key)"
        case .onThisMac: return "On this Mac (no key, nothing leaves your Mac)"
        }
    }
}

struct LanguageModelProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    let category: LanguageModelProviderPresetCategory
    let kind: LanguageModelProviderKind
    let baseURL: String
    /// A sensible starting model, or "" when the user should detect/pick one.
    let suggestedModelIdentifier: String
    /// Where to create an API key; nil for local servers.
    let apiKeyPageURL: URL?
    /// Whether this provider's flagship models accept images. The user can
    /// turn it off per model in settings.
    let supportsVisionByDefault: Bool
    let supportsToolCallingByDefault: Bool
    /// Nil uses the kind's default convention.
    let coordinateConvention: ModelCoordinateConvention?
    /// One line shown in the editor to help the user finish setup.
    let setupHint: String

    func makeConfiguration() -> ProviderConfiguration {
        ProviderConfiguration(
            kind: kind,
            displayName: displayName,
            baseURL: baseURL,
            model: suggestedModelIdentifier,
            supportsVision: supportsVisionByDefault,
            coordinateConvention: coordinateConvention,
            supportsToolCalling: supportsToolCallingByDefault,
            presetIdentifier: id
        )
    }
}

enum LanguageModelProviderCatalog {

    static let allPresets: [LanguageModelProviderPreset] = [
        LanguageModelProviderPreset(
            id: "anthropic",
            displayName: "Anthropic (Claude)",
            category: .cloudAPI,
            kind: .anthropic,
            baseURL: "https://api.anthropic.com",
            suggestedModelIdentifier: "claude-opus-5-5",
            apiKeyPageURL: URL(string: "https://console.anthropic.com/settings/keys"),
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Claude models can see your screen and point precisely."
        ),
        LanguageModelProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://platform.openai.com/api-keys"),
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Paste your key, then detect models and pick one that accepts images."
        ),
        LanguageModelProviderPreset(
            id: "gemini",
            displayName: "Google Gemini",
            category: .cloudAPI,
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://aistudio.google.com/apikey"),
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Gemini models see images and answer screen positions on a 0–999 grid."
        ),
        LanguageModelProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://openrouter.ai/keys"),
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "One key for hundreds of models. Pick one that accepts images to share your screen."
        ),
        LanguageModelProviderPreset(
            id: "mistral",
            displayName: "Mistral",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://api.mistral.ai/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://console.mistral.ai/api-keys"),
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Pick a Mistral model that accepts images to share your screen."
        ),
        LanguageModelProviderPreset(
            id: "xai",
            displayName: "xAI (Grok)",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://api.x.ai/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://console.x.ai"),
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Pick a Grok model that accepts images to share your screen."
        ),
        LanguageModelProviderPreset(
            id: "groq",
            displayName: "Groq",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://api.groq.com/openai/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://console.groq.com/keys"),
            supportsVisionByDefault: false,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Very fast. Most Groq models are text-only — turn on \"can see images\" only for a vision model."
        ),
        LanguageModelProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://platform.deepseek.com/api_keys"),
            supportsVisionByDefault: false,
            supportsToolCallingByDefault: true,
            coordinateConvention: nil,
            setupHint: "Text-only: elfhub can talk and chat, but won't see your screen or point."
        ),
        LanguageModelProviderPreset(
            id: "together",
            displayName: "Together AI",
            category: .cloudAPI,
            kind: .openAICompatible,
            baseURL: "https://api.together.xyz/v1",
            suggestedModelIdentifier: "",
            apiKeyPageURL: URL(string: "https://api.together.ai/settings/api-keys"),
            supportsVisionByDefault: false,
            supportsToolCallingByDefault: false,
            coordinateConvention: nil,
            setupHint: "Open models in the cloud. Turn on \"can see images\" only for a vision model."
        ),
        LanguageModelProviderPreset(
            id: LocalModelServerPreset.ollama.rawValue,
            displayName: "Ollama",
            category: .onThisMac,
            kind: .openAICompatible,
            baseURL: LocalModelServerPreset.ollama.defaultBaseURL,
            suggestedModelIdentifier: "",
            apiKeyPageURL: nil,
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: false,
            coordinateConvention: nil,
            setupHint: "Download a model with the on-device model assistant, or detect ones you already have."
        ),
        LanguageModelProviderPreset(
            id: LocalModelServerPreset.lmStudio.rawValue,
            displayName: "LM Studio",
            category: .onThisMac,
            kind: .openAICompatible,
            baseURL: LocalModelServerPreset.lmStudio.defaultBaseURL,
            suggestedModelIdentifier: "",
            apiKeyPageURL: nil,
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: false,
            coordinateConvention: nil,
            setupHint: "Start the local server in LM Studio (Developer tab), then detect its models."
        ),
        LanguageModelProviderPreset(
            id: LocalModelServerPreset.llamaCpp.rawValue,
            displayName: "llama.cpp server",
            category: .onThisMac,
            kind: .openAICompatible,
            baseURL: LocalModelServerPreset.llamaCpp.defaultBaseURL,
            suggestedModelIdentifier: "",
            apiKeyPageURL: nil,
            supportsVisionByDefault: true,
            supportsToolCallingByDefault: false,
            coordinateConvention: nil,
            setupHint: "Run llama-server with a vision model and its --mmproj file, then detect its model."
        ),
    ]

    static func presets(in category: LanguageModelProviderPresetCategory) -> [LanguageModelProviderPreset] {
        allPresets.filter { $0.category == category }
    }

    static func preset(withIdentifier presetIdentifier: String?) -> LanguageModelProviderPreset? {
        guard let presetIdentifier else { return nil }
        return allPresets.first { $0.id == presetIdentifier }
    }

    /// A blank OpenAI-compatible endpoint for anything not in the catalog
    /// (vLLM, a company gateway, another cloud).
    static func customOpenAICompatibleConfiguration() -> ProviderConfiguration {
        ProviderConfiguration(
            kind: .openAICompatible,
            displayName: "Custom endpoint",
            baseURL: "",
            model: "",
            supportsVision: true
        )
    }
}
