//
//  ProviderConfigurationStore.swift
//  elfhub
//
//  Source of truth for which model elfhub talks to: the user's own configured
//  providers (any catalog preset — Claude, OpenAI, Gemini, OpenRouter… with
//  their key — or a model server on this Mac such as Ollama). Configs persist
//  as JSON in UserDefaults; keys live in the Keychain.
//

import Combine
import Foundation

@MainActor
final class ProviderConfigurationStore: ObservableObject {
    /// The user's provider configurations.
    @Published private(set) var configurations: [ProviderConfiguration]
    @Published private(set) var activeConfigurationID: UUID?

    private static let configurationsKey = "llmProviderConfigurations"
    private static let activeIDKey = "activeLLMProviderID"

    init() {
        let loadedConfigurations = Self.loadConfigurations()
        self.configurations = loadedConfigurations
        self.activeConfigurationID = UserDefaults.standard.string(forKey: Self.activeIDKey)
            .flatMap(UUID.init(uuidString:))
            .flatMap { storedActiveID in
                loadedConfigurations.contains(where: { $0.id == storedActiveID }) ? storedActiveID : nil
            }
            ?? loadedConfigurations.first?.id
        Self.saveConfigurations(loadedConfigurations)
    }

    // MARK: - Active config

    /// The configuration the next turn will use, or nil when nothing is set up yet.
    var activeConfiguration: ProviderConfiguration? {
        configurations.first(where: { $0.id == activeConfigurationID }) ?? configurations.first
    }

    /// True when the active configuration has what it needs to make a request
    /// (e.g. a key for APIs that require one).
    var isActiveConfigurationReady: Bool {
        guard let activeConfiguration else { return false }
        return isReady(activeConfiguration)
    }

    /// True when a configuration has a model and, if it needs one, a key.
    func isReady(_ configuration: ProviderConfiguration) -> Bool {
        guard !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard configuration.requiresAPIKey else { return true }
        return apiKey(forProviderID: configuration.id)?.isEmpty == false
    }

    func setActiveConfiguration(id: UUID) {
        guard configurations.contains(where: { $0.id == id }) else { return }
        activeConfigurationID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeIDKey)
    }

// MARK: - CRUD

    /// Adds or updates a configuration, and stores its key in the Keychain
    /// (pass nil to leave an existing key untouched, "" to clear it).
    func upsert(_ configuration: ProviderConfiguration, apiKey: String?) {
        if let existingIndex = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[existingIndex] = configuration
        } else {
            configurations.append(configuration)
        }
        if let apiKey {
            KeychainSecretStore.setSecret(
                apiKey,
                forAccount: KeychainSecretStore.account(forProviderID: configuration.id)
            )
        }
        if activeConfigurationID == nil {
            setActiveConfiguration(id: configuration.id)
        }
        persist()
    }

    func delete(id: UUID) {
        configurations.removeAll { $0.id == id }
        KeychainSecretStore.deleteSecret(forAccount: KeychainSecretStore.account(forProviderID: id))
        if activeConfigurationID == id {
            activeConfigurationID = configurations.first?.id
            if let newActiveID = activeConfigurationID {
                UserDefaults.standard.set(newActiveID.uuidString, forKey: Self.activeIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeIDKey)
            }
        }
        persist()
    }

    func apiKey(forProviderID providerID: UUID) -> String? {
        KeychainSecretStore.secret(forAccount: KeychainSecretStore.account(forProviderID: providerID))
    }

    // MARK: - Building the live provider

    /// Builds a LanguageModelProvider from the active configuration.
    func makeActiveProvider() throws -> LanguageModelProvider {
        guard let configuration = activeConfiguration else {
            throw LanguageModelProviderError.missingConfiguration("add a model in Settings, under Models")
        }
        return try Self.makeProvider(for: configuration, apiKey: apiKey(forProviderID: configuration.id))
    }

    /// Builds a provider for any configuration (also used by "Test connection").
    static func makeProvider(for configuration: ProviderConfiguration, apiKey: String?) throws -> LanguageModelProvider {
        let capabilities = configuration.languageModelCapabilities

        switch configuration.kind {
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else {
                throw LanguageModelProviderError.missingConfiguration("add your Anthropic API key in Settings, under Models")
            }
            guard let messagesEndpointURL = ClaudeAPI.directMessagesEndpointURL(forBaseURL: configuration.baseURL) else {
                throw LanguageModelProviderError.missingConfiguration("invalid Anthropic base URL")
            }
            return AnthropicLanguageModelProvider(
                claudeAPI: ClaudeAPI(messagesEndpointURL: messagesEndpointURL, apiKey: apiKey, model: configuration.model),
                displayName: configuration.displayName,
                capabilities: capabilities
            )

        case .openAICompatible:
            return try OpenAICompatibleLanguageModelProvider(
                displayName: configuration.displayName,
                baseURL: configuration.baseURL,
                apiKey: apiKey,
                model: configuration.model,
                capabilities: capabilities
            )

        case .gemini:
            guard let apiKey, !apiKey.isEmpty else {
                throw LanguageModelProviderError.missingConfiguration("add your Gemini API key in Settings, under Models")
            }
            return GeminiLanguageModelProvider(
                displayName: configuration.displayName,
                baseURL: configuration.baseURL,
                apiKey: apiKey,
                model: configuration.model,
                capabilities: capabilities
            )
        }
    }

    // MARK: - Persistence

    private func persist() {
        Self.saveConfigurations(configurations)
    }

    private static func loadConfigurations() -> [ProviderConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: configurationsKey),
              let decoded = try? JSONDecoder().decode([ProviderConfiguration].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveConfigurations(_ configurations: [ProviderConfiguration]) {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: configurationsKey)
    }
}

