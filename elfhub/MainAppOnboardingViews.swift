//
//  MainAppOnboardingViews.swift
//  elfhub
//
//  First-run setup and the optional tutorial, shown in the main window's
//  detail pane. Both use MainAppPage, the same fixed reading column as every
//  other page, so the window never resizes and the content never shifts
//  between steps.
//
//  Onboarding, one decision per step:
//    1. Welcome — the stacked logo, the Mac line, and the sentence that
//       says an Elf is an AI agent (brand chapter 08's first-use rule).
//    2. Your Elf — a suggested name (ElfNameSuggestions) with "Suggest
//       another", an optional picture (else initials on Igloo Blue), an optional description, and the
//       optional Researcher and Writer starter Elfs (unchecked).
//    3. Model — "Continue with ChatGPT" first; an API key (four providers,
//       then "More providers…") or a model on this Mac a click away.
//    4. Voice — how the Elf hears (Apple on-device by default) and the
//       natural voice (Kokoro), downloaded in the background when the user
//       moves on with its box ticked (OnboardingNaturalVoice).
//    5. Shortcut and permissions.
//    6. Your data on this Mac (saving chats, screenshots, the action log)
//       and the "Start tutorial" checkbox (checked by default).
//  If permissions are revoked later, only the checklist returns.
//

import AppKit
import SwiftUI

// MARK: - Onboarding Pane

