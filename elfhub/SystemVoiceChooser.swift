//
//  SystemVoiceChooser.swift
//  elfhub
//
//  Choosing the Apple voice the on-device text-to-speech option uses.
//
//  A Mac has dozens of installed voices per language — most are old standard
//  voices or novelty ones (Bells, Zarvox…), many names exist once per region
//  (Shelley for US and UK English), and the good Premium / Enhanced / Siri
//  voices people download in System Settings › Accessibility › Spoken Content
//  get lost in a flat menu. `SystemVoiceCatalog` turns the installed voices
//  into sections (most natural first, novelty hidden unless asked for, one
//  entry per name and region), and `SystemVoiceChooserSheet` shows them with a
//  region, a quality badge and a preview button per voice. The list refreshes
//  when voices finish downloading.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Voice options (pure)

/// One installed Apple voice, as the chooser shows it.
struct SystemVoiceOption: Identifiable, Equatable {
    enum QualityTier: Int, Comparable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        static func < (lhs: QualityTier, rhs: QualityTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Badge text; standard voices get no badge.
        var badgeLabel: String? {
            switch self {
            case .premium: return "Premium"
            case .enhanced: return "Enhanced"
            case .standard: return nil
            }
        }
    }

    /// `AVSpeechSynthesisVoice.identifier`.
    let id: String
    let displayName: String
    /// BCP 47 code like "en-IN".
    let languageCode: String
    let qualityTier: QualityTier
    let isNoveltyVoice: Bool

    init(identifier: String, voiceName: String, languageCode: String, qualityTier: QualityTier, isNoveltyVoice: Bool) {
        self.id = identifier
        self.displayName = Self.displayName(forVoiceName: voiceName, identifier: identifier)
        self.languageCode = languageCode
        self.qualityTier = qualityTier
        self.isNoveltyVoice = isNoveltyVoice
    }

    init(voice: AVSpeechSynthesisVoice) {
        let qualityTier: QualityTier
        switch voice.quality {
        case .premium: qualityTier = .premium
        case .enhanced: qualityTier = .enhanced
        default: qualityTier = .standard
        }
        self.init(
            identifier: voice.identifier,
            voiceName: voice.name,
            languageCode: voice.language,
            qualityTier: qualityTier,
            isNoveltyVoice: voice.voiceTraits.contains(.isNoveltyVoice)
        )
    }

    /// "English (India)" — tells apart voices that share a name across regions.
    var regionDisplayName: String {
        Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
    }

    /// Voice names already carry their quality ("Aaron (Enhanced)"), which the
    /// badge shows instead; Siri voices are only called "Voice 2".
    static func displayName(forVoiceName voiceName: String, identifier: String) -> String {
        var cleanedName = voiceName
        for qualitySuffix in [" (Enhanced)", " (Premium)"] where cleanedName.hasSuffix(qualitySuffix) {
            cleanedName = String(cleanedName.dropLast(qualitySuffix.count))
        }
        if identifier.lowercased().contains("siri"), cleanedName.hasPrefix("Voice ") {
            cleanedName = "Siri \(cleanedName)"
        }
        return cleanedName
    }

    /// Several installs of the same voice (compact and super-compact Samantha)
    /// sound alike; prefer the fuller one.
    fileprivate var isSuperCompactInstall: Bool {
        id.contains("super-compact")
    }
}

/// Turns the installed voices into the chooser's sections.
enum SystemVoiceCatalog {
    struct Section: Identifiable, Equatable {
        let title: String
        let voiceOptions: [SystemVoiceOption]
        var id: String { title }
    }

    static let mostNaturalSectionTitle = "Most natural"
    static let standardSectionTitle = "Standard"
    static let noveltySectionTitle = "Novelty"

    static func installedVoiceOptions() -> [SystemVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map(SystemVoiceOption.init(voice:))
    }

    /// The language voices are offered for: the user's own ("en" for any English).
    static func currentLanguagePrefix() -> String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    static func voiceOption(withIdentifier voiceIdentifier: String) -> SystemVoiceOption? {
        AVSpeechSynthesisVoice(identifier: voiceIdentifier).map(SystemVoiceOption.init(voice:))
    }

