//
//  MainAppSettingsViews.swift
//  elfhub
//
//  Settings, opened from the sidebar's bottom menu. The sidebar swaps to the
//  four categories below (with "Back") and the detail pane shows one
//  category — every configuration grouped by what it's about: Models,
//  Controls (input mode, keys, screen actions), Privacy & permissions, and
//  General.
//

import AppKit
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case models
    case controls
    case privacy
    case general

    var id: Self { self }

    var displayTitle: String {
        switch self {
        case .models: return "Models"
        case .controls: return "Controls"
        case .privacy: return "Privacy & permissions"
        case .general: return "General"
        }
    }

    var systemImageName: String {
        switch self {
        case .models: return "cpu"
        case .controls: return "slider.horizontal.3"
        case .privacy: return "lock.shield"
        case .general: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .models:
            return "Speech-to-text, the language model and the voice. Requests go straight from this app to the services you pick — or stay on this Mac with local models. Keys are kept in your Keychain."
        case .controls:
            return "How you talk to elfhub, the keys that start and stop it, and whether it may act on your screen."
        case .privacy:
            return "What macOS lets elfhub use, what it keeps on this Mac, and apps that are never captured."
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
            case .controls:
                ControlsSettingsContent(companionManager: companionManager)
            case .privacy:
                PermissionGroupView(companionManager: companionManager)
                    .mainAppCard()
                ChatHistorySettingsSection(chatConversationStore: companionManager.chatConversationStore)
                    .mainAppCard()
                ScreenCaptureBlocklistEditor(screenCapturePrivacyBlocklist: ScreenCapturePrivacyBlocklist.shared)
                    .mainAppCard()
                ComputerUseAuditLogSettingsSection(computerUseAuditLog: ComputerUseAuditLog.shared)
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

// MARK: - Controls

/// How elfhub is used: input mode, the keys that start and stop it, and
/// screen actions with their consent gate.
private struct ControlsSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW YOU TALK TO ELFHUB")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            InputModePicker(companionManager: companionManager)
        }
        .mainAppCard()

        VStack(alignment: .leading, spacing: 12) {
            Text("KEYS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            PushToTalkShortcutPicker(companionManager: companionManager)
            EscapeShortcutInfoRow()
        }
        .mainAppCard()

        VStack(alignment: .leading, spacing: 8) {
            Text("SCREEN ACTIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            ScreenActionModeControls(
                coordinator: companionManager.screenActionCoordinator,
                isAccessibilityGranted: companionManager.hasAccessibilityPermission
            )

            ScreenActionConsentCard(coordinator: companionManager.screenActionCoordinator)
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

        AppUpdatesSettingsSection(appUpdateController: companionManager.appUpdateController)
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
        guard let lastUpdateCheckDate = appUpdateController.lastUpdateCheckDate else { return "not checked yet" }
        return "last checked \(lastUpdateCheckDate.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                SettingsToggleRow(
                    iconName: "arrow.down.circle",
                    title: "Download and install updates automatically",
                    detail: "Off: elfhub shows what's new and installs only when you click Install.",
                    isOn: Binding(
                        get: { appUpdateController.automaticallyDownloadsUpdates },
                        set: { appUpdateController.setAutomaticallyDownloadsUpdates($0) }
                    )
                )

                Button(action: { appUpdateController.checkForUpdates() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                        Text("Check for Updates…")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!appUpdateController.canCheckForUpdates)
                .padding(.vertical, 4)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updates are off in development builds")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text("Only the app published on GitHub Releases updates itself.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
        }
        .mainAppCard()
        .onAppear { appUpdateController.refreshUpdaterSettings() }

        Text([versionText, lastCheckedText].compactMap { $0 }.joined(separator: " · "))
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

/// Settings › Privacy & permissions: the local log of actions elfhub took on screen.
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
