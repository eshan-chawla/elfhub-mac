//
//  LanguageModelUsage.swift
//  elfhub
//
//  How many tokens elfhub's model requests used, and about what they cost,
//  for Settings › General › Usage and cost.
//
//  Every provider the app builds (`ProviderConfigurationStore.makeProvider`)
//  is wrapped in `UsageRecordingLanguageModelProvider`, so chats, screen
//  work, background tasks and the memory all count, whatever model they ran
//  on. Each response's token counts are added to daily totals per model and
//  per what the request was for (`LanguageModelUsageLedger`), priced when
//  they're recorded:
//   - from the bundled price list (`LanguageModelPrices.json`, dated, editable),
//   - or what the provider said it charged (OpenRouter),
//   - nothing for models on this Mac, nothing extra on the ChatGPT plan,
//   - and for a model without a price, tokens only — unless the user set a
//     price for it in Settings.
//
//  Only counts are kept — never what was asked or answered — in
//  ~/Library/Application Support/elfhub/Usage/, on this Mac only. The
//  estimate is no bill: the provider's own usage page is the source of truth.
//

import Combine
import Foundation

// MARK: - Prices

/// Dollars per million tokens for one rate card.
struct LanguageModelTokenPrices: Codable, Equatable {
    var input: Double
    var output: Double
    /// Writing to the prompt cache; the input price when nil.
    var cacheWrite: Double?
    /// Reading from the prompt cache; the input price when nil.
    var cacheRead: Double?

    func cost(of usage: LanguageModelUsage) -> Double {
        let tokensPerPriceUnit = 1_000_000.0
        let uncachedInputCost: Double = Double(usage.inputTokens) * input
        let cacheWriteCost: Double = Double(usage.cacheCreationInputTokens) * (cacheWrite ?? input)
        let cacheReadCost: Double = Double(usage.cacheReadInputTokens) * (cacheRead ?? input)
        let outputCost: Double = Double(usage.outputTokens) * output
        return (uncachedInputCost + cacheWriteCost + cacheReadCost + outputCost) / tokensPerPriceUnit
    }
}

/// One model's prices in the price list.
struct LanguageModelPriceListEntry: Codable, Equatable {
    /// "anthropic", "openai" or "gemini" (`LanguageModelPricing.priceListProvider`).
    var provider: String
    var model: String
    var input: Double
    var output: Double
    var cacheWrite: Double?
    var cacheRead: Double?
    /// When one request's input passes this many tokens, `longPrompt` applies.
    var longPromptAboveInputTokens: Int?
    var longPrompt: LanguageModelTokenPrices?

    var standardPrices: LanguageModelTokenPrices {
        LanguageModelTokenPrices(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }

    func prices(forRequestUsing usage: LanguageModelUsage) -> LanguageModelTokenPrices {
        if let longPromptAboveInputTokens, let longPrompt, usage.totalInputTokens > longPromptAboveInputTokens {
            return longPrompt
        }
        return standardPrices
    }
}

/// The bundled price list (`LanguageModelPrices.json`).
struct LanguageModelPriceList: Codable, Equatable {
    var pricesAsOf: String
    var webSearchDollarsPerThousand: [String: Double]
    var models: [LanguageModelPriceListEntry]

    static let bundledResourceName = "LanguageModelPrices"

    static let bundled: LanguageModelPriceList = {
        guard let priceListFileURL = Bundle.main.url(forResource: bundledResourceName, withExtension: "json"),
              let priceListFileData = try? Data(contentsOf: priceListFileURL),
              let decodedPriceList = try? JSONDecoder().decode(LanguageModelPriceList.self, from: priceListFileData) else {
            return LanguageModelPriceList(pricesAsOf: "", webSearchDollarsPerThousand: [:], models: [])
        }
        return decodedPriceList
    }()

    /// The entry for a model: its exact id, or the longest listed id it's a
    /// dated or suffixed version of ("claude-sonnet-4-5-20250929" →
    /// "claude-sonnet-4-5"; "gpt-5-mini" stays "gpt-5-mini", not "gpt-5").
    func entry(forProvider provider: String, model: String) -> LanguageModelPriceListEntry? {
        let normalizedModel = Self.normalizedModelIdentifier(model)
        return models
            .filter { $0.provider == provider }
            .filter { listedEntry in
                let listedModel = listedEntry.model.lowercased()
                return normalizedModel == listedModel
                    || normalizedModel.hasPrefix(listedModel + "-")
                    || normalizedModel.hasPrefix(listedModel + "@")
            }
            .max { $0.model.count < $1.model.count }
    }

