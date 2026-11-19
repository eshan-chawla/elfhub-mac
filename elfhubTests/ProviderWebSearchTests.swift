//
//  ProviderWebSearchTests.swift
//  elfhubTests
//
//  Searching the web with the model's own search (Claude's web search tool,
//  run by Anthropic) when the user picked it in Settings › Tools and the
//  elf's model has it: asked for in the request, read from the stream and kept
//  verbatim for the next round, paused turns sent back to continue, and a
//  search counting as using the web (so the user's folders stay off and its
//  results may be opened with fetch_page).
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ProviderWebSearchTests {

    // MARK: - Claude request

    private func requestAskingForWebSearch() -> LanguageModelRequest {
        var request = LanguageModelRequest(systemPrompt: "you're an elf", userText: "price of the iphone duo?")
        request.providerWebSearch = LanguageModelProviderWebSearch(maximumSearchesPerRequest: 5)
        return request
    }

    private func serverTools(in body: [String: Any]) -> [[String: Any]] {
        ((body["tools"] as? [[String: Any]]) ?? []).filter { $0["type"] != nil }
    }

    @Test func claudeGetsItsWebSearchToolWhenAskedDirectly() throws {
        let body = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: requestAskingForWebSearch(), isDirectToAnthropic: true)
        let webSearchTool = try #require(serverTools(in: body).first)
        #expect(webSearchTool["type"] as? String == "web_search_20260209")
        #expect(webSearchTool["name"] as? String == "web_search")
        #expect(webSearchTool["max_uses"] as? Int == 5)
    }

    @Test func olderClaudeModelsGetTheBasicWebSearchTool() throws {
        let body = ClaudeAPI.buildRequestBody(model: "claude-haiku-4-5", request: requestAskingForWebSearch(), isDirectToAnthropic: true)
        #expect(try #require(serverTools(in: body).first)["type"] as? String == "web_search_20250305")
    }

    @Test func otherAnthropicCompatibleEndpointsNeverGetTheWebSearchTool() {
        let body = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: requestAskingForWebSearch(), isDirectToAnthropic: false)
        #expect(serverTools(in: body).isEmpty)
    }

    @Test func noWebSearchToolUnlessAsked() {
        let request = LanguageModelRequest(systemPrompt: "you're an elf", userText: "hi")
        let body = ClaudeAPI.buildRequestBody(model: "claude-opus-5-5", request: request, isDirectToAnthropic: true)
        #expect(serverTools(in: body).isEmpty)
    }

    // MARK: - Claude stream

    @Test func claudeStreamKeepsSearchesResultsAndCitationsForTheNextRound() throws {
        var accumulator = AnthropicStreamAccumulator()
        let streamLines = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"iphone duo price\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"iPhone Duo","url":"https://www.apple.com/iphone-duo/","encrypted_content":"abc","page_age":null}]}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://www.apple.com/iphone-duo/","title":"iPhone Duo","encrypted_index":"xyz","cited_text":"From $1999"}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"it starts at $1999."}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}"#,
        ]
        for streamLine in streamLines { _ = accumulator.consume(sseLine: streamLine) }

        #expect(accumulator.toolCalls.isEmpty)
        #expect(accumulator.providerWebSearchCount == 1)
        #expect(accumulator.providerWebSearchResultURLs == [try #require(URL(string: "https://www.apple.com/iphone-duo/"))])
        #expect(accumulator.accumulatedText == "it starts at $1999.")

        let replayedBlocks: [[String: Any]] = accumulator.assistantContentBlocks.compactMap { contentBlock in
            guard case let .anthropicRawBlock(rawBlockJSON) = contentBlock else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(rawBlockJSON.utf8)) as? [String: Any]
        }
        #expect(replayedBlocks.map { $0["type"] as? String } == ["server_tool_use", "web_search_tool_result", "text"])
        #expect((replayedBlocks[0]["input"] as? [String: Any])?["query"] as? String == "iphone duo price")
        #expect(((replayedBlocks[1]["content"] as? [[String: Any]])?.first?["encrypted_content"]) as? String == "abc")
        #expect((replayedBlocks[2]["citations"] as? [[String: Any]])?.first?["encrypted_index"] as? String == "xyz")
    }

    @Test func aFailedSearchHasNoResults() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"x"}}}"#)
        _ = accumulator.consume(sseLine: #"data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}}"#)
        #expect(accumulator.providerWebSearchCount == 1)
        #expect(accumulator.providerWebSearchResultURLs.isEmpty)
    }

    // MARK: - The loop

    /// A tool of the user's folders, standing in for the real ones.
    private struct StandInUserFolderTool: ElfTool {
        let definition = LanguageModelToolDefinition(name: "read_user_file", description: "", inputSchema: ["type": "object"])
        let group = ElfToolGroup.userFolders
        let resultFeedsBackToModel = true
        func isAvailable(for role: ElfPromptRole, configuration: ElfConfiguration) -> Bool { true }
        func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome { ElfToolOutcome(resultText: "") }
    }

    private final class UnusedWebPageFetcher: ElfWebPageFetcher {
        func fetch(_ url: URL) async throws -> ElfFetchedWebPage { throw URLError(.cancelled) }
    }

    private struct UnusedSearchService: WebSearchProvider {
        func search(query: String) async throws -> [WebSearchResult] { [] }
    }

    private func makeToolContext(
        capabilities: ElfConfiguration.Capabilities = ElfConfiguration.Capabilities()
    ) throws -> (toolContext: ElfToolContext, cleanUp: () -> Void) {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded(configuration: ElfConfiguration(capabilities: capabilities))
        let toolContext = ElfToolContext(
            elf: Elf(id: "tom", home: home, configuration: home.readConfiguration()),
            changeLog: ElfChangeLog(home: home),
            origin: .task(taskIdentifier: UUID()),
            userUtterance: "research the price of the iphone duo",
            turnEffectLedger: ElfTurnEffectLedger()
        )
        return (toolContext, { try? FileManager.default.removeItem(at: homeDirectory) })
    }

    /// The user picked "the model's own search" in Settings › Tools:
    /// DuckDuckGo stands in for models without one.
    private func webToolsPreferringTheModelsOwnSearch() -> [ElfTool] {
        ElfWebTools.tools(pageFetcher: UnusedWebPageFetcher(), webSearchProvider: UnusedSearchService(), prefersModelsOwnSearch: true)
    }

    private func runLoop(
        provider: ScriptedLanguageModelProvider,
        tools: [ElfTool],
        toolContext: ElfToolContext,
        maximumRounds: Int = 3
    ) async throws -> ElfAgentLoopResult {
        let toolRegistry = ElfToolRegistry(tools: tools)
        return try await ElfAgentLoop.run(
            initialRequest: LanguageModelRequest(
                systemPrompt: "you're tom",
                userText: "research the price of the iphone duo",
                tools: toolRegistry.toolDefinitions(for: .sideElfForeground, configuration: toolContext.elf.configuration)
            ),
            languageModelProvider: provider,
            toolRegistry: toolRegistry,
            toolContext: toolContext,
            guidanceToolNames: [],
            maximumRounds: maximumRounds,
            onReplyTextDelta: { _ in },
            onModelRoundEnded: {}
        )
    }

    @Test func whenTheUserPicksTheModelsOwnSearchAnElfOnClaudeUsesIt() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("$1999.")], supportsProviderWebSearch: true)
        _ = try await runLoop(provider: provider, tools: webToolsPreferringTheModelsOwnSearch(), toolContext: toolContext)
        let sentRequest = try #require(provider.receivedRequests.first)
        #expect(sentRequest.providerWebSearch != nil)
        #expect(!sentRequest.tools.contains { $0.name == "web_search" })
    }

    @Test func anotherServicePickedMeansTheModelsOwnSearchIsNotUsed() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("ok")], supportsProviderWebSearch: true)
        let webTools = ElfWebTools.tools(pageFetcher: UnusedWebPageFetcher(), webSearchProvider: UnusedSearchService())
        _ = try await runLoop(provider: provider, tools: webTools, toolContext: toolContext)
        #expect(provider.receivedRequests.first?.providerWebSearch == nil)
    }

    @Test func noModelSearchWithoutTheWebOrOnAModelWithoutIt() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let webOffProvider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("ok")], supportsProviderWebSearch: true)
        _ = try await runLoop(provider: webOffProvider, tools: ElfFileTools.allTools, toolContext: toolContext)
        #expect(webOffProvider.receivedRequests.first?.providerWebSearch == nil)

        // A model without its own search keeps the stand-in search tool.
        let modelWithoutSearch = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("ok")])
        _ = try await runLoop(provider: modelWithoutSearch, tools: webToolsPreferringTheModelsOwnSearch(), toolContext: toolContext)
        #expect(modelWithoutSearch.receivedRequests.first?.providerWebSearch == nil)
        #expect(modelWithoutSearch.receivedRequests.first?.tools.contains { $0.name == "web_search" } == true)
    }

    @Test func noModelSearchWhenTheUsersFoldersMayBeUsedUnlessTheElfAllowsBoth() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("ok")], supportsProviderWebSearch: true)
        _ = try await runLoop(provider: provider, tools: webToolsPreferringTheModelsOwnSearch() + [StandInUserFolderTool()], toolContext: toolContext)
        #expect(provider.receivedRequests.first?.providerWebSearch == nil)

        let (bothContext, cleanUpBoth) = try makeToolContext(capabilities: ElfConfiguration.Capabilities(allowsWebAndUserFoldersTogether: true))
        defer { cleanUpBoth() }
        let bothProvider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("ok")], supportsProviderWebSearch: true)
        _ = try await runLoop(provider: bothProvider, tools: webToolsPreferringTheModelsOwnSearch() + [StandInUserFolderTool()], toolContext: bothContext)
        #expect(bothProvider.receivedRequests.first?.providerWebSearch != nil)
    }

    @Test func noModelSearchAfterAnEarlierRunUsedTheUsersFolders() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        toolContext.usedResources.insert(.userFolders)
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply("ok")], supportsProviderWebSearch: true)
        _ = try await runLoop(provider: provider, tools: webToolsPreferringTheModelsOwnSearch(), toolContext: toolContext)
        #expect(provider.receivedRequests.first?.providerWebSearch == nil)
    }

    @Test func aSearchTheModelRanCountsAsUsingTheWeb() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let resultURL = try #require(URL(string: "https://www.apple.com/iphone-duo/"))
        var searchedReply = ScriptedLanguageModelProvider.reply("it starts at $1999.")
        searchedReply.providerWebSearchCount = 1
        searchedReply.providerWebSearchResultURLs = [resultURL]
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [searchedReply], supportsProviderWebSearch: true)
        _ = try await runLoop(provider: provider, tools: webToolsPreferringTheModelsOwnSearch(), toolContext: toolContext)
        #expect(toolContext.usedResources.contains(.web))
        #expect(toolContext.influencedBy.contains(.web))
        #expect(toolContext.fetchPageURLPolicy.allows(resultURL))
    }

    @Test func aTurnTheServerPausedIsSentBackToContinue() async throws {
        let (toolContext, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        var pausedReply = ScriptedLanguageModelProvider.reply("let me look that up.")
        pausedReply.stopReason = .pausedByServer
        let provider = ScriptedLanguageModelProvider(
            scriptedResponses: [pausedReply, ScriptedLanguageModelProvider.reply("it starts at $1999.")],
            supportsProviderWebSearch: true
        )
        let loopResult = try await runLoop(provider: provider, tools: webToolsPreferringTheModelsOwnSearch(), toolContext: toolContext)
        #expect(provider.receivedRequests.count == 2)
        let continuedMessages = try #require(provider.receivedRequests.last?.messages)
        #expect(continuedMessages.last?.role == .assistant)
        #expect(continuedMessages.count == 2)
        #expect(loopResult.replyText == "let me look that up. it starts at $1999.")
        // The same tools on every round: changing them mid-turn would
        // throw away the model's earlier thinking.
        #expect(provider.receivedRequests.allSatisfy { $0.providerWebSearch != nil })
    }
}
