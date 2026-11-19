//
//  LanguageModelUsageTests.swift
//  elfhubTests
//
//  Usage and cost: every provider's token counts read the same way (cached
//  input counted apart), the price list found and applied (cache rates,
//  long prompts, web searches), free and plan models, unknown models with a
//  price the user set, daily totals per model and kind of work, periods,
//  saving and resetting — and the test host never writes the real file.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct LanguageModelUsageTests {

    private func temporaryLedger(priceList: LanguageModelPriceList = .bundled) -> (LanguageModelUsageLedger, URL) {
        let storageDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("elfhub-usage-tests-\(UUID().uuidString)")
        return (LanguageModelUsageLedger(storageDirectoryURL: storageDirectoryURL, priceList: priceList), storageDirectoryURL)
    }

    private func configuration(
        kind: LanguageModelProviderKind,
        baseURL: String,
        model: String,
        presetIdentifier: String?
    ) -> ProviderConfiguration {
        ProviderConfiguration(kind: kind, displayName: model, baseURL: baseURL, model: model, supportsVision: true, presetIdentifier: presetIdentifier)
    }

    private var claudeOpus: ProviderConfiguration {
        configuration(kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", presetIdentifier: "anthropic")
    }

    // MARK: - Reading each provider's counts

    @Test func openAICompatibleStreamsReportUsageInTheirLastChunkWithCachedInputApart() {
        var accumulator = OpenAIStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#)
        _ = accumulator.consume(sseLine: #"data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":800}}}"#)
        #expect(accumulator.accumulatedText == "hi")
        #expect(accumulator.usage == LanguageModelUsage(inputTokens: 200, outputTokens: 50, cacheReadInputTokens: 800))
    }

    @Test func openRouterSaysWhatItCharged() {
        let usage = OpenAIStreamAccumulator.usage(fromUsageJSON: ["prompt_tokens": 100, "completion_tokens": 10, "cost": 0.0042])
        #expect(usage.reportedCostInDollars == 0.0042)
    }

    @Test func onlyKnownServersAreAskedForUsageInTheStream() {
        let request = LanguageModelRequest(systemPrompt: "s", userText: "hi")
        let askingBody = OpenAICompatibleLanguageModelProvider.buildRequestBody(model: "m", request: request, includeImages: false, requestsUsageInStream: true)
        let plainBody = OpenAICompatibleLanguageModelProvider.buildRequestBody(model: "m", request: request, includeImages: false)
        #expect((askingBody["stream_options"] as? [String: Bool])?["include_usage"] == true)
        #expect(plainBody["stream_options"] == nil)
        #expect(ProviderConfigurationStore.presetIdentifiersThatReportUsageWhenAsked.contains("openai"))
        #expect(!ProviderConfigurationStore.presetIdentifiersThatReportUsageWhenAsked.contains("mistral"))
    }

    @Test func geminiCountsCachedInputApartAndThinkingAsOutput() {
        let usage = GeminiLanguageModelProvider.usage(fromSSELine: #"data: {"usageMetadata":{"promptTokenCount":500,"cachedContentTokenCount":300,"candidatesTokenCount":40,"thoughtsTokenCount":60}}"#)
        #expect(usage == LanguageModelUsage(inputTokens: 200, outputTokens: 100, cacheReadInputTokens: 300))
        #expect(GeminiLanguageModelProvider.usage(fromSSELine: #"data: {"candidates":[]}"#) == nil)
    }

    // MARK: - The price list

    @Test func theBundledPriceListShipsWithADateAndTheCurrentModels() {
        let priceList = LanguageModelPriceList.bundled
        #expect(!priceList.pricesAsOf.isEmpty)
        #expect(priceList.entry(forProvider: "anthropic", model: "claude-opus-5-5")?.input == 4)
        #expect(priceList.entry(forProvider: "anthropic", model: "claude-sonnet-5-5") != nil)
        #expect(priceList.entry(forProvider: "openai", model: "gpt-5.4") != nil)
        #expect(priceList.entry(forProvider: "gemini", model: "gemini-3.8-flash") != nil)
        #expect(priceList.webSearchDollarsPerThousand["anthropic"] == 10)
    }

    @Test func modelsMatchTheirEntryOrADatedVersionOfItAndTheLongestWins() {
        let priceList = LanguageModelPriceList.bundled
        #expect(priceList.entry(forProvider: "anthropic", model: "claude-sonnet-4-5-20250929")?.model == "claude-sonnet-4-5")
        #expect(priceList.entry(forProvider: "openai", model: "gpt-5-mini")?.model == "gpt-5-mini")
        #expect(priceList.entry(forProvider: "openai", model: "gpt-5.4-mini-2026-03-01")?.model == "gpt-5.4-mini")
        #expect(priceList.entry(forProvider: "gemini", model: "models/gemini-2.5-flash")?.model == "gemini-2.5-flash")
        // "gpt-5" is not a prefix match for an unrelated name.
        #expect(priceList.entry(forProvider: "openai", model: "gpt-50") == nil)
        #expect(priceList.entry(forProvider: "openai", model: "claude-opus-5-5") == nil)
    }

    @Test func claudesCacheReadsAndWritesArePricedAtTheirOwnRates() {
        // Opus 5.5: $4 input, $5 cache writes, $0.20 cache reads, $20 output per million.
        let usage = LanguageModelUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadInputTokens: 1_000_000, cacheCreationInputTokens: 1_000_000)
        let priced = LanguageModelPricing.cost(
            of: usage, webSearchCount: 0, kind: .anthropic, presetIdentifier: "anthropic",
            baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", priceList: .bundled
        )
        #expect(priced.source == .priceList)
        #expect(abs(priced.costInDollars - 29.2) < 0.0001)
    }

    @Test func aLongPromptUsesTheLongPromptRates() {
        let haiku = LanguageModelPriceList.bundled.entry(forProvider: "anthropic", model: "claude-haiku-5-5")!
        #expect(haiku.prices(forRequestUsing: LanguageModelUsage(inputTokens: 50_000)).input == 0.1)
        #expect(haiku.prices(forRequestUsing: LanguageModelUsage(inputTokens: 20_000, cacheReadInputTokens: 90_000)).input == 0.5)
    }

    @Test func claudesOwnWebSearchesAreCharged() {
        let priced = LanguageModelPricing.cost(
            of: LanguageModelUsage(), webSearchCount: 3, kind: .anthropic, presetIdentifier: "anthropic",
            baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", priceList: .bundled
        )
        #expect(abs(priced.costInDollars - 0.03) < 0.0001)
    }

    @Test func openAIsCachedInputIsCheaperAndWritingTheCacheCostsNothingExtra() {
        let prices = LanguageModelPriceList.bundled.entry(forProvider: "openai", model: "gpt-5.4")!.standardPrices
        let usage = LanguageModelUsage(inputTokens: 1_000_000, outputTokens: 0, cacheReadInputTokens: 1_000_000)
        #expect(abs(prices.cost(of: usage) - 2.75) < 0.0001)
    }

    @Test func modelsOnThisMacAreFreeAndTheChatGPTPlanCostsNothingExtra() {
        let usage = LanguageModelUsage(inputTokens: 10_000, outputTokens: 1_000)
        let onThisMac = LanguageModelPricing.cost(
            of: usage, webSearchCount: 0, kind: .openAICompatible, presetIdentifier: nil,
            baseURL: "http://localhost:11434/v1", model: "llama", priceList: .bundled
        )
        #expect(onThisMac.source == .onThisMac && onThisMac.costInDollars == 0)
        let plan = LanguageModelPricing.cost(
            of: usage, webSearchCount: 0, kind: .chatGPTPlan, presetIdentifier: nil,
            baseURL: "", model: "gpt-5.4", priceList: .bundled
        )
        #expect(plan.source == .chatGPTPlan && plan.costInDollars == 0)
    }

    @Test func modelsWithoutAPriceAreUnknownIncludingClaudeBehindAProxy() {
        let usage = LanguageModelUsage(inputTokens: 10_000, outputTokens: 1_000)
        let groq = LanguageModelPricing.cost(
            of: usage, webSearchCount: 0, kind: .openAICompatible, presetIdentifier: "groq",
            baseURL: "https://api.groq.com/openai/v1", model: "llama-4-scout", priceList: .bundled
        )
        #expect(groq.source == .unknown)
        let proxiedClaude = LanguageModelPricing.cost(
            of: usage, webSearchCount: 0, kind: .anthropic, presetIdentifier: nil,
            baseURL: "https://my-proxy.example.com", model: "claude-opus-5-5", priceList: .bundled
        )
        #expect(proxiedClaude.source == .unknown)
    }

    // MARK: - The ledger

    @Test func requestsAddUpPerDayModelAndKindOfWork() {
        let (usageLedger, _) = temporaryLedger()
        let usage = LanguageModelUsage(inputTokens: 1_000, outputTokens: 100, cacheReadInputTokens: 9_000)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .chat)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .chat)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .screenWork)
        #expect(usageLedger.entries.count == 2)

        let summary = usageLedger.summary(for: .today, userPricesByModelKey: [:])
        #expect(summary.totals.requests == 3)
        #expect(summary.totals.inputTokens == 3_000)
        #expect(summary.totals.cacheReadTokens == 27_000)
        #expect(summary.totals.cachedInputShare == 0.9)
        #expect(summary.models.count == 1)
        #expect(summary.categories.map(\.category) == [.chat, .screenWork])
        #expect(summary.totals.costInDollars > 0)
    }

    @Test func aResponseWithoutCountsStillCountsAsARequest() {
        let (usageLedger, _) = temporaryLedger()
        usageLedger.record(usage: nil, webSearchCount: 0, configuration: claudeOpus, category: .chat)
        let summary = usageLedger.summary(for: .allTime, userPricesByModelKey: [:])
        #expect(summary.totals.requests == 1)
        #expect(summary.totals.requestsWithoutTokenCounts == 1)
    }

    @Test func periodsIncludeOnlyTheirDays() {
        let (usageLedger, _) = temporaryLedger()
        let today = Date()
        let calendar = Calendar.current
        let usage = LanguageModelUsage(inputTokens: 100, outputTokens: 10)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .chat, date: today)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .chat, date: calendar.date(byAdding: .day, value: -3, to: today)!)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .chat, date: calendar.date(byAdding: .day, value: -20, to: today)!)
        usageLedger.record(usage: usage, webSearchCount: 0, configuration: claudeOpus, category: .chat, date: calendar.date(byAdding: .day, value: -90, to: today)!)
        #expect(usageLedger.summary(for: .today, today: today, userPricesByModelKey: [:]).totals.requests == 1)
        #expect(usageLedger.summary(for: .lastSevenDays, today: today, userPricesByModelKey: [:]).totals.requests == 2)
        #expect(usageLedger.summary(for: .lastThirtyDays, today: today, userPricesByModelKey: [:]).totals.requests == 3)
        #expect(usageLedger.summary(for: .allTime, today: today, userPricesByModelKey: [:]).totals.requests == 4)
    }

    @Test func aPriceTheUserSetIsUsedForAnUnpricedModel() {
        let (usageLedger, _) = temporaryLedger()
        let groq = configuration(kind: .openAICompatible, baseURL: "https://api.groq.com/openai/v1", model: "llama-4-scout", presetIdentifier: "groq")
        usageLedger.record(usage: LanguageModelUsage(inputTokens: 1_000_000, outputTokens: 1_000_000), webSearchCount: 0, configuration: groq, category: .chat)

        let unpricedSummary = usageLedger.summary(for: .allTime, userPricesByModelKey: [:])
        #expect(unpricedSummary.totals.costInDollars == 0)
        #expect(unpricedSummary.unpricedTokens == 2_000_000)
        #expect(unpricedSummary.models.first?.hasUnpricedRequests == true)

        let modelKey = LanguageModelUsageLedger.modelKey(kind: .openAICompatible, presetIdentifier: "groq", model: "llama-4-scout")
        let pricedSummary = usageLedger.summary(
            for: .allTime,
            userPricesByModelKey: [modelKey: LanguageModelTokenPrices(input: 0.1, output: 0.3, cacheWrite: nil, cacheRead: nil)]
        )
        #expect(abs(pricedSummary.totals.costInDollars - 0.4) < 0.0001)
        #expect(pricedSummary.unpricedTokens == 0)
    }

    @Test func usageIsSavedAndReadBackAndResetRemovesIt() {
        let (usageLedger, storageDirectoryURL) = temporaryLedger()
        usageLedger.record(usage: LanguageModelUsage(inputTokens: 500, outputTokens: 50), webSearchCount: 1, configuration: claudeOpus, category: .memory)
        usageLedger.saveNow()

        let reopenedLedger = LanguageModelUsageLedger(storageDirectoryURL: storageDirectoryURL)
        #expect(reopenedLedger.entries == usageLedger.entries)

        // Only counts are kept: nothing a request said.
        let storedText = (try? String(contentsOf: storageDirectoryURL.appendingPathComponent(LanguageModelUsageLedger.storageFileName), encoding: .utf8)) ?? ""
        #expect(storedText.contains("\"inputTokens\":500"))

        reopenedLedger.resetUsage()
        #expect(reopenedLedger.entries.isEmpty)
        #expect(LanguageModelUsageLedger(storageDirectoryURL: storageDirectoryURL).entries.isEmpty)
    }

    @Test func theTestHostNeverWritesTheRealUsageFile() {
        let applicationSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        #expect(!LanguageModelUsageLedger.defaultStorageDirectoryURL.path.hasPrefix(applicationSupportPath))
    }

    // MARK: - Recording every request

    @Test func everyResponseIsRecordedWithWhatTheRequestWasFor() async throws {
        let (usageLedger, _) = temporaryLedger()
        var scriptedResponse = ScriptedLanguageModelProvider.reply("hello")
        scriptedResponse.usage = LanguageModelUsage(inputTokens: 300, outputTokens: 20)
        let recordingProvider = UsageRecordingLanguageModelProvider(
            wrapping: ScriptedLanguageModelProvider(scriptedResponses: [scriptedResponse]),
            configuration: claudeOpus,
            usageLedger: usageLedger
        )
        var request = LanguageModelRequest(systemPrompt: "s", userText: "hi")
        request.usageCategory = .backgroundTask
        let response = try await recordingProvider.streamResponse(request) { _ in }
        #expect(response.text == "hello")
        #expect(usageLedger.entries.count == 1)
        #expect(usageLedger.entries.first?.category == .backgroundTask)
        #expect(usageLedger.entries.first?.totals.inputTokens == 300)
    }

    @Test func aChatTurnThatWorksOnTheScreenCountsAsScreenWork() async throws {
        let screen = FakeComputerUseScreen()
        let session = ComputerUseSession(
            screen: screen,
            firstCapture: FakeComputerUseScreen.capture(imageData: FakeComputerUseScreen.jpegData(withBoxAt: nil)),
            coordinateConvention: .imagePixels,
            limits: .standard
        )
        let languageModelProvider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("done.")])
        _ = try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(systemPrompt: "s", userText: "click it"),
            languageModelProvider: languageModelProvider,
            toolRegistry: ElfToolRegistry(tools: []),
            toolContext: nil,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: 3,
            computerUseExecutor: session,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )
        #expect(languageModelProvider.receivedRequests.first?.usageCategory == .screenWork)
    }

    @Test func amountsAndTokenCountsReadNaturally() {
        #expect(LanguageModelUsageFormatting.compactTokenCount(950) == "950")
        #expect(LanguageModelUsageFormatting.compactTokenCount(12_400) == "12.4K")
        #expect(LanguageModelUsageFormatting.compactTokenCount(3_200_000) == "3.2M")
        #expect(LanguageModelUsageFormatting.dollars(0) == "$0.00")
        #expect(LanguageModelUsageFormatting.dollars(0.004) == "<$0.01")
        #expect(LanguageModelUsageFormatting.dollars(1.244) == "$1.24")
    }
}
