//
//  ElevenLabsVoiceTests.swift
//  elfhubTests
//
//  ElevenLabs voices without pasting IDs: the presets shipped in the app,
//  the voices listed from the user's account, the main Elf's automatic
//  voice (0.0.1's saved default counts as automatic), and a different,
//  lasting voice for each side Elf.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElevenLabsVoiceTests {

    // MARK: - Presets file

    @Test func thePresetsFileShipsInTheAppAndHangsTogether() throws {
        let presetsFileURL = try #require(Bundle.main.url(forResource: ElevenLabsVoicePresetCatalog.bundledResourceName, withExtension: "json"))
        let catalog = try ElevenLabsVoicePresetCatalog.decoded(from: Data(contentsOf: presetsFileURL))
        #expect(catalog == ElevenLabsVoicePresetCatalog.bundled, "the app reads the file, not the fallback")
        #expect(catalog.voices.count >= 10)

        let presetIdentifiers = catalog.voices.map(\.voiceIdentifier)
        #expect(Set(presetIdentifiers).count == presetIdentifiers.count, "no voice twice")
        #expect(presetIdentifiers.contains(catalog.mainElfVoice))
        #expect(!catalog.sideElfVoices.isEmpty)
        #expect(catalog.sideElfVoices.allSatisfy(presetIdentifiers.contains))
        #expect(!catalog.sideElfVoices.contains(catalog.mainElfVoice), "side Elfs never sound like main")
        for preset in catalog.voices {
            #expect(preset.voiceIdentifier.count == 20 && preset.voiceIdentifier.allSatisfy { $0.isLetter || $0.isNumber },
                    "\(preset.name) has an ElevenLabs-shaped voice ID")
            #expect(!preset.name.isEmpty && !preset.description.isEmpty)
        }
        // Presets are the permanent voices, never the retiring ones.
        let retiringIdentifiers = Set(catalog.voices.compactMap(\.replacesDefaultVoiceIdentifier))
        #expect(retiringIdentifiers.isDisjoint(with: presetIdentifiers))
        #expect(!retiringIdentifiers.contains(catalog.mainElfVoice))
    }

    @Test func aRetiringDefaultVoicePointsToItsReplacementAndKeepsItsName() {
        let catalog = ElevenLabsVoicePresetCatalog.bundled
        // Sarah → Talia, per ElevenLabs' replacement table.
        #expect(catalog.replacement(forRetiringVoiceIdentifier: "EXAVITQu4vr4xnSDxMaL")?.name == "Talia")
        #expect(catalog.replacement(forRetiringVoiceIdentifier: catalog.mainElfVoice) == nil)
        #expect(ElevenLabsVoiceDirectory.shared.displayName(forVoiceIdentifier: "EXAVITQu4vr4xnSDxMaL") == "Sarah")
        #expect(ElevenLabsVoiceDirectory.shared.displayName(forVoiceIdentifier: catalog.mainElfVoice) == "Eddie")
        #expect(ElevenLabsVoiceDirectory.shared.displayName(forVoiceIdentifier: "someUnknownVoiceId00") == nil)
    }

    @Test func theTestHostNeverCallsElevenLabs() {
        // Keys are in the Keychain every build shares.
        ElevenLabsVoiceDirectory.shared.loadAccountVoicesIfNeeded(force: true)
        #expect(ElevenLabsVoiceDirectory.shared.loadState == .notLoaded)
    }

    // MARK: - Main Elf

    @Test func theOldSavedDefaultAndEmptyMeanAutomatic() {
        #expect(ElevenLabsVoiceAssignment.chosenMainVoiceIdentifier(fromSavedValue: nil) == nil)
        #expect(ElevenLabsVoiceAssignment.chosenMainVoiceIdentifier(fromSavedValue: "  ") == nil)
        #expect(ElevenLabsVoiceAssignment.chosenMainVoiceIdentifier(fromSavedValue: "21m00Tcm4TlvDq8ikWAM") == nil,
                "0.0.1 saved Rachel whenever the field was left empty")
        #expect(ElevenLabsVoiceAssignment.chosenMainVoiceIdentifier(fromSavedValue: " myCloneVoice123 ") == "myCloneVoice123")
    }

    // MARK: - Side Elfs

    @Test func eachSideElfGetsTheFirstVoiceNobodyElseHas() {
        let catalog = ElevenLabsVoicePresetCatalog(
            mainElfVoice: "main",
            sideElfVoices: ["main", "a", "b", "c"],
            voices: []
        )
        #expect(ElevenLabsVoiceAssignment.sideElfVoiceIdentifier(catalog: catalog, mainElfVoiceIdentifier: "main", voicesTakenByOtherSideElfs: []) == "a",
                "never the main Elf's voice")
        #expect(ElevenLabsVoiceAssignment.sideElfVoiceIdentifier(catalog: catalog, mainElfVoiceIdentifier: "main", voicesTakenByOtherSideElfs: ["a"]) == "b")
        #expect(ElevenLabsVoiceAssignment.sideElfVoiceIdentifier(catalog: catalog, mainElfVoiceIdentifier: "a", voicesTakenByOtherSideElfs: []) == "main",
                "a user-picked main voice is skipped instead")
        // Every voice taken: shared round-robin.
        #expect(ElevenLabsVoiceAssignment.sideElfVoiceIdentifier(catalog: catalog, mainElfVoiceIdentifier: "main", voicesTakenByOtherSideElfs: ["a", "b", "c"]) == "a")
        #expect(ElevenLabsVoiceAssignment.sideElfVoiceIdentifier(catalog: catalog, mainElfVoiceIdentifier: "main", voicesTakenByOtherSideElfs: ["a", "b", "c", "a"]) == "b")
        let emptyCatalog = ElevenLabsVoicePresetCatalog(mainElfVoice: "main", sideElfVoices: [], voices: [])
        #expect(ElevenLabsVoiceAssignment.sideElfVoiceIdentifier(catalog: emptyCatalog, mainElfVoiceIdentifier: "main", voicesTakenByOtherSideElfs: []) == nil)
    }

    @Test func sideElfsKeepDifferentVoices() throws {
        let companionManager = CompanionManager.shared
        let elfManager = companionManager.elfManager
        let firstSideElf = try elfManager.createElf(identity: .init(name: "Voicetest Ash"))
        let secondSideElf = try elfManager.createElf(identity: .init(name: "Voicetest Birch"))
        defer {
            try? FileManager.default.removeItem(at: firstSideElf.home.directory)
            try? FileManager.default.removeItem(at: secondSideElf.home.directory)
            elfManager.reloadRoster()
        }
        let firstVoice = companionManager.automaticElevenLabsVoiceIdentifier(for: firstSideElf)
        let secondVoice = companionManager.automaticElevenLabsVoiceIdentifier(for: secondSideElf)
        #expect(firstVoice != secondVoice)
        #expect(firstVoice != companionManager.elevenLabsVoiceIdentifier)
        #expect(secondVoice != companionManager.elevenLabsVoiceIdentifier)
        // Kept in its per-Mac settings, so it doesn't change next time.
        #expect(firstSideElf.home.readLocalSettings().automaticElevenLabsVoiceIdentifier == firstVoice)
        #expect(companionManager.automaticElevenLabsVoiceIdentifier(for: firstSideElf) == firstVoice)
        #expect(companionManager.automaticElevenLabsVoiceIdentifier(for: elfManager.mainElf) == companionManager.elevenLabsVoiceIdentifier)
    }

    @Test func olderLocalSettingsWithoutAnAutomaticVoiceStillLoad() throws {
        let olderSettings = try JSONDecoder().decode(ElfLocalSettings.self, from: Data(#"{"voice":{"speechOutputModeRawValue":"system"}}"#.utf8))
        #expect(olderSettings.automaticElevenLabsVoiceIdentifier == nil)
        #expect(olderSettings.voice?.speechOutputModeRawValue == "system")
        let roundTripped = try JSONDecoder().decode(
            ElfLocalSettings.self,
            from: JSONEncoder().encode(ElfLocalSettings(automaticElevenLabsVoiceIdentifier: "OZ0L6eISlOejga3XjDFt"))
        )
        #expect(roundTripped.automaticElevenLabsVoiceIdentifier == "OZ0L6eISlOejga3XjDFt")
    }

    // MARK: - The user's own voices

    @Test func theVoiceListRequestCarriesTheKey() {
        let request = ElevenLabsAccountVoice.voiceListRequest(apiKey: "secret")
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/voices")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "secret")
    }

    @Test func theVoiceListIsReadWithNamesKindsAndLabels() throws {
        let responseData = Data("""
        {"voices": [
          {"voice_id": "abcdefghij0123456789", "name": "My Narrator", "category": "cloned",
           "labels": {"gender": "female", "accent": "british", "use_case": "narrative_story"}},
          {"voice_id": "zyxwvutsrq9876543210", "name": "Designed Bot", "category": "generated", "labels": {}},
          {"voice_id": "", "name": "No id"},
          {"name": "Missing id"}
        ]}
        """.utf8)
        let accountVoices = try ElevenLabsAccountVoice.voices(fromVoiceListResponse: responseData)
        #expect(accountVoices.map(\.name) == ["My Narrator", "Designed Bot"])
        #expect(accountVoices[0].labelSummary == "female · british · narrative story")
        #expect(accountVoices[0].categoryDisplayName == "Your clone")
        #expect(accountVoices[1].categoryDisplayName == "Designed")
        #expect(throws: ElevenLabsVoiceListError.unreadableResponse) {
            try ElevenLabsAccountVoice.voices(fromVoiceListResponse: Data("[]".utf8))
        }
    }
}
