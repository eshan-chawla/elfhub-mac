//
//  OnDeviceVoiceModelStore.swift
//  elfhub
//
//  Downloads, lists and deletes the speech-to-text and voice models elfhub
//  runs on this Mac, and remembers which one each layer uses.
//
//  Models come from Hugging Face only when the user presses Download, and
//  without any Hugging Face account or token (a token on this Mac is never
//  read). They're stored in ~/Library/Application Support/elfhub/VoiceModels
//  in the layout mlx-audio-swift expects (`mlx-audio/<owner>_<name>`), so the
//  engine loads them from there without going online again.
//

import AppKit
import Combine
import Foundation
import HuggingFace
import MLXAudioCore

/// A model downloaded to this Mac.
struct InstalledOnDeviceVoiceModel: Identifiable, Codable, Equatable {
    /// Hugging Face repo id.
    let id: String
    let kind: OnDeviceVoiceModelKind
    let displayName: String
}

/// What checking a pasted Hugging Face repo found, before downloading it.
struct OnDeviceVoiceModelRepositoryCheck: Equatable {
    let repositoryIdentifier: String
    let approximateDownloadSizeInBytes: Int64
}

enum OnDeviceVoiceModelStoreError: LocalizedError {
    case notARepository
    case needsHuggingFaceAccount
    case noMLXWeights

    var errorDescription: String? {
        switch self {
        case .notARepository:
            return "That isn't a Hugging Face model. Paste it as owner/name, or the model's huggingface.co link."
        case .needsHuggingFaceAccount:
            return "This model needs a Hugging Face account to download. elfhub only downloads public models."
        case .noMLXWeights:
            return "This repo has no MLX weights (.safetensors files), so elfhub can't run it."
        }
    }
}

@MainActor
final class OnDeviceVoiceModelStore: ObservableObject {
    struct DownloadProgress: Equatable {
        /// 0…1, from Hugging Face's file progress.
        var fractionCompleted: Double
    }

    @Published private(set) var installedModels: [InstalledOnDeviceVoiceModel] = []
    /// Downloads in progress, by repo id.
    @Published private(set) var downloadProgressByRepositoryIdentifier: [String: DownloadProgress] = [:]
    /// The last failure per repo id, shown next to it until it's tried again.
    @Published private(set) var downloadErrorMessageByRepositoryIdentifier: [String: String] = [:]
    @Published private(set) var activeSpeechToTextModelIdentifier: String?
    @Published private(set) var activeTextToSpeechModelIdentifier: String?
    /// The voice picked for each text-to-speech model, by repo id.
    @Published private(set) var selectedVoiceIdentifierByModelIdentifier: [String: String] = [:]

    let storageDirectory: URL
    private let userDefaults: UserDefaults
    private var downloadTasksByRepositoryIdentifier: [String: Task<Void, Never>] = [:]

    private static let activeSpeechToTextModelKey = "onDeviceSpeechToTextModelIdentifier"
    private static let activeTextToSpeechModelKey = "onDeviceTextToSpeechModelIdentifier"
    private static let selectedVoicesKey = "onDeviceTextToSpeechVoiceIdentifiers"
    private static let installedModelsFileName = "installed-models.json"

