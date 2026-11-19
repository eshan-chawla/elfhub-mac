//
//  ProviderSettingsView.swift
//  elfhub
//
//  The language-model layer: the user's configured models, which one is
//  active, and adding/editing them. Adding starts from a catalog preset
//  (LanguageModelProviderCatalog) so most providers need only a key and a
//  model pick; "Detect models" lists what the account or local server has,
//  and "Test connection" sends a tiny real request. Base URL, wire format,
//  tool calling and coordinates stay under "Advanced". Keys are written to
//  the Keychain via the store and never shown back.
//
//  Embedded in onboarding and in the main window's Models section.
//

import AppKit
import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var store: ProviderConfigurationStore
    /// When set, the preset picker first offers only these cloud providers
    /// (onboarding keeps the first choice short) with "More providers…" to
    /// show the full list; nil shows every preset.
    var featuredPresetIdentifiers: [String]? = nil

    /// The four cloud providers onboarding offers first.
    static let onboardingFeaturedPresetIdentifiers = ["anthropic", "openai", "gemini", "openrouter"]

    /// The config currently being added/edited, or nil when just listing.
    @State private var editingDraft: ProviderConfiguration?
    @State private var editingKeyInput: String = ""
    @State private var isEditingExisting = false
    @State private var isShowingPresetPicker = false
    @State private var isShowingAdvancedOptions = false
    @State private var detectedModelIdentifiers: [String] = []
    @State private var connectionStatusMessage: String?
    @State private var isCheckingConnection = false
    @State private var isShowingEveryPreset = false
    /// The model waiting for "Remove" to be confirmed (it also deletes its key).
    @State private var configurationPendingRemoval: ProviderConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let editingDraft {
                editorForm(draft: editingDraft)
            } else {
                configuredModelList
                if isShowingPresetPicker || store.configurations.isEmpty {
                    presetPicker
                } else {
                    addModelButton
                }
            }
        }
        .confirmationDialog(
            "Remove \(configurationPendingRemoval?.displayName ?? "this model")?",
            isPresented: Binding(
                get: { configurationPendingRemoval != nil },
                set: { isPresented in if !isPresented { configurationPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive) {
                if let configurationPendingRemoval {
                    store.delete(id: configurationPendingRemoval.id)
                }
                configurationPendingRemoval = nil
            }
        } message: {
            Text(configurationPendingRemoval?.id == store.activeConfigurationID
                 ? "Its saved key is deleted too, and your Elf switches to another model."
                 : "Its saved key is deleted too.")
        }
    }

    // MARK: - Configured models

    @ViewBuilder
    private var configuredModelList: some View {
        if !store.configurations.isEmpty {
            VStack(spacing: 6) {
                ForEach(store.configurations) { configuration in
                    configuredModelRow(configuration)
                }
            }
        }
    }

    private func configuredModelRow(_ configuration: ProviderConfiguration) -> some View {
        let isActive = configuration.id == store.activeConfigurationID
        let isReady = store.isReady(configuration)
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(DS.Typography.interface(size: 14))
                .foregroundColor(isActive ? DS.Colors.accent : DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.displayName)
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(configuration.model.isEmpty ? "no model picked" : configuration.model)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(configuration.runsLocally ? "on this Mac" : "cloud")
                }
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer(minLength: 4)

            if isActive {
                InUseBadge()
            }

            capabilityBadge(
                text: configuration.supportsVision ? "sees screen" : "text only",
                color: configuration.supportsVision ? DS.Colors.success : DS.Colors.textTertiary
            )

            if !isReady {
                capabilityBadge(text: notReadyBadgeText(for: configuration), color: DS.Colors.warning)
            }

            // The ChatGPT plan is set up on its own card above, not here.
            if configuration.kind != .chatGPTPlan {
                Button(action: { startEditing(configuration) }) {
                    Image(systemName: "pencil").foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Edit")
                .pointerCursor()
            }

            Button(action: { configurationPendingRemoval = configuration }) {
                Image(systemName: "trash").foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .pointerCursor()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.contrastTint.opacity(isActive ? 0.08 : 0.03))
        )
        // The model in use gets a blue edge, so it stands out from a glance
        // rather than only by its radio dot.
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DS.Colors.accent, lineWidth: isActive ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.setActiveConfiguration(id: configuration.id) }
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Use this model") { store.setActiveConfiguration(id: configuration.id) }
        .pointerCursor()
    }

    private func notReadyBadgeText(for configuration: ProviderConfiguration) -> String {
        if configuration.model.isEmpty { return "pick a model" }
        return configuration.kind == .chatGPTPlan ? "needs sign-in" : "needs key"
    }

    private func capabilityBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(DS.Typography.interface(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var addModelButton: some View {
        Button(action: { isShowingPresetPicker = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("Add a model")
            }
            .font(DS.Typography.interface(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.accentText)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Preset picker

    @ViewBuilder
    private var presetPicker: some View {
        if let featuredPresetIdentifiers, !isShowingEveryPreset {
            featuredPresetPicker(featuredPresetIdentifiers: featuredPresetIdentifiers)
        } else {
            everyPresetPicker
        }
    }

    /// A short first choice: a few cloud providers, then "More providers…".
    private func featuredPresetPicker(featuredPresetIdentifiers: [String]) -> some View {
        let featuredPresets = featuredPresetIdentifiers.compactMap { LanguageModelProviderCatalog.preset(withIdentifier: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(featuredPresets) { preset in
                    presetButton(title: preset.displayName) {
                        startAdding(preset.makeConfiguration())
                    }
                }
            }
            Button("More providers…") { isShowingEveryPreset = true }
                .dsGhostButtonStyle(size: .small)
        }
    }

    private var everyPresetPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(LanguageModelProviderPresetCategory.allCases) { presetCategory in
                VStack(alignment: .leading, spacing: 6) {
                    Text(presetCategory.displayTitle)
                        .dsLabelStyle()
                        .foregroundColor(DS.Colors.textTertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(LanguageModelProviderCatalog.presets(in: presetCategory)) { preset in
                            presetButton(title: preset.displayName) {
                                startAdding(preset.makeConfiguration())
                            }
                        }
                        if presetCategory == .cloudAPI {
                            presetButton(title: "Other endpoint…") {
                                startAdding(LanguageModelProviderCatalog.customOpenAICompatibleConfiguration())
                                isShowingAdvancedOptions = true
                            }
                        }
                    }
                }
            }

            if !store.configurations.isEmpty {
                Button("Cancel") { isShowingPresetPicker = false }
                    .pointerCursor()
            }
        }
    }

    private func presetButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.contrastTint.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Editor

    private func editorForm(draft: ProviderConfiguration) -> some View {
        let preset = LanguageModelProviderCatalog.preset(withIdentifier: draft.presetIdentifier)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isEditingExisting ? "Edit \(draft.displayName)" : "Add \(preset?.displayName ?? "a model")")
                    .font(DS.Typography.interface(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if let apiKeyPageURL = preset?.apiKeyPageURL {
                    Button(action: { NSWorkspace.shared.open(apiKeyPageURL) }) {
                        HStack(spacing: 3) {
                            Text("Get an API key")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                    .help("Opens the provider's key page in your browser")
                    .pointerCursor()
                }
            }

            if let setupHint = preset?.setupHint {
                Text(setupHint)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if draft.requiresAPIKey {
                labeledField("API key") {
                    SecureField(hasStoredKey(for: draft) ? "•••••• saved — leave blank to keep" : "paste your key",
                                text: $editingKeyInput)
                        .textFieldStyle(.roundedBorder)
                }
            }

            labeledField("Model") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("model id", text: bindingForModel())
                            .textFieldStyle(.roundedBorder)
                        Button(isCheckingConnection ? "Looking…" : "Detect models", action: detectModels)
                            .disabled(isCheckingConnection || draft.baseURL.isEmpty)
                            .pointerCursor(isEnabled: !isCheckingConnection && !draft.baseURL.isEmpty)
                            .help("List the models your key or server has")
                    }
                    if !detectedModelIdentifiers.isEmpty {
                        Picker("", selection: bindingForModel()) {
                            ForEach(detectedModelIdentifiers, id: \.self) { modelIdentifier in
                                Text(modelIdentifier).tag(modelIdentifier)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .pointerCursor()
                    }
                }
            }

            Toggle(isOn: bindingForVision()) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Model can see images (multimodal)")
                        .font(DS.Typography.interface(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("On: elfhub shares your screen when you ask, and can point and act. Off: voice and chat only.")
                        .font(DS.Typography.interface(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(DS.Colors.controlTint)
            .pointerCursor()

            DisclosureGroup(isExpanded: $isShowingAdvancedOptions) {
                advancedOptions(draft: draft)
                    .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .pointerCursor()

            HStack(spacing: 8) {
                Button(isCheckingConnection ? "Testing…" : "Test connection", action: testConnection)
                    .disabled(isCheckingConnection || draft.model.isEmpty)
                    .pointerCursor(isEnabled: !isCheckingConnection && !draft.model.isEmpty)
                if let connectionStatusMessage {
                    Text(connectionStatusMessage)
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 10) {
                Button(action: saveDraft) {
                    Text("Save")
                        .font(DS.Typography.interface(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: cancelEditing) {
                    Text("Cancel")
                        .font(DS.Typography.interface(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.contrastTint.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.top, 4)
        }
    }

    private func advancedOptions(draft: ProviderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Name") {
                TextField("My model", text: bindingForName())
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("API format") {
                Picker("", selection: bindingForKind()) {
                    // The ChatGPT plan isn't an API format you can point at
                    // another endpoint; it's set up with its own sign-in.
                    ForEach(LanguageModelProviderKind.allCases.filter { $0 != .chatGPTPlan }) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .pointerCursor()
            }

            labeledField("Base URL") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(draft.kind.exampleBaseURL, text: bindingForBaseURL())
                        .textFieldStyle(.roundedBorder)
                    Text(draft.kind.exampleBaseURL)
                        .font(DS.Typography.interface(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Toggle(isOn: bindingForToolCalling()) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use tool calling for pointing and actions")
                        .font(DS.Typography.interface(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("off = the model writes short text tags instead (works with every model)")
                        .font(DS.Typography.interface(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .tint(DS.Colors.controlTint)
            .pointerCursor()

            if draft.kind != .anthropic {
                labeledField("Screen coordinates") {
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("", selection: bindingForCoordinateConvention()) {
                            ForEach(ModelCoordinateConvention.allCases) { coordinateConvention in
                                Text(coordinateConvention.displayLabel).tag(coordinateConvention)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .pointerCursor()
                        Text("How this model names screen positions. Gemini uses 0–999; Qwen3-VL uses 0–1000; most others use pixels.")
                            .font(DS.Typography.interface(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DS.Typography.interface(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }

    // MARK: - Editing actions

    private func startAdding(_ newConfiguration: ProviderConfiguration) {
        editingDraft = newConfiguration
        editingKeyInput = ""
        isEditingExisting = false
        isShowingPresetPicker = false
        isShowingAdvancedOptions = newConfiguration.presetIdentifier == nil
        resetConnectionState()
    }

    private func startEditing(_ configuration: ProviderConfiguration) {
        editingDraft = configuration
        editingKeyInput = ""
        isEditingExisting = true
        isShowingAdvancedOptions = false
        resetConnectionState()
    }

    private func cancelEditing() {
        editingDraft = nil
        editingKeyInput = ""
        resetConnectionState()
    }

    private func resetConnectionState() {
        detectedModelIdentifiers = []
        connectionStatusMessage = nil
        isCheckingConnection = false
    }

    /// The key to use for detect/test: what's typed now, else what's stored.
    private func effectiveAPIKey(for draft: ProviderConfiguration) -> String? {
        editingKeyInput.isEmpty ? store.apiKey(forProviderID: draft.id) : editingKeyInput
    }

    private func detectModels() {
        guard let draft = editingDraft else { return }
        isCheckingConnection = true
        connectionStatusMessage = "Looking for models…"
        Task { @MainActor in
            do {
                let modelIdentifiers = try await LocalModelServerDiscovery.listModelIdentifiers(
                    for: draft,
                    apiKey: effectiveAPIKey(for: draft)
                )
                detectedModelIdentifiers = modelIdentifiers
                if editingDraft?.model.isEmpty == true, let firstModelIdentifier = modelIdentifiers.first {
                    editingDraft?.model = firstModelIdentifier
                }
                connectionStatusMessage = modelIdentifiers.isEmpty
                    ? "Connected, but no models were listed."
                    : (modelIdentifiers.count == 1 ? "Found 1 model." : "Found \(modelIdentifiers.count) models.")
            } catch let LanguageModelProviderError.httpError(statusCode, _) where statusCode == 401 || statusCode == 403 {
                connectionStatusMessage = "The key was rejected. Check it and try again."
            } catch {
                connectionStatusMessage = draft.runsLocally
                    ? "Couldn't reach the server. Is it running?"
                    : "Couldn't list models: \(error.localizedDescription.prefix(100))"
            }
            isCheckingConnection = false
        }
    }

    private func testConnection() {
        guard let draft = editingDraft else { return }
        isCheckingConnection = true
        connectionStatusMessage = nil
        Task { @MainActor in
            do {
                let reply = try await LocalModelServerDiscovery.testConnection(
                    configuration: draft,
                    apiKey: effectiveAPIKey(for: draft)
                )
                connectionStatusMessage = "Works. The model replied: \"\(reply.prefix(40))\""
            } catch {
                connectionStatusMessage = "Failed: \(error.localizedDescription.prefix(120))"
            }
            isCheckingConnection = false
        }
    }

    private func saveDraft() {
        guard let editingDraft else { return }
        // Pass nil to keep an existing key when the field was left blank.
        let keyToStore: String? = editingKeyInput.isEmpty ? (isEditingExisting ? nil : "") : editingKeyInput
        store.upsert(editingDraft, apiKey: keyToStore)
        // Newly added providers become active for convenience.
        if !isEditingExisting {
            store.setActiveConfiguration(id: editingDraft.id)
        }
        self.editingDraft = nil
        editingKeyInput = ""
    }

    private func hasStoredKey(for configuration: ProviderConfiguration) -> Bool {
        store.apiKey(forProviderID: configuration.id)?.isEmpty == false
    }

    // MARK: - Bindings into the draft

    private func bindingForKind() -> Binding<LanguageModelProviderKind> {
        Binding(get: { editingDraft?.kind ?? .openAICompatible },
                set: { newKind in
                    editingDraft?.kind = newKind
                    editingDraft?.coordinateConvention = newKind.defaultCoordinateConvention
                    editingDraft?.supportsToolCalling = newKind.defaultSupportsToolCalling
                })
    }
    private func bindingForName() -> Binding<String> {
        Binding(get: { editingDraft?.displayName ?? "" }, set: { editingDraft?.displayName = $0 })
    }
    private func bindingForBaseURL() -> Binding<String> {
        Binding(get: { editingDraft?.baseURL ?? "" }, set: { editingDraft?.baseURL = $0 })
    }
    private func bindingForModel() -> Binding<String> {
        Binding(get: { editingDraft?.model ?? "" }, set: { editingDraft?.model = $0 })
    }
    private func bindingForVision() -> Binding<Bool> {
        Binding(get: { editingDraft?.supportsVision ?? true }, set: { editingDraft?.supportsVision = $0 })
    }
    private func bindingForToolCalling() -> Binding<Bool> {
        Binding(get: { editingDraft?.supportsToolCalling ?? false }, set: { editingDraft?.supportsToolCalling = $0 })
    }
    private func bindingForCoordinateConvention() -> Binding<ModelCoordinateConvention> {
        Binding(get: { editingDraft?.coordinateConvention ?? .imagePixels }, set: { editingDraft?.coordinateConvention = $0 })
    }
}
