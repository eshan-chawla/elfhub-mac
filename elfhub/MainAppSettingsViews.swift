//
//  MainAppSettingsViews.swift
//  elfhub
//
//  Settings, opened from the sidebar's bottom menu. The sidebar swaps to the
//  categories below (with "Back") and the detail pane shows one category —
//  every configuration grouped by what it's about, instead of separate
//  Models / Modes / Settings tabs.
//

import AppKit
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case models
    case modes
    case shortcuts
    case permissions
    case privacy
    case general

    var id: Self { self }

    var displayTitle: String {
        switch self {
        case .models: return "Models"
        case .modes: return "Modes"
        case .shortcuts: return "Shortcuts"
        case .permissions: return "Permissions"
        case .privacy: return "Privacy"
        case .general: return "General"
        }
    }

    var systemImageName: String {
        switch self {
        case .models: return "cpu"
        case .modes: return "slider.horizontal.3"
        case .shortcuts: return "keyboard"
        case .permissions: return "lock.shield"
        case .privacy: return "hand.raised"
        case .general: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "Speech-to-text, the language model and the voice. Requests go straight from this app to the services you pick — or stay on this Mac with local models. Keys are kept in your Keychain."
        case .modes:
            return "How you talk to elfhub, and whether it may act on your screen."
        case .shortcuts:
            return "The push-to-talk keys, and how to stop elfhub."
        case .permissions:
            return "What macOS needs to allow so elfhub can hear you, see your screen and act."
        case .privacy:
            return "Chat history, saved screenshots, apps that are never captured, and what your elves may reach."
        case .general:
            return "Startup, sounds and the tutorial."
        }
    }
}

// MARK: - Category Page

/// One settings category in the fixed reading column.
struct SettingsCategoryPage: View {
    @ObservedObject var companionManager: CompanionManager
    let settingsCategory: SettingsCategory

    var body: some View {
        MainAppPage(title: settingsCategory.displayTitle, subtitle: settingsCategory.subtitle) {
            switch settingsCategory {
            case .models:
                ModelsSettingsContent(companionManager: companionManager)
            case .modes:
                ModesSettingsContent(companionManager: companionManager)
            case .shortcuts:
                VStack(alignment: .leading, spacing: 12) {
                    PushToTalkShortcutPicker(companionManager: companionManager)
                    EscapeShortcutInfoRow()
                }
                .mainAppCard()
            case .permissions:
                PermissionGroupView(companionManager: companionManager)
                    .mainAppCard()
            case .privacy:
                ChatHistorySettingsSection(chatConversationStore: companionManager.chatConversationStore)
                    .mainAppCard()
                ScreenCaptureBlocklistEditor(screenCapturePrivacyBlocklist: ScreenCapturePrivacyBlocklist.shared)
                    .mainAppCard()
                ComputerUseAuditLogSettingsSection(computerUseAuditLog: ComputerUseAuditLog.shared)
                    .mainAppCard()
                ElvesReachSettingsSection()
                    .mainAppCard()
            case .general:
                GeneralSettingsContent(companionManager: companionManager)
            }
        }
        // A fresh page per category, so each one starts at the top.
        .id(settingsCategory)
    }
}

// MARK: - Models

/// The three model layers plus the on-device model assistant.
private struct ModelsSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var providerConfigurationStore: ProviderConfigurationStore

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.providerConfigurationStore = companionManager.providerConfigurationStore
    }

    var body: some View {
        ModelLayerCard(
            layerNumber: 1,
            title: "Speech-to-text",
            subtitle: "What hears you when you hold the push-to-talk keys.",
            isReady: companionManager.transcriptionUnavailableExplanation == nil
        ) {
            SpeechToTextLayerSection(
                companionManager: companionManager,
                onDeviceModelAssistant: companionManager.onDeviceModelAssistant
            )
        }

        ModelLayerCard(
            layerNumber: 2,
            title: "Language model",
            subtitle: "What thinks. Click a model to make it active. Multimodal models can see your screen.",
            isReady: providerConfigurationStore.isActiveConfigurationReady
        ) {
            LanguageModelLayerSection(
                companionManager: companionManager,
                providerConfigurationStore: providerConfigurationStore,
                showsOnDeviceModelAssistant: false
            )
        }

        ModelLayerCard(
            layerNumber: 3,
            title: "Text-to-speech",
            subtitle: "How elfhub talks back.",
            isReady: companionManager.speechOutputUnavailableExplanation == nil
        ) {
            TextToSpeechLayerSection(companionManager: companionManager)
        }

        WebSearchSettingsCard()
            .mainAppCard()

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(DS.Colors.accentText)
                Text("On-device models")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            Text("Download open models that run entirely on this Mac. Nothing you say or show them leaves your computer.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            OnDeviceLanguageModelAssistantView(
                onDeviceModelAssistant: companionManager.onDeviceModelAssistant,
                providerConfigurationStore: providerConfigurationStore
            )
        }
        .mainAppCard()
    }
}