    /// Lowercased, without Gemini's "models/" in front.
    static func normalizedModelIdentifier(_ model: String) -> String {
        var normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedModel.hasPrefix("models/") {
            normalizedModel.removeFirst("models/".count)
        }
        return normalizedModel
    }
}

/// Where a recorded cost came from.
enum LanguageModelPricingSource: String, Codable {
    /// The bundled price list.
    case priceList
    /// The provider said what it charged (OpenRouter).
    case reportedByProvider
    /// A model running on this Mac: free.
    case onThisMac
    /// Paid for by the user's ChatGPT plan: nothing extra.
    case chatGPTPlan
    /// No price known; the user can set one.
    case unknown
}

/// Prices one request.
enum LanguageModelPricing {
    /// The price list's provider name for a model, or nil when it has none.
    static func priceListProvider(
        kind: LanguageModelProviderKind,
        presetIdentifier: String?,
        baseURL: String
    ) -> String? {
        switch kind {
        case .anthropic:
            // Only the Claude API's own prices; a proxy may charge otherwise.
            return host(of: baseURL) == "api.anthropic.com" ? "anthropic" : nil
        case .gemini:
            return "gemini"
        case .openAICompatible:
            return presetIdentifier == "openai" || host(of: baseURL) == "api.openai.com" ? "openai" : nil
        case .chatGPTPlan:
            return nil
        }
    }

    /// Whether the model runs on this Mac (a local server preset, or any
    /// address on this computer).
    static func runsOnThisMac(presetIdentifier: String?, baseURL: String) -> Bool {
        if let preset = LanguageModelProviderCatalog.preset(withIdentifier: presetIdentifier), preset.category == .onThisMac {
            return true
        }
        guard let host = host(of: baseURL) else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".local")
    }

    static func host(of baseURL: String) -> String? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
    }

    /// What one request cost and how that was decided.
    static func cost(
        of usage: LanguageModelUsage,
        webSearchCount: Int,
        kind: LanguageModelProviderKind,
        presetIdentifier: String?,
        baseURL: String,
        model: String,
        priceList: LanguageModelPriceList
    ) -> (costInDollars: Double, source: LanguageModelPricingSource) {
        if kind == .chatGPTPlan {
            return (0, .chatGPTPlan)
        }
        if kind == .openAICompatible, runsOnThisMac(presetIdentifier: presetIdentifier, baseURL: baseURL) {
            return (0, .onThisMac)
        }
        if let reportedCostInDollars = usage.reportedCostInDollars {
            return (reportedCostInDollars, .reportedByProvider)
        }
        guard let provider = priceListProvider(kind: kind, presetIdentifier: presetIdentifier, baseURL: baseURL),
              let priceListEntry = priceList.entry(forProvider: provider, model: model) else {
            return (0, .unknown)
        }
        let tokenCost = priceListEntry.prices(forRequestUsing: usage).cost(of: usage)
        let webSearchCost = Double(webSearchCount) * (priceList.webSearchDollarsPerThousand[provider] ?? 0) / 1000
        return (tokenCost + webSearchCost, .priceList)
    }
}

// MARK: - Prices the user set

/// Prices the user gave models the price list doesn't have, by model key.
enum LanguageModelUserPrices {
    static let userDefaultsKey = "languageModelUserPricesByModelKey"

    static func all(in userDefaults: UserDefaults = .standard) -> [String: LanguageModelTokenPrices] {
        guard let storedData = userDefaults.data(forKey: userDefaultsKey),
              let decodedPrices = try? JSONDecoder().decode([String: LanguageModelTokenPrices].self, from: storedData) else {
            return [:]
        }
        return decodedPrices
    }

    static func setPrices(_ prices: LanguageModelTokenPrices?, forModelKey modelKey: String, in userDefaults: UserDefaults = .standard) {
        var allPrices = all(in: userDefaults)
        allPrices[modelKey] = prices
        if let encodedPrices = try? JSONEncoder().encode(allPrices) {
            userDefaults.set(encodedPrices, forKey: userDefaultsKey)
        }
    }
}

// MARK: - Totals

