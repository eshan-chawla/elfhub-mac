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
import Combine
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    /// Startup, sounds, the tutorial, usage and cost, and updates. First, so
    /// Settings opens here.
    case general
    case models
    /// What Elfs can do beyond the model: act on your screen (computer use),
    /// search the web, and what they reach.
    case tools
    /// How you talk to elfhub (input mode, push-to-talk keys, Esc) and how
    /// replies and background work report back.
    case controls
    /// macOS permissions, and everything about what elfhub keeps and sees.
    case privacy

    var id: Self { self }

    var displayTitle: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .tools: return "Tools & capabilities"
        case .controls: return "Controls"
        case .privacy: return "Privacy & permissions"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .tools: return "wrench.and.screwdriver"
        case .controls: return "slider.horizontal.3"
        case .privacy: return "lock.shield"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Startup, sounds, the tutorial, usage and cost, and updates."
        case .models:
            return "Speech-to-text, the language model and the voice. Requests go straight from this app to the services you pick — or stay on this Mac with local models. Keys are kept in your Keychain."
        case .tools:
            return "What your Elfs can do beyond the model: act on your screen, search the web, and use the web and your folders. Whatever you pick, the pages they open are fetched by this Mac."
        case .controls:
            return "How you talk to elfhub and how to stop it, and how replies and background work report back."
        case .privacy:
            return "What macOS allows elfhub to do, chat history and screenshots, and what's never captured or acted on."
        }
    }
}

// MARK: - Category Page

/// One settings category in the fixed reading column: section headings and
/// plain rows divided by hairlines (`SettingsListComponents.swift`), no boxes.
struct SettingsCategoryPage: View {
    @ObservedObject var companionManager: CompanionManager
    let settingsCategory: SettingsCategory

    var body: some View {
        MainAppPage(title: settingsCategory.displayTitle, subtitle: settingsCategory.subtitle) {
            switch settingsCategory {
            case .general:
                GeneralSettingsContent(companionManager: companionManager)
            case .models:
                ModelsSettingsContent(companionManager: companionManager)
            case .tools:
                ToolsAndCapabilitiesSettingsContent(companionManager: companionManager)
            case .controls:
                ControlsSettingsContent(companionManager: companionManager)
            case .privacy:
                PrivacySettingsContent(companionManager: companionManager)
            }
        }
        // Shared rows (also used in onboarding and the menu bar panel) take
        // the list look only here.
        .environment(\.usesSettingsListStyle, true)
        // A fresh page per category, so each one starts at the top.
        .id(settingsCategory)
    }
}

// MARK: - General

private struct GeneralSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        SettingsSection(title: "General") {
            LaunchAtLoginToggleRow()
            SettingsRowDivider()
            SoundCuesToggleRow()
            SettingsRowDivider()
            ErrorReportSettingsRow()
            SettingsRowDivider()
            SettingsLabeledRow(
                title: "Tutorial",
                detail: "Walk through talking, pointing, chatting and acting on your screen again."
            ) {
                // The pane's default secondary button, so it reads as a button.
                Button("Replay the tutorial") { companionManager.startGuidedTutorial() }
                    .pointerCursor()
            }
        }

        LanguageModelUsageSettingsSection(usageLedger: LanguageModelUsageLedger.shared)
            .padding(.top, 12)

        SettingsSection(title: "Updates") {
            AppUpdatesSettingsSection(appUpdateController: companionManager.appUpdateController)
        }
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
            title: "Speech-to-text",
            subtitle: "What hears you when you hold the push-to-talk keys.",
            isReady: companionManager.transcriptionUnavailableExplanation == nil
        ) {
            SpeechToTextLayerSection(
                companionManager: companionManager,
                onDeviceModelAssistant: companionManager.onDeviceModelAssistant
            )
        }

        // The layers are long, so a hairline marks where one ends.
        SettingsRowDivider()

        ModelLayerCard(
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

        SettingsRowDivider()

        ModelLayerCard(
            title: "Text-to-speech",
            subtitle: "How your Elf talks back.",
            isReady: companionManager.speechOutputUnavailableExplanation == nil
        ) {
            TextToSpeechLayerSection(companionManager: companionManager)
        }

        SettingsRowDivider()

        SettingsSection(
            title: "On-device models",
            caption: "Download open models that run entirely on this Mac. Nothing you say or show them leaves your computer."
        ) {
            OnDeviceLanguageModelAssistantView(
                onDeviceModelAssistant: companionManager.onDeviceModelAssistant,
                providerConfigurationStore: providerConfigurationStore
            )
        }
    }
}

