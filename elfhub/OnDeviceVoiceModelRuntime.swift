//
//  OnDeviceVoiceModelRuntime.swift
//  elfhub
//
//  Runs downloaded speech-to-text and voice models with MLX
//  (mlx-audio-swift). An actor, so loading and inference never block the
//  main thread, and so one model never runs twice at once on the GPU.
//
//  Each layer keeps its model in memory once loaded (loading takes seconds,
//  a sentence takes milliseconds); `unloadModel(ofKind:)` frees it when the
//  layer switches to something else.
//

import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS

enum OnDeviceVoiceModelRuntimeError: LocalizedError {
    case unsupportedModel(repositoryIdentifier: String, underlyingDescription: String)
    case producedNoAudio

    var errorDescription: String? {
        switch self {
        case let .unsupportedModel(repositoryIdentifier, underlyingDescription):
            return "elfhub can't run \(repositoryIdentifier) on this Mac: \(underlyingDescription)"
        case .producedNoAudio:
            return "The voice model produced no audio for this sentence."
        }
    }
}

actor OnDeviceVoiceModelRuntime {
    private let storageDirectory: URL
    private var loadedTextToSpeechModel: (repositoryIdentifier: String, model: any SpeechGenerationModel)?
    private var loadedSpeechToTextModel: (repositoryIdentifier: String, model: any STTGenerationModel)?

    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    private var hubCache: HubCache {
        HubCache(cacheDirectory: storageDirectory)
    }

    // MARK: One job at a time

    /// An actor lets another call in at every `await`, so without this a
    /// preload and a push-to-talk could load the same model twice (doubling
    /// memory) or run two models on the GPU at once. Loads, unloads and
    /// inference take turns, first come first served.
    private var isRunningJob = false
    private var jobsWaitingToRun: [CheckedContinuation<Void, Never>] = []

    private func beginJob() async {
        guard isRunningJob else {
            isRunningJob = true
            return
        }
        await withCheckedContinuation { continuation in
            jobsWaitingToRun.append(continuation)
        }
    }

    /// Hands the turn to the next job waiting, if there is one.
    private func endJob() {
        if jobsWaitingToRun.isEmpty {
            isRunningJob = false
        } else {
            jobsWaitingToRun.removeFirst().resume()
        }
    }

    // MARK: Loading

    /// Loads a voice model (if it isn't already), e.g. right after it's
    /// chosen so the first reply doesn't wait for it.
    func prepareTextToSpeechModel(repositoryIdentifier: String) async throws {
        await beginJob()
        defer { endJob() }
        _ = try await textToSpeechModel(repositoryIdentifier: repositoryIdentifier)
    }

    func prepareSpeechToTextModel(repositoryIdentifier: String) async throws {
        await beginJob()
        defer { endJob() }
        _ = try await speechToTextModel(repositoryIdentifier: repositoryIdentifier)
    }

    func unloadModel(ofKind kind: OnDeviceVoiceModelKind) async {
        await beginJob()
        defer { endJob() }
        switch kind {
        case .textToSpeech: loadedTextToSpeechModel = nil
        case .speechToText: loadedSpeechToTextModel = nil
        }
        MLX.GPU.clearCache()
    }

    private func textToSpeechModel(repositoryIdentifier: String) async throws -> any SpeechGenerationModel {
        if let loadedTextToSpeechModel, loadedTextToSpeechModel.repositoryIdentifier == repositoryIdentifier {
            return loadedTextToSpeechModel.model
        }
        loadedTextToSpeechModel = nil
        do {
            let model = try await TTS.loadModel(modelRepo: repositoryIdentifier, cache: hubCache)
            loadedTextToSpeechModel = (repositoryIdentifier, model)
            return model
        } catch {
            throw OnDeviceVoiceModelRuntimeError.unsupportedModel(
                repositoryIdentifier: repositoryIdentifier,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func speechToTextModel(repositoryIdentifier: String) async throws -> any STTGenerationModel {
        if let loadedSpeechToTextModel, loadedSpeechToTextModel.repositoryIdentifier == repositoryIdentifier {
            return loadedSpeechToTextModel.model
        }
        loadedSpeechToTextModel = nil
        do {
            let model = try await STT.loadModel(modelRepo: repositoryIdentifier, cache: hubCache)
            loadedSpeechToTextModel = (repositoryIdentifier, model)
            return model
        } catch {
            throw OnDeviceVoiceModelRuntimeError.unsupportedModel(
                repositoryIdentifier: repositoryIdentifier,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    // MARK: Speaking

    /// One sentence as WAV audio, ready for `NetworkAudioSpeechSynthesisProvider`.
    func synthesizeWAVData(sentence: String, repositoryIdentifier: String, voiceIdentifier: String?) async throws -> Data {
        await beginJob()
        defer { endJob() }
        let model = try await textToSpeechModel(repositoryIdentifier: repositoryIdentifier)
        let generatedAudio = try await model.generate(
            text: sentence,
            voice: voiceIdentifier,
            refAudio: nil,
            refText: nil,
            language: nil
        )
        let floatSamples = generatedAudio.asArray(Float.self)
        guard !floatSamples.isEmpty else { throw OnDeviceVoiceModelRuntimeError.producedNoAudio }
        return BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: OnDeviceVoiceAudioConversion.pcm16Data(fromFloatSamples: floatSamples),
            sampleRate: model.sampleRate
        )
    }

    // MARK: Transcribing

    /// Transcribes a push-to-talk recording (16-bit mono PCM).
    func transcribe(pcm16MonoAudio: Data, sampleRate: Int, repositoryIdentifier: String) async throws -> String {
        await beginJob()
        defer { endJob() }
        let model = try await speechToTextModel(repositoryIdentifier: repositoryIdentifier)
        let recordedSamples = OnDeviceVoiceAudioConversion.floatSamples(fromPCM16Data: pcm16MonoAudio)
        let modelSamples = OnDeviceVoiceAudioConversion.resampledSamples(
            recordedSamples,
            fromSampleRate: sampleRate,
            toSampleRate: model.sampleRate
        )
        guard !modelSamples.isEmpty else { return "" }
        let transcriptionOutput = model.generate(audio: MLXArray(modelSamples))
        return transcriptionOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Pure sample conversions between the models' float audio and the 16-bit
/// PCM the rest of elfhub records and plays.
nonisolated enum OnDeviceVoiceAudioConversion {
    /// Floats in -1…1 → little-endian 16-bit PCM (out-of-range values clip).
    static func pcm16Data(fromFloatSamples floatSamples: [Float]) -> Data {
        var pcm16Data = Data(capacity: floatSamples.count * MemoryLayout<Int16>.size)
        for floatSample in floatSamples {
            let clippedSample = max(-1, min(1, floatSample.isFinite ? floatSample : 0))
            var pcm16Sample = Int16(clippedSample * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &pcm16Sample) { pcm16Data.append(contentsOf: $0) }
        }
        return pcm16Data
    }

    /// Little-endian 16-bit PCM → floats in -1…1.
    static func floatSamples(fromPCM16Data pcm16Data: Data) -> [Float] {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        pcm16Data.withUnsafeBytes { rawBuffer in
            for sampleIndex in 0..<sampleCount {
                let pcm16Sample = Int16(littleEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: sampleIndex * MemoryLayout<Int16>.size,
                    as: Int16.self
                ))
                floatSamples[sampleIndex] = Float(pcm16Sample) / Float(Int16.max)
            }
        }
        return floatSamples
    }

    /// Linear resampling — plenty for speech going into a recognizer.
    static func resampledSamples(_ samples: [Float], fromSampleRate: Int, toSampleRate: Int) -> [Float] {
        guard fromSampleRate > 0, toSampleRate > 0, fromSampleRate != toSampleRate, samples.count > 1 else {
            return samples
        }
        let outputSampleCount = Int((Double(samples.count) * Double(toSampleRate) / Double(fromSampleRate)).rounded())
        guard outputSampleCount > 0 else { return [] }
        let inputSamplesPerOutputSample = Double(samples.count - 1) / Double(max(outputSampleCount - 1, 1))
        return (0..<outputSampleCount).map { outputIndex in
            let inputPosition = Double(outputIndex) * inputSamplesPerOutputSample
            let lowerInputIndex = Int(inputPosition)
            let upperInputIndex = min(lowerInputIndex + 1, samples.count - 1)
            let interpolationWeight = Float(inputPosition - Double(lowerInputIndex))
            return samples[lowerInputIndex] * (1 - interpolationWeight) + samples[upperInputIndex] * interpolationWeight
        }
    }
}
