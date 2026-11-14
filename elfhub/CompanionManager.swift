//
//  CompanionManager.swift
//  elfhub
//
//  Central state manager for the companion. Owns the push-to-talk pipeline
//  (dictation manager + global shortcut monitor), the turn pipeline
//  (screenshot → model → guidance decoding), and the overlay mounting.
//  On-screen guidance (pointer, annotations, status pill) is driven through
//  CompanionEventBus rather than by the overlay reading this object.
//

import AVFoundation
import Combine
import Foundation
import OSLog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    /// Single shared instance for the app lifetime — used by both the main
    /// window (Scene body) and the app-delegate-driven pipeline.
    @MainActor static let shared = CompanionManager()

    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet {
            guard voiceState != oldValue else { return }
            switch voiceState {
            case .listening: companionEventBus.emit(.listeningStarted)
            case .processing: companionEventBus.emit(.processingStarted)
            case .idle, .responding: break
            }
        }
    }
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Channel from this pipeline to the on-screen surfaces.
    let companionEventBus = CompanionEventBus()

    /// State for the overlay windows (pointer, annotations, status pill).
    lazy var screenGuidanceOverlayModel = ScreenGuidanceOverlayModel(
        eventBus: companionEventBus,
        audioPowerLevelPublisher: $currentAudioPowerLevel.eraseToAnyPublisher()
    )

    /// Watches for Esc while elfhub is listening, thinking, talking or showing
    /// guidance, so the user can stop all of it (see `stopEverythingOnEscape`).
    private let escapeStopMonitor = UserInterruptionMonitor()
    /// Times each turn's hops (transcript, first text, first speech, first
    /// action) into the local unified log.
    private let turnLatencyTimeline = CompanionTurnLatencyTimeline()
    private var escapeStopActivationCancellable: AnyCancellable?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// The floating notepad elfhub writes explanations into while it speaks.
    let notepadPanelManager = NotepadPanelManager()
    /// Owns real screen actions (click/type/scroll/key), the per-turn consent
    /// gate, and their preferences. CompanionManager only routes into it, keeping
    /// this file thin.
    let screenActionCoordinator = ScreenActionCoordinator()

    /// Which model the next turn uses: one of the user's own providers (a
    /// cloud API with their key, or a model on this Mac). Exposed so the
    /// Models UI can read/edit it.
    let providerConfigurationStore = ProviderConfigurationStore()
    private var providerConfigurationStoreCancellable: AnyCancellable?

    /// Text chats, saved only on this Mac.
    let chatConversationStore = ChatConversationStore()
    /// The elf the user talks to: its home folder, soul, profile, skills and config.
    let elfManager = ElfManager()

    /// Downloads and manages models that run on this Mac (Ollama, Apple speech).
    let onDeviceModelAssistant = OnDeviceModelAssistant()

    /// The optional walkthrough offered at the end of onboarding.
    lazy var guidedTutorialController: GuidedTutorialController = {
        let guidedTutorialController = GuidedTutorialController(companionEventBus: companionEventBus)
        guidedTutorialController.showStatusPillHint = { [weak self] hintText in
            self?.companionEventBus.emit(.hintRequested(hintText))
        }
        return guidedTutorialController
    }()

    /// One turn of capture → model → guidance → consent → placement.
    lazy var companionTurnPipeline = CompanionTurnPipeline(
        providerConfigurationStore: providerConfigurationStore,
        screenActionCoordinator: screenActionCoordinator,
        companionEventBus: companionEventBus,
        elfPromptContextProvider: { [elfManager] in await elfManager.promptContext() },
        elfForToolsProvider: { [elfManager] in elfManager.mainElf }
    )

    /// The main-window section another surface (e.g. the menu bar panel)
    /// asked to show; MainAppView switches to it and clears the request.
    @Published var requestedMainAppSection: MainAppSection?

    /// The current setup, as an exported elf remembers it. Never includes keys.
    func preferredModelsForElfExport() -> ElfConfiguration.PreferredModels {
        let activeLanguageModelConfiguration = providerConfigurationStore.activeConfiguration
        let voiceName: String?
        switch speechOutputMode {
        case .system: voiceName = SystemVoiceSettings.selectedVoiceIdentifier
        case .elevenLabs: voiceName = elevenLabsVoiceIdentifier
        case .openAICompatibleSpeech: voiceName = OpenAICompatibleSpeechSettings.voiceName
        case .off: voiceName = nil
        }
        return ElfConfiguration.PreferredModels(
            speechToText: transcriptionProviderChoice.rawValue,
            languageModelPreset: activeLanguageModelConfiguration?.presetIdentifier,
            languageModelName: activeLanguageModelConfiguration?.model,
            voiceOutput: speechOutputMode.rawValue,
            voiceName: voiceName
        )
    }

    /// Brings the main window forward, optionally on a specific section.
    func showMainWindow(section: MainAppSection? = nil) {
        NotificationCenter.default.post(name: .dismissCompanionPanel, object: nil)
        if let section {
            requestedMainAppSection = section
        }
        MainWindowPresenter.showMainWindow()
    }

    /// Opens model setup (Settings › Models in the main window).
    func openProviderSettings() {
        showMainWindow(section: .settings(.models))
    }

    /// One chat for the whole app (main window and the standalone chat
    /// window), backed by the on-device conversation store.
    lazy var textChatViewModel = TextChatViewModel(
        companionManager: self,
        chatConversationStore: chatConversationStore
    )

    /// Manages the in-app text-chat window (the no-voice experience).
    private lazy var textChatWindowManager = TextChatWindowManager(textChatViewModel: textChatViewModel)

    /// Opens the text-chat window.
    func openTextChat() {
        textChatWindowManager.show()
    }

    // MARK: - Interaction Input Mode (voice vs text)

    /// How the user talks to elfhub: voice via push-to-talk, typed text in the
    /// chat surface, or both at once. Voice and text share the same pipeline
    /// (screenshot → provider → pointing/actions); this mode only switches what
    /// captures the user's message. Persisted so the choice survives restarts.
    enum InteractionInputMode: String, CaseIterable, Identifiable {
        case voice
        case textOnly
        case both

        var id: String { rawValue }

        var displayLabel: String {
            switch self {
            case .voice: return "Voice"
            case .textOnly: return "Text"
            case .both: return "Both"
            }
        }

        /// Whether the push-to-talk pipeline (mic capture + global shortcut
        /// monitor) should run for this mode. Text-only turns the whole mic
        /// pipeline off — the shortcut tap is removed, not just ignored.
        var isVoiceInputEnabled: Bool {
            self != .textOnly
        }
    }

    @Published var interactionInputMode: InteractionInputMode = {
        let stored = UserDefaults.standard.string(forKey: "interactionInputMode")
        return stored.flatMap(InteractionInputMode.init(rawValue:)) ?? .both
    }()

    func setInteractionInputMode(_ mode: InteractionInputMode) {
        guard interactionInputMode != mode else { return }
        interactionInputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "interactionInputMode")

        // Switching to text-only mid-recording: stop any in-progress dictation
        // immediately so no mic session outlives the mode that started it.
        if !mode.isVoiceInputEnabled {
            buddyDictationManager.cancelCurrentDictation()
            if voiceState == .listening || voiceState == .processing {
                voiceState = .idle
            }
        }

        updatePushToTalkMonitorActivation()
        // Text-only mode drops the microphone requirement, which can change
        // whether elfhub is ready to show guidance.
        updateOverlayMounting()
    }

    /// Starts or stops the global shortcut monitor so it matches the current
    /// combination of input mode + accessibility permission. The monitor only
    /// installs its CGEvent tap when push-to-talk is both allowed and permitted.
    private func updatePushToTalkMonitorActivation() {
        let shouldMonitor = interactionInputMode.isVoiceInputEnabled && hasAccessibilityPermission
        if shouldMonitor {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            // No release event will come once the shortcut tap is gone, so
            // never leave the drawing tap swallowing clicks.
            userScreenInkRecorder.stopRecording()
        }
    }

    // MARK: - Speech Output (pluggable, optional)

    /// On-device voice: the "On-device" choice and the fallback when ElevenLabs fails.
    private lazy var systemSpeechProvider = SystemSpeechSynthesisProvider()

    /// Speaks replies sentence by sentence as they stream in.
    private lazy var streamingSpeechPlayer: StreamingSpeechPlayer = {
        let streamingSpeechPlayer = StreamingSpeechPlayer(onDeviceFallbackProvider: systemSpeechProvider)
        streamingSpeechPlayer.onSpeechStarted = { [weak self] in
            guard let self else { return }
            self.turnLatencyTimeline.mark(.firstSpeech)
            self.voiceState = .responding
            self.companionEventBus.emit(.speechStarted)
        }
        streamingSpeechPlayer.onSpeechFinished = { [weak self] in
            guard let self else { return }
            if self.voiceState == .responding {
                self.voiceState = .idle
            }
            self.companionEventBus.emit(.speechFinished)
        }
        return streamingSpeechPlayer
    }()

    /// How elfhub speaks replies. Persisted; defaults to the on-device voice.
    @Published private(set) var speechOutputMode: SpeechOutputMode = {
        let stored = UserDefaults.standard.string(forKey: "speechOutputMode")
        return stored.flatMap(SpeechOutputMode.init(rawValue:)) ?? .system
    }()

    func setSpeechOutputMode(_ mode: SpeechOutputMode) {
        speechOutputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "speechOutputMode")
        if mode == .off { stopSpeech() }
    }

    /// The ElevenLabs voice used with the user's own key.
    @Published private(set) var elevenLabsVoiceIdentifier: String =
        UserDefaults.standard.string(forKey: "elevenLabsVoiceIdentifier") ?? ElevenLabsTTSClient.defaultVoiceIdentifier

    func setElevenLabsVoiceIdentifier(_ voiceIdentifier: String) {
        let trimmedVoiceIdentifier = voiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        elevenLabsVoiceIdentifier = trimmedVoiceIdentifier.isEmpty ? ElevenLabsTTSClient.defaultVoiceIdentifier : trimmedVoiceIdentifier
        UserDefaults.standard.set(elevenLabsVoiceIdentifier, forKey: "elevenLabsVoiceIdentifier")
    }

    /// Why the chosen voice can't be used yet (it then falls back to the
    /// on-device voice), or nil when it's ready.
    var speechOutputUnavailableExplanation: String? {
        switch speechOutputMode {
        case .system, .off:
            return nil
        case .elevenLabs:
            return KeychainSecretStore.secret(for: .elevenLabs)?.isEmpty == false
                ? nil
                : "Add your ElevenLabs key. Until then elfhub uses the on-device voice."
        case .openAICompatibleSpeech:
            return OpenAICompatibleSpeechSettings.isReady
                ? nil
                : "Add your key (or a local speech server URL). Until then elfhub uses the on-device voice."
        }
    }

    /// The provider for the current voice setting, or nil when speech is off.
    /// A voice that isn't set up yet falls back to the on-device voice.
    private func speechProviderForCurrentSettings() -> SpeechSynthesisProvider? {
        switch speechOutputMode {
        case .off:
            return nil
        case .system:
            return systemSpeechProvider
        case .elevenLabs:
            guard let elevenLabsAPIKey = KeychainSecretStore.secret(for: .elevenLabs), !elevenLabsAPIKey.isEmpty else {
                return systemSpeechProvider
            }
            let elevenLabsTTSClient = ElevenLabsTTSClient(apiKey: elevenLabsAPIKey, voiceIdentifier: elevenLabsVoiceIdentifier)
            return NetworkAudioSpeechSynthesisProvider(synthesizeSpeechAudio: { sentence in
                try await elevenLabsTTSClient.synthesizeSpeechAudio(for: sentence)
            })
        case .openAICompatibleSpeech:
            guard OpenAICompatibleSpeechSettings.isReady else {
                return systemSpeechProvider
            }
            let openAICompatibleSpeechClient = OpenAICompatibleSpeechClient(
                baseURL: OpenAICompatibleSpeechSettings.baseURL,
                apiKey: KeychainSecretStore.secret(for: .openAICompatibleSpeech),
                modelName: OpenAICompatibleSpeechSettings.modelName,
                voiceName: OpenAICompatibleSpeechSettings.voiceName
            )
            return NetworkAudioSpeechSynthesisProvider(synthesizeSpeechAudio: { sentence in
                try await openAICompatibleSpeechClient.synthesizeSpeechAudio(for: sentence)
            })
        }
    }

    /// The voice an elf speaks with: its own, set up on this Mac, or the
    /// voice in Settings › Models. A service that isn't ready falls back to
    /// the on-device voice.
    func speechProvider(for elf: Elf) -> SpeechSynthesisProvider? {
        let elfSpeechChoice = ElfSpeechChoice.choice(
            for: elf.home.readLocalSettings(),
            isMainElf: elf.id == ElfManager.mainElfIdentifier
        )
        switch elfSpeechChoice {
        case .sameAsMain:
            return speechProviderForCurrentSettings()
        case .off:
            return nil
        case let .system(voiceIdentifier):
            return SystemSpeechSynthesisProvider(voiceIdentifierOverride: voiceIdentifier)
        case let .elevenLabs(voiceIdentifier):
            guard let elevenLabsAPIKey = KeychainSecretStore.secret(for: .elevenLabs), !elevenLabsAPIKey.isEmpty else {
                return systemSpeechProvider
            }
            let elevenLabsTTSClient = ElevenLabsTTSClient(apiKey: elevenLabsAPIKey, voiceIdentifier: voiceIdentifier ?? elevenLabsVoiceIdentifier)
            return NetworkAudioSpeechSynthesisProvider(synthesizeSpeechAudio: { sentence in
                try await elevenLabsTTSClient.synthesizeSpeechAudio(for: sentence)
            })
        case let .openAICompatible(voiceName):
            guard OpenAICompatibleSpeechSettings.isReady else { return systemSpeechProvider }
            let openAICompatibleSpeechClient = OpenAICompatibleSpeechClient(
                baseURL: OpenAICompatibleSpeechSettings.baseURL,
                apiKey: KeychainSecretStore.secret(for: .openAICompatibleSpeech),
                modelName: OpenAICompatibleSpeechSettings.modelName,
                voiceName: voiceName ?? OpenAICompatibleSpeechSettings.voiceName
            )
            return NetworkAudioSpeechSynthesisProvider(synthesizeSpeechAudio: { sentence in
                try await openAICompatibleSpeechClient.synthesizeSpeechAudio(for: sentence)
            })
        }
    }

    /// The elf the user called by name ("Juniper, …"), or nil for the main
    /// elf. `chosenElfIdentifier` (the chat's elf picker) wins over the words.
    func addressedElf(for userText: String, chosenElfIdentifier: String? = nil) -> Elf? {
        if let chosenElfIdentifier {
            return chosenElfIdentifier == ElfManager.mainElfIdentifier ? nil : elfManager.elf(withIdentifier: chosenElfIdentifier)
        }
        guard let elfAddressRoute = ElfAddressRouter.route(transcript: userText, elves: elfManager.elves) else { return nil }
        return elfManager.elf(withIdentifier: elfAddressRoute.elfIdentifier)
    }

    /// The voice for a turn answered by `speakingElf` (nil: the main elf).
    private func speechProviderForTurn(answeredBy speakingElf: Elf?) -> SpeechSynthesisProvider? {
        guard let speakingElf else { return speechProviderForCurrentSettings() }
        return speechProvider(for: speakingElf)
    }

    /// Speaks a short sample with the current voice settings ("Preview").
    func previewCurrentVoice() {
        stopSpeech()
        let previewSentence = ElfVoicePreview.sentence(forElfName: elfManager.mainElf.configuration.identity.name)
        companionEventBus.emit(.responseCaptionAvailable(previewSentence))
        streamingSpeechPlayer.speakCompleteText(previewSentence, using: speechProviderForCurrentSettings() ?? systemSpeechProvider)
    }

    /// Speaks a complete line (e.g. a consent prompt) after anything already
    /// being said, and shows it as the caption.
    private func speakResponse(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        companionEventBus.emit(.responseCaptionAvailable(trimmedText))
        guard let speechProvider = speechProviderForCurrentSettings() else { return }
        streamingSpeechPlayer.speakAfterCurrentUtterance(trimmedText, using: speechProvider)
    }

    /// Stops any speech, including queued follow-ups.
    private func stopSpeech() {
        streamingSpeechPlayer.stop()
    }

    // MARK: - Language Model Readiness

    /// True when the active model can actually answer: one is configured,
    /// with its key if it needs one.
    var isLanguageModelReady: Bool {
        providerConfigurationStore.isActiveConfigurationReady
    }

    /// Whether the active model can see the screen (pointing, annotations,
    /// actions). Text-only models still talk and chat.
    var activeLanguageModelSeesScreen: Bool {
        providerConfigurationStore.activeConfiguration?.supportsVision ?? false
    }

    // MARK: - Push-to-talk Shortcut

    @Published private(set) var pushToTalkShortcutOption: BuddyPushToTalkShortcut.ShortcutOption =
        BuddyPushToTalkShortcut.currentShortcutOption

    func setPushToTalkShortcutOption(_ newShortcutOption: BuddyPushToTalkShortcut.ShortcutOption) {
        BuddyPushToTalkShortcut.setCurrentShortcutOption(newShortcutOption)
        pushToTalkShortcutOption = newShortcutOption
    }

    // MARK: - Speech Recognition Choice

    /// Which speech-to-text backend push-to-talk uses. Persisted; defaults to
    /// on-device Apple recognition.
    @Published private(set) var transcriptionProviderChoice: TranscriptionProviderChoice = {
        let stored = UserDefaults.standard.string(forKey: "transcriptionProviderChoice")
        return stored.flatMap(TranscriptionProviderChoice.init(rawValue:)) ?? TranscriptionProviderChoice.defaultChoice
    }()

    func setTranscriptionProviderChoice(_ newTranscriptionProviderChoice: TranscriptionProviderChoice) {
        transcriptionProviderChoice = newTranscriptionProviderChoice
        UserDefaults.standard.set(newTranscriptionProviderChoice.rawValue, forKey: "transcriptionProviderChoice")
        applyTranscriptionProviderChoice()
    }

    /// Rebuilds the transcription backend from the current choice and keys.
    /// Call after keys or Whisper settings change too.
    func applyTranscriptionProviderChoice() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeProvider(for: transcriptionProviderChoice)
        if !buddyDictationManager.replaceTranscriptionProvider(transcriptionProvider) {
            print("🎙️ Transcription: change deferred — a dictation is in progress")
        }
        objectWillChange.send()
    }

    /// Why push-to-talk can't transcribe yet (e.g. missing key), if so.
    var transcriptionUnavailableExplanation: String? {
        buddyDictationManager.transcriptionProviderUnavailableExplanation
    }

    /// Screenshot taken at push-to-talk key-down, so it's ready by key-up.
    private var prefetchedScreenCaptureTask: Task<[CompanionScreenCapture]?, Never>?
    /// Draws on the screen while push-to-talk is held.
    private let userScreenInkRecorder = UserScreenInkRecorder()
    /// What the user drew during the last push-to-talk, sent with its transcript.
    private var pendingUserInkStrokes: [UserInkStroke] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    /// Identifies the response currently in flight; nil when none is. A token
    /// (rather than clearing currentResponseTask) so a cancelled older turn
    /// finishing late can't mark a newer turn as done.
    private var inFlightResponseIdentifier: UUID?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Permissions actually required for the user's current interaction modes.
    /// Text-only mode drops the microphone requirement since nothing listens —
    /// lets a voice-averse user hit a fully "Ready" state.
    var hasPermissionsRequiredForActiveModes: Bool {
        if interactionInputMode.isVoiceInputEnabled {
            return allPermissionsGranted
        }
        return hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    private var elfNamesForDictationCancellable: AnyCancellable?

    /// Which elf may point, annotate and act: whoever the user is talking to.
    @Published private(set) var elfScreenHolder = ElfScreenHolder()

    /// A turn starts: the elf answering it holds the screen, and the pill
    /// names it while it acts (nil: the main elf).
    private func handOverScreen(to speakingElf: Elf?) {
        guard elfScreenHolder.beginTurn(answeredBy: speakingElf?.id) else { return }
        companionEventBus.emit(.screenHolderChanged(elfName: speakingElf?.configuration.identity.name))
    }

    /// The speech recognizer listens for every elf's names, so "Juniper, …"
    /// is heard as Juniper.
    private func bindElfNamesForDictation() {
        elfNamesForDictationCancellable = elfManager.$elves.sink { [weak self] rosterElves in
            self?.buddyDictationManager.updateContextualKeyterms(ElfAddressRouter.dictationKeyterms(for: rosterElves))
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 elfhub start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        wireScreenActionCoordinator()
        bindEscapeStop()
        bindElfNamesForDictation()
        notepadPanelManager.startListening(to: companionEventBus)
        bindProviderConfigurationStore()
        applyTranscriptionProviderChoice()
        Task {
            await onDeviceModelAssistant.refresh()
        }

        // If permissions were revoked (e.g. signing change), the overlay stays
        // unmounted and the panel shows the permissions UI instead.
        updateOverlayMounting()
    }

    /// Keeps the overlay windows mounted exactly while elfhub is usable:
    /// onboarded and holding the permissions the active input modes need.
    /// The overlay draws nothing until there's guidance to show, so being
    /// mounted is invisible to the user.
    private func updateOverlayMounting() {
        let shouldMountOverlay = hasCompletedOnboarding && hasPermissionsRequiredForActiveModes
        if shouldMountOverlay {
            overlayWindowManager.mountOverlay(overlayModel: screenGuidanceOverlayModel)
        } else if overlayWindowManager.isOverlayMounted {
            overlayWindowManager.unmountOverlay()
        }
    }

    /// Mirrors the model store into this object so views observing only the
    /// manager (readiness, status) update when a model is added or switched.
    private func bindProviderConfigurationStore() {
        providerConfigurationStoreCancellable = providerConfigurationStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// Finishes onboarding: mounts the overlay, then either starts the guided
    /// tutorial (the default) or shows a short getting-started hint.
    func completeOnboarding(startTutorial: Bool) {
        NotificationCenter.default.post(name: .dismissCompanionPanel, object: nil)

        // Mark onboarding as completed so setup won't appear again. Naming
        // the elf was part of it, so the one-time naming card never shows.
        hasCompletedOnboarding = true
        ElfNamingPrompt.markOffered()
        objectWillChange.send()

        updateOverlayMounting()
        if startTutorial {
            startGuidedTutorial()
        } else {
            showGettingStartedHint()
        }
    }

    /// Starts (or restarts) the walkthrough, skipping steps the current setup
    /// can't do.
    func startGuidedTutorial() {
        guidedTutorialController.start(
            includesVoiceStep: interactionInputMode.isVoiceInputEnabled,
            includesPointingSteps: activeLanguageModelSeesScreen
        )
        showMainWindow(section: .tutorial)
    }

    private func showGettingStartedHint() {
        let hintText = interactionInputMode.isVoiceInputEnabled
            ? "hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) and ask me anything about your screen"
            : "open chat from the menu bar and ask me anything about your screen"
        companionEventBus.emit(.hintRequested(hintText))
    }

    /// Whether Esc should be watched: only while there is something to stop —
    /// guidance on screen, a voice turn listening / thinking / talking, or a
    /// typed reply streaming. When idle, no tap runs at all.
    static func shouldListenForEscape(
        hasVisibleGuidance: Bool,
        voiceState: CompanionVoiceState,
        isChatReplyStreaming: Bool
    ) -> Bool {
        hasVisibleGuidance || voiceState != .idle || isChatReplyStreaming
    }

    /// While elfhub is busy or showing guidance, Esc stops everything (see
    /// `stopEverythingOnEscape`). The tap is listen-only here, so the user's
    /// app still receives the Esc as well. While elfhub is acting,
    /// `ScreenActionCoordinator` runs its own tap that swallows Esc.
    private func bindEscapeStop() {
        escapeStopMonitor.onEscapePressed = { [weak self] in
            self?.stopEverythingOnEscape()
        }
        userScreenInkRecorder.onStrokesChanged = { [weak self] userInkStrokes in
            self?.companionEventBus.emit(.userInkChanged(userInkStrokes))
        }
        let hasVisibleGuidancePublisher = screenGuidanceOverlayModel.$activePointer
            .combineLatest(screenGuidanceOverlayModel.$activeAnnotations, screenGuidanceOverlayModel.$activeUserInkStrokes)
            .map { activePointer, activeAnnotations, activeUserInkStrokes in
                activePointer != nil || !activeAnnotations.isEmpty || !activeUserInkStrokes.isEmpty
            }
        escapeStopActivationCancellable = hasVisibleGuidancePublisher
            .combineLatest($voiceState, textChatViewModel.$isResponding)
            .map { hasVisibleGuidance, voiceState, isChatReplyStreaming in
                Self.shouldListenForEscape(
                    hasVisibleGuidance: hasVisibleGuidance,
                    voiceState: voiceState,
                    isChatReplyStreaming: isChatReplyStreaming
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldListenForEscape in
                guard let self else { return }
                if shouldListenForEscape && self.hasAccessibilityPermission {
                    self.escapeStopMonitor.start(mode: .watchEscapeWithoutConsuming)
                } else {
                    self.escapeStopMonitor.stop()
                }
            }
    }

    /// Esc stops whatever elfhub is doing: a push-to-talk recording (nothing
    /// is sent), a reply that is still thinking or streaming (voice or typed —
    /// the partial reply is saved in chat), speech, and the pointer and marks.
    /// Running screen actions are stopped by `ScreenActionCoordinator`'s own
    /// Esc tap.
    private func stopEverythingOnEscape() {
        // Esc hands the screen back to the main elf.
        if elfScreenHolder.returnToMainElf() {
            companionEventBus.emit(.screenHolderChanged(elfName: nil))
        }
        // Recording: drop it without sending. The key release that follows
        // does nothing, because the dictation session is already gone.
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        prefetchedScreenCaptureTask?.cancel()
        prefetchedScreenCaptureTask = nil
        if userScreenInkRecorder.isRecording {
            userScreenInkRecorder.stopRecording()
            companionEventBus.emit(.userInkFinished)
        }
        pendingUserInkStrokes = []
        if buddyDictationManager.isDictationInProgress {
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        }

        // Replies: cancelling saves what streamed so far as an interrupted reply.
        currentResponseTask?.cancel()
        textChatViewModel.stopCurrentReply()

        // Speech, then the status pill and everything on screen. A cancelled
        // turn never reports itself finished, so finish it here.
        let wasSpeaking = streamingSpeechPlayer.isSpeaking
        stopSpeech()
        voiceState = .idle
        if wasSpeaking {
            companionEventBus.emit(.speechFinished)
        }
        companionEventBus.emit(.turnFinished)
        companionEventBus.emit(.allGuidanceDismissed)
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        userScreenInkRecorder.stopRecording()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.unmountOverlay()
        notepadPanelManager.closeNotepad()
        escapeStopMonitor.stop()
        screenActionCoordinator.stopRunningActions(spokenReason: nil)

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        escapeStopActivationCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        // Push-to-talk only runs while voice input is enabled AND accessibility
        // is granted — text-only mode removes the event tap entirely.
        updatePushToTalkMonitorActivation()

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        // Mount/unmount follows permissions live (e.g. granted after
        // onboarding, or revoked while running).
        updateOverlayMounting()
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    updateOverlayMounting()
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — finish the turn
                    // here so the status pill doesn't get stuck on "listening".
                    // Only when no response is in flight, otherwise the brief
                    // idle gap between recording and processing would end it early.
                    if self.inFlightResponseIdentifier == nil {
                        self.companionEventBus.emit(.turnFinished)
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Injects the side effects the screen-action coordinator can't own itself:
    /// the live Accessibility check, speaking through TTS, and overlay events
    /// (pointer previews, acting state). Keeps it free of overlay/TTS details.
    private func wireScreenActionCoordinator() {
        screenActionCoordinator.hasAccessibilityPermission = { [weak self] in
            self?.hasAccessibilityPermission ?? false
        }

        screenActionCoordinator.speak = { [weak self] textToSpeak in
            self?.speakResponse(textToSpeak)
        }

        screenActionCoordinator.emitCompanionEvent = { [weak self] companionEvent in
            if case .actionsStarted = companionEvent {
                self?.turnLatencyTimeline.mark(.firstScreenAction)
            }
            self?.companionEventBus.emit(companionEvent)
        }
    }

    // MARK: - Screen Action Voice Confirmation

    /// Handles a finalized push-to-talk transcript. If an action is waiting on
    /// consent, the utterance answers that prompt (see SpokenConfirmationParser:
    /// any "no" wins, and a consequential action needs its verb said back);
    /// otherwise it's a new request.
    private func handleFinalTranscript(_ finalTranscript: String) {
        lastTranscript = finalTranscript
        turnLatencyTimeline.mark(.transcriptReady)
        companionLogger.info("Companion received a transcript of \(finalTranscript.count, privacy: .public) characters: \(finalTranscript, privacy: .private)")
        CompanionEarcon.requestAccepted.play()
        guidedTutorialController.noteVoiceTranscriptReceived()

        if let pendingConsent = screenActionCoordinator.pendingConsent {
            let spokenConfirmationAnswer = SpokenConfirmationParser.interpret(
                finalTranscript,
                requiredVerbKeywords: pendingConsent.requiredConfirmationVerbKeywords
            )
            switch spokenConfirmationAnswer {
            case .confirmed:
                screenActionCoordinator.confirmPendingActions(approvalProvenance: .userSaidYes)
                return
            case .declined:
                screenActionCoordinator.cancelPendingActions()
                return
            case .needsVerbRestatement:
                screenActionCoordinator.askToRestateConsequentialVerb()
                return
            case .unrelated:
                // Not an answer: drop the pending action silently and treat
                // this as a brand-new request.
                screenActionCoordinator.cancelPendingActions(speakDenial: false)
            }
        }

        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Text-only mode removes the event tap, but guard defensively here
            // too so a tap installed right before a mode switch can't start
            // an afterlife dictation session.
            guard interactionInputMode.isVoiceInputEnabled else { return }
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .dismissCompanionPanel, object: nil)

            // Cancel any in-progress response, speech and running actions from
            // a previous utterance, and clear its pointer and annotations.
            currentResponseTask?.cancel()
            stopSpeech()
            screenActionCoordinator.stopRunningActions(spokenReason: nil)
            companionEventBus.emit(.turnStarted(primaryFocusScreenFrame: nil))

            // While the keys are held, pressing and dragging the mouse draws
            // on the screen instead of clicking (see UserScreenInk.swift).
            pendingUserInkStrokes = []
            if hasAccessibilityPermission {
                userScreenInkRecorder.startRecording()
            }

            // Take the screenshot now, while the user is still talking, so it
            // isn't on the critical path when they release the keys.
            prefetchedScreenCaptureTask?.cancel()
            prefetchedScreenCaptureTask = Task { [companionTurnPipeline] in
                try? await companionTurnPipeline.captureCursorScreenForActiveModel()
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.handleFinalTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            turnLatencyTimeline.startTurn(trigger: .pushToTalkReleased)
            finishUserInkRecording()
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    /// Ends drawing when push-to-talk ends; the strokes wait for the
    /// transcript and go out with that turn.
    private func finishUserInkRecording() {
        guard userScreenInkRecorder.isRecording else { return }
        pendingUserInkStrokes = userScreenInkRecorder.stopRecording()
        companionEventBus.emit(.userInkFinished)
    }

    // MARK: - Turn Paths

    /// Voice path: push-to-talk transcript → streamed, spoken reply with
    /// guidance. Speech starts after the first sentence arrives.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        stopSpeech()

        let responseIdentifier = UUID()
        inFlightResponseIdentifier = responseIdentifier
        let prefetchedScreenCaptureTask = self.prefetchedScreenCaptureTask
        self.prefetchedScreenCaptureTask = nil
        // Read now, while the user has just finished talking: if the mouse
        // moved to another monitor since key-down, that's the screen they mean.
        let cursorDisplayIDWhenTurnIsSent = CompanionScreenCaptureUtility.displayIDOfScreenUnderCursor()
        // Voice turns are part of the conversation history, next to typed
        // ones. Recorded before the turn runs: after a quiet spell this starts
        // a new conversation, which also clears what the model remembers.
        var recordedVoiceExchange = textChatViewModel.beginExchange(userText: transcript, inputSource: .spoken)
        // "Juniper, …" goes to Juniper: its model, voice, folder and history,
        // and it holds the screen for this turn.
        let speakingElf = addressedElf(for: transcript)
        handOverScreen(to: speakingElf)
        let userInkStrokes = pendingUserInkStrokes
        pendingUserInkStrokes = []

        currentResponseTask = Task {
            voiceState = .processing
            var streamingReplyPresenter = StreamingReplyPresenter(
                companionEventBus: companionEventBus,
                streamingSpeechPlayer: streamingSpeechPlayer,
                speechProvider: speechProviderForTurn(answeredBy: speakingElf)
            )
            var rawReplyText = ""
            var languageModelSwitchNotice: LanguageModelSwitchNotice?
            do {
                let prefetchedScreenCaptures = await prefetchedScreenCaptureTask?.value
                let reusablePrefetchedScreenCaptures = CompanionScreenCaptureUtility.shouldReusePrefetchedScreenCaptures(
                    prefetchedScreenCaptures,
                    cursorDisplayIDWhenTurnIsSent: cursorDisplayIDWhenTurnIsSent
                ) ? prefetchedScreenCaptures : nil
                let turnResult = try await companionTurnPipeline.runTurn(
                    userText: transcript,
                    prefetchedScreenCaptures: reusablePrefetchedScreenCaptures,
                    userInkStrokes: userInkStrokes,
                    isSpokenTurn: true,
                    speakingElf: speakingElf,
                    onReplyTextDelta: { [textChatViewModel, turnLatencyTimeline] replyTextDelta in
                        turnLatencyTimeline.mark(.firstReplyText)
                        streamingReplyPresenter.receive(replyTextDelta: replyTextDelta)
                        rawReplyText += replyTextDelta
                        textChatViewModel.showStreamingReply(rawReplyText: rawReplyText, for: recordedVoiceExchange)
                    },
                    onModelRoundEnded: {
                        // The model used a tool and may say more: speak what
                        // it said so far, and keep the rounds apart in chat.
                        streamingReplyPresenter.markEndOfModelRound()
                        rawReplyText += "\n"
                    },
                    onElfFileChanged: { [textChatViewModel] fileChange, elfIdentifier in
                        textChatViewModel.recordFileChange(fileChange, elfIdentifier: elfIdentifier, for: recordedVoiceExchange)
                    },
                    onLanguageModelSwitched: { [weak self] switchNotice in
                        guard let self else { return }
                        languageModelSwitchNotice = switchNotice
                        self.companionEventBus.emit(.hintRequested(switchNotice.message))
                        self.textChatViewModel.showLanguageModelSwitchNotice(
                            switchNotice,
                            inConversationWithIdentifier: recordedVoiceExchange.conversationIdentifier
                        )
                        guard case .switchedToFallback = switchNotice else { return }
                        // The fallback answers from the start: stop what was
                        // being said, keep any partial reply as interrupted,
                        // and stream the new answer into a fresh reply.
                        streamingReplyPresenter.abandon()
                        recordedVoiceExchange = self.textChatViewModel.restartExchangeAfterLanguageModelSwitch(
                            recordedVoiceExchange,
                            userText: transcript,
                            inputSource: .spoken,
                            rawReplyTextSoFar: rawReplyText
                        )
                        rawReplyText = ""
                        streamingReplyPresenter = StreamingReplyPresenter(
                            companionEventBus: self.companionEventBus,
                            streamingSpeechPlayer: self.streamingSpeechPlayer,
                            speechProvider: self.speechProviderForTurn(answeredBy: speakingElf)
                        )
                    }
                )
                streamingReplyPresenter.finish(finalSpokenText: turnResult.spokenText)
                textChatViewModel.completeExchange(recordedVoiceExchange, with: turnResult)
                if turnResult.consentCardIsPending {
                    CompanionEarcon.needsConfirmation.play()
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                streamingReplyPresenter.abandon()
                textChatViewModel.saveInterruptedExchange(recordedVoiceExchange, rawReplyTextSoFar: rawReplyText)
            } catch {
                streamingReplyPresenter.abandon()
                print("⚠️ Companion response error: \(error)")
                textChatViewModel.failExchange(recordedVoiceExchange, with: error)
                speakResponseErrorFallback(for: error)
            }

            if !Task.isCancelled {
                if voiceState == .processing {
                    voiceState = .idle
                }
                companionEventBus.emit(.turnFinished)
                // Shown again once the reply is done: while it streamed, the
                // caption took the pill's place. Not over actions, though:
                // "esc to stop" matters more while elfhub is acting.
                if let languageModelSwitchNotice,
                   Self.shouldShowLanguageModelSwitchHintAfterTurn(
                       isRunningScreenActions: screenActionCoordinator.isRunningActions
                   ) {
                    companionEventBus.emit(.hintRequested(languageModelSwitchNotice.message))
                }
            }
            if inFlightResponseIdentifier == responseIdentifier {
                inFlightResponseIdentifier = nil
            }
        }
    }

    /// Text-chat path: a typed message → streamed reply text, with the turn's
    /// result (final text + the screenshot it sent) returned to the chat UI.
    /// Runs the same screenshot + guidance + actions pipeline, and speaks per
    /// the current voice setting.
    /// - Parameter onLanguageModelSwitched: the turn moved between the
    ///   ChatGPT plan and the fallback model. On `.switchedToFallback` the
    ///   fallback starts over, so the chat keeps what streamed so far as an
    ///   interrupted reply.
    func respondToChatMessage(
        _ userText: String,
        chosenElfIdentifier: String? = nil,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void,
        onElfFileChanged: @escaping @MainActor (_ fileChange: ElfChangeLogEntry, _ elfIdentifier: String) -> Void = { _, _ in },
        onLanguageModelSwitched: @escaping @MainActor (LanguageModelSwitchNotice) -> Void = { _ in }
    ) async throws -> CompanionTurnPipeline.TurnResult {
        stopSpeech()
        screenActionCoordinator.stopRunningActions(spokenReason: nil)
        turnLatencyTimeline.startTurn(trigger: .chatMessageSent)
        companionEventBus.emit(.turnStarted(primaryFocusScreenFrame: nil))
        guidedTutorialController.noteChatMessageSent()
        voiceState = .processing
        defer {
            if voiceState == .processing {
                voiceState = .idle
            }
            companionEventBus.emit(.turnFinished)
        }

        let speakingElf = addressedElf(for: userText, chosenElfIdentifier: chosenElfIdentifier)
        handOverScreen(to: speakingElf)
        var streamingReplyPresenter = StreamingReplyPresenter(
            companionEventBus: companionEventBus,
            streamingSpeechPlayer: streamingSpeechPlayer,
            speechProvider: speechProviderForTurn(answeredBy: speakingElf)
        )
        do {
            let turnResult = try await companionTurnPipeline.runTurn(
                userText: userText,
                prefetchedScreenCaptures: nil,
                speakingElf: speakingElf,
                onReplyTextDelta: { [turnLatencyTimeline] replyTextDelta in
                    turnLatencyTimeline.mark(.firstReplyText)
                    streamingReplyPresenter.receive(replyTextDelta: replyTextDelta)
                    onTextChunk(replyTextDelta)
                },
                onModelRoundEnded: {
                    streamingReplyPresenter.markEndOfModelRound()
                    onTextChunk("\n")
                },
                onElfFileChanged: onElfFileChanged,
                onLanguageModelSwitched: { [weak self] switchNotice in
                    guard let self else { return }
                    self.companionEventBus.emit(.hintRequested(switchNotice.message))
                    if case .switchedToFallback = switchNotice {
                        streamingReplyPresenter.abandon()
                        streamingReplyPresenter = StreamingReplyPresenter(
                            companionEventBus: self.companionEventBus,
                            streamingSpeechPlayer: self.streamingSpeechPlayer,
                            speechProvider: self.speechProviderForTurn(answeredBy: speakingElf)
                        )
                    }
                    onLanguageModelSwitched(switchNotice)
                }
            )
            streamingReplyPresenter.finish(finalSpokenText: turnResult.spokenText)
            if turnResult.consentCardIsPending {
                CompanionEarcon.needsConfirmation.play()
            }
            return turnResult
        } catch {
            streamingReplyPresenter.abandon()
            throw error
        }
    }

    /// Whether the switch hint is shown again in the pill after a turn. The
    /// pill can show one thing; while actions run it says what elfhub is
    /// doing and how to stop it, and the chat notice still has the switch.
    nonisolated static func shouldShowLanguageModelSwitchHintAfterTurn(isRunningScreenActions: Bool) -> Bool {
        !isRunningScreenActions
    }

    /// What elfhub says when a turn fails.
    nonisolated static func spokenErrorUtterance(for error: Error) -> String {
        if case let LanguageModelProviderError.missingConfiguration(detail) = error {
            return "I can't answer yet: \(detail)."
        } else if error is ClaudeAPIError {
            return "Sorry, the model declined that request."
        } else if let planUsageError = error as? ChatGPTPlanUsageError {
            // No fallback model answered, so say what to do about the plan.
            return planUsageError.errorDescription ?? "Your ChatGPT plan couldn't answer."
        } else {
            return "Sorry, I couldn't get a response. Check your connection or model settings and try again."
        }
    }

    /// Speaks a short error with the on-device voice when a turn fails — the
    /// configured voice may be the thing that's unreachable — and says what
    /// to fix when the cause is a missing setup step.
    private func speakResponseErrorFallback(for error: Error) {
        CompanionEarcon.failed.play()
        let utterance = Self.spokenErrorUtterance(for: error)
        companionEventBus.emit(.responseCaptionAvailable(utterance))
        streamingSpeechPlayer.speakCompleteText(utterance, using: systemSpeechProvider)
    }
}
