//
//  ModelLayerComponents.swift
//  elfhub
//
//  The three model layers elfhub is built from, each configurable on its own:
//   1. Speech-to-text — what hears you (on-device Apple, AssemblyAI, or any
//      Whisper / OpenAI-compatible endpoint).
//   2. Language model — what thinks (any catalog provider or a model on this
//      Mac; multimodal is optional).
//   3. Text-to-speech — what talks back (on-device Apple voices, ElevenLabs,
//      an OpenAI-compatible speech endpoint, or off).
//  Plus the on-device model assistant (download models to run locally) and
//  the push-to-talk shortcut picker. Used by onboarding and the Models section.
//

import AVFoundation
import AppKit
import Combine
import SwiftUI

// MARK: - Layer Card

/// Numbered card wrapping one layer, with a ready / needs-setup status.
struct ModelLayerCard<Content: View>: View {
    let layerNumber: Int
    let title: String
    let subtitle: String
    let isReady: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(layerNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(isReady ? DS.Colors.accent : DS.Colors.textTertiary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    Text(isReady ? "Ready" : "Needs setup")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isReady ? DS.Colors.success : DS.Colors.warning)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - Shared field helpers

/// Small uppercase label above a field, matching the rest of settings.
struct LayerFieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }
}

/// Paste-to-save key field for one speech-service key. Keys go straight to
/// the Keychain and are never shown back.
struct ServiceKeyField: View {
    let serviceSecretAccount: ServiceSecretAccount
    var apiKeyPageURL: URL? = nil
    var onKeyChanged: () -> Void

    @State private var keyInput = ""
    @State private var hasStoredKey = false
    @State private var didJustSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                LayerFieldLabel(text: "\(serviceSecretAccount.displayLabel) key")
                Spacer()
                if let apiKeyPageURL {
                    Button(action: { NSWorkspace.shared.open(apiKeyPageURL) }) {
                        HStack(spacing: 3) {
                            Text("Get a key")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                    .help("Opens the provider's key page in your browser")
                    .pointerCursor()
                }
            }
            HStack(spacing: 6) {
                SecureField(hasStoredKey ? "•••••• saved — paste to replace" : "paste key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let enteredKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !enteredKey.isEmpty else { return }
                    KeychainSecretStore.setSecret(enteredKey, for: serviceSecretAccount)
                    keyInput = ""
                    refreshStoredKeyState()
                    didJustSave = true
                    onKeyChanged()
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor()
                if hasStoredKey {
                    Button("Remove") {
                        KeychainSecretStore.setSecret(nil, for: serviceSecretAccount)
                        refreshStoredKeyState()
                        didJustSave = false
                        onKeyChanged()
                    }
                    .pointerCursor()
                }
            }
            if didJustSave {
                Text("Saved in Keychain")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.success)
            }
        }
        .onAppear(perform: refreshStoredKeyState)
    }

    private func refreshStoredKeyState() {
        hasStoredKey = KeychainSecretStore.secret(for: serviceSecretAccount)?.isEmpty == false
    }
}

/// Row of quick-fill buttons for an endpoint's presets.
struct EndpointPresetButtons<Preset: Identifiable>: View {
    let presets: [Preset]
    let title: (Preset) -> String
    let onSelect: (Preset) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Quick fill:")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            ForEach(presets) { preset in
                Button(title(preset)) { onSelect(preset) }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }
}

// MARK: - 1. Speech-to-text