/// Token counts and cost added up.
struct LanguageModelUsageTotals: Codable, Equatable {
    var requests = 0
    /// Requests whose provider sent no token counts (some local servers).
    var requestsWithoutTokenCounts = 0
    var inputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var outputTokens = 0
    var webSearches = 0
    /// Estimated dollars, for the requests that had a price.
    var costInDollars = 0.0

    var totalTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens }
    var totalInputTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }

    /// The share of input read from the prompt cache (0…1), or nil with no input.
    var cachedInputShare: Double? {
        totalInputTokens > 0 ? Double(cacheReadTokens) / Double(totalInputTokens) : nil
    }

    mutating func add(_ otherTotals: LanguageModelUsageTotals) {
        requests += otherTotals.requests
        requestsWithoutTokenCounts += otherTotals.requestsWithoutTokenCounts
        inputTokens += otherTotals.inputTokens
        cacheWriteTokens += otherTotals.cacheWriteTokens
        cacheReadTokens += otherTotals.cacheReadTokens
        outputTokens += otherTotals.outputTokens
        webSearches += otherTotals.webSearches
        costInDollars += otherTotals.costInDollars
    }
}

/// One day's usage of one model for one kind of request.
struct LanguageModelUsageEntry: Codable, Equatable {
    /// The local day, "yyyy-MM-dd".
    var day: String
    /// Which model: kind, preset and model id (`LanguageModelUsageLedger.modelKey`).
    var modelKey: String
    var modelName: String
    var providerName: String
    var category: LanguageModelUsageCategory
    var pricingSource: LanguageModelPricingSource
    var totals: LanguageModelUsageTotals
}

/// The periods the card can show.
enum LanguageModelUsagePeriod: String, CaseIterable, Identifiable {
    case today
    case lastSevenDays
    case lastThirtyDays
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .lastSevenDays: return "7 days"
        case .lastThirtyDays: return "30 days"
        case .allTime: return "All time"
        }
    }

    /// The first day included, or nil for all time.
    func firstDay(endingOn today: Date, calendar: Calendar = .current) -> String? {
        let daysBack: Int
        switch self {
        case .today: daysBack = 0
        case .lastSevenDays: daysBack = 6
        case .lastThirtyDays: daysBack = 29
        case .allTime: return nil
        }
        let startOfToday = calendar.startOfDay(for: today)
        let firstDate = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
        return LanguageModelUsageLedger.dayString(for: firstDate, calendar: calendar)
    }
}

/// A period's usage, added up overall, per model and per kind of request.
struct LanguageModelUsageSummary: Equatable {
    struct ModelRow: Equatable, Identifiable {
        var modelKey: String
        var modelName: String
        var providerName: String
        var pricingSource: LanguageModelPricingSource
        var totals: LanguageModelUsageTotals
        /// No price for some of its requests (and none set by the user).
        var hasUnpricedRequests: Bool
        var id: String { modelKey }
    }

    var totals = LanguageModelUsageTotals()
    var models: [ModelRow] = []
    var categories: [(category: LanguageModelUsageCategory, totals: LanguageModelUsageTotals)] = []
    /// Tokens from requests with no price, so the cost leaves them out.
    var unpricedTokens = 0

    static func == (lhs: LanguageModelUsageSummary, rhs: LanguageModelUsageSummary) -> Bool {
        lhs.totals == rhs.totals && lhs.models == rhs.models && lhs.unpricedTokens == rhs.unpricedTokens
            && lhs.categories.map(\.category) == rhs.categories.map(\.category)
            && lhs.categories.map(\.totals) == rhs.categories.map(\.totals)
    }

