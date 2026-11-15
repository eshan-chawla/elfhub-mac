//
//  WebSearchProvider.swift
//  elfhub
//
//  Web search for elves, run from this Mac through the service the user
//  picks in Settings › Tools: DuckDuckGo (no key, the default), Firecrawl,
//  Brave, Tavily or Exa with their key (kept in the Keychain), Firecrawl or
//  SearXNG on their own server — or "the model's own search", where an elf
//  whose model can search (Claude with the user's key) does it inside the
//  model call (ElfAgentLoop.providerWebSearch) and DuckDuckGo stands in for
//  other models. The service gets the elf's search words and nothing else;
//  opening the result pages is always done by this Mac (fetch_page).
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
    case duckDuckGo
    case modelsOwnSearch
    case firecrawl
    case brave
    case tavily
    case exa
    case searxng

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo (no key)"
        case .modelsOwnSearch: return "The model's own search"
        case .firecrawl: return "Firecrawl"
        case .brave: return "Brave Search"
        case .tavily: return "Tavily"
        case .exa: return "Exa"
        case .searxng: return "SearXNG (your own server)"
        }
    }

    /// One line under the picker on what this choice means.
    var explanation: String {
        switch self {
        case .duckDuckGo:
            return "Free and needs no setup. It reads DuckDuckGo's plain results page — not an official service, so it can slow down or stop answering if used a lot."
        case .modelsOwnSearch:
            return "Elves on Claude with your key search inside the model call (Anthropic charges your key about a cent a search). Elves on other models use DuckDuckGo."
        case .firecrawl:
            return "Firecrawl's search with your key, or your own Firecrawl server (it's open source) with no key."
        case .brave:
            return "Brave's independent search index, with your key."
        case .tavily:
            return "A search service made for AI agents, with your key."
        case .exa:
            return "A search service made for AI agents, with your key."
        case .searxng:
            return "Free, open-source search that you run yourself (for example with Docker). Nothing leaves your Mac except what your server asks the search engines."
        }
    }

    /// Whether a key is needed (Firecrawl only on its own service).
    func needsKey(firecrawlBaseURL: URL?) -> Bool {
        switch self {
        case .brave, .tavily, .exa: return true
        case .firecrawl: return (firecrawlBaseURL ?? WebSearchSettings.defaultFirecrawlBaseURL).host == WebSearchSettings.defaultFirecrawlBaseURL.host
        case .duckDuckGo, .modelsOwnSearch, .searxng: return false
        }
    }

    /// Where the user gets a key (opened in their browser).
    var keyPageURL: URL? {
        switch self {
        case .duckDuckGo, .modelsOwnSearch: return nil
        case .firecrawl: return URL(string: "https://www.firecrawl.dev/app/api-keys")
        case .brave: return URL(string: "https://api-dashboard.search.brave.com")
        case .tavily: return URL(string: "https://app.tavily.com")
        case .exa: return URL(string: "https://dashboard.exa.ai")
        case .searxng: return URL(string: "https://docs.searxng.org")
        }
    }
}

/// What the search choice gives elves: a search service run from this Mac
/// (nil when search is off or the service isn't set up yet), and whether
/// the model's own search comes first when the elf's model has one.
struct WebSearchSetup {
    let provider: ConfiguredWebSearchProvider?
    let prefersModelsOwnSearch: Bool
}

/// The service picked in Settings › Tools, and the addresses of the
/// user's own SearXNG or Firecrawl server.
enum WebSearchSettings {
    private static let presetDefaultsKey = "webSearchServicePreset"
    private static let searxngBaseURLDefaultsKey = "webSearchSearxngBaseURL"
    private static let firecrawlBaseURLDefaultsKey = "webSearchFirecrawlBaseURL"
    /// Saved when the user switches search off (no saved choice means the default).
    private static let offValue = "off"
    static let defaultSearxngBaseURL = "http://localhost:8888"
    static let defaultFirecrawlBaseURL = URL(string: "https://api.firecrawl.dev")!

    /// The chosen service; nil when search is off. DuckDuckGo until the
    /// user picks something, so elves can search with no setup.
    static func selectedPreset(in userDefaults: UserDefaults) -> WebSearchServicePreset? {
        guard let savedValue = userDefaults.string(forKey: presetDefaultsKey) else { return .duckDuckGo }
        if savedValue == offValue { return nil }
        return WebSearchServicePreset(rawValue: savedValue) ?? .duckDuckGo
    }

    static func setSelectedPreset(_ preset: WebSearchServicePreset?, in userDefaults: UserDefaults) {
        userDefaults.set(preset?.rawValue ?? offValue, forKey: presetDefaultsKey)
    }

    static var selectedPreset: WebSearchServicePreset? {
        get { selectedPreset(in: .standard) }
        set { setSelectedPreset(newValue, in: .standard) }
    }

