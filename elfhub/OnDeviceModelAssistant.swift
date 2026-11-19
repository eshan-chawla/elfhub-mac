//
//  OnDeviceModelAssistant.swift
//  elfhub
//
//  Helps the user run models entirely on this Mac:
//   - Language models through Ollama's local API (http://localhost:11434):
//     detect whether Ollama is installed / running, list installed models,
//     download recommended or custom models with live progress, delete them,
//     and turn one into the active model in a click.
//   - Apple's on-device speech-recognition model (macOS 26+), which can be
//     downloaded ahead of the first push-to-talk.
//  elfhub itself only ever talks to localhost here; Ollama does the download.
//

import AppKit
import Combine
import Foundation
import Speech

// MARK: - Catalog

/// A model the assistant suggests downloading through Ollama.
struct RecommendedOnDeviceModel: Identifiable, Equatable {
    /// The Ollama model tag, e.g. "qwen3-vl:8b".
    let id: String
    let displayName: String
    let approximateDownloadSizeInGigabytes: Double
    /// Roughly how much memory the Mac needs to run it comfortably.
    let recommendedMemoryInGigabytes: Int
    /// Whether the model accepts images, so elfhub can show it your screen.
    let seesScreen: Bool
    let coordinateConvention: ModelCoordinateConvention
    let summary: String
}

enum OnDeviceModelCatalog {
    static let recommendedLanguageModels: [RecommendedOnDeviceModel] = [
        RecommendedOnDeviceModel(
            id: "qwen3-vl:8b",
            displayName: "Qwen3-VL 8B",
            approximateDownloadSizeInGigabytes: 6.1,
            recommendedMemoryInGigabytes: 16,
            seesScreen: true,
            coordinateConvention: .normalizedTo1000,
            summary: "Best for pointing at things on screen."
        ),
        RecommendedOnDeviceModel(
            id: "qwen2.5vl:7b",
            displayName: "Qwen2.5-VL 7B",
            approximateDownloadSizeInGigabytes: 6.0,
            recommendedMemoryInGigabytes: 16,
            seesScreen: true,
            coordinateConvention: .imagePixels,
            summary: "Strong screen understanding and pointing."
        ),
        RecommendedOnDeviceModel(
            id: "gemma3:4b",
            displayName: "Gemma 3 4B",
            approximateDownloadSizeInGigabytes: 3.3,
            recommendedMemoryInGigabytes: 8,
            seesScreen: true,
            coordinateConvention: .imagePixels,
            summary: "Small and quick. Sees your screen; pointing is rough."
        ),
        RecommendedOnDeviceModel(
            id: "gemma3:12b",
            displayName: "Gemma 3 12B",
            approximateDownloadSizeInGigabytes: 8.1,
            recommendedMemoryInGigabytes: 24,
            seesScreen: true,
            coordinateConvention: .imagePixels,
            summary: "Better answers about what's on screen, needs more memory."
        ),
        RecommendedOnDeviceModel(
            id: "llama3.2:3b",
            displayName: "Llama 3.2 3B (text only)",
            approximateDownloadSizeInGigabytes: 2.0,
            recommendedMemoryInGigabytes: 8,
            seesScreen: false,
            coordinateConvention: .imagePixels,
            summary: "Fast voice and chat answers; can't see your screen."
        ),
    ]

    static func recommendedModel(forModelName modelName: String) -> RecommendedOnDeviceModel? {
        recommendedLanguageModels.first { $0.id == modelName }
    }

    /// This Mac's memory, for flagging models that would run poorly.
    static var installedMemoryInGigabytes: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}

// MARK: - Ollama wire format

struct OllamaInstalledModel: Identifiable, Equatable {
    let name: String
    let sizeInBytes: Int64
    let parameterSize: String?

    var id: String { name }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}

/// What the assistant knows about the local Ollama install.
enum OllamaServerStatus: Equatable {
    case checking
    case notInstalled
    case installedButNotRunning
    case running(version: String)
}

/// Live progress of one `ollama pull`.
struct OllamaDownloadProgress: Equatable {
    var statusText: String
    var completedBytes: Int64
    var totalBytes: Int64

    var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

/// Folds Ollama's streamed pull messages into one progress value. A model
/// downloads as several layers (each with its own digest, total and
/// completed); overall progress is the sum across layers.
struct OllamaPullProgressAccumulator {
    private var totalBytesByLayerDigest: [String: Int64] = [:]
    private var completedBytesByLayerDigest: [String: Int64] = [:]
    private(set) var latestStatusText = "Starting download…"
    private(set) var didSucceed = false
    private(set) var errorMessage: String?

