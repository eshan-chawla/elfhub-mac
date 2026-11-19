//
//  SpeechSynthesisProvider.swift
//  elfhub
//
//  Makes text-to-speech optional and swappable, and sentence-by-sentence so
//  speech can start before the whole reply has arrived:
//   - Apple's on-device voice (no key, works offline) — the default,
//   - ElevenLabs with the user's own key,
//   - any OpenAI-compatible /audio/speech endpoint (OpenAI, or a speech
//     server on this Mac such as Kokoro-FastAPI),
//   - or off, for a fully silent / caption-only experience.
//
//  Each provider splits speaking into "prepare a sentence" (which may hit the
//  network) and "play it", so StreamingSpeechPlayer can prepare the next
//  sentence while the current one plays.
//

import AppKit
import AVFoundation
import Foundation

enum SpeechOutputMode: String, CaseIterable, Identifiable {
    case system
    /// ElevenLabs with the user's own API key. Raw value kept from earlier
    /// builds so a saved choice still loads.
    case elevenLabs = "elevenLabsOwnKey"
    case openAICompatibleSpeech
    /// A voice model downloaded from Hugging Face, run on this Mac with MLX.
    case onDeviceModel
    case off

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .system: return "On-device (Apple)"
        case .elevenLabs: return "ElevenLabs"
        case .openAICompatibleSpeech: return "OpenAI-compatible"
        case .onDeviceModel: return "On-device model"
        case .off: return "Off"
        }
    }

    /// One line explaining the trade-off, shown under the picker.
    var explanation: String {
        switch self {
        case .system:
            return "Private and free: Apple's voices, spoken on this Mac."
        case .elevenLabs:
            return "Natural voices with your ElevenLabs key."
        case .openAICompatibleSpeech:
            return "OpenAI voices, or a speech server running on this Mac (for example Kokoro)."
        case .onDeviceModel:
            return "A voice model you download (Kokoro, Qwen3-TTS and others) speaks on this Mac. Private, and works offline."
        case .off:
            return "Silent: replies show as captions only."
        }
    }
}

/// Ready-made endpoints for the OpenAI-compatible voice choice.
enum SpeechSynthesisEndpointPreset: String, CaseIterable, Identifiable {
    case openAI
    case localKokoro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .localKokoro: return "Kokoro (on this Mac)"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .localKokoro: return "http://localhost:8880/v1"
        }
    }

    var modelName: String {
        switch self {
        case .openAI: return "gpt-4o-mini-tts"
        case .localKokoro: return "kokoro"
        }
    }

    var voiceName: String {
        switch self {
        case .openAI: return "alloy"
        case .localKokoro: return "af_heart"
        }
    }

    var apiKeyPageURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .localKokoro: return nil
        }
    }
}

/// Settings for the OpenAI-compatible voice; the key lives in the Keychain.
enum OpenAICompatibleSpeechSettings {
    private static let baseURLKey = "openAICompatibleSpeechBaseURL"
    private static let modelKey = "openAICompatibleSpeechModel"
    private static let voiceKey = "openAICompatibleSpeechVoice"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? SpeechSynthesisEndpointPreset.openAI.baseURL }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var modelName: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? SpeechSynthesisEndpointPreset.openAI.modelName }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var voiceName: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? SpeechSynthesisEndpointPreset.openAI.voiceName }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    /// Local speech servers usually need no key; cloud ones always do.
    static var isReady: Bool {
        LocalModelServerPreset.isLocalBaseURL(baseURL)
            || KeychainSecretStore.secret(for: .openAICompatibleSpeech)?.isEmpty == false
    }
}

/// Which Apple voice the on-device option uses. Nil uses the most natural
/// installed voice for the user's language (`SystemVoiceCatalog.mostNaturalInstalledVoice`),
/// else the system's default voice.
enum SystemVoiceSettings {
    private static let voiceIdentifierKey = "systemSpeechVoiceIdentifier"

    static var selectedVoiceIdentifier: String? {
        get { UserDefaults.standard.string(forKey: voiceIdentifierKey) }
        set { UserDefaults.standard.set(newValue, forKey: voiceIdentifierKey) }
    }

    // The installed voices and the chooser live in SystemVoiceChooser.swift.

    /// Opens the system pane where more (and higher-quality) voices download.
    static func openVoiceDownloadSettings() {
        if let spokenContentSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(spokenContentSettingsURL)
        }
    }
}

/// Speech ready to play: synthesized audio, or text for the on-device voice.
enum PreparedSpeech {
    case audioData(Data)
    case onDeviceVoiceText(String)
}