// MARK: - Tools & capabilities

/// What Elfs can do beyond the model: act on the screen (computer use) with
/// its consent gate and limits, search the web, and what they reach.
private struct ToolsAndCapabilitiesSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        SettingsSection(
            title: "Acting on your screen",
            caption: "Your Elfs can work in your apps step by step, showing where they'll act first. Press Esc, or touch the mouse or keyboard, to stop at once."
        ) {
            ScreenActionModeControls(
                coordinator: companionManager.screenActionCoordinator,
                isAccessibilityGranted: companionManager.hasAccessibilityPermission,
                explainsEveryMode: true
            )
            SettingsRowDivider()
            ComputerUseStepLimitSettingsRow()
            SettingsRowDivider()
            SpokenStopSettingsRow()

            // Only shown while a step waits for a yes.
            ScreenActionConsentCard(
                coordinator: companionManager.screenActionCoordinator,
                elfName: companionManager.elfManager.mainElf.configuration.identity.name
            )
            .padding(.top, 8)
        }

        SettingsSection(
            title: "Web search",
            caption: "How Elfs with the web on find pages. The service gets only the search words."
        ) {
            WebSearchSettingsCard()
        }

        SettingsSection(title: "What your Elfs reach") {
            ElfsReachSettingsSection()
        }
    }
}

// MARK: - Controls

/// How you talk to elfhub, and how replies and background work report back.
private struct ControlsSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        SettingsSection(title: "Talking to elfhub") {
            InputModePicker(companionManager: companionManager)
            SettingsRowDivider()
            PushToTalkShortcutPicker(companionManager: companionManager)
            SettingsRowDivider()
            EscapeShortcutInfoRow()
        }

        SettingsSection(title: "Replies and background work") {
            LiveCaptionsSettingsRow()
            SettingsRowDivider()
            SettingsToggleRow(
                iconName: "checklist",
                title: "Say when background work is done",
                detail: "When an Elf finishes a task (or has a question) and you're not busy, your main Elf says so. Off: a sound and a note in the chat, and it's mentioned in the next reply.",
                isOn: Binding(
                    get: { companionManager.speaksTaskReports },
                    set: { companionManager.speaksTaskReports = $0 }
                )
            )
        }
    }
}

// MARK: - Privacy & permissions

private struct PrivacySettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        SettingsSection(title: "Permissions") {
            PermissionGroupView(companionManager: companionManager)
        }

        SettingsSection(title: "Chats") {
            ChatHistorySettingsSection(chatConversationStore: companionManager.chatConversationStore)
            SettingsRowDivider()
            MainElfMemorySettingsRow(chatConversationStore: companionManager.chatConversationStore)
        }

        SettingsSection(title: "Screenshots") {
            PersonalNumberMaskingSettingsSection()
            SettingsRowDivider()
            PrivateWebsiteListEditor(privateWebsiteList: PrivateWebsiteList.shared)
            SettingsRowDivider()
            ScreenCaptureBlocklistEditor(screenCapturePrivacyBlocklist: ScreenCapturePrivacyBlocklist.shared)
        }

        SettingsSection(title: "Action log") {
            ComputerUseAuditLogSettingsSection(computerUseAuditLog: ComputerUseAuditLog.shared)
        }
    }
}

// MARK: - Updates

/// Sparkle's settings for the published app, plus the app's version and when
/// it last checked. Xcode and contributor builds never update themselves.
private struct AppUpdatesSettingsSection: View {
    @ObservedObject var appUpdateController: AppUpdateController