// MARK: - Modes

/// How elfhub is used: input mode, and screen actions with their consent gate.
private struct ModesSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW YOU TALK TO ELFHUB")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            InputModePicker(companionManager: companionManager)
        }
        .mainAppCard()

        SettingsToggleRow(
            iconName: "checklist",
            title: "Say when background work is done",
            detail: "When an elf finishes a task (or has a question) and you're not busy, your main elf says so. Off: a sound and a note in the chat, and it's mentioned in the next reply.",
            isOn: Binding(
                get: { companionManager.speaksTaskReports },
                set: { companionManager.speaksTaskReports = $0 }
            )
        )
        .mainAppCard()

        VStack(alignment: .leading, spacing: 8) {
            Text("SCREEN ACTIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            ScreenActionModeControls(
                coordinator: companionManager.screenActionCoordinator,
                isAccessibilityGranted: companionManager.hasAccessibilityPermission
            )

            ScreenActionConsentCard(
                coordinator: companionManager.screenActionCoordinator,
                elfName: companionManager.elfManager.mainElf.configuration.identity.name
            )
        }
        .mainAppCard()
    }
}

// MARK: - General

private struct GeneralSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LaunchAtLoginToggleRow()
            SoundCuesToggleRow()

            Button(action: { companionManager.startGuidedTutorial() }) {
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap")
                        .font(.system(size: 11, weight: .medium))
                    Text("Replay the tutorial")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.vertical, 4)
        }
        .mainAppCard()

        Text("elfhub v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
    }
}

// MARK: - Chat History Settings

/// Where chats are kept and how to remove them.
struct ChatHistorySettingsSection: View {
    @ObservedObject var chatConversationStore: ChatConversationStore
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingDeleteScreenshots = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsToggleRow(
                iconName: "internaldrive",
                title: "Save chats on this Mac",
                detail: "Typed and spoken questions and their replies are stored only in your Library folder — never on a server.",
                isOn: Binding(
                    get: { chatConversationStore.isSavingChatsEnabled },
                    set: { chatConversationStore.setSavingChatsEnabled($0) }
                )
            )

            SettingsToggleRow(
                iconName: "photo.on.rectangle",
                title: "Save screenshots with chats",
                detail: "Keeps the screenshot each question sent to the model and shows it in the chat. Screenshots can contain anything on your screen; apps on the privacy blocklist are never captured.",
                isOn: Binding(
                    get: { chatConversationStore.isSavingScreenshotsEnabled },
                    set: { chatConversationStore.setSavingScreenshotsEnabled($0) }
                )
            )
            .disabled(!chatConversationStore.isSavingChatsEnabled)
            .opacity(chatConversationStore.isSavingChatsEnabled ? 1 : 0.5)

            let screenshotStorageSizeInBytes = chatConversationStore.screenshotStorageSizeInBytes()
            if screenshotStorageSizeInBytes > 0 {
                HStack(spacing: 10) {
                    Button("Delete saved screenshots…") { isConfirmingDeleteScreenshots = true }
                        .pointerCursor()
                    Spacer()
                    Text("Screenshots use \(ByteCountFormatter.string(fromByteCount: screenshotStorageSizeInBytes, countStyle: .file))")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            HStack(spacing: 10) {
                Button("Show in Finder") { chatConversationStore.revealStorageFolderInFinder() }
                    .pointerCursor()
                Button("Delete all chats…") { isConfirmingDeleteAll = true }
                    .disabled(chatConversationStore.conversations.isEmpty)
                    .pointerCursor(isEnabled: !chatConversationStore.conversations.isEmpty)
                Spacer()
                Text("\(chatConversationStore.conversations.count) saved")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .confirmationDialog(
            "Delete all saved chats?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all chats", role: .destructive) {
                chatConversationStore.deleteAllConversations()
            }
        } message: {
            Text("This removes every chat and saved screenshot from this Mac. It can't be undone.")
        }
        .confirmationDialog(
            "Delete saved screenshots?",
            isPresented: $isConfirmingDeleteScreenshots,
            titleVisibility: .visible
        ) {
            Button("Delete screenshots", role: .destructive) {
                chatConversationStore.deleteAllScreenshots()
            }
        } message: {
            Text("Your chats stay; only the screenshots are removed from this Mac. It can't be undone.")
        }
    }
}

/// Settings › Privacy: the local log of actions elfhub took on screen.
struct ComputerUseAuditLogSettingsSection: View {
    @ObservedObject var computerUseAuditLog: ComputerUseAuditLog
    @State private var isConfirmingDeleteLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsToggleRow(
                iconName: "list.bullet.rectangle",
                title: "Keep a log of actions",
                detail: "Records each click, keypress and scroll elfhub takes or is stopped from taking — the control it landed on, why it asked or didn't, and who approved it. Kept only on this Mac; typed text is never written to it.",
                isOn: Binding(
                    get: { computerUseAuditLog.isLoggingEnabled },
                    set: { computerUseAuditLog.setLoggingEnabled($0) }
                )
            )