@MainActor
protocol SpeechSynthesisProvider: AnyObject {
    /// Turns one sentence into playable speech. May use the network; throws on
    /// failure so the player can fall back to the on-device voice.
    func prepareSpeech(for sentence: String) async throws -> PreparedSpeech
    /// Plays prepared speech and returns when it finishes or is stopped.
    /// `onPlaybackProgress` reports how far it has got, for live captions.
    func playPreparedSpeech(
        _ preparedSpeech: PreparedSpeech,
        onPlaybackProgress: @escaping @MainActor (SpeechPlaybackProgress) -> Void
    ) async
    func stopPlayback()
    var isPlaying: Bool { get }
}

// MARK: - Network voices

/// Plays audio from a network voice (ElevenLabs or an OpenAI-compatible
/// speech endpoint); `synthesizeSpeechAudio` turns one sentence into audio.
@MainActor
final class NetworkAudioSpeechSynthesisProvider: NSObject, SpeechSynthesisProvider, AVAudioPlayerDelegate {
    private let synthesizeSpeechAudio: (String) async throws -> Data
    private var audioPlayer: AVAudioPlayer?
    private var playbackFinishedContinuation: CheckedContinuation<Void, Never>?
    /// Reports the played fraction about 20 times a second while playing:
    /// audio voices give no word timings, so captions follow the clock.
    private var playbackProgressTask: Task<Void, Never>?

    init(synthesizeSpeechAudio: @escaping (String) async throws -> Data) {
        self.synthesizeSpeechAudio = synthesizeSpeechAudio
    }

    func prepareSpeech(for sentence: String) async throws -> PreparedSpeech {
        .audioData(try await synthesizeSpeechAudio(sentence))
    }

    func playPreparedSpeech(
        _ preparedSpeech: PreparedSpeech,
        onPlaybackProgress: @escaping @MainActor (SpeechPlaybackProgress) -> Void
    ) async {
        guard case let .audioData(audioData) = preparedSpeech,
              let audioPlayer = try? AVAudioPlayer(data: audioData) else { return }
        self.audioPlayer = audioPlayer
        audioPlayer.delegate = self

        await withCheckedContinuation { continuation in
            playbackFinishedContinuation = continuation
            if !audioPlayer.play() {
                resumePlaybackFinishedContinuation()
                return
            }
            onPlaybackProgress(.playedFraction(0))
            playbackProgressTask = Task { @MainActor [weak audioPlayer] in
                while !Task.isCancelled, let audioPlayer, audioPlayer.isPlaying {
                    let audioDuration = audioPlayer.duration
                    if audioDuration > 0 {
                        onPlaybackProgress(.playedFraction(audioPlayer.currentTime / audioDuration))
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
        onPlaybackProgress(.playedFraction(1))
    }

    func stopPlayback() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        resumePlaybackFinishedContinuation()
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    private func resumePlaybackFinishedContinuation() {
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.resumePlaybackFinishedContinuation()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.resumePlaybackFinishedContinuation()
        }
    }
}

// MARK: - On-device voice

/// Apple's built-in speech synthesizer — always available, fully on-device,
/// needs no key. Also the fallback when a network voice fails.
@MainActor
final class SystemSpeechSynthesisProvider: NSObject, SpeechSynthesisProvider, AVSpeechSynthesizerDelegate {
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var utteranceFinishedContinuation: CheckedContinuation<Void, Never>?
    /// Where the words Apple's voice is about to say go, for live captions.
    private var playbackProgressHandler: (@MainActor (SpeechPlaybackProgress) -> Void)?
    /// An elf's own Apple voice; nil speaks with the voice chosen in
    /// Settings › Models.
    private let voiceIdentifierOverride: String?

    init(voiceIdentifierOverride: String? = nil) {
        self.voiceIdentifierOverride = voiceIdentifierOverride
        super.init()
        speechSynthesizer.delegate = self
    }

    /// The voice an Elf was given, else the one picked in Settings, else
    /// the most natural installed voice — a fresh Mac's default voice is
    /// often a robotic one even when a Premium or Enhanced one is installed.
    var voiceIdentifierToSpeakWith: String? {
        voiceIdentifierOverride
            ?? SystemVoiceSettings.selectedVoiceIdentifier
            ?? SystemVoiceCatalog.mostNaturalInstalledVoice()?.id
    }

    func prepareSpeech(for sentence: String) async throws -> PreparedSpeech {
        .onDeviceVoiceText(sentence)
    }

    func playPreparedSpeech(
        _ preparedSpeech: PreparedSpeech,
        onPlaybackProgress: @escaping @MainActor (SpeechPlaybackProgress) -> Void
    ) async {
        guard case let .onDeviceVoiceText(sentence) = preparedSpeech else { return }
        playbackProgressHandler = onPlaybackProgress
        defer {
            playbackProgressHandler = nil
            onPlaybackProgress(.spokenThroughCharacterOffset(sentence.count))
        }
        await withCheckedContinuation { continuation in
            utteranceFinishedContinuation = continuation
            let utterance = AVSpeechUtterance(string: sentence)
            if let selectedVoiceIdentifier = voiceIdentifierToSpeakWith,
               let selectedVoice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
                utterance.voice = selectedVoice
            }
            speechSynthesizer.speak(utterance)
        }
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        resumeUtteranceFinishedContinuation()
    }

    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    private func resumeUtteranceFinishedContinuation() {
        utteranceFinishedContinuation?.resume()
        utteranceFinishedContinuation = nil
    }

    /// Apple's voice says which characters come next: the end of that range,
    /// in characters (it reports UTF-16 offsets).
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let spokenText = utterance.speechString
        let rangeEndInUTF16 = min(characterRange.location + characterRange.length, spokenText.utf16.count)
        let rangeEndIndex = String.Index(utf16Offset: rangeEndInUTF16, in: spokenText)
        let spokenThroughCharacterOffset = spokenText.distance(from: spokenText.startIndex, to: rangeEndIndex)
        Task { @MainActor in
            self.playbackProgressHandler?(.spokenThroughCharacterOffset(spokenThroughCharacterOffset))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.resumeUtteranceFinishedContinuation()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.resumeUtteranceFinishedContinuation()
        }
    }
}

// MARK: - Earcons

/// Short system sounds marking moments the user can't see while looking
/// elsewhere: request accepted, elfhub needs a yes, something went wrong.
enum CompanionEarcon {
    case requestAccepted
    case needsConfirmation
    case failed