    private var versionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "elfhub v\(shortVersion) (build \(buildNumber))"
    }

    private var lastCheckedText: String? {
        guard appUpdateController.isUpdatingAvailable else { return nil }
        guard let lastUpdateCheckDate = appUpdateController.lastUpdateCheckDate else { return "Not checked yet" }
        return "Last checked \(lastUpdateCheckDate.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appUpdateController.isUpdatingAvailable {
                SettingsToggleRow(
                    iconName: "arrow.triangle.2.circlepath",
                    title: "Check for updates automatically",
                    detail: "Once a day, elfhub asks GitHub whether a newer version exists. Only the app's version is sent.",
                    isOn: Binding(
                        get: { appUpdateController.automaticallyChecksForUpdates },
                        set: { appUpdateController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    iconName: "arrow.down.circle",
                    title: "Download and install updates automatically",
                    detail: "Off: elfhub shows what's new and installs only when you click Install.",
                    isOn: Binding(
                        get: { appUpdateController.automaticallyDownloadsUpdates },
                        set: { appUpdateController.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                SettingsRowDivider()
                SettingsLabeledRow(title: versionText, detail: lastCheckedText) {
                    Button("Check for updates…") { appUpdateController.checkForUpdates() }
                        .disabled(!appUpdateController.canCheckForUpdates)
                        .pointerCursor(isEnabled: appUpdateController.canCheckForUpdates)
                }
            } else {
                SettingsLabeledRow(
                    title: "Updates are off in development builds",
                    detail: "Only the app published on GitHub Releases updates itself. This is \(versionText)."
                ) {
                    EmptyView()
                }
            }
        }
        .onAppear { appUpdateController.refreshUpdaterSettings() }
    }
}

// MARK: - Chat History Settings

/// Where chats are kept and how to remove them.
struct ChatHistorySettingsSection: View {
    @ObservedObject var chatConversationStore: ChatConversationStore
    @AppStorage(ChatTitleSettings.isEnabledKey) private var namesChatsAutomatically = true
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingDeleteScreenshots = false
    /// Measured on appear and a moment after the chats change, not in
    /// `body`: it walks every saved screenshot, and the store changes with
    /// every streamed word of a reply.
    @State private var screenshotStorageSizeInBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggleRow(
                iconName: "internaldrive",
                title: "Save chats on this Mac",
                detail: "Typed and spoken questions and their replies are stored only in your Library folder — never on a server.",
                isOn: Binding(
                    get: { chatConversationStore.isSavingChatsEnabled },
                    set: { chatConversationStore.setSavingChatsEnabled($0) }
                )
            )
            SettingsRowDivider()
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
            SettingsRowDivider()
            SettingsToggleRow(
                iconName: "textformat",
                title: "Name chats automatically",
                detail: "After a chat's first reply, its question and answer are sent once more to your language model to get a short title — fixing speech slips. Off: chats are named with the first thing you said.",
                isOn: $namesChatsAutomatically
            )

            // Neutral actions and facts on the left; the destructive button
            // on its own at the right edge, red, so it's never clicked by
            // mistake for the button beside it.
            if screenshotStorageSizeInBytes > 0 {
                SettingsRowDivider()
                HStack(spacing: 10) {
                    Text("Screenshots use \(ByteCountFormatter.string(fromByteCount: screenshotStorageSizeInBytes, countStyle: .file))")
                        .font(DS.Typography.interface(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button("Delete saved screenshots…") { isConfirmingDeleteScreenshots = true }
                        .dsDestructiveSecondaryButtonStyle()
                }
                .padding(.vertical, 10)
            }

            SettingsRowDivider()
            HStack(spacing: 10) {
                Button("Show in Finder") { chatConversationStore.revealStorageFolderInFinder() }
                    .pointerCursor()
                Text("\(chatConversationStore.conversations.count) saved")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Delete all chats…") { isConfirmingDeleteAll = true }
                    .dsDestructiveSecondaryButtonStyle()
                    .disabled(chatConversationStore.conversations.isEmpty)
            }
            .padding(.vertical, 10)
        }
        .onAppear { screenshotStorageSizeInBytes = chatConversationStore.screenshotStorageSizeInBytes() }
        .onReceive(chatConversationStore.objectWillChange.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            screenshotStorageSizeInBytes = chatConversationStore.screenshotStorageSizeInBytes()
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

/// Settings › Privacy & permissions: the local log of actions elfhub took on screen.
struct ComputerUseAuditLogSettingsSection: View {
    @ObservedObject var computerUseAuditLog: ComputerUseAuditLog
    @State private var isConfirmingDeleteLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            SettingsRowDivider()
            HStack(spacing: 10) {
                Button("Show in Finder") { computerUseAuditLog.revealLogInFinder() }
                    .pointerCursor()
                Text(logFileSizeInBytes > 0
                     ? "Log uses \(ByteCountFormatter.string(fromByteCount: logFileSizeInBytes, countStyle: .file))"
                     : "No actions logged")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Delete log…") { isConfirmingDeleteLog = true }
                    .dsDestructiveSecondaryButtonStyle()
                    .disabled(logFileSizeInBytes == 0)
            }
            .padding(.vertical, 10)
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

/// How elfs search the web (Settings › Tools & capabilities): DuckDuckGo with no key by
/// default, the model's own search, Firecrawl, Brave, Tavily or Exa with
/// the user's key, their own SearXNG or Firecrawl server — or off.
private struct WebSearchSettingsCard: View {
    @State private var selectedPreset = WebSearchSettings.selectedPreset
    @State private var apiKeyDraft = ""
    @State private var savedKeyRevision = 0
    @State private var isConfirmingWebSearchKeyRemoval = false
    @State private var searxngBaseURLDraft = WebSearchSettings.searxngBaseURL
    @State private var firecrawlBaseURLDraft = WebSearchSettings.firecrawlBaseURL

    private var isReady: Bool {
        _ = savedKeyRevision
        return WebSearchSettings.currentSetup().provider != nil
    }

    var body: some View {
        // The section above names it and says what the service gets.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Search with")
                    .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: true))
                    .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: true))
                Spacer()
                Picker("", selection: Binding(
                    get: { selectedPreset },
                    set: { newPreset in
                        selectedPreset = newPreset
                        WebSearchSettings.selectedPreset = newPreset
                        apiKeyDraft = ""
                    }
                )) {
                    ForEach(WebSearchServicePreset.allCases) { preset in
                        Text(preset.displayName).tag(WebSearchServicePreset?.some(preset))
                    }
                    Divider()
                    Text("Off").tag(WebSearchServicePreset?.none)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }
            Text(selectedPreset?.explanation ?? "Elfs can't search. They can still open addresses you give them.")
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if selectedPreset == .firecrawl {
                TextField("Firecrawl address", text: $firecrawlBaseURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: firecrawlBaseURLDraft) { _, newAddress in
                        WebSearchSettings.firecrawlBaseURL = newAddress
                        savedKeyRevision += 1
                    }
            }
            if let selectedPreset, selectedPreset == .firecrawl || selectedPreset.needsKey(firecrawlBaseURL: URL(string: firecrawlBaseURLDraft)) {
                keyRow(for: selectedPreset)
            }
            if selectedPreset == .searxng {
                TextField("SearXNG address", text: $searxngBaseURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searxngBaseURLDraft) { _, newAddress in WebSearchSettings.searxngBaseURL = newAddress }
                Text("Its JSON output must be switched on (search.formats: json in its settings).")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if selectedPreset != nil, selectedPreset != .modelsOwnSearch, !isReady {
                // SearXNG needs no key, only a working address.
                Label(selectedPreset == .searxng ? "Add your SearXNG server's address to use it." : "Add a key to use this service.", systemImage: "exclamationmark.circle")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func keyRow(for preset: WebSearchServicePreset) -> some View {
        let hasSavedKey = savedKeyRevision >= 0 && WebSearchSettings.savedKey(for: preset)?.isEmpty == false
        HStack(spacing: 8) {
            SecureField(hasSavedKey ? "\(preset.displayName) key saved — paste a new one to replace it" : "\(preset.displayName) key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveKey(for: preset) }
            Button("Save") { saveKey(for: preset) }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor(isEnabled: !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            if hasSavedKey {
                Button("Remove key") {
                    isConfirmingWebSearchKeyRemoval = true
                }
                .pointerCursor()
            }
            if let keyPageURL = preset.keyPageURL {
                Button("Get a key") { NSWorkspace.shared.open(keyPageURL) }
                    .pointerCursor()
            }
        }
        .confirmationDialog(
            "Remove your \(preset.displayName) key?",
            isPresented: $isConfirmingWebSearchKeyRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove key", role: .destructive) {
                _ = KeychainSecretStore.deleteSecret(forAccount: WebSearchSettings.keychainAccountName(for: preset))
                savedKeyRevision += 1
            }
        } message: {
            Text("It's deleted from your Keychain, and web search stops working until you add one again.")
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

// MARK: - What elfs reach

/// Settings › Tools & capabilities: what leaves this Mac when elfs work — plain words, so nobody is
/// surprised that an elf on a web task contacts the web.
private struct ElfsReachSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Elfs with the web switched on (your other Elfs by default; your main Elf only if you turn it on) send their search words to the web search you picked above (DuckDuckGo unless you change it; with “the model's own search”, to your model's company inside the model call), and open web pages they were led to — search results and their links, or addresses you give them. Pages are fetched by this app straight from those sites over https, never through an elfhub server, and addresses on your own Mac or home network are refused.")
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Elfs read and change only folders you grant them on their page (read only unless you allow changes), and every change they make is kept so you can undo it. What they read goes to your language model like the rest of the conversation.")
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

/// Settings › Privacy & permissions: black out personal numbers in screenshots (on by default).
struct PersonalNumberMaskingSettingsSection: View {
    @AppStorage(ScreenshotSensitiveContentMasker.isEnabledKey) private var hidesPersonalNumbersInScreenshots = true

    var body: some View {
        SettingsToggleRow(
            iconName: "rectangle.fill.badge.minus",
            title: "Hide personal numbers in screenshots",
            detail: "Before a screenshot leaves your Mac, card numbers, social security and social insurance numbers, health card numbers and anything labelled as a patient ID, medical record number or date of birth are blacked out. The text is read on this Mac.",
            isOn: $hidesPersonalNumbersInScreenshots
        )
    }
}

/// Settings › Tools & capabilities: saying "stop" while elfhub acts, without push-to-talk.
struct SpokenStopSettingsRow: View {
    @AppStorage(SpokenStopListener.isEnabledKey) private var listensForSpokenStopWhileActing = false
    /// Why it can't listen on this Mac, shown under the switch while it's on.
    @State private var unavailableReason: String?

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsToggleRow(
                iconName: "hand.raised",
                title: "Listen for “stop” while acting",
                detail: "While elfhub works on your screen step by step, you can say “stop”, “cancel”, “wait” or “hold on” instead of pressing Esc. The microphone is on only during those runs, and what it hears is recognized on this Mac and never sent anywhere. Bluetooth headsets may switch to their call microphone meanwhile.",
                isOn: Binding(
                    get: { listensForSpokenStopWhileActing },
                    set: { isOn in
                        listensForSpokenStopWhileActing = isOn
                        guard isOn else { return }
                        Task { @MainActor in
                            _ = await SpokenStopListener.requestSpeechRecognitionPermission()
                            unavailableReason = SpokenStopListener.unavailableReason
                        }
                    }
                )
            )
            if listensForSpokenStopWhileActing, let unavailableReason {
                Text(unavailableReason)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, usesSettingsListStyle ? 0 : 24)
                    .padding(.bottom, usesSettingsListStyle ? 10 : 0)
            }
        }
        .onAppear { unavailableReason = SpokenStopListener.unavailableReason }
    }
}

// MARK: - Steps per task

/// "Steps per task": how long one run on the screen may go.
/// 15 by default; more for long work. Time scales with it, and waiting for
/// something to load or finish doesn't use steps.
struct ComputerUseStepLimitSettingsRow: View {
    @AppStorage(ComputerUseRunLimits.maximumStepsKey) private var maximumSteps = ComputerUseRunLimits.defaultMaximumSteps

    private var limits: ComputerUseRunLimits { ComputerUseRunLimits(maximumSteps: maximumSteps) }

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        VStack(alignment: .leading, spacing: usesSettingsListStyle ? 3 : 4) {
            HStack {
                HStack(spacing: 8) {
                    SettingsRowIcon(systemName: "list.number")
                    Text("Steps per task")
                        .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: usesSettingsListStyle))
                        .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: usesSettingsListStyle))
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { limits.maximumSteps },
                    set: { maximumSteps = $0 }
                )) {
                    ForEach(ComputerUseRunLimits.stepChoices, id: \.self) { stepChoice in
                        Text(stepChoice == ComputerUseRunLimits.defaultMaximumSteps ? "\(stepChoice) (default)" : "\(stepChoice)")
                            .tag(stepChoice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }
            Text("Up to \(limits.maximumSteps) steps and \(limits.activeDurationDescription) of work per task, plus up to \(Int(ComputerUseRunLimits.maximumTotalWaitInSeconds / 60)) minutes of waiting for things to load or finish (waiting uses no steps). Press Esc to stop at any time. More steps can mean more model usage.")
                .font(SettingsRowMetrics.detailFont(usesSettingsListStyle: usesSettingsListStyle))
                .foregroundColor(SettingsRowMetrics.detailColor(usesSettingsListStyle: usesSettingsListStyle))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, usesSettingsListStyle ? 0 : 24)
        }
        .padding(.vertical, SettingsRowMetrics.verticalPadding(usesSettingsListStyle: usesSettingsListStyle))
    }
}

/// "Offer to report problems": on by default. When an unexpected error
/// happens, a window offers a redacted GitHub issue to read, edit and open.
struct ErrorReportSettingsRow: View {
    @AppStorage(ErrorReportSettings.offersReportsKey) private var offersErrorReports = true

    var body: some View {
        SettingsToggleRow(
            iconName: "ladybug",
            title: "Offer to report problems",
            detail: "When something unexpected goes wrong, elfhub offers to open a GitHub issue about it. You read and edit it first, with keys and personal details taken out, and nothing is sent unless you submit it on GitHub.",
            isOn: $offersErrorReports
        )
    }
}

// MARK: - Live captions

/// "Show live captions": off by default. Replies that aren't spoken (voice
/// off) always show their text; this is about spoken ones.
struct LiveCaptionsSettingsRow: View {
    @AppStorage(LiveCaptionSettings.isEnabledKey) private var showsLiveCaptions = false

    var body: some View {
        SettingsToggleRow(
            iconName: "captions.bubble",
            title: "Show live captions",
            detail: "Shows what your Elf says in a panel at the top of the screen, word by word as it's spoken. When the voice is off, replies always show there.",
            isOn: $showsLiveCaptions
        )
    }
}

// MARK: - Memory

/// "Build a memory from your chats": on by default. Shown in onboarding's
/// last step and Settings › Privacy & permissions, since it sends past chat
/// text to the model again.
struct MainElfMemorySettingsRow: View {
    @ObservedObject var chatConversationStore: ChatConversationStore
    @AppStorage(MainElfMemorySettings.isEnabledKey) private var buildsMemoryFromChats = true

    var body: some View {
        SettingsToggleRow(
            iconName: "book.closed",
            title: "Build a memory from your chats",
            detail: "Half an hour after a chat goes quiet, your main Elf sends it to your model once to update its notes about you (user.md), so later chats know what you've talked about. With a model on this Mac, it never leaves it. Every change is listed on your main Elf's page, with Undo.",
            isOn: $buildsMemoryFromChats
        )
        .disabled(!chatConversationStore.isSavingChatsEnabled)
        .opacity(chatConversationStore.isSavingChatsEnabled ? 1 : DS.Colors.disabledOpacity)
    }
}
