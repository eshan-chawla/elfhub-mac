//
//  MainAppOnboardingViews.swift
//  elfhub
//
//  First-run setup and the optional tutorial, shown in the main window's
//  detail pane. Both use MainAppPage, the same fixed reading column as every
//  other page, so the window never resizes and the content never shifts
//  between steps.
//
//  Onboarding: 1. Models (speech-to-text, language model, text-to-speech) →
//  2. Shortcuts & permissions, your data on this Mac (saving chats,
//  screenshots, the action log) and a "Start tutorial" checkbox (checked by
//  default). If permissions are revoked later, only the checklist returns.
//

import AppKit
import SwiftUI

// MARK: - Onboarding Pane

/// Pre-ready detail pane.
/// - Fresh install: step 1 (models) → step 2 (shortcuts, permissions, your
///   data on this Mac, tutorial checkbox) → Finish.
/// - Permissions revoked after onboarding: the permission checklist only.
struct OnboardingPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var providerConfigurationStore: ProviderConfigurationStore

    private enum OnboardingStep {
        case models
        case shortcutsAndPermissions
    }

    @State private var currentStep: OnboardingStep = .models
    /// "Start tutorial" — checked by default, never forced.
    @State private var shouldStartTutorial = true

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.providerConfigurationStore = companionManager.providerConfigurationStore
    }

    var body: some View {
        MainAppPage {
            if companionManager.hasCompletedOnboarding {
                revokedPermissionsContent
            } else {
                stepIndicator
                switch currentStep {
                case .models:
                    modelsStep
                case .shortcutsAndPermissions:
                    shortcutsAndPermissionsStep
                }
            }
        }
        // A fresh page per step, so the next step starts at the top.
        .id(currentStep)
    }

    // MARK: Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepIndicatorItem(number: 1, title: "Models", isCurrent: currentStep == .models)
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 24, height: 1)
            stepIndicatorItem(number: 2, title: "Shortcuts & permissions", isCurrent: currentStep == .shortcutsAndPermissions)
        }
    }

    private func stepIndicatorItem(number: Int, title: String, isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(isCurrent ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(isCurrent ? DS.Colors.accent : Color.white.opacity(0.08)))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)
        }
    }

    // MARK: Step 1 — models

    private var isSpeechToTextReady: Bool {
        !companionManager.interactionInputMode.isVoiceInputEnabled
            || companionManager.transcriptionUnavailableExplanation == nil
    }

    private var canContinueFromModelsStep: Bool {
        providerConfigurationStore.isActiveConfigurationReady && isSpeechToTextReady
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to elfhub.")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("An open-source companion that hears you, sees your screen when you ask, talks you through things, points at what matters, and can act for you when you allow it.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("elfhub runs on your Mac with your own keys, your ChatGPT plan, or local models. There's no elfhub account or server — the only things that leave this app are the requests to the services you pick below.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ModelLayerCard(
                layerNumber: 1,
                title: "Speech-to-text",
                subtitle: "What hears you when you hold the push-to-talk keys.",
                isReady: isSpeechToTextReady
            ) {
                SpeechToTextLayerSection(
                    companionManager: companionManager,
                    onDeviceModelAssistant: companionManager.onDeviceModelAssistant
                )
            }

            ModelLayerCard(
                layerNumber: 2,
                title: "Language model",
                subtitle: "What thinks. Multimodal is optional: a model that sees images can look at your screen and point; a text-only one just talks.",
                isReady: providerConfigurationStore.isActiveConfigurationReady
            ) {
                LanguageModelLayerSection(
                    companionManager: companionManager,
                    providerConfigurationStore: providerConfigurationStore,
                    showsOnDeviceModelAssistant: true
                )
            }

            ModelLayerCard(
                layerNumber: 3,
                title: "Text-to-speech",
                subtitle: "How elfhub talks back. You can change all of this later in Settings › Models.",
                isReady: companionManager.speechOutputUnavailableExplanation == nil
            ) {
                TextToSpeechLayerSection(companionManager: companionManager)
            }

            HStack {
                if !canContinueFromModelsStep {
                    Text(providerConfigurationStore.isActiveConfigurationReady
                         ? "Finish setting up speech-to-text to continue."
                         : "Add a language model to continue.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                OnboardingPrimaryButton(title: "Next", isEnabled: canContinueFromModelsStep) {
                    currentStep = .shortcutsAndPermissions
                }
                .frame(width: 160)
            }
        }
    }

    // MARK: Step 2 — shortcuts & permissions

    private var shortcutsAndPermissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts and permissions")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Keep the defaults or pick your own. elfhub only looks at your screen when you press the shortcut or send a chat message.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                LayerFieldLabel(text: "How you talk to elfhub")
                InputModePicker(companionManager: companionManager)
                if companionManager.interactionInputMode.isVoiceInputEnabled {
                    PushToTalkShortcutPicker(companionManager: companionManager)
                }
                EscapeShortcutInfoRow()
            }
            .mainAppCard()

            PermissionGroupView(companionManager: companionManager)
                .mainAppCard()

            OnboardingDataOnThisMacCard(
                chatConversationStore: companionManager.chatConversationStore,
                computerUseAuditLog: ComputerUseAuditLog.shared
            )
            .mainAppCard()

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $shouldStartTutorial) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start tutorial")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("A short, hands-on walkthrough: talk, get pointed at something, clear it, and chat. Skip any step, or the whole thing.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .pointerCursor()

                HStack {
                    Button("Back") { currentStep = .models }
                        .pointerCursor()
                    Spacer()
                    if !companionManager.hasPermissionsRequiredForActiveModes {
                        Text("Grant the permissions above to finish.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    OnboardingPrimaryButton(
                        title: shouldStartTutorial ? "Finish & start tutorial" : "Finish",
                        isEnabled: companionManager.hasPermissionsRequiredForActiveModes
                    ) {
                        companionManager.completeOnboarding(startTutorial: shouldStartTutorial)
                    }
                    .frame(width: 210)
                }
            }
            .mainAppCard()
        }
    }

    // MARK: Revoked permissions

    private var revokedPermissionsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Some permissions were revoked. Grant them below to keep using elfhub.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            PermissionGroupView(companionManager: companionManager)
                .mainAppCard()
        }
    }
}