struct SpeechToTextLayerSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var onDeviceModelAssistant: OnDeviceModelAssistant

    @State private var whisperBaseURLInput = WhisperTranscriptionSettings.baseURL
    @State private var whisperModelInput = WhisperTranscriptionSettings.modelName

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recognize speech with")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { companionManager.transcriptionProviderChoice },
                    set: { companionManager.setTranscriptionProviderChoice($0) }
                )) {
                    ForEach(TranscriptionProviderChoice.allCases) { transcriptionProviderChoice in
                        Text(transcriptionProviderChoice.displayLabel).tag(transcriptionProviderChoice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }

            Text(companionManager.transcriptionProviderChoice.explanation)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            switch companionManager.transcriptionProviderChoice {
            case .appleOnDevice:
                AppleSpeechModelStatusRow(onDeviceModelAssistant: onDeviceModelAssistant)
            case .assemblyAI:
                ServiceKeyField(
                    serviceSecretAccount: .assemblyAI,
                    apiKeyPageURL: URL(string: "https://www.assemblyai.com/dashboard/api-keys"),
                    onKeyChanged: { companionManager.applyTranscriptionProviderChoice() }
                )
            case .openAICompatibleWhisper:
                whisperEndpointFields
            }

            if let transcriptionUnavailableExplanation = companionManager.transcriptionUnavailableExplanation {
                Text(transcriptionUnavailableExplanation)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whisperEndpointFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            EndpointPresetButtons(
                presets: WhisperTranscriptionEndpointPreset.allCases,
                title: { $0.displayName },
                onSelect: { whisperTranscriptionEndpointPreset in
                    whisperBaseURLInput = whisperTranscriptionEndpointPreset.baseURL
                    whisperModelInput = whisperTranscriptionEndpointPreset.modelName
                    saveWhisperEndpoint()
                }
            )

            LayerFieldLabel(text: "Endpoint and model")
            HStack(spacing: 6) {
                TextField(WhisperTranscriptionSettings.defaultBaseURL, text: $whisperBaseURLInput)
                    .textFieldStyle(.roundedBorder)
                TextField(WhisperTranscriptionSettings.defaultModelName, text: $whisperModelInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                Button("Save", action: saveWhisperEndpoint)
                    .pointerCursor()
            }
            Text("A local server such as faster-whisper-server / Speaches at http://localhost:8000/v1 keeps your voice on this Mac and needs no key.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !LocalModelServerPreset.isLocalBaseURL(whisperBaseURLInput) {
                ServiceKeyField(
                    serviceSecretAccount: .openAICompatibleTranscription,
                    apiKeyPageURL: WhisperTranscriptionEndpointPreset.allCases.first { $0.baseURL == whisperBaseURLInput }?.apiKeyPageURL,
                    onKeyChanged: { companionManager.applyTranscriptionProviderChoice() }
                )
            }
        }
    }

    private func saveWhisperEndpoint() {
        WhisperTranscriptionSettings.baseURL = whisperBaseURLInput.trimmingCharacters(in: .whitespaces)
        WhisperTranscriptionSettings.modelName = whisperModelInput.trimmingCharacters(in: .whitespaces)
        companionManager.applyTranscriptionProviderChoice()
    }
}

/// Status of Apple's on-device speech model, with a download button on
/// macOS 26+ so the first push-to-talk doesn't wait for it.
struct AppleSpeechModelStatusRow: View {
    @ObservedObject var onDeviceModelAssistant: OnDeviceModelAssistant

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .foregroundColor(DS.Colors.textTertiary)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if onDeviceModelAssistant.appleSpeechModelStatus == .notDownloaded {
                Button("Download now") { onDeviceModelAssistant.downloadAppleSpeechModel() }
                    .controlSize(.small)
                    .pointerCursor()
            }
            if let appleSpeechModelDownloadFraction = onDeviceModelAssistant.appleSpeechModelDownloadFraction {
                ProgressView(value: appleSpeechModelDownloadFraction)
                    .frame(width: 90)
            }
        }
    }

    private var statusText: String {
        switch onDeviceModelAssistant.appleSpeechModelStatus {
        case .checking: return "Checking Apple's speech model…"
        case .builtIn: return "Uses macOS's built-in speech recognition."
        case .unsupportedLanguage: return "Your language isn't supported on-device; elfhub will use English."
        case .notDownloaded: return "Apple's speech model for your language isn't downloaded yet (it also downloads on first use)."
        case .downloading: return "Downloading Apple's speech model…"
        case .installed: return "Apple's speech model is installed on this Mac."
        }
    }
}

// MARK: - 2. Language model

