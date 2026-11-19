//
//  OnDeviceVoiceModelLayerTests.swift
//  elfhubTests
//
//  The downloaded MLX models as choices in the speech-to-text and voice
//  layers: they're listed, say what's missing until a model is downloaded
//  and chosen, a side elf can speak with one, and push-to-talk audio is
//  collected and handed to the model when the user lets go.
//

import AVFoundation
import Foundation
import Testing
@testable import elfhub

@MainActor
struct OnDeviceVoiceModelLayerTests {

    @Test func theModelsAreAChoiceInBothLayers() {
        #expect(TranscriptionProviderChoice.allCases.contains(.onDeviceModel))
        #expect(SpeechOutputMode.allCases.contains(.onDeviceModel))
        #expect(TranscriptionProviderChoice.onDeviceModel.displayLabel == "On-device model")
        #expect(SpeechOutputMode.onDeviceModel.displayLabel == "On-device model")
    }

    @Test func itSaysWhatsMissingUntilAModelIsDownloadedAndChosen() {
        #expect(OnDeviceVoiceModelLayers.unavailableExplanation(kind: .speechToText, activeModelIdentifier: nil, installedModelIdentifiers: []) != nil)
        #expect(OnDeviceVoiceModelLayers.unavailableExplanation(kind: .textToSpeech, activeModelIdentifier: "mlx-community/Kokoro-82M-bf16", installedModelIdentifiers: []) != nil)
        #expect(OnDeviceVoiceModelLayers.unavailableExplanation(kind: .textToSpeech, activeModelIdentifier: "mlx-community/Kokoro-82M-bf16", installedModelIdentifiers: ["mlx-community/Kokoro-82M-bf16"]) == nil)
    }

    @Test func aSideElfCanSpeakWithAnOnDeviceModelVoice() {
        let localSettings = ElfLocalSettings(voice: ElfVoiceSelection(speechOutputModeRawValue: SpeechOutputMode.onDeviceModel.rawValue, voiceIdentifier: "af_bella"))
        #expect(ElfSpeechChoice.choice(for: localSettings, isMainElf: false) == .onDeviceModel(voiceIdentifier: "af_bella"))
    }

    private func silentBuffer(seconds: Double, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        return buffer
    }

    @Test func pushToTalkAudioIsHandedToTheModelWhenTheUserLetsGo() async throws {
        var transcribedByteCounts: [Int] = []
        var transcribedSampleRates: [Int] = []
        var finalTranscripts: [String] = []
        let session = OnDeviceModelTranscriptionSession(
            transcribe: { pcm16MonoAudio, sampleRate in
                transcribedByteCounts.append(pcm16MonoAudio.count)
                transcribedSampleRates.append(sampleRate)
                return "hello there"
            },
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { finalTranscripts.append($0) },
            onError: { _ in }
        )
        session.appendAudioBuffer(silentBuffer(seconds: 0.5))
        session.requestFinalTranscript()
        for _ in 0..<50 where finalTranscripts.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(finalTranscripts == ["hello there"])
        #expect(transcribedSampleRates == [OnDeviceModelTranscriptionSession.recordingSampleRate])
        // Half a second of 16 kHz 16-bit mono.
        #expect(transcribedByteCounts.first.map { abs($0 - 16_000) < 400 } == true)
    }
}