    static var searxngBaseURL: String {
        get { UserDefaults.standard.string(forKey: searxngBaseURLDefaultsKey) ?? defaultSearxngBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: searxngBaseURLDefaultsKey) }
    }

    static var firecrawlBaseURL: String {
        get { UserDefaults.standard.string(forKey: firecrawlBaseURLDefaultsKey) ?? defaultFirecrawlBaseURL.absoluteString }
        set { UserDefaults.standard.set(newValue, forKey: firecrawlBaseURLDefaultsKey) }
    }

    /// Each service keeps its own key, so switching services never sends
    /// one vendor's key to another.
    static func keychainAccountName(for preset: WebSearchServicePreset) -> String {
        "service-key-web-search-" + preset.rawValue
    }

    static func savedKey(for preset: WebSearchServicePreset) -> String? {
        KeychainSecretStore.secret(forAccount: keychainAccountName(for: preset))
    }

    /// What elves get from a choice. "The model's own search" keeps
    /// DuckDuckGo as the search for elves whose model has none.
    static func setup(
        for preset: WebSearchServicePreset?,
        apiKey: String?,
        searxngBaseURL: URL?,
        firecrawlBaseURL: URL?
    ) -> WebSearchSetup {
        guard preset != .modelsOwnSearch else {
            return WebSearchSetup(
                provider: ConfiguredWebSearchProvider.makeIfReady(preset: .duckDuckGo, apiKey: nil, searxngBaseURL: nil),
                prefersModelsOwnSearch: true
            )
        }
        return WebSearchSetup(
            provider: ConfiguredWebSearchProvider.makeIfReady(
                preset: preset,
                apiKey: apiKey,
                searxngBaseURL: searxngBaseURL,
                firecrawlBaseURL: firecrawlBaseURL
            ),
            prefersModelsOwnSearch: false
        )
    }

    /// The search for elves from what's saved now.
    static func currentSetup() -> WebSearchSetup {
        setup(
            for: selectedPreset,
            apiKey: selectedPreset.flatMap(savedKey(for:)),
            searxngBaseURL: URL(string: searxngBaseURL),
            firecrawlBaseURL: URL(string: firecrawlBaseURL)
        )
    }
}

struct ConfiguredWebSearchProvider: WebSearchProvider, Equatable {
    static let resultCount = 8
    static let timeoutInSeconds: TimeInterval = 15

    let preset: WebSearchServicePreset
    let apiKey: String?
    let searxngBaseURL: URL?
    var firecrawlBaseURL: URL? = nil

    /// A provider when the service is picked and has what it needs. "The
    /// model's own search" isn't a service of its own (see WebSearchSettings.setup).
    static func makeIfReady(
        preset: WebSearchServicePreset?,
        apiKey: String?,
        searxngBaseURL: URL?,
        firecrawlBaseURL: URL? = nil
    ) -> ConfiguredWebSearchProvider? {
        guard let preset, preset != .modelsOwnSearch else { return nil }
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableAPIKey = trimmedAPIKey?.isEmpty == false ? trimmedAPIKey : nil
        if preset.needsKey(firecrawlBaseURL: firecrawlBaseURL), usableAPIKey == nil { return nil }
        if preset == .searxng, searxngBaseURL == nil { return nil }
        return ConfiguredWebSearchProvider(
            preset: preset,
            apiKey: usableAPIKey,
            searxngBaseURL: searxngBaseURL,
            firecrawlBaseURL: preset == .firecrawl ? (firecrawlBaseURL ?? WebSearchSettings.defaultFirecrawlBaseURL) : nil
        )
    }

    /// DuckDuckGo's results page without scripts, which answers a form post.
    static let duckDuckGoResultsPageURL = URL(string: "https://html.duckduckgo.com/html/")!