struct LanguageModelLayerSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var providerConfigurationStore: ProviderConfigurationStore
    /// Shows the local-download assistant inside this section (onboarding);
    /// the Models section shows it as its own card instead.
    var showsOnDeviceModelAssistant: Bool

    @State private var isShowingOnDeviceModelAssistant = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatGPTPlanCard(
                chatGPTPlanAccount: ChatGPTPlanAccount.shared,
                providerConfigurationStore: providerConfigurationStore
            )

            ProviderSettingsView(store: providerConfigurationStore)

            if providerConfigurationStore.isActiveConfigurationReady && !companionManager.activeLanguageModelSeesScreen {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("This model is text-only: elfhub will talk and chat, but won't see your screen, point, or act. Pick a multimodal model for that.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsOnDeviceModelAssistant {
                DisclosureGroup(isExpanded: $isShowingOnDeviceModelAssistant) {
                    OnDeviceLanguageModelAssistantView(
                        onDeviceModelAssistant: companionManager.onDeviceModelAssistant,
                        providerConfigurationStore: providerConfigurationStore
                    )
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download a model to run on this Mac")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                }
                .pointerCursor()
            }
        }
    }
}

// MARK: - On-device model assistant (language models via Ollama)

struct OnDeviceLanguageModelAssistantView: View {
    @ObservedObject var onDeviceModelAssistant: OnDeviceModelAssistant
    @ObservedObject var providerConfigurationStore: ProviderConfigurationStore

    @State private var customModelNameInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ollamaStatusRow

            if case .running = onDeviceModelAssistant.ollamaServerStatus {
                recommendedModelList
                customModelRow
                otherInstalledModelList
            }

