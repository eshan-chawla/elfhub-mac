//
//  OnDeviceVoiceModelLayers.swift
//  elfhub
//
//  The downloaded MLX models (OnDeviceVoiceModelStore / Runtime) as a
//  choice in the speech-to-text and voice layers: "On-device model" in
//  Settings › Models and onboarding. Speech-to-text collects push-to-talk
//  audio and transcribes it with the chosen model when the user lets go;
//  the voice speaks each sentence with the chosen model and voice. Until a
//  model is downloaded and chosen, the layer says what's missing and the
//  voice falls back to Apple's on-device voice.
//

import AVFoundation
import Foundation

/// The one model store and engine the app shares.
@MainActor
final class OnDeviceVoiceModelLayers {
    static let shared = OnDeviceVoiceModelLayers()

    let store = OnDeviceVoiceModelStore()
    private(set) lazy var runtime = OnDeviceVoiceModelRuntime(storageDirectory: store.storageDirectory)

    /// What's missing before a layer can use its model, or nil when ready.
    nonisolated static func unavailableExplanation(
        kind: OnDeviceVoiceModelKind,
        activeModelIdentifier: String?,
        installedModelIdentifiers: Set<String>
    ) -> String? {
        let layerName = kind == .speechToText ? "speech model" : "voice model"
        guard let activeModelIdentifier else {
            return "Download a \(layerName) below and choose it."
        }
        guard installedModelIdentifiers.contains(activeModelIdentifier) else {
            return "The chosen \(layerName) isn't downloaded. Download it again below, or choose another."
        }
        return nil
    }

    func unavailableExplanation(kind: OnDeviceVoiceModelKind) -> String? {
        Self.unavailableExplanation(
            kind: kind,
            activeModelIdentifier: store.activeModelIdentifier(forKind: kind),
            installedModelIdentifiers: Set(store.installedModels.map(\.id))
        )
    }

    func isReady(kind: OnDeviceVoiceModelKind) -> Bool {
        unavailableExplanation(kind: kind) == nil
    }

    /// Frees a layer's model (the layer moved to another service, or its
    /// model was deleted).
    func unloadModel(kind: OnDeviceVoiceModelKind) {
        let runtime = self.runtime
        Task.detached(priority: .utility) { await runtime.unloadModel(ofKind: kind) }
    }

    /// Loads the chosen model ahead of time, so the first sentence or
    /// recording doesn't wait for it (loading takes seconds).
    func prepareActiveModel(kind: OnDeviceVoiceModelKind) {
        guard isReady(kind: kind), let activeModelIdentifier = store.activeModelIdentifier(forKind: kind) else { return }
        let runtime = self.runtime
        Task.detached(priority: .utility) {
            switch kind {
            case .speechToText: try? await runtime.prepareSpeechToTextModel(repositoryIdentifier: activeModelIdentifier)
            case .textToSpeech: try? await runtime.prepareTextToSpeechModel(repositoryIdentifier: activeModelIdentifier)
            }
        }
    }

    /// A voice that speaks with the chosen model (and `voiceIdentifierOverride`
    /// for an elf with its own voice), or nil when it isn't ready.
    func makeSpeechProvider(voiceIdentifierOverride: String? = nil) -> SpeechSynthesisProvider? {
        guard isReady(kind: .textToSpeech), let activeModelIdentifier = store.activeTextToSpeechModelIdentifier else { return nil }
        // An elf's voice saved for another model isn't passed to this one.
        let availableVoiceIdentifiers = Set(store.availableVoices(forModelIdentifier: activeModelIdentifier).map(\.id))
        let usableVoiceOverride = voiceIdentifierOverride.flatMap { availableVoiceIdentifiers.contains($0) ? $0 : nil }
        let voiceIdentifier = usableVoiceOverride ?? store.voiceIdentifier(forModelIdentifier: activeModelIdentifier)
        let runtime = self.runtime
        return NetworkAudioSpeechSynthesisProvider(synthesizeSpeechAudio: { sentence in
            try await runtime.synthesizeWAVData(sentence: sentence, repositoryIdentifier: activeModelIdentifier, voiceIdentifier: voiceIdentifier)
        })
    }
}

enum OnDeviceModelTranscriptionError: LocalizedError {
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case let .notReady(explanation): return explanation
        }
    }
}

/// Speech-to-text with the downloaded model chosen in Settings › Models.
final class OnDeviceModelTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "On-device model"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        OnDeviceVoiceModelLayers.shared.isReady(kind: .speechToText)
    }

    var unavailableExplanation: String? {
        OnDeviceVoiceModelLayers.shared.unavailableExplanation(kind: .speechToText)
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let onDeviceVoiceModelLayers = OnDeviceVoiceModelLayers.shared
        guard let activeModelIdentifier = onDeviceVoiceModelLayers.store.activeSpeechToTextModelIdentifier,
              onDeviceVoiceModelLayers.isReady(kind: .speechToText) else {
            throw OnDeviceModelTranscriptionError.notReady(unavailableExplanation ?? "Choose a speech model in Settings › Models.")
        }
        let runtime = onDeviceVoiceModelLayers.runtime
        return OnDeviceModelTranscriptionSession(
            transcribe: { pcm16MonoAudio, sampleRate in
                try await runtime.transcribe(pcm16MonoAudio: pcm16MonoAudio, sampleRate: sampleRate, repositoryIdentifier: activeModelIdentifier)
            },
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

/// Collects push-to-talk audio as 16 kHz 16-bit mono and transcribes it all
/// when the user lets go (these models work on a whole recording).
final class OnDeviceModelTranscriptionSession: BuddyStreamingTranscriptionSession {
    static let recordingSampleRate = 16_000
    /// Long recordings on a slow Mac can take a while to transcribe.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 30.0

    private let transcribe: (_ pcm16MonoAudio: Data, _ sampleRate: Int) async throws -> String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "so.elfhub.on-device-model.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(recordingSampleRate))
    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        transcribe: @escaping (_ pcm16MonoAudio: Data, _ sampleRate: Int) async throws -> String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.transcribe = transcribe
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer), !audioPCM16Data.isEmpty else { return }
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled, !stateQueue.sync(execute: { isCancelled }) else { return }
        guard !bufferedPCM16AudioData.isEmpty else {
            onFinalTranscriptReady("")
            return
        }
        do {
            let transcriptText = try await transcribe(bufferedPCM16AudioData, Self.recordingSampleRate)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            onFinalTranscriptReady(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }
    }
}
