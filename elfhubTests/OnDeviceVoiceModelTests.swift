//
//  OnDeviceVoiceModelTests.swift
//  elfhubTests
//
//  On-device speech models: which Macs get which recommendation, the
//  catalog's integrity, reading pasted Hugging Face repos, voice names, the
//  store's saved choices, and the audio conversions around the models.
//  Downloads and inference need the network and gigabytes of models, so
//  they're checked by hand, not here.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct OnDeviceVoiceModelTests {

    // MARK: - Compute tiers

    @Test func memoryMapsToComputeTiers() {
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 8) == .compact)
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 16) == .standard)
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 18) == .standard)
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 24) == .roomy)
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 36) == .roomy)
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 64) == .workstation)
        #expect(OnDeviceComputeProfile.computeTier(forMemoryInGigabytes: 128) == .workstation)
    }

    @Test func profileSummaryAndComfortCheck() {
        let computeProfile = OnDeviceComputeProfile(chipName: "Apple M3 Pro", memoryInGigabytes: 36)
        #expect(computeProfile.summary == "Apple M3 Pro · 36 GB")
        #expect(computeProfile.canComfortablyRun(recommendedMemoryInGigabytes: 32))
        #expect(!computeProfile.canComfortablyRun(recommendedMemoryInGigabytes: 64))
    }

    // MARK: - Recommendations

    @Test func everyMacGetsABestPickForBothLayersThatFitsIt() {
        for computeTier in OnDeviceComputeProfile.ComputeTier.allCases {
            for kind in OnDeviceVoiceModelKind.allCases {
                let bestPick = OnDeviceVoiceModelCatalog.bestPick(for: computeTier, kind: kind)
                #expect(bestPick != nil, "no \(kind) pick for \(computeTier)")
                #expect(bestPick?.kind == kind)
                #expect((bestPick?.recommendedMemoryInGigabytes ?? .max) <= computeTier.rawValue)
            }
        }
    }

    @Test func smallMacsGetSmallModelsAndBigMacsGetBetterOnes() {
        #expect(OnDeviceVoiceModelCatalog.bestPick(for: .compact, kind: .textToSpeech)?.id == "mlx-community/Kokoro-82M-bf16")
        #expect(OnDeviceVoiceModelCatalog.bestPick(for: .compact, kind: .speechToText)?.id == "mlx-community/whisper-large-v3-turbo-4bit")
        #expect(OnDeviceVoiceModelCatalog.bestPick(for: .standard, kind: .speechToText)?.id == "mlx-community/parakeet-tdt-0.6b-v3")
        #expect(OnDeviceVoiceModelCatalog.bestPick(for: .workstation, kind: .textToSpeech)?.id == "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
    }

    @Test func catalogEntriesAreCompleteAndUnique() {
        let recommendedModels = OnDeviceVoiceModelCatalog.recommendedModels
        #expect(Set(recommendedModels.map(\.id)).count == recommendedModels.count)
        for recommendedModel in recommendedModels {
            #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: recommendedModel.id) == recommendedModel.id)
            #expect(!recommendedModel.licenseName.isEmpty)
            #expect(recommendedModel.approximateDownloadSizeInGigabytes > 0)
            if recommendedModel.licenseName.hasPrefix("CC-BY") {
                #expect(recommendedModel.creditLine != nil, "\(recommendedModel.id) needs attribution")
            }
            if recommendedModel.kind == .textToSpeech {
                #expect(recommendedModel.defaultVoiceIdentifier != nil)
                if !recommendedModel.builtInVoices.isEmpty, let defaultVoiceIdentifier = recommendedModel.defaultVoiceIdentifier {
                    #expect(recommendedModel.builtInVoices.map(\.id).contains(defaultVoiceIdentifier))
                }
            }
        }
    }

    // MARK: - Pasted repos

    @Test func pastedRepositoriesAreRead() {
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: " mlx-community/Kokoro-82M-bf16 ") == "mlx-community/Kokoro-82M-bf16")
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "https://huggingface.co/mlx-community/whisper-large-v3-turbo") == "mlx-community/whisper-large-v3-turbo")
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "https://huggingface.co/owner/name/tree/main") == "owner/name")
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "hf.co/owner/model.v2/blob/main/config.json") == "owner/model.v2")
    }

    @Test func thingsThatArentRepositoriesAreRejected() {
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "") == nil)
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "kokoro") == nil)
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "owner/name with spaces") == nil)
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "owner/../etc") == nil)
        #expect(OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: "https://example.com/owner/name/extra") == nil)
    }

    // MARK: - Voices

    @Test func kokoroVoiceNamesAreReadable() {
        #expect(OnDeviceVoiceModelCatalog.displayName(forVoiceIdentifier: "af_heart") == "Heart · American English, female")
        #expect(OnDeviceVoiceModelCatalog.displayName(forVoiceIdentifier: "bm_george") == "George · British English, male")
        #expect(OnDeviceVoiceModelCatalog.displayName(forVoiceIdentifier: "conversational_a") == "Conversational A")
        #expect(OnDeviceVoiceModelCatalog.displayName(forVoiceIdentifier: "ryan") == "Ryan")
    }

    @Test func voicesComeFromTheDownloadedVoicesFolderElseTheCatalog() throws {
        let modelDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: modelDirectory) }
        let voicesDirectory = modelDirectory.appendingPathComponent("voices")
        try FileManager.default.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        for voiceFileName in ["bf_emma.safetensors", "af_heart.safetensors", "af_heart.pt"] {
            FileManager.default.createFile(atPath: voicesDirectory.appendingPathComponent(voiceFileName).path, contents: Data())
        }
        let folderVoices = OnDeviceVoiceModelCatalog.voices(inModelDirectory: modelDirectory, repositoryIdentifier: "mlx-community/Kokoro-82M-bf16")
        #expect(folderVoices.map(\.id) == ["af_heart", "bf_emma"])

        let catalogVoices = OnDeviceVoiceModelCatalog.voices(
            inModelDirectory: modelDirectory.appendingPathComponent("missing"),
            repositoryIdentifier: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit"
        )
        #expect(catalogVoices.map(\.id) == ["conversational_a", "conversational_b"])
    }

    // MARK: - Store

    private func makeIsolatedStore() -> (store: OnDeviceVoiceModelStore, cleanUp: () -> Void) {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceModels-\(UUID().uuidString)")
        let userDefaultsSuiteName = "OnDeviceVoiceModelTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        let store = OnDeviceVoiceModelStore(storageDirectory: storageDirectory, userDefaults: userDefaults)
        return (store, {
            try? FileManager.default.removeItem(at: storageDirectory)
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        })
    }

    @Test func modelsAreStoredWhereTheEngineLooksForThem() {
        let (store, cleanUp) = makeIsolatedStore()
        defer { cleanUp() }
        #expect(store.modelDirectory(forRepositoryIdentifier: "mlx-community/Kokoro-82M-bf16").path
            == store.storageDirectory.appendingPathComponent("mlx-audio/mlx-community_Kokoro-82M-bf16").path)
    }

    @Test func activeModelsAndVoicesAreRemembered() {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceModels-\(UUID().uuidString)")
        let userDefaultsSuiteName = "OnDeviceVoiceModelTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        defer {
            try? FileManager.default.removeItem(at: storageDirectory)
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        let store = OnDeviceVoiceModelStore(storageDirectory: storageDirectory, userDefaults: userDefaults)
        store.setVoiceIdentifier("conversational_b", forModelIdentifier: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit")
        #expect(store.voiceIdentifier(forModelIdentifier: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit") == "conversational_b")
        // A voice the model doesn't have falls back to the catalog default.
        store.setVoiceIdentifier("af_heart", forModelIdentifier: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit")
        #expect(store.voiceIdentifier(forModelIdentifier: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit") == "conversational_a")

        // An active model whose download is gone is cleared on reload.
        store.setActiveModel("mlx-community/Kokoro-82M-bf16", kind: .textToSpeech)
        let reloadedStore = OnDeviceVoiceModelStore(storageDirectory: storageDirectory, userDefaults: userDefaults)
        #expect(reloadedStore.activeTextToSpeechModelIdentifier == nil)
    }

    // MARK: - Audio conversion

    @Test func floatAudioBecomesClippedPCM16AndBack() {
        let pcm16Data = OnDeviceVoiceAudioConversion.pcm16Data(fromFloatSamples: [0, 1, -1, 2, -2, .nan, 0.5])
        #expect(pcm16Data.count == 7 * 2)
        let roundTrippedSamples = OnDeviceVoiceAudioConversion.floatSamples(fromPCM16Data: pcm16Data)
        #expect(roundTrippedSamples.count == 7)
        #expect(roundTrippedSamples[0] == 0)
        #expect(roundTrippedSamples[1] == 1)
        #expect(abs(roundTrippedSamples[2] + 1) < 0.0001)
        #expect(roundTrippedSamples[3] == 1)
        #expect(abs(roundTrippedSamples[4] + 1) < 0.0001)
        #expect(roundTrippedSamples[5] == 0)
        #expect(abs(roundTrippedSamples[6] - 0.5) < 0.001)
    }

    @Test func resamplingKeepsDurationAndEndpoints() {
        let oneSecondAt24Kilohertz = (0..<24_000).map { Float($0) / 24_000 }
        let resampledTo16Kilohertz = OnDeviceVoiceAudioConversion.resampledSamples(oneSecondAt24Kilohertz, fromSampleRate: 24_000, toSampleRate: 16_000)
        #expect(resampledTo16Kilohertz.count == 16_000)
        #expect(resampledTo16Kilohertz.first == oneSecondAt24Kilohertz.first)
        #expect(abs((resampledTo16Kilohertz.last ?? 0) - (oneSecondAt24Kilohertz.last ?? 0)) < 0.0001)
        #expect(OnDeviceVoiceAudioConversion.resampledSamples([0.1, 0.2], fromSampleRate: 16_000, toSampleRate: 16_000) == [0.1, 0.2])
    }

    @Test func synthesizedSpeechIsWrappedAsPlayableWAV() {
        let pcm16Data = OnDeviceVoiceAudioConversion.pcm16Data(fromFloatSamples: [0, 0.25, -0.25, 0])
        let wavData = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm16Data, sampleRate: 24_000)
        #expect(wavData.count == 44 + pcm16Data.count)
        #expect(String(data: wavData.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wavData.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
    }
}