    /// Adds up entries. Requests without a price use the price the user
    /// set for that model, when there is one.
    static func summarizing(
        _ entries: [LanguageModelUsageEntry],
        userPricesByModelKey: [String: LanguageModelTokenPrices]
    ) -> LanguageModelUsageSummary {
        var summary = LanguageModelUsageSummary()
        var modelRowsByKey: [String: ModelRow] = [:]
        var totalsByCategory: [LanguageModelUsageCategory: LanguageModelUsageTotals] = [:]

        for entry in entries {
            var entryTotals = entry.totals
            var entryIsUnpriced = false
            if entry.pricingSource == .unknown {
                if let userPrices = userPricesByModelKey[entry.modelKey] {
                    entryTotals.costInDollars = userPrices.cost(of: LanguageModelUsage(
                        inputTokens: entryTotals.inputTokens,
                        outputTokens: entryTotals.outputTokens,
                        cacheReadInputTokens: entryTotals.cacheReadTokens,
                        cacheCreationInputTokens: entryTotals.cacheWriteTokens
                    ))
                } else {
                    entryIsUnpriced = true
                    summary.unpricedTokens += entryTotals.totalTokens
                }
            }

            summary.totals.add(entryTotals)
            totalsByCategory[entry.category, default: LanguageModelUsageTotals()].add(entryTotals)

            var modelRow = modelRowsByKey[entry.modelKey] ?? ModelRow(
                modelKey: entry.modelKey,
                modelName: entry.modelName,
                providerName: entry.providerName,
                pricingSource: entry.pricingSource,
                totals: LanguageModelUsageTotals(),
                hasUnpricedRequests: false
            )
            modelRow.totals.add(entryTotals)
            modelRow.hasUnpricedRequests = modelRow.hasUnpricedRequests || entryIsUnpriced
            // A model priced from the list on one day stays "list" priced.
            if modelRow.pricingSource == .unknown { modelRow.pricingSource = entry.pricingSource }
            modelRowsByKey[entry.modelKey] = modelRow
        }

        summary.models = modelRowsByKey.values.sorted { firstRow, secondRow in
            if firstRow.totals.costInDollars != secondRow.totals.costInDollars {
                return firstRow.totals.costInDollars > secondRow.totals.costInDollars
            }
            return firstRow.totals.totalTokens > secondRow.totals.totalTokens
        }
        summary.categories = LanguageModelUsageCategory.allCases.compactMap { category in
            totalsByCategory[category].map { (category: category, totals: $0) }
        }
        return summary
    }
}

// MARK: - The ledger

/// Daily usage totals, saved on this Mac.
@MainActor
final class LanguageModelUsageLedger: ObservableObject {
    /// The app's ledger; the unit-test host gets a throwaway folder so test
    /// runs never touch the real file.
    static let shared = LanguageModelUsageLedger(storageDirectoryURL: defaultStorageDirectoryURL)

    static let storageFileName = "language-model-usage.json"
    /// Saved this long after the last request, so a burst writes once.
    static let saveDelaySeconds = 2.0

    @Published private(set) var entries: [LanguageModelUsageEntry] = []

    private let storageFileURL: URL
    private let priceList: LanguageModelPriceList
    private var pendingSaveTask: Task<Void, Never>?

    static var defaultStorageDirectoryURL: URL {
        if CompanionManager.isRunningUnitTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("elfhub-tests-usage-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportDirectoryURL
            .appendingPathComponent("elfhub", isDirectory: true)
            .appendingPathComponent("Usage", isDirectory: true)
    }

    init(storageDirectoryURL: URL, priceList: LanguageModelPriceList = .bundled) {
        self.storageFileURL = storageDirectoryURL.appendingPathComponent(Self.storageFileName)
        self.priceList = priceList
        if let storedData = try? Data(contentsOf: storageFileURL),
           let storedLedgerFile = try? JSONDecoder().decode(StoredLedgerFile.self, from: storedData) {
            entries = storedLedgerFile.entries
        }
    }

    private struct StoredLedgerFile: Codable {
        var version = 1
        var entries: [LanguageModelUsageEntry]
    }

    var pricesAsOf: String { priceList.pricesAsOf }

    /// Which model, as one string: kind, preset and model id.
    static func modelKey(kind: LanguageModelProviderKind, presetIdentifier: String?, model: String) -> String {
        [kind.rawValue, presetIdentifier ?? "custom", LanguageModelPriceList.normalizedModelIdentifier(model)].joined(separator: "|")
    }

    static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", dateComponents.year ?? 0, dateComponents.month ?? 0, dateComponents.day ?? 0)
    }