    /// The voice the on-device option uses when none is picked, by name.
    static func systemDefaultVoiceName() -> String? {
        guard let systemDefaultVoice = AVSpeechSynthesisVoice(language: nil) else { return nil }
        return SystemVoiceOption.displayName(forVoiceName: systemDefaultVoice.name, identifier: systemDefaultVoice.identifier)
    }

    /// Voices for the user's language, one entry per name and region (the
    /// best-quality install wins), grouped most natural → standard → novelty.
    /// Novelty voices are left out unless asked for. The selected voice is
    /// always listed, whatever the filters, so the current choice is visible.
    static func sections(
        from voiceOptions: [SystemVoiceOption],
        languagePrefix: String,
        includesNoveltyVoices: Bool,
        searchText: String,
        selectedVoiceIdentifier: String?
    ) -> [Section] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        func matchesSearch(_ voiceOption: SystemVoiceOption) -> Bool {
            guard !trimmedSearchText.isEmpty else { return true }
            return voiceOption.displayName.localizedCaseInsensitiveContains(trimmedSearchText)
                || voiceOption.regionDisplayName.localizedCaseInsensitiveContains(trimmedSearchText)
        }

        let voicesForLanguage = voiceOptions.filter { voiceOption in
            voiceOption.languageCode.hasPrefix(languagePrefix) && (includesNoveltyVoices || !voiceOption.isNoveltyVoice)
        }

        // One entry per name and region, keeping the best install of it.
        var bestVoiceByNameAndRegion: [String: SystemVoiceOption] = [:]
        for voiceOption in voicesForLanguage {
            let nameAndRegionKey = "\(voiceOption.displayName.lowercased())|\(voiceOption.languageCode)"
            if let currentBestVoice = bestVoiceByNameAndRegion[nameAndRegionKey],
               !isBetterInstall(voiceOption, than: currentBestVoice) {
                continue
            }
            bestVoiceByNameAndRegion[nameAndRegionKey] = voiceOption
        }

        var listedVoiceOptions = Array(bestVoiceByNameAndRegion.values).filter(matchesSearch)
        if let selectedVoiceIdentifier,
           !listedVoiceOptions.contains(where: { $0.id == selectedVoiceIdentifier }),
           let selectedVoiceOption = voiceOptions.first(where: { $0.id == selectedVoiceIdentifier }) {
            listedVoiceOptions.append(selectedVoiceOption)
        }

        let sortedVoiceOptions = listedVoiceOptions.sorted { firstVoice, secondVoice in
            if firstVoice.qualityTier != secondVoice.qualityTier {
                return firstVoice.qualityTier > secondVoice.qualityTier
            }
            if firstVoice.displayName != secondVoice.displayName {
                return firstVoice.displayName.localizedCaseInsensitiveCompare(secondVoice.displayName) == .orderedAscending
            }
            return firstVoice.languageCode < secondVoice.languageCode
        }