            // The log publishes a new revision on every write or delete, so
            // this size is re-read whenever it changes.
            let logFileSizeInBytes = computerUseAuditLog.logFileSizeInBytes()
            HStack(spacing: 10) {
                Button("Show in Finder") { computerUseAuditLog.revealLogInFinder() }
                    .pointerCursor()
                Button("Delete log…") { isConfirmingDeleteLog = true }
                    .disabled(logFileSizeInBytes == 0)
                    .pointerCursor(isEnabled: logFileSizeInBytes > 0)
                Spacer()
                Text(logFileSizeInBytes > 0
                     ? "Log uses \(ByteCountFormatter.string(fromByteCount: logFileSizeInBytes, countStyle: .file))"
                     : "No actions logged")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .confirmationDialog(
            "Delete the action log?",
            isPresented: $isConfirmingDeleteLog,
            titleVisibility: .visible
        ) {
            Button("Delete log", role: .destructive) {
                computerUseAuditLog.deleteLog()
            }
        } message: {
            Text("This removes the record of actions elfhub took from this Mac. It can't be undone.")
        }
    }
}

// MARK: - Web search

/// The optional search service elves use for web_search: off, or Brave,
/// Tavily or Exa with the user's key, or their own SearXNG server.
private struct WebSearchSettingsCard: View {
    @State private var selectedPreset = WebSearchSettings.selectedPreset
    @State private var apiKeyDraft = ""
    @State private var savedKeyRevision = 0
    @State private var searxngBaseURLDraft = WebSearchSettings.searxngBaseURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Web search (optional)")
            Text("Lets your elves search the web for their tasks. The service you pick gets only the search words. Without one, elves can still open addresses you give them.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Service")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { selectedPreset },
                    set: { newPreset in
                        selectedPreset = newPreset
                        WebSearchSettings.selectedPreset = newPreset
                        apiKeyDraft = ""
                    }
                )) {
                    Text("Off").tag(WebSearchServicePreset?.none)
                    ForEach(WebSearchServicePreset.allCases) { preset in
                        Text(preset.displayName).tag(WebSearchServicePreset?.some(preset))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }
            if let selectedPreset, selectedPreset.needsKey {
                let hasSavedKey = savedKeyRevision >= 0 && WebSearchSettings.savedKey(for: selectedPreset)?.isEmpty == false
                HStack(spacing: 8) {
                    SecureField(hasSavedKey ? "\(selectedPreset.displayName) key saved — paste a new one to replace it" : "\(selectedPreset.displayName) key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveKey(for: selectedPreset) }
                    Button("Save") { saveKey(for: selectedPreset) }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .pointerCursor(isEnabled: !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasSavedKey {
                        Button("Remove key") {
                            _ = KeychainSecretStore.deleteSecret(forAccount: WebSearchSettings.keychainAccountName(for: selectedPreset))
                            savedKeyRevision += 1
                        }
                        .pointerCursor()
                    }
                    if let keyPageURL = selectedPreset.keyPageURL {
                        Button("Get a key") { NSWorkspace.shared.open(keyPageURL) }
                            .pointerCursor()
                    }
                }
            }
            if selectedPreset == .searxng {
                TextField("SearXNG address", text: $searxngBaseURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { WebSearchSettings.searxngBaseURL = searxngBaseURLDraft }
                    .onChange(of: searxngBaseURLDraft) { _, newAddress in WebSearchSettings.searxngBaseURL = newAddress }
                Text("Its JSON output must be switched on (search.formats: json in its settings).")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func saveKey(for preset: WebSearchServicePreset) {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        _ = KeychainSecretStore.setSecret(trimmedKey, forAccount: WebSearchSettings.keychainAccountName(for: preset))
        savedKeyRevision += 1
        apiKeyDraft = ""
    }
}

// MARK: - What elves reach

/// What leaves this Mac when elves work: plain words, so nobody is
/// surprised that an elf on a web task contacts the web.
private struct ElvesReachSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayerFieldLabel(text: "What your elves reach")
            Text("Elves with the web switched on (your other elves by default; your main elf only if you turn it on) send their search words to the web search service you picked in Settings › Models, and open web pages they were led to — search results and their links, or addresses you give them. Pages are fetched by this app straight from those sites over https, never through an elfhub server, and addresses on your own Mac or home network are refused.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Elves read and change only folders you grant them on their page (read only unless you allow changes), and every change they make is kept so you can undo it. What they read goes to your language model like the rest of the conversation.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