    /// Applies one NDJSON line from POST /api/pull.
    mutating func apply(pullResponseLine: String) {
        guard let lineData = pullResponseLine.data(using: .utf8),
              let pullMessage = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }
        if let pullErrorMessage = pullMessage["error"] as? String {
            errorMessage = pullErrorMessage
            return
        }
        if let statusText = pullMessage["status"] as? String {
            latestStatusText = statusText
            if statusText == "success" {
                didSucceed = true
            }
        }
        if let layerDigest = pullMessage["digest"] as? String {
            if let layerTotalBytes = (pullMessage["total"] as? NSNumber)?.int64Value {
                totalBytesByLayerDigest[layerDigest] = layerTotalBytes
            }
            if let layerCompletedBytes = (pullMessage["completed"] as? NSNumber)?.int64Value {
                completedBytesByLayerDigest[layerDigest] = layerCompletedBytes
            }
        }
    }

    var progress: OllamaDownloadProgress {
        OllamaDownloadProgress(
            statusText: Self.friendlyStatusText(for: latestStatusText),
            completedBytes: completedBytesByLayerDigest.values.reduce(0, +),
            totalBytes: totalBytesByLayerDigest.values.reduce(0, +)
        )
    }

    /// Ollama reports "pulling 6a0746a1ec1a"; show something readable.
    static func friendlyStatusText(for ollamaStatusText: String) -> String {
        if ollamaStatusText.hasPrefix("pulling manifest") { return "Preparing…" }
        if ollamaStatusText.hasPrefix("pulling") { return "Downloading…" }
        if ollamaStatusText.hasPrefix("verifying") { return "Verifying…" }
        if ollamaStatusText.hasPrefix("writing") { return "Finishing…" }
        if ollamaStatusText == "success" { return "Downloaded" }
        return ollamaStatusText.prefix(1).uppercased() + ollamaStatusText.dropFirst()
    }
}

