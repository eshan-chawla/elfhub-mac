//
//  OnDeviceVoiceModelViews.swift
//  elfhub
//
//  The "On-device model" choice in the speech-to-text and voice layers
//  (Settings › Models and onboarding): this Mac's chip and memory, the
//  recommended models for it (the best fit first), download with progress
//  and Cancel, Use, Delete, a voice picker for voice models, and any other
//  Hugging Face model by pasting its name. Downloads are anonymous and go
//  to Application Support/elfhub/VoiceModels.
//

import SwiftUI

struct OnDeviceVoiceModelSection: View {
    let kind: OnDeviceVoiceModelKind
    /// Called after a different model is chosen (the layer reloads).
    var onActiveModelChanged: () -> Void = {}

    @ObservedObject private var store = OnDeviceVoiceModelLayers.shared.store
    @State private var pastedRepositoryText = ""
    @State private var isCheckingRepository = false
    @State private var repositoryCheck: OnDeviceVoiceModelRepositoryCheck?
    @State private var repositoryCheckMessage: String?
    /// The download waiting for "Delete" to be confirmed.
    @State private var repositoryIdentifierPendingDeletion: String?

    private let computeProfile = OnDeviceComputeProfile.current

    private var recommendedModels: [RecommendedOnDeviceVoiceModel] {
        let bestPickIdentifier = OnDeviceVoiceModelCatalog.bestPick(for: computeProfile.computeTier, kind: kind)?.id
        return OnDeviceVoiceModelCatalog.recommendedModels(ofKind: kind).sorted { firstModel, secondModel in
            (firstModel.id == bestPickIdentifier ? 0 : 1) < (secondModel.id == bestPickIdentifier ? 0 : 1)
        }
    }