        let candidateSections = [
            Section(
                title: mostNaturalSectionTitle,
                voiceOptions: sortedVoiceOptions.filter { !$0.isNoveltyVoice && $0.qualityTier > .standard }
            ),
            Section(
                title: standardSectionTitle,
                voiceOptions: sortedVoiceOptions.filter { !$0.isNoveltyVoice && $0.qualityTier == .standard }
            ),
            Section(
                title: noveltySectionTitle,
                voiceOptions: sortedVoiceOptions.filter { $0.isNoveltyVoice }
            )
        ]
        return candidateSections.filter { !$0.voiceOptions.isEmpty }
    }

    /// The voice replies use when the user hasn't picked one: the most
    /// natural installed voice for their language — Premium before
    /// Enhanced, their own region before others, a full install before a
    /// super-compact one — or nil when only standard voices are installed
    /// (then the system's default voice speaks). Novelty voices never.
    static func mostNaturalVoice(from voiceOptions: [SystemVoiceOption], preferredLanguageCode: String) -> SystemVoiceOption? {
        let languagePrefix = String(preferredLanguageCode.prefix { $0 != "-" && $0 != "_" }).lowercased()
        let normalizedPreferredLanguageCode = preferredLanguageCode.replacingOccurrences(of: "_", with: "-").lowercased()
        let naturalVoicesForLanguage = voiceOptions.filter { voiceOption in
            !voiceOption.isNoveltyVoice
                && voiceOption.qualityTier > .standard
                && voiceOption.languageCode.lowercased().hasPrefix(languagePrefix)
        }
        return naturalVoicesForLanguage.min { firstVoice, secondVoice in
            if firstVoice.qualityTier != secondVoice.qualityTier {
                return firstVoice.qualityTier > secondVoice.qualityTier
            }
            let firstIsInPreferredRegion = firstVoice.languageCode.lowercased() == normalizedPreferredLanguageCode
            let secondIsInPreferredRegion = secondVoice.languageCode.lowercased() == normalizedPreferredLanguageCode
            if firstIsInPreferredRegion != secondIsInPreferredRegion {
                return firstIsInPreferredRegion
            }
            if firstVoice.isSuperCompactInstall != secondVoice.isSuperCompactInstall {
                return !firstVoice.isSuperCompactInstall
            }
            if firstVoice.displayName != secondVoice.displayName {
                return firstVoice.displayName.localizedCaseInsensitiveCompare(secondVoice.displayName) == .orderedAscending
            }
            return firstVoice.id < secondVoice.id
        }
    }

    /// The user's language and region as a BCP 47 code ("en-US").
    static func currentLanguageCode() -> String {
        let languagePrefix = currentLanguagePrefix()
        guard let regionCode = Locale.current.region?.identifier else { return languagePrefix }
        return "\(languagePrefix)-\(regionCode)"
    }

    /// The most natural voice installed on this Mac for the user's language.
    static func mostNaturalInstalledVoice() -> SystemVoiceOption? {
        mostNaturalVoice(from: installedVoiceOptions(), preferredLanguageCode: currentLanguageCode())
    }

    private static func isBetterInstall(_ candidateVoice: SystemVoiceOption, than currentBestVoice: SystemVoiceOption) -> Bool {
        if candidateVoice.qualityTier != currentBestVoice.qualityTier {
            return candidateVoice.qualityTier > currentBestVoice.qualityTier
        }
        return currentBestVoice.isSuperCompactInstall && !candidateVoice.isSuperCompactInstall
    }
}

// MARK: - Preview player

/// Plays a short sample in one voice, so voices can be compared before
/// picking. Separate from elfhub's own speech so previewing never touches a
/// reply in progress.
final class SystemVoicePreviewPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// The voice being previewed; "" is the system default voice.
    @Published private(set) var previewingVoiceIdentifier: String?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentPreviewUtteranceIdentifier: ObjectIdentifier?


    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Plays the sample in this voice, or stops it if it's already playing.
    /// `previewSentence` introduces the elf by its name ("Hi, I'm Juniper…").
    func togglePreview(ofVoiceWithIdentifier voiceIdentifier: String, previewSentence: String) {
        let wasPreviewingThisVoice = previewingVoiceIdentifier == voiceIdentifier
        stop()
        guard !wasPreviewingThisVoice else { return }

        let previewUtterance = AVSpeechUtterance(string: previewSentence)
        if !voiceIdentifier.isEmpty {
            previewUtterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }
        currentPreviewUtteranceIdentifier = ObjectIdentifier(previewUtterance)
        previewingVoiceIdentifier = voiceIdentifier
        speechSynthesizer.speak(previewUtterance)
    }

    func stop() {
        currentPreviewUtteranceIdentifier = nil
        previewingVoiceIdentifier = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    private func previewEnded(utteranceIdentifier: ObjectIdentifier) {
        // A stopped preview reports in after the next one has started; only
        // the current one may clear the playing state.
        guard utteranceIdentifier == currentPreviewUtteranceIdentifier else { return }
        currentPreviewUtteranceIdentifier = nil
        previewingVoiceIdentifier = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.previewEnded(utteranceIdentifier: utteranceIdentifier)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.previewEnded(utteranceIdentifier: utteranceIdentifier)
        }
    }
}

// MARK: - Chooser sheet

/// The voice chooser, opened from Text-to-speech in Settings › Models and
/// onboarding. Picking a voice applies it right away.
struct SystemVoiceChooserSheet: View {
    /// The chosen voice's identifier; "" follows the system default voice.
    @Binding var selectedVoiceIdentifier: String
    /// The main elf's name, for the sample sentence ("Hi, I'm Juniper").
    let elfName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voicePreviewPlayer = SystemVoicePreviewPlayer()
    @State private var installedVoiceOptions = SystemVoiceCatalog.installedVoiceOptions()
    @State private var searchText = ""
    @State private var showsNoveltyVoices = false

