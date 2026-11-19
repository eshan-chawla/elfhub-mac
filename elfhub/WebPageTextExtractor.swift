//
//  WebPageTextExtractor.swift
//  elfhub
//
//  A web page as plain text for an elf to read: its title, the visible
//  text (scripts, styles and other invisible parts dropped, entities
//  decoded, blocks on their own lines, cells kept apart), and the links on
//  it, resolved to full addresses — the only links fetch_page may follow
//  next. One pass over the page, never backtracking, so a hostile page
//  (endless "<", unclosed comments) can't make it slow; run off the main
//  thread by fetch_page.
//

import Foundation

nonisolated struct ExtractedWebPage: Equatable, Sendable {
    let title: String
    let text: String
    let linkURLs: [URL]
}

nonisolated enum WebPageTextExtractor {
    /// The extracted text stops here.
    static let maximumTextCharacters = 400_000
    /// A tag longer than this is treated as text, not a tag.
    private static let maximumTagLength = 4_096

    private static let invisibleElementNames: Set<String> = ["script", "style", "noscript", "svg", "template", "iframe", "head", "object"]
    private static let blockElementNames: Set<String> = [
        "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "tr", "table", "section",
        "article", "header", "footer", "blockquote", "pre", "main", "nav", "aside", "hr", "dl", "dt", "dd", "form",
    ]

    /// Tags inside a line of text: they add nothing between words.
    private static let inlineElementNames: Set<String> = [
        "a", "span", "b", "i", "em", "strong", "u", "code", "small", "sup", "sub", "mark", "abbr", "cite", "q", "s", "label", "font", "time", "kbd",
    ]

    static func page(fromHTML html: String, pageURL: URL) -> ExtractedWebPage {
        let characters = Array(html.unicodeScalars)
        var visibleText = String.UnicodeScalarView()
        // Counted as it grows: asking the text for its count each time
        // would itself be slow on a long page.
        var visibleScalarCount = 0
        var title = ""
        var linkURLs: [URL] = []
        var scalarIndex = 0
        // Where the next ">" is, found once and reused, so scanning stays linear.
        var nextClosingBracketIndex = -1

        func firstIndex(of searchedScalars: [Unicode.Scalar], from startIndex: Int, caseInsensitive: Bool) -> Int? {
            guard !searchedScalars.isEmpty, startIndex < characters.count else { return nil }
            var candidateIndex = startIndex
            while candidateIndex + searchedScalars.count <= characters.count {
                var matches = true
                for (offset, searchedScalar) in searchedScalars.enumerated() {
                    let pageScalar = characters[candidateIndex + offset]
                    let comparedScalar = caseInsensitive ? lowercased(pageScalar) : pageScalar
                    if comparedScalar != searchedScalar {
                        matches = false
                        break
                    }
                }
                if matches { return candidateIndex }
                candidateIndex += 1
            }
            return nil
        }

        // The title, wherever it is (it usually sits in the skipped <head>).
        if let titleStart = firstIndex(of: Array("<title".unicodeScalars), from: 0, caseInsensitive: true),
           let titleOpenEnd = characters[titleStart...].firstIndex(of: ">"),
           let titleEnd = firstIndex(of: Array("</title".unicodeScalars), from: titleOpenEnd + 1, caseInsensitive: true) {
            title = String(String.UnicodeScalarView(characters[(titleOpenEnd + 1)..<titleEnd]))
        }

        while scalarIndex < characters.count, visibleScalarCount < maximumTextCharacters {
            let currentScalar = characters[scalarIndex]
            guard currentScalar == "<" else {
                visibleText.append(currentScalar)
                visibleScalarCount += 1
                scalarIndex += 1
                continue
            }
            // A comment: skip to its end, or drop the rest if it never ends.
            let isCommentStart = scalarIndex + 3 < characters.count
                && characters[scalarIndex + 1] == "!" && characters[scalarIndex + 2] == "-" && characters[scalarIndex + 3] == "-"
            if isCommentStart {
                guard let commentEnd = firstIndex(of: Array("-->".unicodeScalars), from: scalarIndex + 4, caseInsensitive: false) else { break }
                scalarIndex = commentEnd + 3
                continue
            }
            if nextClosingBracketIndex < scalarIndex {
                nextClosingBracketIndex = characters[(scalarIndex + 1)...].firstIndex(of: ">") ?? characters.count
            }
            guard nextClosingBracketIndex < characters.count, nextClosingBracketIndex - scalarIndex <= maximumTagLength else {
                // No tag here after all: it's text.
                visibleText.append(currentScalar)
                visibleScalarCount += 1
                scalarIndex += 1
                continue
            }
            let tagScalars = Array(characters[(scalarIndex + 1)..<nextClosingBracketIndex])
            let isClosingTag = tagScalars.first == "/"
            let tagName = String(String.UnicodeScalarView(tagScalars.drop(while: { $0 == "/" }).prefix(while: { $0.properties.isAlphabetic || ("0"..."9").contains($0) })))
                .lowercased()
            let tagEnd = nextClosingBracketIndex + 1

            if !isClosingTag, invisibleElementNames.contains(tagName) || tagName == "title" {
                // Skip to the matching close; an element never closed hides
                // the rest of the page.
                let closingTagScalars = Array("</\(tagName)".unicodeScalars)
                guard let closingTagStart = firstIndex(of: closingTagScalars, from: tagEnd, caseInsensitive: true) else { break }
                let closingTagEnd = (characters[closingTagStart...].firstIndex(of: ">") ?? (characters.count - 1)) + 1
                scalarIndex = closingTagEnd
                continue
            }
            if !isClosingTag, tagName == "a", let linkTarget = attributeValue(named: "href", in: String(String.UnicodeScalarView(tagScalars))) {
                let decodedLinkTarget = decodedEntities(linkTarget)
                if !decodedLinkTarget.hasPrefix("#"), !decodedLinkTarget.lowercased().hasPrefix("javascript:"),
                   let linkURL = URL(string: decodedLinkTarget, relativeTo: pageURL)?.absoluteURL,
                   ["http", "https"].contains(linkURL.scheme?.lowercased() ?? ""), !linkURLs.contains(linkURL) {
                    linkURLs.append(linkURL)
                }
            }
            // Blocks start a line, inline tags join words, anything else
            // (a table cell, say) keeps its neighbours apart.
            if !inlineElementNames.contains(tagName) {
                visibleText.append(contentsOf: (blockElementNames.contains(tagName) ? "\n" : " ").unicodeScalars)
                visibleScalarCount += 1
            }
            scalarIndex = tagEnd
        }

        let decodedText = decodedEntities(String(visibleText))
        let textLines = decodedText
            .components(separatedBy: "\n")
            .map { textLine in textLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return ExtractedWebPage(
            title: decodedEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
            text: textLines.joined(separator: "\n"),
            linkURLs: linkURLs
        )
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }

    /// An attribute's value in a tag's text (quoted or not).
    private static func attributeValue(named attributeName: String, in tagText: String) -> String? {
        guard let nameRange = tagText.range(of: attributeName + "=", options: .caseInsensitive)
                ?? tagText.range(of: attributeName + " =", options: .caseInsensitive) else { return nil }
        let afterEquals = tagText[nameRange.upperBound...].drop(while: { $0 == " " })
        guard let firstCharacter = afterEquals.first else { return nil }
        if firstCharacter == "\"" || firstCharacter == "'" {
            let quotedValue = afterEquals.dropFirst()
            return quotedValue.firstIndex(of: firstCharacter).map { String(quotedValue[..<$0]) }
        }
        return String(afterEquals.prefix(while: { !$0.isWhitespace && $0 != ">" }))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "euro": "€", "pound": "£",
        "copy": "©", "reg": "®", "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "middot": "·", "times": "×",
    ]
    /// Bounded parts, so this pattern stays linear too.
    private static let entityPattern = try? NSRegularExpression(pattern: #"&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{1,10});"#)

    /// "&amp;" → "&", "&#8212;" → "—", "&#x2014;" → "—".
    static func decodedEntities(_ text: String) -> String {
        guard let entityPattern, text.contains("&") else { return text }
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
