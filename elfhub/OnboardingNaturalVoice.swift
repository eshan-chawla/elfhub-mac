//
//  OnboardingNaturalVoice.swift
//  elfhub
//
//  The natural voice onboarding offers: Kokoro 82M, run on this Mac with
//  MLX. Apple's built-in voices are what a fresh Mac has, and most of them
//  sound robotic, so onboarding offers this one with its box ticked. It is
//  downloaded from Hugging Face (anonymously) only when the user moves on
//  with the box ticked, continues in the background, and becomes the voice
//  once it's ready — unless the user picked another voice meanwhile. Until
//  then Apple's voice speaks.
//
//  Kokoro is offered on every Mac, not the bigger Qwen3-TTS models some
//  Macs could run: 0.4 GB is a fair first download, and it starts talking
//  almost instantly. The bigger voices stay in Settings › Models.
//

import Foundation

enum OnboardingNaturalVoice {
    /// The Hugging Face repo of the voice model onboarding offers.
    static let modelIdentifier = "mlx-community/Kokoro-82M-bf16"

    static var recommendedModel: RecommendedOnDeviceVoiceModel? {
        OnDeviceVoiceModelCatalog.recommendedModel(withIdentifier: modelIdentifier)
    }

    /// Kokoro's clearest voices, the short list onboarding shows. The first
    /// is the one picked when the user doesn't choose.
    static let featuredVoices: [OnDeviceModelVoice] = OnDeviceVoiceModelCatalog
        .featuredVoiceIdentifiers(forModelIdentifier: modelIdentifier)
        .map { voiceIdentifier in
        OnDeviceModelVoice(id: voiceIdentifier, displayName: OnDeviceVoiceModelCatalog.displayName(forVoiceIdentifier: voiceIdentifier))
    }

    static var defaultVoiceIdentifier: String { featuredVoices[0].id }

    /// Whether onboarding should offer the download: only while replies
    /// still use the voice a fresh install starts with (Apple's), and the
    /// natural voice isn't already the one in use.
    static func shouldOfferDownload(
        currentSpeechOutputMode: SpeechOutputMode,
        activeTextToSpeechModelIdentifier: String?,
        installedModelIdentifiers: Set<String>
    ) -> Bool {
        if currentSpeechOutputMode == .onDeviceModel,
           let activeTextToSpeechModelIdentifier,
           installedModelIdentifiers.contains(activeTextToSpeechModelIdentifier) {
            return false
        }
        return currentSpeechOutputMode == .system
    }

    /// Whether a finished download should become the voice: only if the
    /// user hasn't changed the voice since the download started.
    static func shouldSwitchToDownloadedVoice(
        currentSpeechOutputMode: SpeechOutputMode,
        speechOutputModeWhenDownloadStarted: SpeechOutputMode
    ) -> Bool {
        currentSpeechOutputMode == speechOutputModeWhenDownloadStarted
            && currentSpeechOutputMode != .off
    }
}
