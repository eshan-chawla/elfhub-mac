//
//  ElfVoiceTests.swift
//  elfhubTests
//
//  Each elf can speak with its own voice from the voice services already
//  set up on this Mac; without one (and always for the main elf) it speaks
//  with the voice in Settings › Models.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfVoiceTests {

    @Test func anElfWithoutAVoiceSpeaksWithMains() {
        #expect(ElfSpeechChoice.choice(for: ElfLocalSettings(), isMainElf: false) == .sameAsMain)
        let systemVoice = ElfVoiceSelection(speechOutputModeRawValue: SpeechOutputMode.system.rawValue, voiceIdentifier: "com.apple.voice.Ava")
        #expect(ElfSpeechChoice.choice(for: ElfLocalSettings(voice: systemVoice), isMainElf: true) == .sameAsMain)
        let unknownVoice = ElfVoiceSelection(speechOutputModeRawValue: "somethingNew", voiceIdentifier: nil)
        #expect(ElfSpeechChoice.choice(for: ElfLocalSettings(voice: unknownVoice), isMainElf: false) == .sameAsMain)
    }

    @Test func aSideElfsOwnVoiceIsUsed() {
        let systemVoice = ElfVoiceSelection(speechOutputModeRawValue: SpeechOutputMode.system.rawValue, voiceIdentifier: "com.apple.voice.Ava")
        #expect(ElfSpeechChoice.choice(for: ElfLocalSettings(voice: systemVoice), isMainElf: false) == .system(voiceIdentifier: "com.apple.voice.Ava"))
        let elevenLabsVoice = ElfVoiceSelection(speechOutputModeRawValue: SpeechOutputMode.elevenLabs.rawValue, voiceIdentifier: "voice-42")
        #expect(ElfSpeechChoice.choice(for: ElfLocalSettings(voice: elevenLabsVoice), isMainElf: false) == .elevenLabs(voiceIdentifier: "voice-42"))
        let silentVoice = ElfVoiceSelection(speechOutputModeRawValue: SpeechOutputMode.off.rawValue, voiceIdentifier: nil)
        #expect(ElfSpeechChoice.choice(for: ElfLocalSettings(voice: silentVoice), isMainElf: false) == .off)
    }

    @Test func aSystemVoiceOverrideIsUsed() {
        #expect(SystemSpeechSynthesisProvider(voiceIdentifierOverride: "com.apple.voice.Ava").voiceIdentifierToSpeakWith == "com.apple.voice.Ava")
        #expect(SystemSpeechSynthesisProvider().voiceIdentifierToSpeakWith == SystemVoiceSettings.selectedVoiceIdentifier)
    }

    @Test func localSettingsAreSavedPerElf() throws {
        let elvesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elves-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elvesDirectory) }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        try elfManager.createElf(identity: .init(name: "Ada"))
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        let configurationIdentifier = UUID()
        try adaEditor.updateLocalSettings { localSettings in localSettings.languageModelConfigurationIdentifier = configurationIdentifier }
        #expect(adaEditor.localSettings.languageModelConfigurationIdentifier == configurationIdentifier)
        #expect(elfManager.elf(withIdentifier: "ada")?.home.readLocalSettings().languageModelConfigurationIdentifier == configurationIdentifier)
        #expect(elfManager.mainElf.home.readLocalSettings().languageModelConfigurationIdentifier == nil)
    }
}
