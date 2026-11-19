//
//  ElevenLabsVoices.swift
//  elfhub
//
//  Choosing ElevenLabs voices without pasting IDs:
//   - ElevenLabsVoicePresetCatalog: the Recommended voices, read from
//     ElevenLabsVoicePresets.json in the app (edit that file to change the
//     defaults) — ElevenLabs' permanent replacements for its retiring
//     Default voices.
//   - ElevenLabsAccountVoice / ElevenLabsVoiceDirectory: the voices on the
//     user's own ElevenLabs account (their clones, designs and saved library
//     voices), listed with their key when they open the voice picker.
//   - ElevenLabsVoiceAssignment: the main Elf's automatic voice, and a
//     different voice for each side Elf, so Elfs sound like themselves.
//   - ElevenLabsVoicePicker: the menu that replaces the voice ID field;
//     pasting an ID is still there for any other voice.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Presets

nonisolated struct ElevenLabsVoicePreset: Codable, Equatable, Sendable, Identifiable {
    let voiceIdentifier: String
    let name: String
    /// ElevenLabs' own short description ("Natural and helpful").
    let description: String
    /// The retiring Default voice this one replaces, if any.
    var replacesDefaultVoiceName: String?
    var replacesDefaultVoiceIdentifier: String?

    var id: String { voiceIdentifier }
}

nonisolated struct ElevenLabsVoicePresetCatalog: Codable, Equatable, Sendable {
    /// The main Elf's voice when the user picks none.
    let mainElfVoice: String
    /// The order side Elfs are given their own voices in.
    let sideElfVoices: [String]
    /// Everything offered as Recommended, in the order shown.
    let voices: [ElevenLabsVoicePreset]

    static let bundledResourceName = "ElevenLabsVoicePresets"

    /// The presets shipped in the app; the built-in one if the file is
    /// missing or broken, so ElevenLabs always has a voice.
    static let bundled: ElevenLabsVoicePresetCatalog = {
        guard let presetsFileURL = Bundle.main.url(forResource: bundledResourceName, withExtension: "json"),
              let presetsFileData = try? Data(contentsOf: presetsFileURL),
              let decodedCatalog = try? decoded(from: presetsFileData) else {
            return builtInFallback
        }
        return decodedCatalog
    }()

    /// Eddie, "Natural and helpful": the bundled file's main voice.
    static let builtInFallback = ElevenLabsVoicePresetCatalog(
        mainElfVoice: "l7kNoIfnJKPg7779LI2t",
        sideElfVoices: [],
        voices: [ElevenLabsVoicePreset(voiceIdentifier: "l7kNoIfnJKPg7779LI2t", name: "Eddie", description: "Natural and helpful")]
    )

    static func decoded(from presetsFileData: Data) throws -> ElevenLabsVoicePresetCatalog {
        try JSONDecoder().decode(ElevenLabsVoicePresetCatalog.self, from: presetsFileData)
    }

    func preset(withIdentifier voiceIdentifier: String) -> ElevenLabsVoicePreset? {
        voices.first { $0.voiceIdentifier == voiceIdentifier }
    }

    /// For a retiring Default voice, the preset that replaces it.
    func replacement(forRetiringVoiceIdentifier voiceIdentifier: String) -> ElevenLabsVoicePreset? {
        voices.first { $0.replacesDefaultVoiceIdentifier == voiceIdentifier }
    }
}

// MARK: - Voices on the user's account

nonisolated struct ElevenLabsAccountVoice: Equatable, Sendable, Identifiable {
    let voiceIdentifier: String
    let name: String
    /// ElevenLabs' category: premade, cloned, generated, professional, …
    let category: String
    /// Its labels in a few words ("female · american · conversational").
    let labelSummary: String

    var id: String { voiceIdentifier }

    /// What kind of voice it is, in the user's words.
    var categoryDisplayName: String {
        switch category {
        case "premade": return "Default"
        case "cloned": return "Your clone"
        case "generated": return "Designed"
        case "professional": return "Professional"
        default: return "Saved"
        }
    }

    /// Reads `GET /v1/voices`. Voices without an id or name are skipped.
    static func voices(fromVoiceListResponse responseData: Data) throws -> [ElevenLabsAccountVoice] {
        guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let voiceObjects = responseObject["voices"] as? [[String: Any]] else {
            throw ElevenLabsVoiceListError.unreadableResponse
        }
        return voiceObjects.compactMap { voiceObject in
            guard let voiceIdentifier = voiceObject["voice_id"] as? String, !voiceIdentifier.isEmpty,
                  let name = voiceObject["name"] as? String, !name.isEmpty else { return nil }
            let labels = voiceObject["labels"] as? [String: Any] ?? [:]
            let labelSummary = ["gender", "accent", "use_case", "descriptive"]
                .compactMap { labels[$0] as? String }
                .map { $0.replacingOccurrences(of: "_", with: " ") }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return ElevenLabsAccountVoice(
                voiceIdentifier: voiceIdentifier,
                name: name,
                category: voiceObject["category"] as? String ?? "",
                labelSummary: labelSummary
            )
        }
    }

    /// The list request, with the user's key (pure; tested).
    static func voiceListRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }
}

