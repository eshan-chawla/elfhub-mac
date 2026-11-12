//
//  OnDeviceVoiceModelCatalog.swift
//  elfhub
//
//  Speech-to-text and voice (text-to-speech) models elfhub recommends
//  downloading from Hugging Face and running on this Mac with MLX
//  (mlx-audio-swift). Each pick was checked for its license, that the engine
//  loads it by repo id, and its download size; `bestFitTiers` says which Macs
//  it's the first suggestion for (see OnDeviceComputeProfile).
//
//  People can also download any other Hugging Face repo the engine supports
//  (`normalizedRepositoryIdentifier(from:)` reads what they paste).
//

import Foundation

nonisolated enum OnDeviceVoiceModelKind: String, Codable, CaseIterable, Sendable {
    case speechToText
    case textToSpeech

    var displayName: String {
        switch self {
        case .speechToText: return "Speech-to-text"
        case .textToSpeech: return "Voice"
        }
    }
}

/// One voice a text-to-speech model can speak with.
nonisolated struct OnDeviceModelVoice: Identifiable, Equatable, Sendable {
    /// The name the engine takes (`voice:`), e.g. "af_heart".
    let id: String
    let displayName: String
}

nonisolated struct RecommendedOnDeviceVoiceModel: Identifiable, Equatable, Sendable {
    /// Hugging Face repo id, e.g. "mlx-community/Kokoro-82M-bf16".
    let id: String
    let displayName: String
    let kind: OnDeviceVoiceModelKind
    let approximateDownloadSizeInGigabytes: Double
    /// Memory the Mac should have to run it comfortably next to other apps.
    let recommendedMemoryInGigabytes: Int
    /// Macs this model is the first suggestion for.
    let bestFitTiers: Set<OnDeviceComputeProfile.ComputeTier>
    let summary: String
    let languagesSummary: String
    let licenseName: String
    /// Attribution some licenses ask for (CC-BY), shown next to the model.
    let creditLine: String?
    /// Voices for models that don't ship a `voices/` folder; models that do
    /// list theirs from the download (`OnDeviceVoiceModelCatalog.voices(inModelDirectory:)`).
    let builtInVoices: [OnDeviceModelVoice]
    let defaultVoiceIdentifier: String?
}

