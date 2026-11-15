//
//  WebSearchProviderTests.swift
//  elfhubTests
//
//  Web search through a service the user picks: each service gets the
//  request it expects (key in the right header, the query, eight results),
//  and its answer is read into titles, addresses and snippets.
//

import Foundation
import Testing
@testable import elfhub

struct WebSearchProviderTests {

    private func provider(_ preset: WebSearchServicePreset, apiKey: String? = "test-key") -> ConfiguredWebSearchProvider {
        ConfiguredWebSearchProvider(preset: preset, apiKey: apiKey, searxngBaseURL: URL(string: "http://localhost:8888")!)
    }

    @Test func eachServiceGetsTheRequestItExpects() throws {
        let braveRequest = try provider(.brave).makeRequest(query: "flights to Lisbon")
        #expect(braveRequest.httpMethod == "GET")
        #expect(braveRequest.url?.host == "api.search.brave.com")
        #expect(braveRequest.url?.query?.contains("q=flights%20to%20Lisbon") == true)
        #expect(braveRequest.value(forHTTPHeaderField: "X-Subscription-Token") == "test-key")

        let tavilyRequest = try provider(.tavily).makeRequest(query: "flights")
        #expect(tavilyRequest.httpMethod == "POST")
        #expect(tavilyRequest.url?.absoluteString == "https://api.tavily.com/search")
        #expect(tavilyRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let tavilyBodyData = try #require(tavilyRequest.httpBody)
        let tavilyBody = try #require(try JSONSerialization.jsonObject(with: tavilyBodyData) as? [String: Any])
        #expect(tavilyBody["query"] as? String == "flights")
        #expect(tavilyBody["max_results"] as? Int == ConfiguredWebSearchProvider.resultCount)

        let exaRequest = try provider(.exa).makeRequest(query: "flights")
        #expect(exaRequest.url?.absoluteString == "https://api.exa.ai/search")
        #expect(exaRequest.value(forHTTPHeaderField: "x-api-key") == "test-key")
        let exaBodyData = try #require(exaRequest.httpBody)
        let exaBody = try #require(try JSONSerialization.jsonObject(with: exaBodyData) as? [String: Any])
        #expect(exaBody["numResults"] as? Int == ConfiguredWebSearchProvider.resultCount)

        let searxngRequest = try provider(.searxng, apiKey: nil).makeRequest(query: "flights")
        #expect(searxngRequest.url?.absoluteString.hasPrefix("http://localhost:8888/search?") == true)
        #expect(searxngRequest.url?.query?.contains("format=json") == true)
    }