    /// Installed models of this kind that aren't in the catalog (pasted ones).
    private var otherInstalledModels: [InstalledOnDeviceVoiceModel] {
        store.installedModels(ofKind: kind).filter { OnDeviceVoiceModelCatalog.recommendedModel(withIdentifier: $0.id) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac: \(computeProfile.summary). Models run on its GPU; nothing you say leaves it.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if store.activeModelIdentifier(forKind: kind) == nil {
                Text(kind == .speechToText
                     ? "Until you choose one, push-to-talk uses Apple's on-device speech recognition."
                     : "Until you choose one, your Elf speaks with Apple's on-device voice.")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(recommendedModels) { recommendedModel in
                modelRow(
                    repositoryIdentifier: recommendedModel.id,
                    displayName: recommendedModel.displayName,
                    detailLines: detailLines(for: recommendedModel),
                    isBestPick: recommendedModel.id == OnDeviceVoiceModelCatalog.bestPick(for: computeProfile.computeTier, kind: kind)?.id,
                    isTooBigForThisMac: !computeProfile.canComfortablyRun(recommendedMemoryInGigabytes: recommendedModel.recommendedMemoryInGigabytes)
                )
            }
            ForEach(otherInstalledModels) { installedModel in
                modelRow(
                    repositoryIdentifier: installedModel.id,
                    displayName: installedModel.displayName,
                    detailLines: [installedModel.id],
                    isBestPick: false,
                    isTooBigForThisMac: false
                )
            }

            if kind == .textToSpeech,
               let activeModelIdentifier = store.activeTextToSpeechModelIdentifier,
               store.isInstalled(activeModelIdentifier) {
                voicePicker(forModelIdentifier: activeModelIdentifier)
            }

            otherModelField

            Button(action: { store.revealStorageInFinder() }) {
                Text("Show downloaded models in Finder")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .confirmationDialog(
            "Delete this download?",
            isPresented: Binding(
                get: { repositoryIdentifierPendingDeletion != nil },
                set: { isPresented in if !isPresented { repositoryIdentifierPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let repositoryIdentifierPendingDeletion {
                    delete(repositoryIdentifierPendingDeletion)
                }
                repositoryIdentifierPendingDeletion = nil
            }
        } message: {
            Text(repositoryIdentifierPendingDeletion.map { store.activeModelIdentifier(forKind: kind) == $0 } == true
                 ? "It's the one in use, so elfhub goes back to Apple's on-device \(kind == .speechToText ? "speech recognition" : "voice"). You'd need to download it again."
                 : "You'd need to download it again to use it.")
        }
    }

    private func detailLines(for recommendedModel: RecommendedOnDeviceVoiceModel) -> [String] {
        var detailLines = [recommendedModel.summary]
        var sizeAndLicense = String(format: "%.1f GB · %@ · %@", recommendedModel.approximateDownloadSizeInGigabytes, recommendedModel.languagesSummary, recommendedModel.licenseName)
        if let creditLine = recommendedModel.creditLine {
            sizeAndLicense += " · " + creditLine
        }
        detailLines.append(sizeAndLicense)
        return detailLines
    }

    @ViewBuilder
    private func modelRow(
        repositoryIdentifier: String,
        displayName: String,
        detailLines: [String],
        isBestPick: Bool,
        isTooBigForThisMac: Bool
    ) -> some View {
        let isInstalled = store.isInstalled(repositoryIdentifier)
        let isActive = store.activeModelIdentifier(forKind: kind) == repositoryIdentifier
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(DS.Typography.interface(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        if isBestPick {
                            Text("Recommended for this Mac")
                                .font(DS.Typography.interface(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.accent)
                        }
                    }
                    ForEach(detailLines, id: \.self) { detailLine in
                        Text(detailLine)
                            .font(DS.Typography.interface(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isTooBigForThisMac {
                        Text("Needs more memory than this Mac has to run comfortably.")
                            .font(DS.Typography.interface(size: 11))
                            .foregroundColor(DS.Colors.warning)
                    }
                }
                Spacer()
                modelRowControls(repositoryIdentifier: repositoryIdentifier, displayName: displayName, isInstalled: isInstalled, isActive: isActive)
            }
            if let downloadProgress = store.downloadProgressByRepositoryIdentifier[repositoryIdentifier] {
                ProgressView(value: downloadProgress.fractionCompleted)
                    .progressViewStyle(.linear)
            }
            if let downloadErrorMessage = store.downloadErrorMessageByRepositoryIdentifier[repositoryIdentifier] {
                Text(downloadErrorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The same wash as the active on-device language model's row.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? DS.Colors.contrastTint.opacity(0.08) : Color.clear)
        )
    }

    @ViewBuilder
    private func modelRowControls(repositoryIdentifier: String, displayName: String, isInstalled: Bool, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            if store.isDownloading(repositoryIdentifier) {
                Button("Cancel") { store.cancelDownload(repositoryIdentifier) }
                    .pointerCursor()
            } else if isInstalled {
                if isActive {
                    InUseBadge()
                } else {
                    Button("Use") { choose(repositoryIdentifier) }
                        .pointerCursor()
                }
                Button(action: { repositoryIdentifierPendingDeletion = repositoryIdentifier }) {
                    Image(systemName: "trash")
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Delete this download")
            } else {
                Button(store.activeModelIdentifier(forKind: kind) == nil ? "Download & use" : "Download") {
                    let usesWhenDownloaded = store.activeModelIdentifier(forKind: kind) == nil
                    store.download(repositoryIdentifier: repositoryIdentifier, kind: kind, displayName: displayName) {
                        if usesWhenDownloaded { choose(repositoryIdentifier) }
                    }
                }
                .pointerCursor()
            }
        }
    }

    private func choose(_ repositoryIdentifier: String) {
        store.setActiveModel(repositoryIdentifier, kind: kind)
        // Loading the new model replaces the one that was in use.
        OnDeviceVoiceModelLayers.shared.prepareActiveModel(kind: kind)
        onActiveModelChanged()
    }

    private func delete(_ repositoryIdentifier: String) {
        let wasActive = store.activeModelIdentifier(forKind: kind) == repositoryIdentifier
        store.delete(repositoryIdentifier)
        if wasActive {
            // Its weights leave memory too.
            OnDeviceVoiceModelLayers.shared.unloadModel(kind: kind)
            onActiveModelChanged()
        }
    }

    private func voicePicker(forModelIdentifier modelIdentifier: String) -> some View {
        let availableVoices = store.availableVoices(forModelIdentifier: modelIdentifier)
        return Group {
            if !availableVoices.isEmpty {
                HStack {
                    Text("Voice")
                        .font(DS.Typography.interface(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("Voice", selection: Binding(
                        get: { store.voiceIdentifier(forModelIdentifier: modelIdentifier) ?? availableVoices[0].id },
                        set: { store.setVoiceIdentifier($0, forModelIdentifier: modelIdentifier) }
                    )) {
                        // The clearest voices first, then a divider and the rest.
                        let featuredVoiceIdentifiers = Set(OnDeviceVoiceModelCatalog.featuredVoiceIdentifiers(forModelIdentifier: modelIdentifier))
                        let featuredVoices = availableVoices.filter { featuredVoiceIdentifiers.contains($0.id) }
                        let otherVoices = availableVoices.filter { !featuredVoiceIdentifiers.contains($0.id) }
                        ForEach(featuredVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                        if !featuredVoices.isEmpty && !otherVoices.isEmpty {
                            Divider()
                        }
                        ForEach(otherVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .pointerCursor()
                }
            }
        }
    }

    private var otherModelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Another Hugging Face model, like mlx-community/…", text: $pastedRepositoryText)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.interface(size: 12))
                    .onSubmit(checkPastedRepository)
                Button(isCheckingRepository ? "Checking…" : "Check", action: checkPastedRepository)
                    .disabled(isCheckingRepository || pastedRepositoryText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .pointerCursor()
            }
            if let repositoryCheck {
                HStack {
                    Text(String(format: "%@ · about %.1f GB", repositoryCheck.repositoryIdentifier, Double(repositoryCheck.approximateDownloadSizeInBytes) / 1_000_000_000))
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Button("Download") {
                        let repositoryIdentifier = repositoryCheck.repositoryIdentifier
                        store.download(
                            repositoryIdentifier: repositoryIdentifier,
                            kind: kind,
                            displayName: repositoryIdentifier.components(separatedBy: "/").last ?? repositoryIdentifier
                        )
                        self.repositoryCheck = nil
                        pastedRepositoryText = ""
                    }
                    .pointerCursor()
                }
            }
            if let repositoryCheckMessage {
                Text(repositoryCheckMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkPastedRepository() {
        let pastedText = pastedRepositoryText
        guard !pastedText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isCheckingRepository = true
        repositoryCheck = nil
        repositoryCheckMessage = nil
        Task { @MainActor in
            do {
                repositoryCheck = try await store.checkRepository(pastedText: pastedText)
            } catch {
                repositoryCheckMessage = error.localizedDescription
            }
            isCheckingRepository = false
        }
    }
}