nonisolated enum OnDeviceVoiceModelCatalog {
    static let recommendedModels: [RecommendedOnDeviceVoiceModel] = [
        // MARK: Voices (text-to-speech)
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/Kokoro-82M-bf16",
            displayName: "Kokoro 82M",
            kind: .textToSpeech,
            approximateDownloadSizeInGigabytes: 0.4,
            recommendedMemoryInGigabytes: 8,
            bestFitTiers: [.compact, .standard],
            summary: "Fast and natural, with dozens of voices. Starts talking almost instantly.",
            languagesSummary: "English, Spanish, French, Hindi, Italian, Japanese, Portuguese, Mandarin",
            licenseName: "Apache-2.0",
            creditLine: nil,
            builtInVoices: [],
            defaultVoiceIdentifier: "af_heart"
        ),
        RecommendedOnDeviceVoiceModel(
            id: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit",
            displayName: "Marvis 250M",
            kind: .textToSpeech,
            approximateDownloadSizeInGigabytes: 0.7,
            recommendedMemoryInGigabytes: 16,
            bestFitTiers: [],
            summary: "Conversational and expressive, made for speaking in real time.",
            languagesSummary: "English",
            licenseName: "Apache-2.0",
            creditLine: nil,
            builtInVoices: [
                OnDeviceModelVoice(id: "conversational_a", displayName: "Conversational A"),
                OnDeviceModelVoice(id: "conversational_b", displayName: "Conversational B"),
            ],
            defaultVoiceIdentifier: "conversational_a"
        ),
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
            displayName: "Qwen3-TTS 0.6B",
            kind: .textToSpeech,
            approximateDownloadSizeInGigabytes: 2.0,
            recommendedMemoryInGigabytes: 16,
            bestFitTiers: [.roomy],
            summary: "Very natural speech. Takes a little longer to start each sentence.",
            languagesSummary: "English, Mandarin, Japanese, Korean, German, French and more",
            licenseName: "Apache-2.0",
            creditLine: nil,
            builtInVoices: qwen3TextToSpeechVoices,
            defaultVoiceIdentifier: "ryan"
        ),
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            displayName: "Qwen3-TTS 1.7B",
            kind: .textToSpeech,
            approximateDownloadSizeInGigabytes: 3.1,
            recommendedMemoryInGigabytes: 32,
            bestFitTiers: [.workstation],
            summary: "The most natural voice here, for Macs with plenty of memory.",
            languagesSummary: "English, Mandarin, Japanese, Korean, German, French and more",
            licenseName: "Apache-2.0",
            creditLine: nil,
            builtInVoices: qwen3TextToSpeechVoices,
            defaultVoiceIdentifier: "ryan"
        ),

        // MARK: Speech-to-text
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/whisper-large-v3-turbo-4bit",
            displayName: "Whisper large-v3 turbo (4-bit)",
            kind: .speechToText,
            approximateDownloadSizeInGigabytes: 0.5,
            recommendedMemoryInGigabytes: 8,
            bestFitTiers: [.compact],
            summary: "Accurate in many languages at a small size.",
            languagesSummary: "Around 100 languages",
            licenseName: "MIT",
            creditLine: nil,
            builtInVoices: [],
            defaultVoiceIdentifier: nil
        ),
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            kind: .speechToText,
            approximateDownloadSizeInGigabytes: 2.5,
            recommendedMemoryInGigabytes: 16,
            bestFitTiers: [.standard, .roomy, .workstation],
            summary: "Very fast and very accurate, with punctuation.",
            languagesSummary: "25 European languages, including English",
            licenseName: "CC-BY-4.0",
            creditLine: "Parakeet TDT 0.6B v3 by NVIDIA, CC-BY-4.0",
            builtInVoices: [],
            defaultVoiceIdentifier: nil
        ),
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/Qwen3-ASR-0.6B-8bit",
            displayName: "Qwen3-ASR 0.6B",
            kind: .speechToText,
            approximateDownloadSizeInGigabytes: 1.0,
            recommendedMemoryInGigabytes: 16,
            bestFitTiers: [],
            summary: "Strong across many languages and accents.",
            languagesSummary: "52 languages and dialects",
            licenseName: "Apache-2.0",
            creditLine: nil,
            builtInVoices: [],
            defaultVoiceIdentifier: nil
        ),
        RecommendedOnDeviceVoiceModel(
            id: "mlx-community/whisper-large-v3-turbo",
            displayName: "Whisper large-v3 turbo",
            kind: .speechToText,
            approximateDownloadSizeInGigabytes: 1.6,
            recommendedMemoryInGigabytes: 32,
            bestFitTiers: [],
            summary: "Whisper at full precision, the most accurate Whisper here.",
            languagesSummary: "Around 100 languages",
            licenseName: "MIT",
            creditLine: nil,
            builtInVoices: [],
            defaultVoiceIdentifier: nil
        ),
    ]

    /// Qwen3-TTS CustomVoice speakers (`talker_config.spk_id` in its config).
    private static let qwen3TextToSpeechVoices: [OnDeviceModelVoice] = [
        OnDeviceModelVoice(id: "ryan", displayName: "Ryan"),
        OnDeviceModelVoice(id: "aiden", displayName: "Aiden"),
        OnDeviceModelVoice(id: "eric", displayName: "Eric"),
        OnDeviceModelVoice(id: "dylan", displayName: "Dylan"),
        OnDeviceModelVoice(id: "serena", displayName: "Serena"),
        OnDeviceModelVoice(id: "vivian", displayName: "Vivian"),
        OnDeviceModelVoice(id: "uncle_fu", displayName: "Uncle Fu"),
        OnDeviceModelVoice(id: "ono_anna", displayName: "Ono Anna"),
        OnDeviceModelVoice(id: "sohee", displayName: "Sohee"),
    ]

    /// Files every download fetches besides the engine's own defaults
    /// (`*.safetensors`, `*.json`, `*.txt`, `*.wav`): tokenizers and voice
    /// files some models load. Original PyTorch/GGUF weights are skipped.
    static let additionalDownloadPatterns = [
        "*.model", "*.vocab", "*.tiktoken", "voices/*.safetensors", "embeddings/*.safetensors",
    ]

    static func recommendedModels(ofKind kind: OnDeviceVoiceModelKind) -> [RecommendedOnDeviceVoiceModel] {
        recommendedModels.filter { $0.kind == kind }
    }

    static func recommendedModel(withIdentifier repositoryIdentifier: String) -> RecommendedOnDeviceVoiceModel? {
        recommendedModels.first { $0.id.caseInsensitiveCompare(repositoryIdentifier) == .orderedSame }
    }

    /// The first model to suggest on this Mac for one layer.
    static func bestPick(
        for computeTier: OnDeviceComputeProfile.ComputeTier,
        kind: OnDeviceVoiceModelKind
    ) -> RecommendedOnDeviceVoiceModel? {
        let modelsOfKind = recommendedModels(ofKind: kind)
        if let bestFitModel = modelsOfKind.first(where: { $0.bestFitTiers.contains(computeTier) }) {
            return bestFitModel
        }
        // Fall back to the largest model that still fits this tier.
        return modelsOfKind
            .filter { $0.recommendedMemoryInGigabytes <= computeTier.rawValue }
            .max { $0.recommendedMemoryInGigabytes < $1.recommendedMemoryInGigabytes }
    }

    /// Reads a Hugging Face repo from what people paste: "owner/name", or a
    /// link like "https://huggingface.co/owner/name/tree/main". Nil when it
    /// isn't one.
    static func normalizedRepositoryIdentifier(from pastedText: String) -> String? {
        var remainingText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        for linkPrefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/", "hf.co/", "https://hf.co/"]
        where remainingText.lowercased().hasPrefix(linkPrefix) {
            remainingText = String(remainingText.dropFirst(linkPrefix.count))
            break
        }
        let pathComponents = remainingText.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pathComponents.count >= 2 else { return nil }
        // A link may go on into the repo (/tree/main, /blob/main/config.json).
        if pathComponents.count > 2, !["tree", "blob", "resolve"].contains(pathComponents[2]) {
            return nil
        }
        let ownerName = pathComponents[0]
        let repositoryName = pathComponents[1]
        guard isValidRepositoryNameComponent(ownerName), isValidRepositoryNameComponent(repositoryName) else {
            return nil
        }
        return "\(ownerName)/\(repositoryName)"
    }

    private static func isValidRepositoryNameComponent(_ nameComponent: String) -> Bool {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return !nameComponent.isEmpty
            && nameComponent.count <= 96
            && !nameComponent.hasPrefix(".")
            && nameComponent.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    // MARK: Voices

    /// Voices of a downloaded model: its `voices/*.safetensors` files (Kokoro
    /// and similar), else the catalog's built-in list for it.
    static func voices(inModelDirectory modelDirectory: URL, repositoryIdentifier: String) -> [OnDeviceModelVoice] {
        let voicesDirectory = modelDirectory.appendingPathComponent("voices")
        let voiceFileNames = (try? FileManager.default.contentsOfDirectory(atPath: voicesDirectory.path)) ?? []
        let voiceIdentifiers = voiceFileNames
            .filter { $0.hasSuffix(".safetensors") }
            .map { String($0.dropLast(".safetensors".count)) }
            .sorted()
        if !voiceIdentifiers.isEmpty {
            return voiceIdentifiers.map { OnDeviceModelVoice(id: $0, displayName: displayName(forVoiceIdentifier: $0)) }
        }
        return recommendedModel(withIdentifier: repositoryIdentifier)?.builtInVoices ?? []
    }

    /// "af_heart" → "Heart · American English, female". Kokoro names start
    /// with a language letter and f/m; other names are just capitalized.
    static func displayName(forVoiceIdentifier voiceIdentifier: String) -> String {
        let nameParts = voiceIdentifier.split(separator: "_", maxSplits: 1).map(String.init)
        guard nameParts.count == 2, nameParts[0].count == 2 else {
            return voiceIdentifier.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let languageLetter = nameParts[0].first!
        let genderLetter = nameParts[0].last!
        let languageNamesByLetter: [Character: String] = [
            "a": "American English", "b": "British English", "e": "Spanish", "f": "French",
            "h": "Hindi", "i": "Italian", "j": "Japanese", "p": "Brazilian Portuguese", "z": "Mandarin",
        ]
        let genderNamesByLetter: [Character: String] = ["f": "female", "m": "male"]
        guard let languageName = languageNamesByLetter[languageLetter],
              let genderName = genderNamesByLetter[genderLetter] else {
            return voiceIdentifier.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "\(nameParts[1].capitalized) · \(languageName), \(genderName)"
    }
}