enum OllamaWireFormat {
    /// Parses GET /api/tags.
    static func parseInstalledModels(fromTagsResponse responseData: Data) -> [OllamaInstalledModel] {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let modelEntries = json["models"] as? [[String: Any]] else {
            return []
        }
        return modelEntries.compactMap { modelEntry in
            guard let modelName = (modelEntry["name"] as? String) ?? (modelEntry["model"] as? String) else { return nil }
            let modelDetails = modelEntry["details"] as? [String: Any]
            return OllamaInstalledModel(
                name: modelName,
                sizeInBytes: (modelEntry["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: modelDetails?["parameter_size"] as? String
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Parses POST /api/show's "capabilities" (e.g. ["completion","vision","tools"]).
    static func parseCapabilities(fromShowResponse responseData: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let capabilities = json["capabilities"] as? [String] else {
            return []
        }
        return Set(capabilities)
    }

    /// Ollama names untagged models "name:latest"; treat both as the same.
    static func modelNamesMatch(_ firstModelName: String, _ secondModelName: String) -> Bool {
        func normalizedModelName(_ modelName: String) -> String {
            modelName.contains(":") ? modelName : modelName + ":latest"
        }
        return normalizedModelName(firstModelName) == normalizedModelName(secondModelName)
    }
}

// MARK: - Assistant

@MainActor
final class OnDeviceModelAssistant: ObservableObject {
    @Published private(set) var ollamaServerStatus: OllamaServerStatus = .checking
    @Published private(set) var installedLanguageModels: [OllamaInstalledModel] = []
    /// In-flight downloads keyed by model name.
    @Published private(set) var activeDownloadProgressByModelName: [String: OllamaDownloadProgress] = [:]
    @Published private(set) var lastProblemDescription: String?

    /// Apple's on-device speech model (macOS 26+).
    @Published private(set) var appleSpeechModelStatus: AppleSpeechModelStatus = .checking
    @Published private(set) var appleSpeechModelDownloadFraction: Double?

    private static let ollamaBaseURL = URL(string: "http://localhost:11434")!
    private static let ollamaApplicationURL = URL(fileURLWithPath: "/Applications/Ollama.app")
    static let ollamaDownloadPageURL = URL(string: "https://ollama.com/download")!

    private var downloadTasksByModelName: [String: Task<Void, Never>] = [:]
    private var ollamaStartupPollingTask: Task<Void, Never>?

    // MARK: Ollama status

    func refresh() async {
        await refreshOllamaStatus()
        await refreshAppleSpeechModelStatus()
    }

    func refreshOllamaStatus() async {
        if let ollamaVersion = await fetchOllamaVersion() {
            ollamaServerStatus = .running(version: ollamaVersion)
            await refreshInstalledLanguageModels()
        } else {
            installedLanguageModels = []
            ollamaServerStatus = Self.isOllamaApplicationInstalled ? .installedButNotRunning : .notInstalled
        }
    }

    private static var isOllamaApplicationInstalled: Bool {
        FileManager.default.fileExists(atPath: ollamaApplicationURL.path)
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") != nil
    }

    private func fetchOllamaVersion() async -> String? {
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return json["version"] as? String ?? "unknown"
    }

    func refreshInstalledLanguageModels() async {
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 4
        guard let (responseData, _) = try? await URLSession.shared.data(for: request) else { return }
        installedLanguageModels = OllamaWireFormat.parseInstalledModels(fromTagsResponse: responseData)
    }

    func isInstalled(modelName: String) -> Bool {
        installedLanguageModels.contains { OllamaWireFormat.modelNamesMatch($0.name, modelName) }
    }

    /// Opens Ollama.app and waits (briefly) for its server to come up.
    func startOllama() {
        NSWorkspace.shared.openApplication(at: Self.ollamaApplicationURL, configuration: NSWorkspace.OpenConfiguration())
        ollamaStartupPollingTask?.cancel()
        ollamaStartupPollingTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.refreshOllamaStatus()
                if case .running = self.ollamaServerStatus { return }
            }
        }
    }

    /// Ollama is installed by the user from its website, in their browser.
    func openOllamaDownloadPage() {
        NSWorkspace.shared.open(Self.ollamaDownloadPageURL)
    }

    // MARK: Downloads

    func downloadLanguageModel(named modelName: String) {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty, downloadTasksByModelName[trimmedModelName] == nil else { return }
        lastProblemDescription = nil
        activeDownloadProgressByModelName[trimmedModelName] = OllamaDownloadProgress(
            statusText: "Starting download…",
            completedBytes: 0,
            totalBytes: 0
        )

        downloadTasksByModelName[trimmedModelName] = Task { [weak self] in
            await self?.performDownload(ofModelNamed: trimmedModelName)
        }
    }

    func cancelDownload(ofModelNamed modelName: String) {
        downloadTasksByModelName[modelName]?.cancel()
        downloadTasksByModelName[modelName] = nil
        activeDownloadProgressByModelName[modelName] = nil
    }

    private func performDownload(ofModelNamed modelName: String) async {
        defer {
            downloadTasksByModelName[modelName] = nil
            activeDownloadProgressByModelName[modelName] = nil
        }
        do {
            var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/pull"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Large models can take a long time; progress lines keep arriving.
            request.timeoutInterval = 60 * 60
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelName, "stream": true])

            let (responseLines, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                lastProblemDescription = "Ollama couldn't start downloading \(modelName)."
                return
            }

            var pullProgressAccumulator = OllamaPullProgressAccumulator()
            for try await pullResponseLine in responseLines.lines {
                pullProgressAccumulator.apply(pullResponseLine: pullResponseLine)
                if let pullErrorMessage = pullProgressAccumulator.errorMessage {
                    lastProblemDescription = "Couldn't download \(modelName): \(pullErrorMessage)"
                    return
                }
                activeDownloadProgressByModelName[modelName] = pullProgressAccumulator.progress
            }
            if !pullProgressAccumulator.didSucceed && !Task.isCancelled {
                lastProblemDescription = "The download of \(modelName) stopped before it finished."
            }
        } catch is CancellationError {
            // The user cancelled; nothing to report.
        } catch {
            if !Task.isCancelled {
                lastProblemDescription = "Couldn't download \(modelName): \(error.localizedDescription)"
            }
        }
        await refreshInstalledLanguageModels()
    }

    func deleteLanguageModel(named modelName: String) {
        Task {
            var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/delete"))
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelName])
            _ = try? await URLSession.shared.data(for: request)
            await refreshInstalledLanguageModels()
        }
    }

    // MARK: Using a model

    /// Makes an installed Ollama model the active language model, reusing an
    /// existing Ollama configuration for it when there is one.
    func useLanguageModel(named modelName: String, in providerConfigurationStore: ProviderConfigurationStore) async {
        let modelCapabilities = await fetchCapabilities(ofModelNamed: modelName)
        let recommendedModel = OnDeviceModelCatalog.recommendedModel(forModelName: modelName)
        let seesScreen = modelCapabilities.isEmpty
            ? (recommendedModel?.seesScreen ?? true)
            : modelCapabilities.contains("vision")

        if let existingConfiguration = providerConfigurationStore.configurations.first(where: { configuration in
            configuration.presetIdentifier == LocalModelServerPreset.ollama.rawValue
                && OllamaWireFormat.modelNamesMatch(configuration.model, modelName)
        }) {
            providerConfigurationStore.setActiveConfiguration(id: existingConfiguration.id)
            return
        }

        var ollamaConfiguration = ProviderConfiguration.localServer(.ollama)
        ollamaConfiguration.displayName = "\(recommendedModel?.displayName ?? modelName) (Ollama)"
        ollamaConfiguration.model = modelName
        ollamaConfiguration.supportsVision = seesScreen
        ollamaConfiguration.coordinateConvention = recommendedModel?.coordinateConvention ?? .imagePixels
        ollamaConfiguration.supportsToolCalling = modelCapabilities.contains("tools")
        providerConfigurationStore.upsert(ollamaConfiguration, apiKey: "")
        providerConfigurationStore.setActiveConfiguration(id: ollamaConfiguration.id)
    }

    private func fetchCapabilities(ofModelNamed modelName: String) async -> Set<String> {
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelName])
        guard let (responseData, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return OllamaWireFormat.parseCapabilities(fromShowResponse: responseData)
    }

    // MARK: Apple on-device speech model

    enum AppleSpeechModelStatus: Equatable {
        case checking
        /// macOS before 26 uses the older built-in recognizer; nothing to download.
        case builtIn
        case unsupportedLanguage
        case notDownloaded
        case downloading
        case installed
    }

    func refreshAppleSpeechModelStatus() async {
        guard #available(macOS 26, *) else {
            appleSpeechModelStatus = .builtIn
            return
        }
        appleSpeechModelStatus = await AppleOnDeviceSpeechModelInstaller.currentStatus()
    }

    func downloadAppleSpeechModel() {
        guard #available(macOS 26, *) else { return }
        appleSpeechModelStatus = .downloading
        appleSpeechModelDownloadFraction = 0
        Task { [weak self] in
            do {
                try await AppleOnDeviceSpeechModelInstaller.install { fractionCompleted in
                    Task { @MainActor [weak self] in
                        self?.appleSpeechModelDownloadFraction = fractionCompleted
                    }
                }
            } catch {
                self?.lastProblemDescription = "Couldn't download Apple's speech model: \(error.localizedDescription)"
            }
            self?.appleSpeechModelDownloadFraction = nil
            await self?.refreshAppleSpeechModelStatus()
        }
    }
}