    /// Adds one response to today's totals for its model and kind.
    func record(
        usage: LanguageModelUsage?,
        webSearchCount: Int,
        configuration: ProviderConfiguration,
        category: LanguageModelUsageCategory,
        date: Date = Date()
    ) {
        let reportedUsage = usage ?? LanguageModelUsage()
        let pricedRequest = LanguageModelPricing.cost(
            of: reportedUsage,
            webSearchCount: webSearchCount,
            kind: configuration.kind,
            presetIdentifier: configuration.presetIdentifier,
            baseURL: configuration.baseURL,
            model: configuration.model,
            priceList: priceList
        )
        var requestTotals = LanguageModelUsageTotals()
        requestTotals.requests = 1
        requestTotals.requestsWithoutTokenCounts = usage == nil ? 1 : 0
        requestTotals.inputTokens = reportedUsage.inputTokens
        requestTotals.cacheWriteTokens = reportedUsage.cacheCreationInputTokens
        requestTotals.cacheReadTokens = reportedUsage.cacheReadInputTokens
        requestTotals.outputTokens = reportedUsage.outputTokens
        requestTotals.webSearches = webSearchCount
        requestTotals.costInDollars = pricedRequest.costInDollars

        let day = Self.dayString(for: date)
        let modelKey = Self.modelKey(kind: configuration.kind, presetIdentifier: configuration.presetIdentifier, model: configuration.model)
        if let existingIndex = entries.firstIndex(where: {
            $0.day == day && $0.modelKey == modelKey && $0.category == category && $0.pricingSource == pricedRequest.source
        }) {
            entries[existingIndex].totals.add(requestTotals)
        } else {
            entries.append(LanguageModelUsageEntry(
                day: day,
                modelKey: modelKey,
                modelName: configuration.model.isEmpty ? configuration.displayName : configuration.model,
                providerName: Self.providerName(for: configuration),
                category: category,
                pricingSource: pricedRequest.source,
                totals: requestTotals
            ))
        }
        scheduleSave()
    }

    static func providerName(for configuration: ProviderConfiguration) -> String {
        if configuration.kind == .chatGPTPlan { return "ChatGPT plan" }
        if let preset = LanguageModelProviderCatalog.preset(withIdentifier: configuration.presetIdentifier) {
            return preset.displayName
        }
        return configuration.displayName
    }

    func summary(for period: LanguageModelUsagePeriod, today: Date = Date(), userPricesByModelKey: [String: LanguageModelTokenPrices]) -> LanguageModelUsageSummary {
        let firstDay = period.firstDay(endingOn: today)
        let entriesInPeriod = entries.filter { entry in
            guard let firstDay else { return true }
            return entry.day >= firstDay
        }
        return LanguageModelUsageSummary.summarizing(entriesInPeriod, userPricesByModelKey: userPricesByModelKey)
    }

    func resetUsage() {
        entries = []
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        try? FileManager.default.removeItem(at: storageFileURL)
    }

    private func scheduleSave() {
        guard pendingSaveTask == nil else { return }
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.saveDelaySeconds))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the file at once (also used by tests).
    func saveNow() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard let encodedData = try? JSONEncoder().encode(StoredLedgerFile(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: storageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encodedData.write(to: storageFileURL, options: .atomic)
    }
}

// MARK: - Recording every request

/// Wraps a provider so each response's tokens go into the ledger. Behaves
/// exactly like the provider it wraps; a failed request records nothing.
final class UsageRecordingLanguageModelProvider: LanguageModelProvider {
    let wrappedProvider: LanguageModelProvider
    private let configuration: ProviderConfiguration
    private let usageLedger: LanguageModelUsageLedger

    init(wrapping wrappedProvider: LanguageModelProvider, configuration: ProviderConfiguration, usageLedger: LanguageModelUsageLedger) {
        self.wrappedProvider = wrappedProvider
        self.configuration = configuration
        self.usageLedger = usageLedger
    }

    var displayName: String { wrappedProvider.displayName }
    var capabilities: LanguageModelCapabilities { wrappedProvider.capabilities }
    var supportsProviderWebSearch: Bool { wrappedProvider.supportsProviderWebSearch }
    var supportsAnthropicComputerToolset: Bool { wrappedProvider.supportsAnthropicComputerToolset }

    func streamResponse(
        _ request: LanguageModelRequest,
        onStreamEvent: @MainActor @Sendable (LanguageModelStreamEvent) -> Void
    ) async throws -> LanguageModelResponse {
        let response = try await wrappedProvider.streamResponse(request, onStreamEvent: onStreamEvent)
        usageLedger.record(
            usage: response.usage,
            webSearchCount: response.providerWebSearchCount,
            configuration: configuration,
            category: request.usageCategory
        )
        return response
    }
}