/// Big accent button used by onboarding steps.
/// Onboarding step 2: what elfhub keeps on this Mac, shown before setup ends
/// so nobody is saving chats without having seen the choice. The toggles show
/// the stores' own defaults (chats on, screenshots off, action log on) and
/// change the same settings as Settings › Privacy.
struct OnboardingDataOnThisMacCard: View {
    @ObservedObject var chatConversationStore: ChatConversationStore
    @ObservedObject var computerUseAuditLog: ComputerUseAuditLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayerFieldLabel(text: "Your data on this Mac")

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

            SettingsToggleRow(
                iconName: "list.bullet.rectangle",
                title: "Keep a log of actions",
                detail: "Records each click, keypress and scroll elfhub takes or is stopped from taking — the control it landed on, why it asked or didn't, and who approved it. Kept only on this Mac; typed text is never written to it.",
                isOn: Binding(
                    get: { computerUseAuditLog.isLoggingEnabled },
                    set: { computerUseAuditLog.setLoggingEnabled($0) }
                )
            )

            Text("Change these anytime in Settings › Privacy.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(isEnabled ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: isEnabled)
        .disabled(!isEnabled)
    }
}

// MARK: - Guided Tutorial Pane

/// The optional walkthrough: one real thing to try per step, completed
/// automatically when elfhub sees it happen. Skippable at every point.
struct GuidedTutorialPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var guidedTutorialController: GuidedTutorialController
    var onSelectSection: (MainAppSection) -> Void

    var body: some View {
        MainAppPage {
            HStack {
                Text("Tutorial")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("End tutorial") { guidedTutorialController.endTutorial() }
                    .pointerCursor()
            }

            progressIndicator

            if guidedTutorialController.isFinished {
                finishedCard
            } else if let currentStep = guidedTutorialController.currentStep {
                stepCard(currentStep)
            }
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(guidedTutorialController.steps.enumerated()), id: \.element) { stepIndex, tutorialStep in
                Capsule()
                    .fill(progressColor(stepIndex: stepIndex, tutorialStep: tutorialStep))
                    .frame(height: 4)
            }
        }
    }

    private func progressColor(stepIndex: Int, tutorialStep: GuidedTutorialStep) -> Color {
        if guidedTutorialController.completedSteps.contains(tutorialStep) {
            return DS.Colors.success
        }
        if stepIndex == guidedTutorialController.currentStepIndex && !guidedTutorialController.isFinished {
            return DS.Colors.accent
        }
        return Color.white.opacity(0.1)
    }

    private func stepCard(_ tutorialStep: GuidedTutorialStep) -> some View {
        let isComplete = guidedTutorialController.isCurrentStepComplete
        return VStack(alignment: .leading, spacing: 14) {
            Text("Step \(guidedTutorialController.currentStepIndex + 1) of \(guidedTutorialController.steps.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text(tutorialStep.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(tutorialStep.instruction(pushToTalkShortcutText: companionManager.pushToTalkShortcutOption.displayText))
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if tutorialStep == .pushToTalk {
                HStack(spacing: 4) {
                    ForEach(companionManager.pushToTalkShortcutOption.keyCapsuleLabels, id: \.self) { keyLabel in
                        KeyCapsule(keyLabel: keyLabel)
                    }
                }
            }

            if !tutorialStep.completesOnAcknowledgement {
                HStack(spacing: 6) {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DS.Colors.success)
                        Text("Nice — that worked.")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to try it…")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isComplete ? DS.Colors.success : DS.Colors.textTertiary)
            }

            HStack {
                if tutorialStep == .textChat {
                    Button("Open Chat") { onSelectSection(.chat) }
                        .pointerCursor()
                }
                if tutorialStep == .screenActions {
                    Button("Open Settings › Modes") { onSelectSection(.settings(.modes)) }
                        .pointerCursor()
                }
                Spacer()
                if !isComplete && !tutorialStep.completesOnAcknowledgement {
                    Button("Skip this step") { guidedTutorialController.skipCurrentStep() }
                        .pointerCursor()
                }
                if tutorialStep.completesOnAcknowledgement {
                    OnboardingPrimaryButton(title: "Got it", isEnabled: true) {
                        guidedTutorialController.acknowledgeCurrentStep()
                    }
                    .frame(width: 140)
                } else {
                    OnboardingPrimaryButton(title: "Next", isEnabled: isComplete) {
                        guidedTutorialController.goToNextStep()
                    }
                    .frame(width: 140)
                }
            }
        }
        .mainAppCard()
    }

    private var finishedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're all set.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold \(companionManager.pushToTalkShortcutOption.displayText) anytime to talk, or use Chat. You can replay this tutorial from Settings › General.")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                OnboardingPrimaryButton(title: "Done", isEnabled: true) {
                    guidedTutorialController.endTutorial()
                }
                .frame(width: 140)
            }
        }
        .mainAppCard()
    }
}

