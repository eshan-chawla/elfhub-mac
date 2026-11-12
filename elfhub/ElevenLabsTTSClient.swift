//
//  ElevenLabsTTSClient.swift
//  elfhub
//
//  Network text-to-speech clients, one sentence per request:
//   - ElevenLabs, directly with the user's own key and chosen voice;
//   - any OpenAI-compatible /audio/speech endpoint (OpenAI, or a speech
//     server running on this Mac such as Kokoro-FastAPI).
//  Playback is handled by NetworkAudioSpeechSynthesisProvider.
//

import Foundation

final class ElevenLabsTTSClient {

    /// A premade ElevenLabs voice available on every account, used when the
    /// user hasn't picked one.
    static let defaultVoiceIdentifier = "21m00Tcm4TlvDq8ikWAM"
    static let speechModelIdentifier = "eleven_flash_v2_5"

    private let apiKey: String
    private let voiceIdentifier: String
    private let session: URLSession

    init(apiKey: String, voiceIdentifier: String) {
        self.apiKey = apiKey
        self.voiceIdentifier = voiceIdentifier

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Returns MP3 audio for `text`. Throws on network or API errors so the
    /// caller can fall back to the on-device voice.
    func synthesizeSpeechAudio(for text: String) async throws -> Data {
        var request = try Self.makeRequest(apiKey: apiKey, voiceIdentifier: voiceIdentifier)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": Self.speechModelIdentifier,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
            ],
        ] as [String: Any])

        return try await NetworkSpeechAudioRequest.perform(request, using: session, serviceName: "ElevenLabs")
    }

    /// Builds the request (pure; unit-tested).
    static func makeRequest(apiKey: String, voiceIdentifier: String) throws -> URLRequest {
        guard let directURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceIdentifier)?output_format=mp3_44100_128") else {
            throw NSError(domain: "ElevenLabsTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid voice id"])
        }
        var request = URLRequest(url: directURL)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        return request
    }
}

// MARK: - OpenAI-compatible speech

/// Text-to-speech through any OpenAI-compatible `/audio/speech` endpoint.
final class OpenAICompatibleSpeechClient {
    private let baseURL: String
    private let apiKey: String?
    private let modelName: String
    private let voiceName: String
    private let session: URLSession

    init(baseURL: String, apiKey: String?, modelName: String, voiceName: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.voiceName = voiceName

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func synthesizeSpeechAudio(for text: String) async throws -> Data {
        let request = try Self.makeRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            modelName: modelName,
            voiceName: voiceName,
            text: text
        )
        return try await NetworkSpeechAudioRequest.perform(request, using: session, serviceName: "Speech server")
    }

    /// Builds the request (pure; unit-tested).
    static func makeRequest(baseURL: String, apiKey: String?, modelName: String, voiceName: String, text: String) throws -> URLRequest {
        guard let speechEndpointURL = LanguageModelWireFormatSupport.url(byAppending: "/audio/speech", to: baseURL) else {
            throw NSError(domain: "OpenAICompatibleSpeech", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid speech base URL"])
        }
        var request = URLRequest(url: speechEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "voice": voiceName,
            "input": text,
            "response_format": "mp3",
        ])
        return request
    }
}

/// Shared send-and-check for the network voices.
enum NetworkSpeechAudioRequest {
    static func perform(_ request: URLRequest, using session: URLSession, serviceName: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "NetworkSpeech", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "\(serviceName): invalid response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NetworkSpeech", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "\(serviceName) error (\(httpResponse.statusCode))"])
        }
        try Task.checkCancellation()
        return data
    }
}
