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

    /// What each account held the last time it was read or written here.
    /// Readiness checks read keys on every turn and in view bodies; each
    /// Keychain query is a trip to securityd. Only elfhub writes these items,
    /// so the cache stays right; a failed read (a locked Keychain) is never
    /// cached. `nil` means "known to have no secret".
    nonisolated(unsafe) private static var cachedSecretByAccount: [String: String?] = [:]
    private static let cacheLock = NSLock()

    private static func cachedSecret(forAccount account: String) -> String?? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedSecretByAccount[account]
    }

    private static func cache(_ secret: String?, forAccount account: String) {
        cacheLock.lock()
        cachedSecretByAccount[account] = .some(secret)
        cacheLock.unlock()
    }

    private static func forgetCachedSecret(forAccount account: String) {
        cacheLock.lock()
        cachedSecretByAccount[account] = nil
        cacheLock.unlock()
    }

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
        if updateStatus == errSecSuccess {
            cache(secret, forAccount: account)
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            forgetCachedSecret(forAccount: account)
            return false
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secretData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let didAdd = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        if didAdd {
            cache(secret, forAccount: account)
        } else {
            forgetCachedSecret(forAccount: account)
        }
        return didAdd
    }

    /// Reads a secret, or nil if none is stored.
    static func secret(forAccount account: String) -> String? {
        if let cachedSecret = cachedSecret(forAccount: account) {
            return cachedSecret
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if copyStatus == errSecItemNotFound {
            cache(nil, forAccount: account)
            return nil
        }
        guard copyStatus == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        cache(secret, forAccount: account)
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
        let didDelete = status == errSecSuccess || status == errSecItemNotFound
        if didDelete {
            cache(nil, forAccount: account)
        } else {
            forgetCachedSecret(forAccount: account)
        }
        return didDelete
    }

    /// Every secret elfhub keeps (model keys, speech and search keys, the
    /// ChatGPT sign-in), for taking them out of an error report before the
    /// user sees it. Never sent anywhere.
    static func allStoredSecrets() -> [String] {
        let accountListQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(accountListQuery as CFDictionary, &result) == errSecSuccess,
              let itemAttributes = result as? [[String: Any]] else { return [] }
        return itemAttributes
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap { secret(forAccount: $0) }
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

    var id: String { rawValue }

    var keychainAccountName: String {
        switch self {
        case .assemblyAI: return "service-key-assemblyai"
        case .elevenLabs: return "service-key-elevenlabs"
        case .openAICompatibleTranscription: return "service-key-openai-transcription"
        case .openAICompatibleSpeech: return "service-key-openai-speech"
        }
    }

    var displayLabel: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .elevenLabs: return "ElevenLabs"
        case .openAICompatibleTranscription: return "Whisper / OpenAI transcription"
        case .openAICompatibleSpeech: return "OpenAI-compatible voice"
        }
    }
}
