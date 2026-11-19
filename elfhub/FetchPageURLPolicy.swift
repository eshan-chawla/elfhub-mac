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

    /// The URL as compared: http and https alike (pages are fetched over
    /// https), host lowercased, fragment dropped.
    private static func comparisonKey(_ url: URL) -> String? {
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = urlComponents.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = urlComponents.host, !host.isEmpty else { return nil }
        urlComponents.scheme = "https"
        urlComponents.host = host.lowercased()
        urlComponents.fragment = nil
        if urlComponents.path.isEmpty { urlComponents.path = "/" }
        return urlComponents.string
    }

    /// The https form of an http(s) address: elfs always fetch over https.
    static func httpsURL(for url: URL) -> URL? {
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = urlComponents.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        urlComponents.scheme = "https"
        return urlComponents.url
    }

    /// True for names and addresses on the user's own Mac or network, and
    /// for addresses that aren't ordinary internet hosts (multicast,
    /// reserved, benchmarking, NAT64 and other mapped forms).
    static func isPrivateNetworkHost(_ host: String) -> Bool {
        var loweredHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while loweredHost.hasSuffix(".") { loweredHost.removeLast() }
        if let zoneIndex = loweredHost.firstIndex(of: "%") { loweredHost = String(loweredHost[..<zoneIndex]) }
        guard !loweredHost.isEmpty else { return true }

        var ipv4Address = in_addr()
        if inet_pton(AF_INET, loweredHost, &ipv4Address) == 1 {
            return isPrivateIPv4(UInt32(bigEndian: ipv4Address.s_addr))
        }
        var ipv6Address = in6_addr()
        if inet_pton(AF_INET6, loweredHost, &ipv6Address) == 1 {
            let addressBytes = withUnsafeBytes(of: ipv6Address) { Array($0) }
            return isPrivateIPv6(addressBytes)
        }
        // A name: local-only names and single words (no dot) never reach
        // the internet; anything else is resolved and checked again.
        return loweredHost == "localhost" || loweredHost.hasSuffix(".localhost") || loweredHost.hasSuffix(".local")
            || loweredHost.hasSuffix(".internal") || loweredHost.hasSuffix(".lan") || loweredHost.hasSuffix(".home.arpa")
            || !loweredHost.contains(".")
    }

    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let firstOctet = address >> 24
        let secondOctet = (address >> 16) & 0xFF
        switch (firstOctet, secondOctet) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        case (198, 18...19): return true
        case (192, 0) where (address >> 8) & 0xFF == 0: return true
        default: return firstOctet >= 224
        }
    }

    private static func isPrivateIPv6(_ addressBytes: [UInt8]) -> Bool {
        let leadingZeroCount = addressBytes.prefix(while: { $0 == 0 }).count
        // ::, ::1 and IPv4-compatible ::a.b.c.d
        if leadingZeroCount >= 12 {
            let embeddedIPv4 = addressBytes[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return embeddedIPv4 <= 1 || isPrivateIPv4(embeddedIPv4)
        }
        // IPv4-mapped ::ffff:a.b.c.d
        if leadingZeroCount == 10, addressBytes[10] == 0xFF, addressBytes[11] == 0xFF {
            return isPrivateIPv4(addressBytes[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        // NAT64 64:ff9b::/96
        if addressBytes[0] == 0x00, addressBytes[1] == 0x64, addressBytes[2] == 0xFF, addressBytes[3] == 0x9B { return true }
        // Unique local fc00::/7, link-local fe80::/10, site-local fec0::/10, multicast ff00::/8
        if addressBytes[0] & 0xFE == 0xFC { return true }
        if addressBytes[0] == 0xFE, addressBytes[1] & 0x80 == 0x80 { return true }
        if addressBytes[0] == 0xFF { return true }
        return false
    }
}