    private var voiceSections: [SystemVoiceCatalog.Section] {
        SystemVoiceCatalog.sections(
            from: installedVoiceOptions,
            languagePrefix: SystemVoiceCatalog.currentLanguagePrefix(),
            includesNoveltyVoices: showsNoveltyVoices,
            searchText: searchText,
            selectedVoiceIdentifier: selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)
            filterControls
            ScrollView {
                voiceList
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            Divider().background(DS.Colors.borderSubtle)
            footer
        }
        .frame(width: 520, height: 580)
        .background(DS.Colors.background)
        // New voices appear once they finish downloading in System Settings.
        // Also re-read when the user comes back to the app, in case the
        // download finished while elfhub wasn't listening.
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            installedVoiceOptions = SystemVoiceCatalog.installedVoiceOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            installedVoiceOptions = SystemVoiceCatalog.installedVoiceOptions()
        }
        .onDisappear { voicePreviewPlayer.stop() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a voice")
                    .font(DS.Typography.interface(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Apple voices installed on this Mac. Premium and Enhanced voices sound the most natural — press play to hear one.")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var filterControls: some View {
        HStack(spacing: 12) {
            TextField("Search voices or regions", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Toggle("Show novelty voices", isOn: $showsNoveltyVoices)
                .toggleStyle(.checkbox)
                .font(DS.Typography.interface(size: 12))
                .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var voiceList: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SystemVoiceChooserRow(
                    title: systemDefaultRowTitle,
                    subtitle: "Follows the voice set for your language in System Settings",
                    qualityBadgeLabel: nil,
                    isSelected: selectedVoiceIdentifier.isEmpty,
                    isPreviewing: voicePreviewPlayer.previewingVoiceIdentifier == "",
                    onSelect: { selectedVoiceIdentifier = "" },
                    onTogglePreview: { voicePreviewPlayer.togglePreview(ofVoiceWithIdentifier: "", previewSentence: ElfVoicePreview.sentence(forElfName: elfName)) }
                )
            }

            ForEach(voiceSections) { voiceSection in
                Text(voiceSection.title.uppercased())
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                ForEach(voiceSection.voiceOptions) { voiceOption in
                    SystemVoiceChooserRow(
                        title: voiceOption.displayName,
                        subtitle: voiceOption.regionDisplayName,
                        qualityBadgeLabel: voiceOption.qualityTier.badgeLabel,
                        isSelected: selectedVoiceIdentifier == voiceOption.id,
                        isPreviewing: voicePreviewPlayer.previewingVoiceIdentifier == voiceOption.id,
                        onSelect: { selectedVoiceIdentifier = voiceOption.id },
                        onTogglePreview: { voicePreviewPlayer.togglePreview(ofVoiceWithIdentifier: voiceOption.id, previewSentence: ElfVoicePreview.sentence(forElfName: elfName)) }
                    )
                }
            }

            if voiceSections.isEmpty && !searchText.isEmpty {
                Text("No voices match \"\(searchText)\".")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 12)
            }
        }
    }

    private var systemDefaultRowTitle: String {
        if let systemDefaultVoiceName = SystemVoiceCatalog.systemDefaultVoiceName() {
            return "System default (\(systemDefaultVoiceName))"
        }
        return "System default"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Downloaded a voice in System Settings? It shows up here once it's installed.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Get better voices") { SystemVoiceSettings.openVoiceDownloadSettings() }
                .help("Premium and Enhanced voices download free in System Settings › Accessibility › Spoken Content")
                .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// One voice in the chooser: click the row to pick it, the play button to hear it.
private struct SystemVoiceChooserRow: View {
    let title: String
    let subtitle: String
    let qualityBadgeLabel: String?
    let isSelected: Bool
    let isPreviewing: Bool
    let onSelect: () -> Void
    let onTogglePreview: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(DS.Typography.interface(size: 14))
                .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer(minLength: 8)

            if let qualityBadgeLabel {
                Text(qualityBadgeLabel)
                    .font(DS.Typography.interface(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.success.opacity(0.12)))
            }

            Button(action: onTogglePreview) {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
                    .font(DS.Typography.interface(size: 16))
                    .foregroundColor(isPreviewing ? DS.Colors.accentText : DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(isPreviewing ? "Stop" : "Hear this voice")
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle : (isHovered ? DS.Colors.surface2 : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}