            if let lastProblemDescription = onDeviceModelAssistant.lastProblemDescription {
                Text(lastProblemDescription)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await onDeviceModelAssistant.refreshOllamaStatus()
        }
    }

    // MARK: Ollama status

    @ViewBuilder
    private var ollamaStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ollamaStatusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(ollamaStatusDetail)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch onDeviceModelAssistant.ollamaServerStatus {
            case .checking:
                ProgressView().controlSize(.small)
            case .notInstalled:
                Button("Get Ollama") { onDeviceModelAssistant.openOllamaDownloadPage() }
                    .help("Opens ollama.com in your browser")
                    .pointerCursor()
                Button("Check again") {
                    Task { await onDeviceModelAssistant.refreshOllamaStatus() }
                }
                .pointerCursor()
            case .installedButNotRunning:
                Button("Start Ollama") { onDeviceModelAssistant.startOllama() }
                    .pointerCursor()
            case .running:
                Button(action: {
                    Task { await onDeviceModelAssistant.refreshOllamaStatus() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .pointerCursor()
            }
        }
    }

    private var ollamaStatusTitle: String {
        switch onDeviceModelAssistant.ollamaServerStatus {
        case .checking: return "Looking for Ollama…"
        case .notInstalled: return "Ollama isn't installed"
        case .installedButNotRunning: return "Ollama is installed but not running"
        case let .running(version): return "Ollama \(version) is running"
        }
    }

    private var ollamaStatusDetail: String {
        switch onDeviceModelAssistant.ollamaServerStatus {
        case .checking: return "Ollama is a free app that runs open models on your Mac."
        case .notInstalled: return "Ollama is a free app that downloads and runs open models on your Mac. Install it, open it, then check again."
        case .installedButNotRunning: return "Start it to download and run models."
        case .running: return "This Mac has \(OnDeviceModelCatalog.installedMemoryInGigabytes) GB of memory. Models run fully offline once downloaded."
        }
    }

    // MARK: Recommended models

    private var recommendedModelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            LayerFieldLabel(text: "Recommended")
            ForEach(OnDeviceModelCatalog.recommendedLanguageModels) { recommendedModel in
                onDeviceModelRow(
                    modelName: recommendedModel.id,
                    title: recommendedModel.displayName,
                    detail: "\(recommendedModel.summary) ≈\(String(format: "%.1f", recommendedModel.approximateDownloadSizeInGigabytes)) GB",
                    seesScreen: recommendedModel.seesScreen,
                    memoryWarning: recommendedModel.recommendedMemoryInGigabytes > OnDeviceModelCatalog.installedMemoryInGigabytes
                        ? "Works best with \(recommendedModel.recommendedMemoryInGigabytes) GB of memory"
                        : nil
                )
            }
        }
    }

    private var customModelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LayerFieldLabel(text: "Any other Ollama model")
            HStack(spacing: 6) {
                TextField("model name, e.g. llava:7b", text: $customModelNameInput)
                    .textFieldStyle(.roundedBorder)
                Button("Download") {
                    onDeviceModelAssistant.downloadLanguageModel(named: customModelNameInput)
                    customModelNameInput = ""
                }
                .disabled(customModelNameInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
            }
        }
    }

    @ViewBuilder
    private var otherInstalledModelList: some View {
        let otherInstalledModels = onDeviceModelAssistant.installedLanguageModels.filter { installedModel in
            !OnDeviceModelCatalog.recommendedLanguageModels.contains { OllamaWireFormat.modelNamesMatch($0.id, installedModel.name) }
        }
        let downloadingModelNames = onDeviceModelAssistant.activeDownloadProgressByModelName.keys.filter { downloadingModelName in
            !OnDeviceModelCatalog.recommendedLanguageModels.contains { $0.id == downloadingModelName }
                && !otherInstalledModels.contains { OllamaWireFormat.modelNamesMatch($0.name, downloadingModelName) }
        }
        if !otherInstalledModels.isEmpty || !downloadingModelNames.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                LayerFieldLabel(text: "Also on this Mac")
                ForEach(otherInstalledModels) { installedModel in
                    onDeviceModelRow(
                        modelName: installedModel.name,
                        title: installedModel.name,
                        detail: [installedModel.parameterSize, installedModel.formattedSize].compactMap { $0 }.joined(separator: " · "),
                        seesScreen: nil,
                        memoryWarning: nil
                    )
                }
                ForEach(downloadingModelNames.sorted(), id: \.self) { downloadingModelName in
                    onDeviceModelRow(modelName: downloadingModelName, title: downloadingModelName, detail: "", seesScreen: nil, memoryWarning: nil)
                }
            }
        }
    }

    // MARK: Row

    private func onDeviceModelRow(
        modelName: String,
        title: String,
        detail: String,
        seesScreen: Bool?,
        memoryWarning: String?
    ) -> some View {
        let downloadProgress = onDeviceModelAssistant.activeDownloadProgressByModelName[modelName]
        let isInstalled = onDeviceModelAssistant.isInstalled(modelName: modelName)
        let isActiveModel = providerConfigurationStore.activeConfiguration.map { activeConfiguration in
            activeConfiguration.presetIdentifier == LocalModelServerPreset.ollama.rawValue
                && OllamaWireFormat.modelNamesMatch(activeConfiguration.model, modelName)
        } ?? false

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        if let seesScreen {
                            Text(seesScreen ? "sees screen" : "text only")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(seesScreen ? DS.Colors.success : DS.Colors.textTertiary)
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    if let memoryWarning, !isInstalled {
                        Text(memoryWarning)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.warning)
                    }
                }

                Spacer()

                if downloadProgress != nil {
                    Button("Cancel") { onDeviceModelAssistant.cancelDownload(ofModelNamed: modelName) }
                        .controlSize(.small)
                        .pointerCursor()
                } else if isInstalled {
                    if isActiveModel {
                        Text("In use")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.success)
                    } else {
                        Button("Use") {
                            Task {
                                await onDeviceModelAssistant.useLanguageModel(named: modelName, in: providerConfigurationStore)
                            }
                        }
                        .controlSize(.small)
                        .pointerCursor()
                    }
                    Button(action: { onDeviceModelAssistant.deleteLanguageModel(named: modelName) }) {
                        Image(systemName: "trash")
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete from this Mac")
                    .pointerCursor()
                } else {
                    Button("Download") { onDeviceModelAssistant.downloadLanguageModel(named: modelName) }
                        .controlSize(.small)
                        .pointerCursor()
                }
            }

            if let downloadProgress {
                HStack(spacing: 8) {
                    if let fractionCompleted = downloadProgress.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(downloadProgressText(downloadProgress))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize()
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isActiveModel ? 0.08 : 0.03))
        )
    }

    private func downloadProgressText(_ downloadProgress: OllamaDownloadProgress) -> String {
        guard downloadProgress.totalBytes > 0 else { return downloadProgress.statusText }
        let completedText = ByteCountFormatter.string(fromByteCount: downloadProgress.completedBytes, countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: downloadProgress.totalBytes, countStyle: .file)
        return "\(downloadProgress.statusText) \(completedText) of \(totalText)"
    }
}

