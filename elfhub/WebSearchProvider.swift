//
//  WebSearchProvider.swift
//  elfhub
//
//  Web search for elves through a search service the user picks and pays
//  for themselves — Brave, Tavily or Exa with their key (kept in the
//  Keychain), or a SearXNG server they run — set in Settings › Models.
//  Without one, elves have no web_search, only fetch_page for addresses the
//  user gives. The service gets the elf's search query and nothing else.
//

import Foundation

struct WebSearchResult: Equatable {
    let title: String
    let url: URL
    let snippet: String
}

protocol WebSearchProvider {
    func search(query: String) async throws -> [WebSearchResult]
}

enum WebSearchServicePreset: String, CaseIterable, Identifiable {
    case brave
    case tavily
    case exa
    case searxng

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brave: return "Brave Search"
        case .tavily: return "Tavily"
        case .exa: return "Exa"
        case .searxng: return "SearXNG (your own server)"
        }
    }

    var needsKey: Bool { self != .searxng }

    /// Where the user gets a key (opened in their browser).
    var keyPageURL: URL? {
        switch self {
        case .brave: return URL(string: "https://api-dashboard.search.brave.com")
        case .tavily: return URL(string: "https://app.tavily.com")
        case .exa: return URL(string: "https://dashboard.exa.ai")
        case .searxng: return URL(string: "https://docs.searxng.org")
        }
    }
}

/// The service picked in Settings › Models, and SearXNG's address.
enum WebSearchSettings {
    private static let presetDefaultsKey = "webSearchServicePreset"
    private static let searxngBaseURLDefaultsKey = "webSearchSearxngBaseURL"
    static let defaultSearxngBaseURL = "http://localhost:8888"

    static var selectedPreset: WebSearchServicePreset? {
        get { UserDefaults.standard.string(forKey: presetDefaultsKey).flatMap(WebSearchServicePreset.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: presetDefaultsKey) }
    }

    static var searxngBaseURL: String {
        get { UserDefaults.standard.string(forKey: searxngBaseURLDefaultsKey) ?? defaultSearxngBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: searxngBaseURLDefaultsKey) }
    }

    /// Each service keeps its own key, so switching services never sends
    /// one vendor's key to another.
    static func keychainAccountName(for preset: WebSearchServicePreset) -> String {
        "service-key-web-search-" + preset.rawValue
    }

    static func savedKey(for preset: WebSearchServicePreset) -> String? {
        KeychainSecretStore.secret(forAccount: keychainAccountName(for: preset))
    }

    /// The search provider for elves, or nil when none is set up.
    static func currentProvider() -> ConfiguredWebSearchProvider? {
        ConfiguredWebSearchProvider.makeIfReady(
            preset: selectedPreset,
            apiKey: selectedPreset.flatMap(savedKey(for:)),
            searxngBaseURL: URL(string: searxngBaseURL)
        )
    }
}

struct ConfiguredWebSearchProvider: WebSearchProvider, Equatable {
    static let resultCount = 8
    static let timeoutInSeconds: TimeInterval = 15

    let preset: WebSearchServicePreset
    let apiKey: String?
    let searxngBaseURL: URL?

    /// A provider when the service is picked and has what it needs.
    static func makeIfReady(preset: WebSearchServicePreset?, apiKey: String?, searxngBaseURL: URL?) -> ConfiguredWebSearchProvider? {
        guard let preset else { return nil }
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset.needsKey, trimmedAPIKey?.isEmpty != false { return nil }
        if preset == .searxng, searxngBaseURL == nil { return nil }
        return ConfiguredWebSearchProvider(preset: preset, apiKey: trimmedAPIKey, searxngBaseURL: searxngBaseURL)
    }

    func makeRequest(query: String) throws -> URLRequest {
        var request: URLRequest
        switch preset {
        case .brave:
            var urlComponents = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            urlComponents.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(Self.resultCount))]
            request = URLRequest(url: urlComponents.url!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        case .tavily:
            request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + (apiKey ?? ""), forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "max_results": Self.resultCount])
        case .exa:
            request = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query, "numResults": Self.resultCount, "contents": ["highlights": true],
            ])
        case .searxng:
            guard let searxngBaseURL,
                  var urlComponents = URLComponents(url: searxngBaseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false) else {
                throw URLError(.badURL)
            }
            urlComponents.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
            request = URLRequest(url: urlComponents.url!)
            request.httpMethod = "GET"
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = Self.timeoutInSeconds
        return request
    }

    /// Titles, addresses and snippets from the service's answer; results
    /// that aren't http(s) pages are left out.
    static func results(fromResponseData responseData: Data, preset: WebSearchServicePreset) throws -> [WebSearchResult] {
        guard let answer = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let rawResults: [[String: Any]]
        switch preset {
        case .brave:
            rawResults = ((answer["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        case .tavily, .exa, .searxng:
            rawResults = (answer["results"] as? [[String: Any]]) ?? []
        }
        return rawResults.compactMap { rawResult in
            guard let address = rawResult["url"] as? String, let resultURL = URL(string: address),
                  ["http", "https"].contains(resultURL.scheme?.lowercased() ?? "") else { return nil }
            let snippet: String
            switch preset {
            case .brave: snippet = rawResult["description"] as? String ?? ""
            case .tavily, .searxng: snippet = rawResult["content"] as? String ?? ""
            case .exa: snippet = (rawResult["highlights"] as? [String])?.joined(separator: " … ") ?? rawResult["text"] as? String ?? ""
            }
            return WebSearchResult(
                title: (rawResult["title"] as? String) ?? address,
                url: resultURL,
                snippet: WebPageTextExtractor.decodedEntities(snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            )
        }
        .prefix(resultCount)
        .map { $0 }
    }

    /// One shared ephemeral session for searches (no cookies or cache).
    private static let searchSession = URLSession(configuration: .ephemeral)

    func search(query: String) async throws -> [WebSearchResult] {
        let (responseData, response) = try await Self.searchSession.data(for: try makeRequest(query: query))
        if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
            throw URLError(statusCode == 401 || statusCode == 403 ? .userAuthenticationRequired : .badServerResponse)
        }
        return try Self.results(fromResponseData: responseData, preset: preset)
    }
}
