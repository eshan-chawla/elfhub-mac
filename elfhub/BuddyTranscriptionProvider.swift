//
//  BuddyTranscriptionProvider.swift
//  elfhub
//
//  Shared protocol surface for voice transcription backends, and the runtime
//  choice between them:
//   - On-device (Apple): SpeechAnalyzer on macOS 26+, SFSpeechRecognizer
//     before that. Private, offline, no key. The default.
//   - AssemblyAI with the user's own key (streaming).
//   - Any OpenAI-compatible transcription endpoint (OpenAI, Groq, or a local
//     faster-whisper server) with an optional key.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

// MARK: - Runtime choice

enum TranscriptionProviderChoice: String, CaseIterable, Identifiable {
    case appleOnDevice
    /// Raw value kept from earlier builds so a saved choice still loads.
    case assemblyAI = "assemblyAIOwnKey"
    case openAICompatibleWhisper
    /// A speech model downloaded from Hugging Face, run on this Mac with MLX.
    case onDeviceModel

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .appleOnDevice: return "On-device (Apple)"
        case .assemblyAI: return "AssemblyAI"
        case .openAICompatibleWhisper: return "Whisper / OpenAI-compatible"
        case .onDeviceModel: return "On-device model"
        }
    }

    /// One line explaining the trade-off, shown under the picker.
    var explanation: String {
        switch self {
        case .appleOnDevice:
            return "Private and free: your voice never leaves this Mac."
        case .assemblyAI:
            return "Fast streaming recognition with your AssemblyAI key."
        case .openAICompatibleWhisper:
            return "OpenAI, Groq, or a Whisper server running on this Mac."
        case .onDeviceModel:
            return "A speech model you download (Whisper, Parakeet and others) runs on this Mac. Private, and works offline."
        }
    }

    static let defaultChoice: TranscriptionProviderChoice = .appleOnDevice
}

/// Ready-made endpoints for the OpenAI-compatible transcription choice.
enum WhisperTranscriptionEndpointPreset: String, CaseIterable, Identifiable {
    case openAI
    case groq
    case localFasterWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .localFasterWhisper: return "Local Whisper server"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .localFasterWhisper: return "http://localhost:8000/v1"
        }
    }

    var modelName: String {
        switch self {
        case .openAI: return "gpt-4o-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .localFasterWhisper: return "Systran/faster-whisper-small"
        }
    }

    /// Where to get a key; nil for the local server.
    var apiKeyPageURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .localFasterWhisper: return nil
        }
    }
}

/// Settings for the OpenAI-compatible transcription endpoint.
enum WhisperTranscriptionSettings {
    private static let baseURLKey = "whisperTranscriptionBaseURL"
    private static let modelKey = "whisperTranscriptionModel"

    static let defaultBaseURL = WhisperTranscriptionEndpointPreset.openAI.baseURL
    static let defaultModelName = WhisperTranscriptionEndpointPreset.openAI.modelName

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var modelName: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModelName }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
}

enum BuddyTranscriptionProviderFactory {

    static func makeProvider(for transcriptionProviderChoice: TranscriptionProviderChoice) -> any BuddyTranscriptionProvider {
        let provider = resolveProvider(for: transcriptionProviderChoice)
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider(for transcriptionProviderChoice: TranscriptionProviderChoice) -> any BuddyTranscriptionProvider {
        switch transcriptionProviderChoice {
        case .appleOnDevice:
            return makeAppleOnDeviceProvider()

        case .assemblyAI:
            return AssemblyAIStreamingTranscriptionProvider(apiKey: KeychainSecretStore.secret(for: .assemblyAI))

        case .openAICompatibleWhisper:
            return OpenAIAudioTranscriptionProvider(
                baseURL: WhisperTranscriptionSettings.baseURL,
                apiKey: KeychainSecretStore.secret(for: .openAICompatibleTranscription),
                modelName: WhisperTranscriptionSettings.modelName
            )
        case .onDeviceModel:
            return OnDeviceModelTranscriptionProvider()
        }
    }

    /// SpeechAnalyzer where available (better accuracy, fully on-device),
    /// otherwise the older SFSpeechRecognizer.
    static func makeAppleOnDeviceProvider() -> any BuddyTranscriptionProvider {
        if #available(macOS 26, *) {
            return SpeechAnalyzerTranscriptionProvider()
        }
        return AppleSpeechTranscriptionProvider()
    }
}