    private static let soundCuesEnabledKey = "areSoundCuesEnabled"

    static var areSoundCuesEnabled: Bool {
        UserDefaults.standard.object(forKey: soundCuesEnabledKey) as? Bool ?? true
    }

    static func setSoundCuesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: soundCuesEnabledKey)
    }

    private var systemSoundName: NSSound.Name {
        switch self {
        case .requestAccepted: return "Tink"
        case .needsConfirmation: return "Glass"
        case .failed: return "Basso"
        }
    }

    func play() {
        guard Self.areSoundCuesEnabled, let sound = NSSound(named: systemSoundName) else { return }
        sound.volume = 0.35
        sound.play()
    }
}

// MARK: - An elf's own voice

/// Which voice an elf speaks with: its own (from the voice services set up
/// on this Mac) when it has one, otherwise the voice in Settings › Models.
/// The main elf always uses Settings › Models.
enum ElfSpeechChoice: Equatable {
    case sameAsMain
    case off
    case system(voiceIdentifier: String?)
    case elevenLabs(voiceIdentifier: String?)
    case openAICompatible(voiceName: String?)
    /// The downloaded voice model chosen in Settings › Models, with this voice.
    case onDeviceModel(voiceIdentifier: String?)

    /// `isSystemVoiceInstalled` tells whether an Apple voice is still on this
    /// Mac; one that was removed falls back to the main elf's voice rather
    /// than the system default.
    static func choice(
        for localSettings: ElfLocalSettings,
        isMainElf: Bool,
        isSystemVoiceInstalled: (String) -> Bool = { AVSpeechSynthesisVoice(identifier: $0) != nil }
    ) -> ElfSpeechChoice {
        guard !isMainElf,
              let voice = localSettings.voice,
              let speechOutputMode = SpeechOutputMode(rawValue: voice.speechOutputModeRawValue) else { return .sameAsMain }
        let trimmedVoiceIdentifier = voice.voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceIdentifier = trimmedVoiceIdentifier?.isEmpty == false ? trimmedVoiceIdentifier : nil
        switch speechOutputMode {
        case .off: return .off
        case .system:
            if let voiceIdentifier, !isSystemVoiceInstalled(voiceIdentifier) { return .sameAsMain }
            return .system(voiceIdentifier: voiceIdentifier)
        case .elevenLabs: return .elevenLabs(voiceIdentifier: voiceIdentifier)
        case .openAICompatibleSpeech: return .openAICompatible(voiceName: voiceIdentifier)
        case .onDeviceModel: return .onDeviceModel(voiceIdentifier: voiceIdentifier)
        }
    }
}