    @Test func eachServicesAnswerIsRead() throws {
        let braveAnswer = #"{"web":{"results":[{"title":"TAP","url":"https://flytap.com","description":"Direct flights"},{"title":"No snippet","url":"https://b.example"}]}}"#
        #expect(try ConfiguredWebSearchProvider.results(fromResponseData: Data(braveAnswer.utf8), preset: .brave) == [
            WebSearchResult(title: "TAP", url: URL(string: "https://flytap.com")!, snippet: "Direct flights"),
            WebSearchResult(title: "No snippet", url: URL(string: "https://b.example")!, snippet: ""),
        ])
        let tavilyAnswer = #"{"results":[{"title":"TAP","url":"https://flytap.com","content":"Direct"}]}"#
        #expect(try ConfiguredWebSearchProvider.results(fromResponseData: Data(tavilyAnswer.utf8), preset: .tavily).first?.snippet == "Direct")
        let exaAnswer = #"{"results":[{"title":"TAP","url":"https://flytap.com","highlights":["Direct flights","daily"]}]}"#
        #expect(try ConfiguredWebSearchProvider.results(fromResponseData: Data(exaAnswer.utf8), preset: .exa).first?.snippet == "Direct flights … daily")
        let searxngAnswer = #"{"results":[{"title":"TAP","url":"https://flytap.com","content":"Direct"},{"title":"bad","url":"javascript:alert(1)"}]}"#
        #expect(try ConfiguredWebSearchProvider.results(fromResponseData: Data(searxngAnswer.utf8), preset: .searxng).map(\.title) == ["TAP"])
    }

    @Test func aServiceThatNeedsAKeyHasNoProviderWithoutOne() {
        #expect(ConfiguredWebSearchProvider.makeIfReady(preset: .brave, apiKey: nil, searxngBaseURL: nil) == nil)
        #expect(ConfiguredWebSearchProvider.makeIfReady(preset: .brave, apiKey: "  ", searxngBaseURL: nil) == nil)
        #expect(ConfiguredWebSearchProvider.makeIfReady(preset: .searxng, apiKey: nil, searxngBaseURL: URL(string: "http://localhost:8888")) != nil)
        #expect(ConfiguredWebSearchProvider.makeIfReady(preset: nil, apiKey: "key", searxngBaseURL: nil) == nil)
    }

    // MARK: - DuckDuckGo (no key)

    @Test func duckDuckGoNeedsNoKeyAndPostsTheQuery() throws {
        let duckDuckGo = try #require(ConfiguredWebSearchProvider.makeIfReady(preset: .duckDuckGo, apiKey: nil, searxngBaseURL: nil))
        let request = try duckDuckGo.makeRequest(query: "flights to Lisbon & Porto")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://html.duckduckgo.com/html/")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == "q=flights%20to%20Lisbon%20%26%20Porto")
    }

    @Test func duckDuckGoResultsAreReadFromItsPage() throws {
        let resultsPage = """
        <div class="result results_links web-result">
          <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://www.swift.org/">Swift &amp; you</a></h2>
          <a class="result__snippet" href="https://www.swift.org/">Swift is a <b>general-purpose</b> language.</a>
        </div>
        <div class="result results_links web-result">
          <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://www.swift.org/">Swift again</a></h2>
        </div>
        <div class="result result--ad">
          <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=ads.example">An ad</a></h2>
        </div>
        <div class="result results_links web-result">
          <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FSwift&amp;rut=abc">Swift - Wikipedia</a></h2>
          <a class="result__snippet" href="x">An encyclopedia entry.</a>
        </div>
        <div class="result"><a class="result__a" href="javascript:alert(1)">bad</a></div>
        """
        let results = try ConfiguredWebSearchProvider.results(fromResponseData: Data(resultsPage.utf8), preset: .duckDuckGo)
        #expect(results == [
            WebSearchResult(title: "Swift & you", url: URL(string: "https://www.swift.org/")!, snippet: "Swift is a general-purpose language."),
            WebSearchResult(title: "Swift - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Swift")!, snippet: "An encyclopedia entry."),
        ])
    }

    @Test func aDuckDuckGoPageWithoutResultsIsEmpty() throws {
        #expect(try ConfiguredWebSearchProvider.results(fromResponseData: Data("<html>please wait</html>".utf8), preset: .duckDuckGo).isEmpty)
    }

    // MARK: - Firecrawl

    @Test func firecrawlGetsItsSearchRequestAndItsAnswerIsRead() throws {
        let firecrawl = try #require(ConfiguredWebSearchProvider.makeIfReady(preset: .firecrawl, apiKey: "fc-key", searxngBaseURL: nil))
        let request = try firecrawl.makeRequest(query: "flights")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.firecrawl.dev/v2/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fc-key")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["query"] as? String == "flights")
        #expect(body["limit"] as? Int == ConfiguredWebSearchProvider.resultCount)

        let answer = #"{"success":true,"data":{"web":[{"title":"TAP","url":"https://flytap.com","description":"Direct flights"}],"news":[]}}"#
        #expect(try ConfiguredWebSearchProvider.results(fromResponseData: Data(answer.utf8), preset: .firecrawl) == [
            WebSearchResult(title: "TAP", url: URL(string: "https://flytap.com")!, snippet: "Direct flights"),
        ])
    }

    @Test func firecrawlNeedsAKeyOnlyOnItsOwnService() throws {
        #expect(ConfiguredWebSearchProvider.makeIfReady(preset: .firecrawl, apiKey: nil, searxngBaseURL: nil) == nil)
        let selfHosted = try #require(ConfiguredWebSearchProvider.makeIfReady(
            preset: .firecrawl, apiKey: nil, searxngBaseURL: nil, firecrawlBaseURL: URL(string: "http://localhost:3002")
        ))
        let request = try selfHosted.makeRequest(query: "flights")
        #expect(request.url?.absoluteString == "http://localhost:3002/v2/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - The choice in Settings › Tools

    @Test func duckDuckGoIsTheDefaultAndOffCanBeChosen() throws {
        let userDefaultsSuiteName = "web-search-settings-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        #expect(WebSearchSettings.selectedPreset(in: userDefaults) == .duckDuckGo)
        WebSearchSettings.setSelectedPreset(nil, in: userDefaults)
        #expect(WebSearchSettings.selectedPreset(in: userDefaults) == nil)
        WebSearchSettings.setSelectedPreset(.firecrawl, in: userDefaults)
        #expect(WebSearchSettings.selectedPreset(in: userDefaults) == .firecrawl)
    }

    @Test func theModelsOwnSearchFallsBackToDuckDuckGoForOtherModels() {
        #expect(ConfiguredWebSearchProvider.makeIfReady(preset: .modelsOwnSearch, apiKey: nil, searxngBaseURL: nil) == nil)
        let modelsOwnSetup = WebSearchSettings.setup(for: .modelsOwnSearch, apiKey: nil, searxngBaseURL: nil, firecrawlBaseURL: nil)
        #expect(modelsOwnSetup.prefersModelsOwnSearch)
        #expect(modelsOwnSetup.provider?.preset == .duckDuckGo)
        let braveSetup = WebSearchSettings.setup(for: .brave, apiKey: "key", searxngBaseURL: nil, firecrawlBaseURL: nil)
        #expect(!braveSetup.prefersModelsOwnSearch)
        #expect(braveSetup.provider?.preset == .brave)
        let offSetup = WebSearchSettings.setup(for: nil, apiKey: nil, searxngBaseURL: nil, firecrawlBaseURL: nil)
        #expect(offSetup.provider == nil && !offSetup.prefersModelsOwnSearch)
    }

    @Test func eachServiceKeepsItsOwnKey() {
        let accountNames = Set(WebSearchServicePreset.allCases.map(WebSearchSettings.keychainAccountName(for:)))
        #expect(accountNames.count == WebSearchServicePreset.allCases.count)
    }
}