nonisolated enum ElevenLabsVoiceListError: LocalizedError, Equatable {
    case unreadableResponse
    case keyCannotListVoices
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableResponse:
            return "ElevenLabs answered with something unexpected. Pick a recommended voice or paste a voice ID."
        case .keyCannotListVoices:
            return "This key can't list your voices (it needs the Voices permission). Pick a recommended voice or paste a voice ID."
        case let .requestFailed(statusCode):
            return "Couldn't load your voices (ElevenLabs said \(statusCode)). Pick a recommended voice or paste a voice ID."
        }
    }
}

/// The voices on the user's ElevenLabs account, loaded with their key when
/// a voice picker appears — never in the background.
@MainActor
final class ElevenLabsVoiceDirectory: ObservableObject {
    static let shared = ElevenLabsVoiceDirectory()

    enum LoadState: Equatable {
        case notLoaded
        case loading
        case loaded
        case failed(message: String)
    }

    @Published private(set) var accountVoices: [ElevenLabsAccountVoice] = []
    @Published private(set) var loadState: LoadState = .notLoaded

    /// Loads once per launch unless `force` (the Refresh button).
    func loadAccountVoicesIfNeeded(force: Bool = false) {
        // Keys live in the Keychain every build shares, so the unit-test
        // host would otherwise call ElevenLabs with the user's real key.
        guard !CompanionManager.isRunningUnitTests else { return }
        guard force || loadState == .notLoaded else { return }
        guard let apiKey = KeychainSecretStore.secret(for: .elevenLabs), !apiKey.isEmpty else {
            accountVoices = []
            loadState = .notLoaded
            return
        }
        loadState = .loading
        Task {
            do {
                let (responseData, response) = try await URLSession.shared.data(for: ElevenLabsAccountVoice.voiceListRequest(apiKey: apiKey))
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 401 || statusCode == 403 {
                    throw ElevenLabsVoiceListError.keyCannotListVoices
                }
                guard (200..<300).contains(statusCode) else {
                    throw ElevenLabsVoiceListError.requestFailed(statusCode: statusCode)
                }
                accountVoices = try ElevenLabsAccountVoice.voices(fromVoiceListResponse: responseData)
                loadState = .loaded
            } catch {
                loadState = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Forgets the list, e.g. after the key changed.
    func forgetAccountVoices() {
        accountVoices = []
        loadState = .notLoaded
    }

    /// A voice's name for showing which one is chosen: a preset's, then one
    /// on the account; nil for an ID elfhub doesn't know.
    func displayName(forVoiceIdentifier voiceIdentifier: String, catalog: ElevenLabsVoicePresetCatalog = .bundled) -> String? {
        if let preset = catalog.preset(withIdentifier: voiceIdentifier) {
            return preset.name
        }
        if let accountVoiceName = accountVoices.first(where: { $0.voiceIdentifier == voiceIdentifier })?.name {
            return accountVoiceName
        }
        // A retiring Default voice someone picked before (Sarah, Brian, …).
        return catalog.replacement(forRetiringVoiceIdentifier: voiceIdentifier)?.replacesDefaultVoiceName
    }
}

// MARK: - Which Elf gets which voice

nonisolated enum ElevenLabsVoiceAssignment {
    /// elfhub 0.0.1 saved this (ElevenLabs' retired "Rachel") whenever the
    /// voice field was left empty, so it means "automatic", not a choice.
    static let legacyDefaultVoiceIdentifier = "21m00Tcm4TlvDq8ikWAM"

    /// The saved main voice setting as a choice: nil means automatic.
    static func chosenMainVoiceIdentifier(fromSavedValue savedValue: String?) -> String? {
        guard let trimmedSavedValue = savedValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedSavedValue.isEmpty,
              trimmedSavedValue != legacyDefaultVoiceIdentifier else { return nil }
        return trimmedSavedValue
    }

    /// A side Elf's own voice: the first in the rotation that isn't the
    /// main Elf's and that no other side Elf has; once every one is taken,
    /// they're shared round-robin. Nil when the presets list none.
    static func sideElfVoiceIdentifier(
        catalog: ElevenLabsVoicePresetCatalog,
        mainElfVoiceIdentifier: String,
        voicesTakenByOtherSideElfs: [String]
    ) -> String? {
        let candidateVoiceIdentifiers = catalog.sideElfVoices.filter { $0 != mainElfVoiceIdentifier }
        guard !candidateVoiceIdentifiers.isEmpty else { return nil }
        if let freeVoiceIdentifier = candidateVoiceIdentifiers.first(where: { !voicesTakenByOtherSideElfs.contains($0) }) {
            return freeVoiceIdentifier
        }
        return candidateVoiceIdentifiers[voicesTakenByOtherSideElfs.count % candidateVoiceIdentifiers.count]
    }
}

// MARK: - Picker

/// The ElevenLabs voice menu: Automatic, the recommended voices, the voices
/// on the user's account, or a pasted voice ID.
struct ElevenLabsVoicePicker: View {
    @ObservedObject var voiceDirectory: ElevenLabsVoiceDirectory
    var catalog: ElevenLabsVoicePresetCatalog = .bundled
    /// nil = automatic.
    let selectedVoiceIdentifier: String?
    /// What "Automatic" means right now.
    let automaticVoiceIdentifier: String
    /// Why it's automatic, in a few words ("picked for each Elf").
    var automaticExplanation: String = "elfhub's pick"
    let onSelect: (String?) -> Void
    /// Plays a short sample of a voice (uses a few ElevenLabs characters).
    var onPreview: ((String) -> Void)?

    @State private var isPastingVoiceIdentifier = false
    @State private var pastedVoiceIdentifierInput = ""

    private var effectiveVoiceIdentifier: String { selectedVoiceIdentifier ?? automaticVoiceIdentifier }

    private var accountVoicesNotInPresets: [ElevenLabsAccountVoice] {
        voiceDirectory.accountVoices.filter { catalog.preset(withIdentifier: $0.voiceIdentifier) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Button("Automatic — \(voiceName(for: automaticVoiceIdentifier))") { onSelect(nil) }
                    Section("Recommended") {
                        ForEach(catalog.voices) { preset in
                            Button("\(preset.name) — \(preset.description)") { onSelect(preset.voiceIdentifier) }
                        }
                    }
                    if !accountVoicesNotInPresets.isEmpty {
                        Section("Your ElevenLabs voices") {
                            ForEach(accountVoicesNotInPresets) { accountVoice in
                                Button(accountVoice.labelSummary.isEmpty
                                       ? "\(accountVoice.name) (\(accountVoice.categoryDisplayName))"
                                       : "\(accountVoice.name) — \(accountVoice.labelSummary) (\(accountVoice.categoryDisplayName))") {
                                    onSelect(accountVoice.voiceIdentifier)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Paste a voice ID…") {
                        pastedVoiceIdentifierInput = ""
                        isPastingVoiceIdentifier = true
                    }
                } label: {
                    Text(selectedVoiceTitle)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()

                Spacer(minLength: 0)

                if let onPreview {
                    Button {
                        onPreview(effectiveVoiceIdentifier)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .help("Hear this voice (uses a few ElevenLabs characters)")
                    .pointerCursor()
                }
                Button {
                    voiceDirectory.loadAccountVoicesIfNeeded(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Load the voices on your ElevenLabs account again")
                .disabled(voiceDirectory.loadState == .loading)
                .pointerCursor()
            }

            if isPastingVoiceIdentifier {
                HStack(spacing: 6) {
                    TextField("Voice ID from ElevenLabs › My Voices › Copy voice ID", text: $pastedVoiceIdentifierInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(usePastedVoiceIdentifier)
                    Button("Use", action: usePastedVoiceIdentifier)
                        .disabled(pastedVoiceIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor()
                    Button("Cancel") { isPastingVoiceIdentifier = false }
                        .pointerCursor()
                }
            }

            if let statusLine {
                Text(statusLine)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let replacement = catalog.replacement(forRetiringVoiceIdentifier: effectiveVoiceIdentifier) {
                HStack(spacing: 6) {
                    Text("\(replacement.replacesDefaultVoiceName ?? "This voice") is one of ElevenLabs' Default voices, which stop working on 31 December 2026.")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Switch to \(replacement.name)") { onSelect(replacement.voiceIdentifier) }
                        .pointerCursor()
                }
            }
        }
        .task {
            voiceDirectory.loadAccountVoicesIfNeeded()
        }
    }

    private func usePastedVoiceIdentifier() {
        let trimmedVoiceIdentifier = pastedVoiceIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceIdentifier.isEmpty else { return }
        onSelect(trimmedVoiceIdentifier)
        isPastingVoiceIdentifier = false
    }

    private func voiceName(for voiceIdentifier: String) -> String {
        voiceDirectory.displayName(forVoiceIdentifier: voiceIdentifier, catalog: catalog)
            ?? "voice \(voiceIdentifier.prefix(8))…"
    }

    private var selectedVoiceTitle: String {
        guard let selectedVoiceIdentifier else {
            return "Automatic (\(voiceName(for: automaticVoiceIdentifier)))"
        }
        if let preset = catalog.preset(withIdentifier: selectedVoiceIdentifier) {
            return "\(preset.name) — \(preset.description)"
        }
        return voiceName(for: selectedVoiceIdentifier)
    }

    private var statusLine: String? {
        switch voiceDirectory.loadState {
        case .loading:
            return "Loading the voices on your ElevenLabs account…"
        case let .failed(message):
            return message
        case .loaded:
            let ownVoiceCount = accountVoicesNotInPresets.count
            if selectedVoiceIdentifier == nil {
                return "Automatic: \(automaticExplanation)." + (ownVoiceCount > 0 ? " \(ownVoiceCount) of your own voices are in the menu too." : "")
            }
            return ownVoiceCount > 0 ? "\(ownVoiceCount) of your own voices are in the menu too." : nil
        case .notLoaded:
            return selectedVoiceIdentifier == nil ? "Automatic: \(automaticExplanation)." : nil
        }
    }
}
