//
//  KeychainSecretStore.swift
//  elfhub
//
//  Minimal wrapper over the macOS Keychain for storing API keys. Keys never go
//  into UserDefaults or the app bundle — only here. Used for LLM provider keys
//  (one per provider configuration) and the user's own speech-service keys.
//

import Foundation
import Security

enum KeychainSecretStore {
    /// Namespaces all elfhub secrets under one service so they're easy to find/clear.
    private static let service = "so.elfhub.secrets"

    /// Stores (or clears, when `secret` is nil/empty) a secret for `account`.
    /// An existing item is updated in place, so there is never a moment with
    /// no item: the ChatGPT sign-in's refresh token rotates on every renewal
    /// and must not be lost if the app quits mid-write.
    @discardableResult
    static func setSecret(_ secret: String?, forAccount account: String) -> Bool {
        guard let secret, !secret.isEmpty, let secretData = secret.data(using: .utf8) else {
            return deleteSecret(forAccount: account)
        }

        let existingItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            existingItemQuery as CFDictionary,
            [kSecValueData as String: secretData] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secretData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a secret, or nil if none is stored.
    static func secret(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }

    @discardableResult
    static func deleteSecret(forAccount account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The Keychain account name for a provider config's API key.
    static func account(forProviderID providerID: UUID) -> String {
        "provider-key-\(providerID.uuidString)"
    }

    static func secret(for serviceSecretAccount: ServiceSecretAccount) -> String? {
        secret(forAccount: serviceSecretAccount.keychainAccountName)
    }

    @discardableResult
    static func setSecret(_ secret: String?, for serviceSecretAccount: ServiceSecretAccount) -> Bool {
        setSecret(secret, forAccount: serviceSecretAccount.keychainAccountName)
    }
}

/// Keys for speech services (model provider keys are stored per provider
/// configuration instead).
enum ServiceSecretAccount: String, CaseIterable, Identifiable {
    case assemblyAI
    case elevenLabs
    case openAICompatibleTranscription
    case openAICompatibleSpeech
    /// The web search service elves use (Brave, Tavily or Exa).
    case webSearch

    var id: String { rawValue }

    var keychainAccountName: String {
        switch self {
        case .assemblyAI: return "service-key-assemblyai"
        case .elevenLabs: return "service-key-elevenlabs"
        case .openAICompatibleTranscription: return "service-key-openai-transcription"
        case .openAICompatibleSpeech: return "service-key-openai-speech"
        case .webSearch: return "service-key-web-search"
        }
    }

    var displayLabel: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .elevenLabs: return "ElevenLabs"
        case .openAICompatibleTranscription: return "Whisper / OpenAI transcription"
        case .openAICompatibleSpeech: return "OpenAI-compatible voice"
        case .webSearch: return "Web search"
        }
    }
}