    func makeRequest(query: String) throws -> URLRequest {
        var request: URLRequest
        switch preset {
        case .duckDuckGo:
            request = URLRequest(url: Self.duckDuckGoResultsPageURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue("elfhub (searching for its user)", forHTTPHeaderField: "User-Agent")
            var formCharacters = CharacterSet.alphanumerics
            formCharacters.insert(charactersIn: "-._~")
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? ""
            request.httpBody = Data("q=\(encodedQuery)".utf8)
            request.timeoutInterval = Self.timeoutInSeconds
            return request
        case .modelsOwnSearch:
            throw URLError(.unsupportedURL)
        case .firecrawl:
            let baseURL = firecrawlBaseURL ?? WebSearchSettings.defaultFirecrawlBaseURL
            request = URLRequest(url: baseURL.appendingPathComponent("v2").appendingPathComponent("search"))
            request.httpMethod = "POST"
            if let apiKey {
                request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "limit": Self.resultCount])
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
        if preset == .duckDuckGo {
            return DuckDuckGoResultsPage.results(fromHTML: String(decoding: responseData, as: UTF8.self), limit: resultCount)
        }
        guard let answer = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let rawResults: [[String: Any]]
        switch preset {
        case .brave:
            rawResults = ((answer["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        case .firecrawl:
            rawResults = ((answer["data"] as? [String: Any])?["web"] as? [[String: Any]]) ?? []
        case .tavily, .exa, .searxng:
            rawResults = (answer["results"] as? [[String: Any]]) ?? []
        case .duckDuckGo, .modelsOwnSearch:
            rawResults = []
        }
        return rawResults.compactMap { rawResult in
            guard let address = rawResult["url"] as? String, let resultURL = URL(string: address),
                  ["http", "https"].contains(resultURL.scheme?.lowercased() ?? "") else { return nil }
            let snippet: String
            switch preset {
            case .brave, .firecrawl: snippet = rawResult["description"] as? String ?? ""
            case .tavily, .searxng: snippet = rawResult["content"] as? String ?? ""
            case .exa: snippet = (rawResult["highlights"] as? [String])?.joined(separator: " … ") ?? rawResult["text"] as? String ?? ""
            case .duckDuckGo, .modelsOwnSearch: snippet = ""
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

// MARK: - DuckDuckGo's results page

/// Reads DuckDuckGo's plain results page: each result's title link
/// (`class="result__a"`) and the description after it
/// (`class="result__snippet"`). One pass from start to end, no regex, so a
/// page that isn't what's expected can't stall it. Links through
/// DuckDuckGo's redirect (`/l/?uddg=…`) are unwrapped; ads (links back to
/// duckduckgo.com) and the same address twice are left out.
enum DuckDuckGoResultsPage {
    private static let titleLinkMarker = "class=\"result__a\""
    private static let snippetMarker = "class=\"result__snippet\""

    static func results(fromHTML resultsPageHTML: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        var addressesSeen: Set<String> = []
        var searchStart = resultsPageHTML.startIndex
        while results.count < limit,
              let titleMarkerRange = resultsPageHTML.range(of: titleLinkMarker, range: searchStart..<resultsPageHTML.endIndex) {
            searchStart = titleMarkerRange.upperBound
            guard let titleLink = link(around: titleMarkerRange, in: resultsPageHTML) else { continue }
            searchStart = titleLink.end
            // The description belongs to this result if it comes before the next title.
            let nextTitleStart = resultsPageHTML.range(of: titleLinkMarker, range: titleLink.end..<resultsPageHTML.endIndex)?.lowerBound
                ?? resultsPageHTML.endIndex
            var snippet = ""
            if let snippetMarkerRange = resultsPageHTML.range(of: snippetMarker, range: titleLink.end..<nextTitleStart),
               let snippetLink = link(around: snippetMarkerRange, in: resultsPageHTML) {
                snippet = snippetLink.text
            }
            guard let resultURL = resultAddress(fromHref: titleLink.href),
                  addressesSeen.insert(resultURL.absoluteString).inserted else { continue }
            results.append(WebSearchResult(title: titleLink.text, url: resultURL, snippet: snippet))
        }
        return results
    }

    /// The `<a …>` tag holding the marker: its href, its text (tags and
    /// entities removed) and where the link ends.
    private static func link(around markerRange: Range<String.Index>, in resultsPageHTML: String) -> (href: String, text: String, end: String.Index)? {
        guard let tagStart = resultsPageHTML.range(of: "<a", options: .backwards, range: resultsPageHTML.startIndex..<markerRange.lowerBound)?.lowerBound,
              let tagEnd = resultsPageHTML.range(of: ">", range: markerRange.upperBound..<resultsPageHTML.endIndex)?.upperBound,
              let linkEnd = resultsPageHTML.range(of: "</a>", range: tagEnd..<resultsPageHTML.endIndex) else { return nil }
        let openingTag = resultsPageHTML[tagStart..<tagEnd]
        guard let hrefStart = openingTag.range(of: "href=\"")?.upperBound,
              let hrefEnd = openingTag.range(of: "\"", range: hrefStart..<openingTag.endIndex)?.lowerBound else { return nil }
        let innerHTML = String(resultsPageHTML[tagEnd..<linkEnd.lowerBound])
        let text = WebPageTextExtractor.decodedEntities(innerHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (WebPageTextExtractor.decodedEntities(String(openingTag[hrefStart..<hrefEnd])), text, linkEnd.upperBound)
    }

    /// The page a result leads to, unwrapping DuckDuckGo's redirect; nil
    /// for ads, DuckDuckGo's own pages and anything that isn't http(s).
    private static func resultAddress(fromHref href: String) -> URL? {
        let absoluteHref = href.hasPrefix("//") ? "https:" + href : href
        guard let hrefComponents = URLComponents(string: absoluteHref) else { return nil }
        if let redirectedAddress = hrefComponents.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return resultAddress(fromHref: redirectedAddress)
        }
        guard let resultURL = hrefComponents.url,
              ["http", "https"].contains(resultURL.scheme?.lowercased() ?? ""),
              let host = resultURL.host?.lowercased(),
              host != "duckduckgo.com", !host.hasSuffix(".duckduckgo.com") else { return nil }
        return resultURL
    }
}