// MARK: - 3. Text-to-speech

struct TextToSpeechLayerSection: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var speechBaseURLInput = OpenAICompatibleSpeechSettings.baseURL
    @State private var speechModelInput = OpenAICompatibleSpeechSettings.modelName
    @State private var speechVoiceInput = OpenAICompatibleSpeechSettings.voiceName
    @State private var elevenLabsVoiceInput = ""
    @State private var selectedSystemVoiceIdentifier = SystemVoiceSettings.selectedVoiceIdentifier ?? ""
    @State private var isShowingSystemVoiceChooser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speak replies with")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { companionManager.speechOutputMode },
                    set: { companionManager.setSpeechOutputMode($0) }
                )) {
                    ForEach(SpeechOutputMode.allCases) { speechOutputMode in
                        Text(speechOutputMode.displayLabel).tag(speechOutputMode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }

            Text(companionManager.speechOutputMode.explanation)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            switch companionManager.speechOutputMode {
            case .system:
                systemVoiceFields
            case .elevenLabs:
                elevenLabsFields
            case .openAICompatibleSpeech:
                openAICompatibleSpeechFields
            case .off:
                EmptyView()
            }

            if let speechOutputUnavailableExplanation = companionManager.speechOutputUnavailableExplanation {
                Text(speechOutputUnavailableExplanation)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if companionManager.speechOutputMode != .off {
                Button(action: { companionManager.previewCurrentVoice() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle")
                        Text("Preview voice")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .pointerCursor()
            }
        }
    }

    /// The chosen voice (or the system default) with a button that opens the
    /// voice chooser — a flat menu can't hold the dozens of installed voices.
    private var systemVoiceFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            LayerFieldLabel(text: "Voice")
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedSystemVoiceTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(selectedSystemVoiceDetail)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Button("Choose…") { isShowingSystemVoiceChooser = true }
                    .pointerCursor()
                Button("Get better voices") { SystemVoiceSettings.openVoiceDownloadSettings() }
                    .help("Premium and Enhanced voices download free in System Settings › Accessibility › Spoken Content")
                    .pointerCursor()
            }
        }
        .sheet(isPresented: $isShowingSystemVoiceChooser) {
            SystemVoiceChooserSheet(selectedVoiceIdentifier: Binding(
                get: { selectedSystemVoiceIdentifier },
                set: { newVoiceIdentifier in
                    selectedSystemVoiceIdentifier = newVoiceIdentifier
                    SystemVoiceSettings.selectedVoiceIdentifier = newVoiceIdentifier.isEmpty ? nil : newVoiceIdentifier
                }
            ))
        }
    }

    /// The chosen voice, if it's still installed.
    private var selectedSystemVoiceOption: SystemVoiceOption? {
        guard !selectedSystemVoiceIdentifier.isEmpty else { return nil }
        return SystemVoiceCatalog.voiceOption(withIdentifier: selectedSystemVoiceIdentifier)
    }

    private var selectedSystemVoiceTitle: String {
        if let selectedSystemVoiceOption {
            return selectedSystemVoiceOption.displayName
        }
        if let systemDefaultVoiceName = SystemVoiceCatalog.systemDefaultVoiceName() {
            return "System default (\(systemDefaultVoiceName))"
        }
        return "System default"
    }

    private var selectedSystemVoiceDetail: String {
        guard let selectedSystemVoiceOption else {
            return "The voice set for your language in System Settings"
        }
        if let qualityBadgeLabel = selectedSystemVoiceOption.qualityTier.badgeLabel {
            return "\(selectedSystemVoiceOption.regionDisplayName) · \(qualityBadgeLabel)"
        }
        return selectedSystemVoiceOption.regionDisplayName
    }

    private var elevenLabsFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            ServiceKeyField(
                serviceSecretAccount: .elevenLabs,
                apiKeyPageURL: URL(string: "https://elevenlabs.io/app/settings/api-keys"),
                onKeyChanged: { companionManager.objectWillChange.send() }
            )
            LayerFieldLabel(text: "Voice id")
            HStack(spacing: 6) {
                TextField(companionManager.elevenLabsVoiceIdentifier, text: $elevenLabsVoiceInput)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    companionManager.setElevenLabsVoiceIdentifier(elevenLabsVoiceInput)
                    elevenLabsVoiceInput = ""
                }
                .pointerCursor()
            }
        }
    }

    private var openAICompatibleSpeechFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            EndpointPresetButtons(
                presets: SpeechSynthesisEndpointPreset.allCases,
                title: { $0.displayName },
                onSelect: { speechSynthesisEndpointPreset in
                    speechBaseURLInput = speechSynthesisEndpointPreset.baseURL
                    speechModelInput = speechSynthesisEndpointPreset.modelName
                    speechVoiceInput = speechSynthesisEndpointPreset.voiceName
                    saveOpenAICompatibleSpeechSettings()
                }
            )

            LayerFieldLabel(text: "Endpoint, model and voice")
            TextField(SpeechSynthesisEndpointPreset.openAI.baseURL, text: $speechBaseURLInput)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                TextField("model", text: $speechModelInput)
                    .textFieldStyle(.roundedBorder)
                TextField("voice", text: $speechVoiceInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Save", action: saveOpenAICompatibleSpeechSettings)
                    .pointerCursor()
            }
            Text("Kokoro-FastAPI runs a natural voice on this Mac at http://localhost:8880/v1 with no key.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !LocalModelServerPreset.isLocalBaseURL(speechBaseURLInput) {
                ServiceKeyField(
                    serviceSecretAccount: .openAICompatibleSpeech,
                    apiKeyPageURL: SpeechSynthesisEndpointPreset.allCases.first { $0.baseURL == speechBaseURLInput }?.apiKeyPageURL,
                    onKeyChanged: { companionManager.objectWillChange.send() }
                )
            }
        }
    }

    private func saveOpenAICompatibleSpeechSettings() {
        OpenAICompatibleSpeechSettings.baseURL = speechBaseURLInput.trimmingCharacters(in: .whitespaces)
        OpenAICompatibleSpeechSettings.modelName = speechModelInput.trimmingCharacters(in: .whitespaces)
        OpenAICompatibleSpeechSettings.voiceName = speechVoiceInput.trimmingCharacters(in: .whitespaces)
        companionManager.objectWillChange.send()
    }
}

