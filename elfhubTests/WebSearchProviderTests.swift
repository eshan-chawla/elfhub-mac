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

    @Test func eachServiceKeepsItsOwnKey() {
        let accountNames = Set(WebSearchServicePreset.allCases.map(WebSearchSettings.keychainAccountName(for:)))
        #expect(accountNames.count == WebSearchServicePreset.allCases.count)
    }
}