/// Pre-ready detail pane.
/// - Fresh install: the six steps above, then Finish.
/// - Permissions revoked after onboarding: the permission checklist only.
struct OnboardingPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var providerConfigurationStore: ProviderConfigurationStore
    @ObservedObject private var onDeviceVoiceModelStore: OnDeviceVoiceModelStore

    enum OnboardingStep: Int, CaseIterable {
        case welcome
        case yourElf
        case model
        case voice
        case shortcutAndPermissions
        case yourData

        /// The marker's label; the welcome has no marker.
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .yourElf: return "Your Elf"
            case .model: return "Model"
            case .voice: return "Voice"
            case .shortcutAndPermissions: return "Shortcut and permissions"
            case .yourData: return "Your data"
            }
        }

        var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
        var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    }

    @State private var currentStep: OnboardingStep = .welcome

    // Step 2's fields, filled from the main Elf (or a suggestion) when it appears.
    @State private var mainElfNameDraft = ""
    @State private var mainElfDescriptionDraft = ""
    @State private var hasFilledMainElfDrafts = false
    @State private var mainElfStepErrorMessage: String?
    /// Starter Elfs to add at Finish, so going Back never leaves stray Elfs behind.
    @State private var chosenStarterTemplates: Set<ElfStarterTemplate> = ElfStarterTemplate.chosenByDefaultInOnboarding
    @State private var isShowingStarterElfs = false

    // Step 3.
    @State private var isShowingAPIKeyProviders = false
    @State private var isShowingModelsOnThisMac = false

    // Step 4.
    @State private var shouldDownloadNaturalVoice = true
    @State private var chosenNaturalVoiceIdentifier = OnboardingNaturalVoice.defaultVoiceIdentifier
    @State private var isShowingHearingChoices = false
    @State private var isShowingOtherVoices = false

    /// "Start tutorial" — checked by default, never forced.
    @State private var shouldStartTutorial = true

    /// The step setup was on, kept so a relaunch picks up there: granting
    /// Screen Recording means quitting and reopening elfhub mid-setup.
    static let resumeStepDefaultsKey = "onboardingStepToResume"

    /// `initialStep` is for the visual snapshot tests; the app starts where
    /// setup was left (the welcome the first time).
    init(companionManager: CompanionManager, initialStep: OnboardingStep? = nil) {
        self.companionManager = companionManager
        self.providerConfigurationStore = companionManager.providerConfigurationStore
        self.onDeviceVoiceModelStore = OnDeviceVoiceModelLayers.shared.store
        let savedStep = OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: Self.resumeStepDefaultsKey))
        self._currentStep = State(initialValue: initialStep ?? savedStep ?? .welcome)
    }

    var body: some View {
        MainAppPage {
            if companionManager.hasCompletedOnboarding {
                revokedPermissionsContent
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if currentStep != .welcome {
                        OnboardingStepMarker(
                            stepNumber: currentStep.rawValue,
                            stepCount: OnboardingStep.allCases.count - 1,
                            title: currentStep.title
                        )
                    }
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .yourElf:
                        yourElfStep
                    case .model:
                        modelStep
                    case .voice:
                        voiceStep
                    case .shortcutAndPermissions:
                        shortcutAndPermissionsStep
                    case .yourData:
                        yourDataStep
                    }
                }
                .dsEntrance()
            }
        }
        // A fresh page per step, so the next step starts at the top and enters once.
        .id(currentStep)
    }

    private func goBack() {
        if let previousStep = currentStep.previous { show(previousStep) }
    }

    private func goForward() {
        if let nextStep = currentStep.next { show(nextStep) }
    }

    private func show(_ step: OnboardingStep) {
        currentStep = step
        UserDefaults.standard.set(step.rawValue, forKey: Self.resumeStepDefaultsKey)
    }

    /// Back on the left, an optional hint, the step's one primary action on the right.
    private func stepFooter(
        primaryTitle: String,
        isPrimaryEnabled: Bool,
        hintWhenDisabled: String?,
        secondaryActionTitle: String? = nil,
        secondaryAction: @escaping () -> Void = {},
        primaryAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if currentStep.previous != nil {
                Button("Back", action: goBack)
                    .dsSecondaryButtonStyle()
            }
            if let secondaryActionTitle {
                Button(secondaryActionTitle, action: secondaryAction)
                    .dsGhostButtonStyle()
            }
            Spacer()
            if !isPrimaryEnabled, let hintWhenDisabled {
                Text(hintWhenDisabled)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(primaryTitle, action: primaryAction)
                .dsPrimaryButtonStyle()
                .disabled(!isPrimaryEnabled)
        }
        .padding(.top, 4)
    }

    // MARK: Step 1 — welcome

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            BrandStackedLockup(markSize: 80)
                .padding(.top, 24)

            VStack(spacing: 14) {
                Text("The place for Elfs to live on your machine.")
                    .dsDisplayHeading(size: 34)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("An open-source menu-bar app. Ask your Elf, an AI agent, for help: it looks at your screen when you ask, points at what matters, and acts only when you say so.")
                    .font(DS.Typography.interface(size: 15))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                Text("No elfhub account or server. You choose the model, and your chats stay on this Mac.")
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)

            Button("Get started", action: goForward)
                .dsPrimaryButtonStyle()
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Step 2 — your Elf

    private var otherElfNames: [String] {
        ElfNameRules.namesInUse(byElfs: companionManager.elfManager.elfs, excludingElfWithIdentifier: ElfManager.mainElfIdentifier)
    }

    private var mainElfNameProblems: [ElfNameProblem] {
        ElfNameRules.problems(forName: mainElfNameDraft, otherElfNames: otherElfNames)
    }

    private var canContinueFromYourElfStep: Bool {
        mainElfNameProblems.allSatisfy(\.isWarning)
    }

    private var yourElfStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(
                title: "Name your Elf",
                explanation: "Your Elf is the AI agent you talk to. You'll call it by name, and it introduces itself with it. Keep this one or pick your own."
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ElfAvatar(elf: companionManager.elfManager.mainElf, displayedName: mainElfNameDraft, size: 56)
                        .padding(.top, 22)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .bottom, spacing: 8) {
                            DSTextField(
                                label: "Name",
                                placeholder: "Juniper",
                                text: $mainElfNameDraft,
                                onSubmit: continueFromYourElfStep
                            )
                            Button("Suggest another") {
                                mainElfNameDraft = ElfNameSuggestions.suggestion(after: mainElfNameDraft, otherElfNames: otherElfNames)
                            }
                            .dsGhostButtonStyle()
                            .padding(.bottom, 1)
                        }
                        if let nameProblem = mainElfNameProblems.first {
                            Text(nameProblem.message)
                                .font(DS.Typography.small)
                                .foregroundColor(nameProblem.isWarning ? DS.Colors.warning : DS.Colors.destructiveText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Picture (optional)")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                    ElfAvatarPictureButtons(elfIdentifier: ElfManager.mainElfIdentifier, elfManager: companionManager.elfManager)
                }

                DSTextField(
                    label: "What it's for (optional)",
                    placeholder: "Helps me with my day at work",
                    text: $mainElfDescriptionDraft
                )

                if let mainElfStepErrorMessage {
                    Text(mainElfStepErrorMessage)
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .mainAppCard()

            let availableStarterTemplates = companionManager.elfManager.availableStarterTemplates
            if !availableStarterTemplates.isEmpty {
                DisclosureGroup(isExpanded: $isShowingStarterElfs) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your main Elf can hand longer work to these, or you can talk to them by name. You can add them later from the Elfs list too.")
                            .font(DS.Typography.small)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(availableStarterTemplates) { starterTemplate in
                            starterElfRow(starterTemplate)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Add more Elfs (optional)")
                        .font(DS.Typography.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .pointerCursor()
                .mainAppCard()
            }

            stepFooter(
                primaryTitle: "Continue",
                isPrimaryEnabled: canContinueFromYourElfStep,
                hintWhenDisabled: nil,
                secondaryActionTitle: "Import an .elf file…",
                // Bring an Elf someone shared (it's added beside yours).
                secondaryAction: { ElfImportPicker.chooseAndPreview(companionManager: companionManager) },
                primaryAction: continueFromYourElfStep
            )
        }
        .onAppear(perform: fillMainElfDraftsOnce)
    }

    private func starterElfRow(_ starterTemplate: ElfStarterTemplate) -> some View {
        Toggle(isOn: Binding(
            get: { chosenStarterTemplates.contains(starterTemplate) },
            set: { isChosen in
                if isChosen {
                    chosenStarterTemplates.insert(starterTemplate)
                } else {
                    chosenStarterTemplates.remove(starterTemplate)
                }
            }
        )) {
            HStack(spacing: 10) {
                ElfAvatar(
                    name: starterTemplate.identity.name,
                    fillIndex: ElfAvatarAppearance.fillIndex(forElfIdentifier: starterTemplate.rawValue, avatarColorIndex: nil),
                    size: 28
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(starterTemplate.identity.name)
                        .font(DS.Typography.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(starterTemplate.identity.description)
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .pointerCursor()
    }

    /// Fills step 2 from the main Elf once: its name, unless it still has
    /// the placeholder name a new Elf starts with — then a suggestion.
    private func fillMainElfDraftsOnce() {
        guard !hasFilledMainElfDrafts else { return }
        hasFilledMainElfDrafts = true
        let mainElf = companionManager.elfManager.mainElf
        let mainElfIdentity = mainElf.configuration.identity
        let hasPlaceholderName = ElfNameRules.foldedForComparison(mainElfIdentity.name)
            == ElfNameRules.foldedForComparison(ElfConfiguration.Identity().name)
        mainElfNameDraft = hasPlaceholderName
            ? ElfNameSuggestions.firstSuggestion(otherElfNames: otherElfNames, randomIndex: Int.random(in: 0..<1000))
            : mainElfIdentity.name
        mainElfDescriptionDraft = mainElfIdentity.description
    }

    /// Saves the main Elf's name (through the name rules) and description
    /// (its picture is saved as soon as it's chosen), then moves on. Stays on the step if anything fails.
    private func continueFromYourElfStep() {
        guard canContinueFromYourElfStep else { return }
        let mainElfEditor = ElfEditor(editingMainElfOf: companionManager.elfManager)
        do {
            let trimmedName = mainElfNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName != mainElfEditor.elf.configuration.identity.name {
                try mainElfEditor.rename(to: trimmedName)
            }
            try mainElfEditor.updateDescription(mainElfDescriptionDraft)
            mainElfStepErrorMessage = nil
            goForward()
        } catch {
            mainElfStepErrorMessage = error.localizedDescription
        }
    }

    /// Adds the starter Elfs chosen in step 2 that aren't there yet.
    private func addChosenStarterElfs() {
        let elfManager = companionManager.elfManager
        for starterTemplate in ElfStarterTemplate.allCases
        where chosenStarterTemplates.contains(starterTemplate) && elfManager.availableStarterTemplates.contains(starterTemplate) {
            try? elfManager.createElf(fromStarterTemplate: starterTemplate)
        }
    }

    // MARK: Step 3 — model

    /// Models set up some other way than the ChatGPT plan (a key or this Mac).
    private var hasModelsOtherThanTheChatGPTPlan: Bool {
        providerConfigurationStore.configurations.contains { $0.kind != .chatGPTPlan }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(
                title: "Choose a model",
                explanation: "The model is what thinks. There's no elfhub account or server: your questions go from this Mac straight to the service you pick, or stay on this Mac."
            )

            VStack(alignment: .leading, spacing: 10) {
                LayerFieldLabel(text: "Recommended")
                ChatGPTPlanCard(
                    chatGPTPlanAccount: ChatGPTPlanAccount.shared,
                    providerConfigurationStore: providerConfigurationStore
                )
            }
            .mainAppCard()

            DisclosureGroup(isExpanded: Binding(
                get: { isShowingAPIKeyProviders || hasModelsOtherThanTheChatGPTPlan },
                set: { isShowingAPIKeyProviders = $0 }
            )) {
                ProviderSettingsView(
                    store: providerConfigurationStore,
                    featuredPresetIdentifiers: ProviderSettingsView.onboardingFeaturedPresetIdentifiers
                )
                .padding(.top, 10)
            } label: {
                disclosureLabel(
                    title: "Use an API key",
                    detail: "Anthropic, OpenAI, Google Gemini, OpenRouter and more. You pay the provider for what you use."
                )
            }
            .pointerCursor()
            .mainAppCard()

            DisclosureGroup(isExpanded: $isShowingModelsOnThisMac) {
                OnDeviceLanguageModelAssistantView(
                    onDeviceModelAssistant: companionManager.onDeviceModelAssistant,
                    providerConfigurationStore: providerConfigurationStore
                )
                .padding(.top, 10)
            } label: {
                disclosureLabel(
                    title: "Run a model on this Mac",
                    detail: "Free and private, with Ollama. Needs a few gigabytes of disk and memory."
                )
            }
            .pointerCursor()
            .mainAppCard()

            if providerConfigurationStore.isActiveConfigurationReady && !companionManager.activeLanguageModelSeesScreen {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("This model is text-only. Your Elf will talk and chat, but won't see your screen, point or act. Pick a model that sees images for that.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            stepFooter(
                primaryTitle: "Continue",
                isPrimaryEnabled: providerConfigurationStore.isActiveConfigurationReady,
                hintWhenDisabled: "Choose a model to continue.",
                primaryAction: goForward
            )
        }
    }

    private func disclosureLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DS.Typography.bodyMedium)
                .foregroundColor(DS.Colors.textPrimary)
            Text(detail)
                .font(DS.Typography.small)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 4 — voice

    private var isSpeechToTextReady: Bool {
        !companionManager.interactionInputMode.isVoiceInputEnabled
            || companionManager.transcriptionUnavailableExplanation == nil
    }

    private var shouldOfferNaturalVoice: Bool {
        OnboardingNaturalVoice.shouldOfferDownload(
            currentSpeechOutputMode: companionManager.speechOutputMode,
            activeTextToSpeechModelIdentifier: onDeviceVoiceModelStore.activeTextToSpeechModelIdentifier,
            installedModelIdentifiers: Set(onDeviceVoiceModelStore.installedModels.map(\.id))
        )
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(
                title: "How your Elf hears and sounds",
                explanation: "You hold a shortcut and talk; your Elf answers out loud as it writes. Both can run entirely on this Mac."
            )

            VStack(alignment: .leading, spacing: 10) {
                LayerFieldLabel(text: "Hearing")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundColor(DS.Colors.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(companionManager.transcriptionProviderChoice.displayLabel)
                            .font(DS.Typography.bodyMedium)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(companionManager.transcriptionProviderChoice.explanation)
                            .font(DS.Typography.small)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let transcriptionUnavailableExplanation = companionManager.transcriptionUnavailableExplanation,
                   companionManager.interactionInputMode.isVoiceInputEnabled {
                    Text(transcriptionUnavailableExplanation)
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(isExpanded: $isShowingHearingChoices) {
                    SpeechToTextLayerSection(
                        companionManager: companionManager,
                        onDeviceModelAssistant: companionManager.onDeviceModelAssistant
                    )
                    .padding(.top, 8)
                } label: {
                    Text("Change how it hears")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .pointerCursor()
            }
            .mainAppCard()

            VStack(alignment: .leading, spacing: 12) {
                LayerFieldLabel(text: "Voice")
                if shouldOfferNaturalVoice {
                    naturalVoiceOffer
                } else {
                    currentVoiceSummary
                }
                DisclosureGroup(isExpanded: $isShowingOtherVoices) {
                    TextToSpeechLayerSection(companionManager: companionManager)
                        .padding(.top, 8)
                } label: {
                    Text("Other voices")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .pointerCursor()
            }
            .mainAppCard()

            NaturalVoiceDownloadStatusRow(
                onDeviceVoiceModelStore: onDeviceVoiceModelStore,
                onTryAgain: { companionManager.startNaturalVoiceDownload(voiceIdentifier: chosenNaturalVoiceIdentifier) }
            )

            stepFooter(
                primaryTitle: "Continue",
                isPrimaryEnabled: isSpeechToTextReady,
                hintWhenDisabled: "Finish setting up how your Elf hears to continue.",
                primaryAction: continueFromVoiceStep
            )
        }
    }

    /// Kokoro with its box ticked, a short list of its voices, and what the
    /// download is and where it comes from.
    private var naturalVoiceOffer: some View {
        let naturalVoiceSize = OnboardingNaturalVoice.recommendedModel.map { Int(($0.approximateDownloadSizeInGigabytes * 1000).rounded()) } ?? 400
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $shouldDownloadNaturalVoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download a natural voice")
                        .font(DS.Typography.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Kokoro, about \(naturalVoiceSize) MB from Hugging Face, downloaded without an account. It runs on this Mac, so what your Elf says never leaves it to be spoken. Until it's ready, Apple's voice speaks.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .pointerCursor()

            if shouldDownloadNaturalVoice {
                HStack(spacing: 8) {
                    Text("Voice")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                    Picker("", selection: $chosenNaturalVoiceIdentifier) {
                        ForEach(OnboardingNaturalVoice.featuredVoices) { featuredVoice in
                            Text(featuredVoice.displayName).tag(featuredVoice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .pointerCursor()
                }
                .padding(.leading, 20)
            }
        }
    }

    /// The voice already in use, with a preview.
    private var currentVoiceSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .foregroundColor(DS.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(companionManager.speechOutputMode.displayLabel)
                    .font(DS.Typography.bodyMedium)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(companionManager.speechOutputMode.explanation)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if companionManager.speechOutputMode != .off {
                Button("Preview voice") { companionManager.previewCurrentVoice() }
                    .dsSecondaryButtonStyle(size: .small)
            }
        }
    }

    private func continueFromVoiceStep() {
        if shouldOfferNaturalVoice && shouldDownloadNaturalVoice {
            companionManager.startNaturalVoiceDownload(voiceIdentifier: chosenNaturalVoiceIdentifier)
        }
        goForward()
    }

    // MARK: Step 5 — shortcut and permissions

    private var shortcutAndPermissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(
                title: "Your shortcut",
                explanation: "Hold the shortcut, say what you need, and let go. Your Elf only looks at your screen when you press it or send a chat message."
            )

            NaturalVoiceDownloadStatusRow(
                onDeviceVoiceModelStore: onDeviceVoiceModelStore,
                onTryAgain: { companionManager.startNaturalVoiceDownload(voiceIdentifier: chosenNaturalVoiceIdentifier) }
            )

            VStack(alignment: .leading, spacing: 10) {
                LayerFieldLabel(text: "How you talk to your Elf")
                InputModePicker(companionManager: companionManager)
                if companionManager.interactionInputMode.isVoiceInputEnabled {
                    PushToTalkShortcutPicker(companionManager: companionManager)
                }
                EscapeShortcutInfoRow()
            }
            .mainAppCard()

            PermissionGroupView(companionManager: companionManager)
                .mainAppCard()

            stepFooter(
                primaryTitle: "Continue",
                isPrimaryEnabled: companionManager.hasPermissionsRequiredForActiveModes,
                hintWhenDisabled: "Grant the permissions above to continue.",
                primaryAction: goForward
            )
        }
    }

    // MARK: Step 6 — your data

    private var yourDataStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(
                title: "Your data stays on this Mac",
                explanation: "elfhub keeps what you choose here, in your Library folder. Only your questions go to the model you picked."
            )

            NaturalVoiceDownloadStatusRow(
                onDeviceVoiceModelStore: onDeviceVoiceModelStore,
                onTryAgain: { companionManager.startNaturalVoiceDownload(voiceIdentifier: chosenNaturalVoiceIdentifier) }
            )

            OnboardingDataOnThisMacCard(
                chatConversationStore: companionManager.chatConversationStore,
                computerUseAuditLog: ComputerUseAuditLog.shared
            )
            .mainAppCard()

            Toggle(isOn: $shouldStartTutorial) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start the tutorial")
                        .font(DS.Typography.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("A short, hands-on walkthrough: talk, get pointed at something, clear it, and chat. Skip any step, or the whole thing.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .pointerCursor()
            .mainAppCard()

            stepFooter(
                primaryTitle: shouldStartTutorial ? "Finish and start tutorial" : "Finish setup",
                isPrimaryEnabled: companionManager.hasPermissionsRequiredForActiveModes,
                hintWhenDisabled: "Grant the permissions in the previous step to finish.",
                primaryAction: {
                    addChosenStarterElfs()
                    UserDefaults.standard.removeObject(forKey: Self.resumeStepDefaultsKey)
                    companionManager.completeOnboarding(startTutorial: shouldStartTutorial)
                }
            )
        }
    }

    // MARK: Revoked permissions

    private var revokedPermissionsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(
                title: "Permissions needed",
                explanation: "Some permissions were turned off. Turn them back on below to keep using elfhub."
            )
            PermissionGroupView(companionManager: companionManager)
                .mainAppCard()
        }
    }
}

// MARK: - Name your elf card

/// Shown once above the chat to people who finished onboarding before it
/// asked for the elf's name, while their main elf is still called "elf".
struct NameYourElfCard: View {
    @ObservedObject var elfManager: ElfManager
    /// Called after Save, "Keep" or the close button, once the answer is recorded.
    let onAnswered: () -> Void

    @State private var nameDraft = ""
    @State private var hasFilledDrafts = false
    @State private var errorMessage: String?

    private var defaultElfName: String { ElfConfiguration.Identity().name }

    private var otherElfNames: [String] {
        ElfNameRules.namesInUse(byElfs: elfManager.elfs, excludingElfWithIdentifier: ElfManager.mainElfIdentifier)
    }

    private var isNameDraftEmpty: Bool {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text("Give your Elf a name. You'll call it by name, and it introduces itself with it.")
                    .font(DS.Typography.bodyMedium)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // Closing is the same answer as "Keep": the card never comes back.
                Button(action: dismissWithoutRenaming) {
                    Image(systemName: "xmark")
                        .font(DS.Typography.interface(size: 11, weight: .semibold))
                }
                .dsIconButtonStyle(size: 24, tooltip: "Don't ask again", tooltipAlignment: .trailing)
                .accessibilityLabel("Don't ask again")
            }
            HStack(alignment: .center, spacing: 10) {
                ElfAvatar(elf: elfManager.mainElf, displayedName: nameDraft, size: 32)
                DSTextField(label: nil, placeholder: "Juniper", text: $nameDraft, onSubmit: saveName)
                    .frame(maxWidth: 240)
                Button("Suggest another") {
                    nameDraft = ElfNameSuggestions.suggestion(after: nameDraft, otherElfNames: otherElfNames)
                }
                .dsGhostButtonStyle()
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Save name", action: saveName)
                    .dsPrimaryButtonStyle()
                    .disabled(isNameDraftEmpty)
                Button("Keep \u{201C}\(defaultElfName)\u{201D}", action: dismissWithoutRenaming)
                .dsSecondaryButtonStyle()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
        .mainAppCard()
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear {
            guard !hasFilledDrafts else { return }
            hasFilledDrafts = true
            nameDraft = ElfNameSuggestions.firstSuggestion(otherElfNames: otherElfNames, randomIndex: Int.random(in: 0..<1000))
        }
    }

    private func dismissWithoutRenaming() {
        ElfNamingPrompt.markOffered()
        onAnswered()
    }

    private func saveName() {
        guard !isNameDraftEmpty else { return }
        do {
            try elfManager.renameElf(withIdentifier: ElfManager.mainElfIdentifier, to: nameDraft)
            ElfNamingPrompt.markOffered()
            errorMessage = nil
            onAnswered()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Onboarding's last step: what elfhub keeps on this Mac, shown before setup ends
/// so nobody is saving chats without having seen the choice. The toggles show
/// the stores' own defaults (chats on, screenshots off, action log on) and
/// change the same settings as Settings › Privacy & permissions.
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

            MainElfMemorySettingsRow(chatConversationStore: chatConversationStore)

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

            Text("Change these anytime in Settings › Privacy & permissions.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}
