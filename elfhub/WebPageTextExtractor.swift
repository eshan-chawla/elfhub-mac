//
//  WebPageTextExtractor.swift
//  elfhub
//
//  A web page as plain text for an elf to read: its title, the visible
//  text (scripts, styles and other invisible parts dropped, entities
//  decoded, blocks on their own lines), and the links on it, resolved to
//  full addresses — the only links fetch_page may follow next.
//

import Foundation

nonisolated struct ExtractedWebPage: Equatable, Sendable {
    let title: String
    let text: String
    let linkURLs: [URL]
}

nonisolated enum WebPageTextExtractor {
    private static let invisibleElementPattern = try? NSRegularExpression(
        pattern: #"<(script|style|noscript|svg|template|iframe|head)\b[^>]*>[\s\S]*?</\1\s*>"#,
        options: [.caseInsensitive]
    )
    private static let titlePattern = try? NSRegularExpression(pattern: #"<title\b[^>]*>([\s\S]*?)</title\s*>"#, options: [.caseInsensitive])
    private static let linkPattern = try? NSRegularExpression(pattern: #"<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
    private static let blockBoundaryPattern = try? NSRegularExpression(
        pattern: #"</?(p|div|br|h[1-6]|li|ul|ol|tr|table|section|article|header|footer|blockquote|pre)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let anyTagPattern = try? NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let commentPattern = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)

    static func page(fromHTML html: String, pageURL: URL) -> ExtractedWebPage {
        let title = firstCapture(of: titlePattern, in: html).map(decodedEntities)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let linkURLs = allCaptures(of: linkPattern, in: html).compactMap { linkTarget -> URL? in
            let decodedLinkTarget = decodedEntities(linkTarget)
            guard !decodedLinkTarget.hasPrefix("#"), !decodedLinkTarget.lowercased().hasPrefix("javascript:"),
                  let linkURL = URL(string: decodedLinkTarget, relativeTo: pageURL)?.absoluteURL,
                  ["http", "https"].contains(linkURL.scheme?.lowercased() ?? "") else { return nil }
            return linkURL
        }

        var visibleHTML = replacing(commentPattern, in: html, with: " ")
        visibleHTML = replacing(invisibleElementPattern, in: visibleHTML, with: " ")
        visibleHTML = replacing(blockBoundaryPattern, in: visibleHTML, with: "\n")
        visibleHTML = replacing(anyTagPattern, in: visibleHTML, with: "")
        let decodedText = decodedEntities(visibleHTML)
        let textLines = decodedText
            .components(separatedBy: "\n")
            .map { textLine in textLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var uniqueLinkURLs: [URL] = []
        for linkURL in linkURLs where !uniqueLinkURLs.contains(linkURL) {
            uniqueLinkURLs.append(linkURL)
        }
        return ExtractedWebPage(title: title, text: textLines.joined(separator: "\n"), linkURLs: uniqueLinkURLs)
    }

    private static func replacing(_ pattern: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let pattern else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstCapture(of pattern: NSRegularExpression?, in text: String) -> String? {
        guard let match = pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func allCaptures(of pattern: NSRegularExpression?, in text: String) -> [String] {
        (pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "euro": "€", "pound": "£",
        "copy": "©", "reg": "®", "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "middot": "·", "times": "×",
    ]
    private static let entityPattern = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)

    /// "&amp;" → "&", "&#8212;" → "—", "&#x2014;" → "—".
    static func decodedEntities(_ text: String) -> String {
        guard let entityPattern else { return text }
        var decodedText = ""
        var lastIndex = text.startIndex
        for match in entityPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let matchRange = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            decodedText += text[lastIndex..<matchRange.lowerBound]
            let entityName = String(text[nameRange])
            var replacement: String?
            if entityName.hasPrefix("#x") || entityName.hasPrefix("#X") {
                replacement = UInt32(entityName.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entityName.hasPrefix("#") {
                replacement = UInt32(entityName.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[entityName.lowercased()]
            }
            decodedText += replacement ?? String(text[matchRange])
            lastIndex = matchRange.upperBound
        }
        decodedText += text[lastIndex...]
        return decodedText
    }
}