    nonisolated static var defaultStorageDirectory: URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportDirectory
            .appendingPathComponent("elfhub", isDirectory: true)
            .appendingPathComponent("VoiceModels", isDirectory: true)
    }

    init(storageDirectory: URL = OnDeviceVoiceModelStore.defaultStorageDirectory, userDefaults: UserDefaults = .standard) {
        self.storageDirectory = storageDirectory
        self.userDefaults = userDefaults
        activeSpeechToTextModelIdentifier = userDefaults.string(forKey: Self.activeSpeechToTextModelKey)
        activeTextToSpeechModelIdentifier = userDefaults.string(forKey: Self.activeTextToSpeechModelKey)
        selectedVoiceIdentifierByModelIdentifier = userDefaults.dictionary(forKey: Self.selectedVoicesKey) as? [String: String] ?? [:]
        reloadInstalledModels()
    }

    /// Where the engine keeps downloads (its Hugging Face cache root).
    var hubCache: HubCache {
        HubCache(cacheDirectory: storageDirectory)
    }

    /// A Hugging Face client that never sends a token.
    private func makeAnonymousHubClient() -> HubClient {
        HubClient(host: HubClient.defaultHost, bearerToken: nil, cache: hubCache)
    }

    /// The folder the engine loads a model from.
    func modelDirectory(forRepositoryIdentifier repositoryIdentifier: String) -> URL {
        storageDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(repositoryIdentifier.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    // MARK: Installed models

    func isInstalled(_ repositoryIdentifier: String) -> Bool {
        installedModels.contains { $0.id == repositoryIdentifier }
    }

    func installedModels(ofKind kind: OnDeviceVoiceModelKind) -> [InstalledOnDeviceVoiceModel] {
        installedModels.filter { $0.kind == kind }
    }

    /// Reads the list of downloads, dropping any whose folder is gone.
    func reloadInstalledModels() {
        let installedModelsFileURL = storageDirectory.appendingPathComponent(Self.installedModelsFileName)
        let savedModels = (try? Data(contentsOf: installedModelsFileURL))
            .flatMap { try? JSONDecoder().decode([InstalledOnDeviceVoiceModel].self, from: $0) } ?? []
        var reloadedModels = savedModels.filter { installedModel in
            FileManager.default.fileExists(atPath: modelDirectory(forRepositoryIdentifier: installedModel.id).path)
        }
        // A recommended model can be on disk without being in the list (its
        // download finished but the list wasn't saved, or mlx-audio-swift's
        // own tools fetched it into this folder): count it once it's complete.
        for recommendedModel in OnDeviceVoiceModelCatalog.recommendedModels
        where !reloadedModels.contains(where: { $0.id == recommendedModel.id })
            && Self.looksLikeCompleteDownload(modelDirectory(forRepositoryIdentifier: recommendedModel.id)) {
            reloadedModels.append(InstalledOnDeviceVoiceModel(
                id: recommendedModel.id,
                kind: recommendedModel.kind,
                displayName: recommendedModel.displayName
            ))
        }
        installedModels = reloadedModels
        if activeSpeechToTextModelIdentifier.map(isInstalled) == false {
            setActiveModel(nil, kind: .speechToText)
        }
        if activeTextToSpeechModelIdentifier.map(isInstalled) == false {
            setActiveModel(nil, kind: .textToSpeech)
        }
    }

    /// The engine's own completeness marks: its snapshot manifest and a
    /// non-empty weights file.
    private static func looksLikeCompleteDownload(_ modelDirectory: URL) -> Bool {
        let snapshotManifestURL = modelDirectory.appendingPathComponent(".mlx-audio-snapshot.json")
        guard FileManager.default.fileExists(atPath: snapshotManifestURL.path),
              let directoryFiles = try? FileManager.default.contentsOfDirectory(
                at: modelDirectory,
                includingPropertiesForKeys: [.fileSizeKey]
              ) else { return false }
        return directoryFiles.contains { fileURL in
            fileURL.pathExtension == "safetensors"
                && ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
    }

    private func saveInstalledModels() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let installedModelsFileURL = storageDirectory.appendingPathComponent(Self.installedModelsFileName)
        if let encodedModels = try? JSONEncoder().encode(installedModels) {
            try? encodedModels.write(to: installedModelsFileURL, options: .atomic)
        }
    }

    /// Disk space a downloaded model takes.
    func sizeOnDiskInBytes(ofRepositoryIdentifier repositoryIdentifier: String) -> Int64 {
        Self.allocatedSizeInBytes(ofDirectory: modelDirectory(forRepositoryIdentifier: repositoryIdentifier))
    }

    var totalSizeOnDiskInBytes: Int64 {
        installedModels.reduce(0) { $0 + sizeOnDiskInBytes(ofRepositoryIdentifier: $1.id) }
    }

    private static func allocatedSizeInBytes(ofDirectory directoryURL: URL) -> Int64 {
        guard let directoryEnumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var totalBytes: Int64 = 0
        for case let fileURL as URL in directoryEnumerator {
            let fileBytes = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            totalBytes += Int64(fileBytes)
        }
        return totalBytes
    }

    // MARK: Active models and voices

    func activeModelIdentifier(forKind kind: OnDeviceVoiceModelKind) -> String? {
        switch kind {
        case .speechToText: return activeSpeechToTextModelIdentifier
        case .textToSpeech: return activeTextToSpeechModelIdentifier
        }
    }

    func setActiveModel(_ repositoryIdentifier: String?, kind: OnDeviceVoiceModelKind) {
        switch kind {
        case .speechToText:
            activeSpeechToTextModelIdentifier = repositoryIdentifier
            userDefaults.set(repositoryIdentifier, forKey: Self.activeSpeechToTextModelKey)
        case .textToSpeech:
            activeTextToSpeechModelIdentifier = repositoryIdentifier
            userDefaults.set(repositoryIdentifier, forKey: Self.activeTextToSpeechModelKey)
        }
    }

    func availableVoices(forModelIdentifier repositoryIdentifier: String) -> [OnDeviceModelVoice] {
        OnDeviceVoiceModelCatalog.voices(
            inModelDirectory: modelDirectory(forRepositoryIdentifier: repositoryIdentifier),
            repositoryIdentifier: repositoryIdentifier
        )
    }

    /// The voice to speak with: the user's pick, else the catalog's default,
    /// else the model's first voice; nil lets the model use its own default.
    func voiceIdentifier(forModelIdentifier repositoryIdentifier: String) -> String? {
        let availableVoiceIdentifiers = availableVoices(forModelIdentifier: repositoryIdentifier).map(\.id)
        if let selectedVoiceIdentifier = selectedVoiceIdentifierByModelIdentifier[repositoryIdentifier],
           availableVoiceIdentifiers.isEmpty || availableVoiceIdentifiers.contains(selectedVoiceIdentifier) {
            return selectedVoiceIdentifier
        }
        if let catalogDefaultVoice = OnDeviceVoiceModelCatalog.recommendedModel(withIdentifier: repositoryIdentifier)?.defaultVoiceIdentifier,
           availableVoiceIdentifiers.isEmpty || availableVoiceIdentifiers.contains(catalogDefaultVoice) {
            return catalogDefaultVoice
        }
        return availableVoiceIdentifiers.first
    }

    func setVoiceIdentifier(_ voiceIdentifier: String, forModelIdentifier repositoryIdentifier: String) {
        selectedVoiceIdentifierByModelIdentifier[repositoryIdentifier] = voiceIdentifier
        userDefaults.set(selectedVoiceIdentifierByModelIdentifier, forKey: Self.selectedVoicesKey)
    }

    // MARK: Downloading

    func isDownloading(_ repositoryIdentifier: String) -> Bool {
        downloadProgressByRepositoryIdentifier[repositoryIdentifier] != nil
    }

    /// Downloads a model in the background. `onFinished` runs on success
    /// (e.g. "Download & use" switches the layer to it then).
    func download(
        repositoryIdentifier: String,
        kind: OnDeviceVoiceModelKind,
        displayName: String,
        onFinished: (() -> Void)? = nil
    ) {
        guard !isDownloading(repositoryIdentifier) else { return }
        guard let repositoryID = Repo.ID(rawValue: repositoryIdentifier) else {
            downloadErrorMessageByRepositoryIdentifier[repositoryIdentifier] = OnDeviceVoiceModelStoreError.notARepository.localizedDescription
            return
        }
        downloadErrorMessageByRepositoryIdentifier[repositoryIdentifier] = nil
        downloadProgressByRepositoryIdentifier[repositoryIdentifier] = DownloadProgress(fractionCompleted: 0)

        let hubClient = makeAnonymousHubClient()
        let hubCache = self.hubCache
        downloadTasksByRepositoryIdentifier[repositoryIdentifier] = Task { [weak self] in
            do {
                _ = try await ModelUtils.resolveOrDownloadModel(
                    client: hubClient,
                    cache: hubCache,
                    repoID: repositoryID,
                    requiredExtension: "safetensors",
                    additionalMatchingPatterns: OnDeviceVoiceModelCatalog.additionalDownloadPatterns,
                    progressHandler: { [weak self] downloadProgress in
                        guard self?.downloadProgressByRepositoryIdentifier[repositoryIdentifier] != nil else { return }
                        self?.downloadProgressByRepositoryIdentifier[repositoryIdentifier] =
                            DownloadProgress(fractionCompleted: downloadProgress.fractionCompleted)
                    }
                )
                guard let self else { return }
                self.finishDownload(repositoryIdentifier)
                if !self.isInstalled(repositoryIdentifier) {
                    self.installedModels.append(
                        InstalledOnDeviceVoiceModel(id: repositoryIdentifier, kind: kind, displayName: displayName)
                    )
                    self.saveInstalledModels()
                }
                onFinished?()
            } catch is CancellationError {
                self?.finishDownload(repositoryIdentifier)
                self?.removeDownloadedFiles(ofRepositoryIdentifier: repositoryIdentifier)
            } catch {
                guard let self else { return }
                self.finishDownload(repositoryIdentifier)
                self.downloadErrorMessageByRepositoryIdentifier[repositoryIdentifier] = Self.readableMessage(for: error)
            }
        }
    }

    func cancelDownload(_ repositoryIdentifier: String) {
        downloadTasksByRepositoryIdentifier[repositoryIdentifier]?.cancel()
    }

    private func finishDownload(_ repositoryIdentifier: String) {
        downloadTasksByRepositoryIdentifier[repositoryIdentifier] = nil
        downloadProgressByRepositoryIdentifier[repositoryIdentifier] = nil
    }

    /// Deletes a downloaded model; a layer using it goes back to no model.
    func delete(_ repositoryIdentifier: String) {
        cancelDownload(repositoryIdentifier)
        removeDownloadedFiles(ofRepositoryIdentifier: repositoryIdentifier)
        installedModels.removeAll { $0.id == repositoryIdentifier }
        saveInstalledModels()
        for kind in OnDeviceVoiceModelKind.allCases where activeModelIdentifier(forKind: kind) == repositoryIdentifier {
            setActiveModel(nil, kind: kind)
        }
    }

    /// The model folder and the Hugging Face cache copy of the repo (APFS
    /// clones share space, but both must go to free it).
    private func removeDownloadedFiles(ofRepositoryIdentifier repositoryIdentifier: String) {
        try? FileManager.default.removeItem(at: modelDirectory(forRepositoryIdentifier: repositoryIdentifier))
        if let repositoryID = Repo.ID(rawValue: repositoryIdentifier) {
            try? FileManager.default.removeItem(at: hubCache.repoDirectory(repo: repositoryID, kind: .model))
        }
    }

    func revealStorageInFinder() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([storageDirectory])
    }

    // MARK: Checking a pasted repo

    /// Looks a repo up on Hugging Face (public models only) and estimates
    /// what downloading it would fetch. Whether the engine can run it is
    /// known once it's loaded: unsupported models show a clear error then.
    func checkRepository(pastedText: String) async throws -> OnDeviceVoiceModelRepositoryCheck {
        guard let repositoryIdentifier = OnDeviceVoiceModelCatalog.normalizedRepositoryIdentifier(from: pastedText),
              let repositoryID = Repo.ID(rawValue: repositoryIdentifier) else {
            throw OnDeviceVoiceModelStoreError.notARepository
        }
        let modelInfo: Model
        do {
            modelInfo = try await makeAnonymousHubClient().getModel(repositoryID, filesMetadata: true)
        } catch {
            throw OnDeviceVoiceModelStoreError.needsHuggingFaceAccount
        }
        if let gatedMode = modelInfo.gated, gatedMode != .notGated {
            throw OnDeviceVoiceModelStoreError.needsHuggingFaceAccount
        }
        let repositoryFiles = modelInfo.siblings ?? []
        guard repositoryFiles.contains(where: { $0.relativeFilename.hasSuffix(".safetensors") }) else {
            throw OnDeviceVoiceModelStoreError.noMLXWeights
        }
        let downloadedFileExtensions = ["safetensors", "json", "txt", "wav", "model", "vocab", "tiktoken"]
        let approximateDownloadSizeInBytes = repositoryFiles
            .filter { repositoryFile in
                downloadedFileExtensions.contains((repositoryFile.relativeFilename as NSString).pathExtension.lowercased())
            }
            .reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        return OnDeviceVoiceModelRepositoryCheck(
            repositoryIdentifier: repositoryIdentifier,
            approximateDownloadSizeInBytes: approximateDownloadSizeInBytes
        )
    }

    private static func readableMessage(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "You're offline. Connect to the internet to download models."
        }
        return "Download failed: \(error.localizedDescription)"
    }
}