// MARK: - Push-to-talk shortcut

/// Choose the push-to-talk shortcut; shows the keys as capsules.
struct PushToTalkShortcutPicker: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Push to talk")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    HStack(spacing: 4) {
                        ForEach(companionManager.pushToTalkShortcutOption.keyCapsuleLabels, id: \.self) { keyLabel in
                            KeyCapsule(keyLabel: keyLabel)
                        }
                        Text("hold, talk, release")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            Picker("", selection: Binding(
                get: { companionManager.pushToTalkShortcutOption },
                set: { companionManager.setPushToTalkShortcutOption($0) }
            )) {
                ForEach(BuddyPushToTalkShortcut.ShortcutOption.allCases) { shortcutOption in
                    Text(shortcutOption == BuddyPushToTalkShortcut.defaultShortcutOption
                         ? "\(shortcutOption.displayText) (default)"
                         : shortcutOption.displayText)
                        .tag(shortcutOption)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }
}

/// The fixed "stop" shortcut, shown alongside push-to-talk for reference.
struct EscapeShortcutInfoRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "escape")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stop and clear")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Esc stops elfhub — listening, thinking, talking or acting — and clears the pointer and marks.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            KeyCapsule(keyLabel: "esc")
        }
        .padding(.vertical, 4)
    }
}

struct KeyCapsule: View {
    let keyLabel: String

    var body: some View {
        Text(keyLabel)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}