/// Downloads Apple's SpeechTranscriber model for the user's language ahead of
/// the first push-to-talk (otherwise it downloads on first use).
@available(macOS 26, *)
enum AppleOnDeviceSpeechModelInstaller {
    private static func makeSpeechTranscriber() async -> SpeechTranscriber? {
        guard let transcriptionLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.autoupdatingCurrent) else {
            return nil
        }
        return SpeechTranscriber(locale: transcriptionLocale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    static func currentStatus() async -> OnDeviceModelAssistant.AppleSpeechModelStatus {
        guard let speechTranscriber = await makeSpeechTranscriber() else { return .unsupportedLanguage }
        switch await AssetInventory.status(forModules: [speechTranscriber]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notDownloaded
        case .unsupported: return .unsupportedLanguage
        @unknown default: return .notDownloaded
        }
    }

    static func install(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let speechTranscriber = await makeSpeechTranscriber() else { return }
        guard let assetInstallationRequest = try await AssetInventory.assetInstallationRequest(supporting: [speechTranscriber]) else {
            return
        }
        let downloadProgress = assetInstallationRequest.progress
        let progressObservation = downloadProgress.observe(\.fractionCompleted) { observedProgress, _ in
            onProgress(observedProgress.fractionCompleted)
        }
        defer { progressObservation.invalidate() }
        try await assetInstallationRequest.downloadAndInstall()
    }
}