// MARK: - Local server discovery

/// Talks to providers outside a chat turn: listing models (for the "Detect
/// models" button) and a minimal test request.
enum LocalModelServerDiscovery {

    /// Model ids the configured endpoint offers, using each kind's own
    /// model-list route and auth header.
    static func listModelIdentifiers(for configuration: ProviderConfiguration, apiKey: String?) async throws -> [String] {
        switch configuration.kind {
        case .openAICompatible:
            return try await listModelIdentifiers(baseURL: configuration.baseURL, apiKey: apiKey)
        case .anthropic:
            guard let modelsURL = LanguageModelWireFormatSupport.url(byAppending: "/v1/models?limit=100", to: configuration.baseURL) else {
                throw LanguageModelProviderError.missingConfiguration("invalid base URL")
            }
            var request = URLRequest(url: modelsURL)
            request.timeoutInterval = 8
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return parseModelIdentifiers(fromModelsResponse: try await performModelListRequest(request))
        case .gemini:
            guard let modelsURL = LanguageModelWireFormatSupport.url(byAppending: "/models?pageSize=200", to: configuration.baseURL) else {
                throw LanguageModelProviderError.missingConfiguration("invalid base URL")
            }
            var request = URLRequest(url: modelsURL)
            request.timeoutInterval = 8
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-goog-api-key")
            return parseGeminiModelIdentifiers(fromModelsResponse: try await performModelListRequest(request))
        }
    }

    private static func performModelListRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw LanguageModelProviderError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }

    /// Parses Gemini's {"models":[{"name":"models/…","supportedGenerationMethods":[…]}]},
    /// keeping only chat-capable models and dropping the "models/" prefix
    /// (the provider adds it back when building request URLs).
    static func parseGeminiModelIdentifiers(fromModelsResponse responseData: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let modelEntries = json["models"] as? [[String: Any]] else {
            return []
        }
        return modelEntries.compactMap { modelEntry -> String? in
            guard let modelName = modelEntry["name"] as? String else { return nil }
            let supportedGenerationMethods = modelEntry["supportedGenerationMethods"] as? [String] ?? []
            guard supportedGenerationMethods.isEmpty || supportedGenerationMethods.contains("generateContent") else { return nil }
            return modelName.hasPrefix("models/") ? String(modelName.dropFirst("models/".count)) : modelName
        }
        .sorted()
    }

    /// Model ids from GET <baseURL>/models, sorted.
    static func listModelIdentifiers(baseURL: String, apiKey: String?) async throws -> [String] {
        guard let modelsURL = LanguageModelWireFormatSupport.url(byAppending: "/models", to: baseURL) else {
            throw LanguageModelProviderError.missingConfiguration("invalid base URL")
        }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 8
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw LanguageModelProviderError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        return parseModelIdentifiers(fromModelsResponse: data)
    }

    /// Parses the OpenAI-style {"data":[{"id":...}]} model list.
    static func parseModelIdentifiers(fromModelsResponse responseData: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let modelEntries = json["data"] as? [[String: Any]] else {
            return []
        }
        return modelEntries.compactMap { $0["id"] as? String }.sorted()
    }

    /// Sends a tiny text-only request through the real provider to confirm the
    /// endpoint, key and model all work. Returns the model's reply.
    static func testConnection(configuration: ProviderConfiguration, apiKey: String?) async throws -> String {
        let provider = try ProviderConfigurationStore.makeProvider(for: configuration, apiKey: apiKey)
        let testRequest = LanguageModelRequest(
            systemPrompt: "Reply with exactly: ok",
            userText: "connection test",
            maxOutputTokens: 512
        )
        let testResponse = try await provider.streamResponse(testRequest, onStreamEvent: { _ in })
        return testResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
