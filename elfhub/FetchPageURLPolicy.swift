//
//  FetchPageURLPolicy.swift
//  elfhub
//
//  Which web pages an elf may open with fetch_page. Only pages it was led
//  to: a search result, a link on a page it already opened in this task, or
//  an address the user said or typed. Never an address a page or file
//  merely mentions in its text, and never anything on the user's own Mac or
//  network (localhost, .local names, private and link-local addresses), so
//  a web page can't steer an elf into the user's router or printer.
//  http and https only.
//

import Foundation

nonisolated struct FetchPageURLPolicy: Sendable {
    private var searchResultURLKeys: Set<String> = []
    private var openedPageLinkURLKeys: Set<String> = []
    private var userUtteranceURLKeys: Set<String> = []

    mutating func recordSearchResults(_ searchResultURLs: [URL]) {
        searchResultURLKeys.formUnion(searchResultURLs.compactMap(Self.comparisonKey))
    }

    mutating func recordLinks(onOpenedPage linkURLs: [URL]) {
        openedPageLinkURLKeys.formUnion(linkURLs.compactMap(Self.comparisonKey))
    }

    /// Addresses in what the user said or typed may be opened.
    mutating func recordUserUtterance(_ userUtterance: String) {
        guard let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let detectedURLs = linkDetector
            .matches(in: userUtterance, range: NSRange(userUtterance.startIndex..., in: userUtterance))
            .compactMap(\.url)
        userUtteranceURLKeys.formUnion(detectedURLs.compactMap(Self.comparisonKey))
    }

    func allows(_ url: URL) -> Bool {
        guard let urlKey = Self.comparisonKey(url),
              let host = url.host, !Self.isPrivateNetworkHost(host) else { return false }
        return searchResultURLKeys.contains(urlKey) || openedPageLinkURLKeys.contains(urlKey) || userUtteranceURLKeys.contains(urlKey)
    }

    /// The URL as compared: http(s) only, host lowercased, fragment dropped.
    private static func comparisonKey(_ url: URL) -> String? {
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = urlComponents.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = urlComponents.host, !host.isEmpty else { return nil }
        urlComponents.scheme = scheme
        urlComponents.host = host.lowercased()
        urlComponents.fragment = nil
        if urlComponents.path.isEmpty { urlComponents.path = "/" }
        return urlComponents.string
    }

    /// True for names and addresses on the user's own Mac or network.
    static func isPrivateNetworkHost(_ host: String) -> Bool {
        let loweredHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if loweredHost == "localhost" || loweredHost.hasSuffix(".localhost") || loweredHost.hasSuffix(".local")
            || loweredHost.hasSuffix(".internal") || loweredHost.hasSuffix(".lan") || !loweredHost.contains(".") && !loweredHost.contains(":") {
            return true
        }
        // IPv6: loopback, unique local (fc00::/7), link-local (fe80::/10), unspecified.
        if loweredHost.contains(":") {
            return loweredHost == "::1" || loweredHost == "::" || loweredHost.hasPrefix("fc") || loweredHost.hasPrefix("fd")
                || loweredHost.hasPrefix("fe8") || loweredHost.hasPrefix("fe9") || loweredHost.hasPrefix("fea") || loweredHost.hasPrefix("feb")
                || loweredHost.hasPrefix("::ffff:")
        }
        let addressParts = loweredHost.split(separator: ".").compactMap { Int($0) }
        guard addressParts.count == 4, loweredHost.split(separator: ".").count == 4 else { return false }
        switch (addressParts[0], addressParts[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}
