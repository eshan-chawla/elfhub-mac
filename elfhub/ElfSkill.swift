//
//  ElfSkill.swift
//  elfhub
//
//  A skill is one piece of working knowledge ("how the team deploys"),
//  stored the way Hermes and other agentskills.io agents store skills, so
//  their skill folders can be dropped straight into an elf's skills/:
//
//    skills/<slug>/SKILL.md
//
//      ---
//      name: Deploying the web app
//      description: Steps and gotchas for shipping the web app.
//      license: MIT              ← keys elfhub doesn't use are kept as written
//      ---
//
//      the body, in markdown…
//
//  Other files a skill folder carries (references/, scripts/, assets/) are
//  data only: elfhub never runs them.
//

import Foundation

nonisolated struct ElfSkill: Identifiable, Equatable, Sendable {
    /// The skill's folder name under skills/.
    let slug: String
    var name: String
    var description: String
    var body: String
    /// Frontmatter lines elfhub doesn't use (license, metadata, version…),
    /// written back unchanged so a Hermes skill keeps everything it came with.
    var unrecognizedFrontmatterLines: [String]

    var id: String { slug }

    init(slug: String, name: String, description: String, body: String, unrecognizedFrontmatterLines: [String] = []) {
        self.slug = slug
        self.name = name
        self.description = description
        self.body = body
        self.unrecognizedFrontmatterLines = unrecognizedFrontmatterLines
    }

    /// A new skill, filed in a folder named after it.
    init(name: String, description: String, body: String) {
        self.init(slug: Self.slug(forName: name), name: name, description: description, body: body)
    }

    /// The SKILL.md file's contents.
    var skillMarkdown: String {
        var markdownLines = [
            "---",
            "name: " + Self.frontmatterScalar(name),
            "description: " + Self.frontmatterBlockOrScalar(description),
        ]
        markdownLines.append(contentsOf: unrecognizedFrontmatterLines)
        markdownLines.append("---")
        markdownLines.append("")
        markdownLines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        return markdownLines.joined(separator: "\n") + "\n"
    }

    /// Reads a SKILL.md file. Without a name in its frontmatter (or without
    /// frontmatter at all) the skill is named after its folder.
    static func parse(slug: String, skillMarkdown: String) -> ElfSkill {
        let parsedSkillFile = SkillFrontmatterParser.parse(skillMarkdown)
        let frontmatterName = parsedSkillFile.frontmatterValues["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ElfSkill(
            slug: slug,
            name: frontmatterName.isEmpty ? slug.replacingOccurrences(of: "-", with: " ") : frontmatterName,
            description: parsedSkillFile.frontmatterValues["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            body: parsedSkillFile.body,
            unrecognizedFrontmatterLines: parsedSkillFile.unrecognizedFrontmatterLines
        )
    }

    /// "Deploying the Web App!" → "deploying-the-web-app": lowercase letters,
    /// digits and hyphens, at most 64 characters. `fallback` is used when
    /// nothing usable is left (a name made only of emoji or punctuation).
    static func slug(forName name: String, fallback: String = "skill") -> String {
        var slugCharacters: [Character] = []
        var previousCharacterWasSeparator = true
        // Accents are folded first ("José" → "jose"); anything else that
        // isn't an ASCII letter or digit becomes a separator, so folder
        // names stay portable across file systems and zip tools.
        let foldedName = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for character in foldedName {
            if (character.isLetter || character.isNumber) && character.isASCII {
                slugCharacters.append(character)
                previousCharacterWasSeparator = false
            } else if !previousCharacterWasSeparator {
                slugCharacters.append("-")
                previousCharacterWasSeparator = true
            }
        }
        let slug = String(slugCharacters.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? fallback : slug
    }

    /// A value with line breaks as a `|` block (indented lines keep the
    /// breaks); anything else on one line.
    private static func frontmatterBlockOrScalar(_ value: String) -> String {
        let normalizedValue = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedValue.contains("\n") else { return frontmatterScalar(normalizedValue) }
        let indentedLines = normalizedValue
            .components(separatedBy: "\n")
            .map { valueLine in valueLine.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "  " + valueLine }
        return "|\n" + indentedLines.joined(separator: "\n")
    }

    /// A frontmatter value on one line, double-quoted when YAML would
    /// otherwise read it differently (a colon, a #, edge spaces, a leading
    /// YAML symbol, or nothing at all).
    private static func frontmatterScalar(_ value: String) -> String {
        let singleLineValue = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let yamlSymbolsThatCantStartAPlainValue = Set("-?:,[]{}#&*!|>'\"%@`")
        let needsQuotes = singleLineValue.isEmpty
            || singleLineValue.contains(":")
            || singleLineValue.contains("#")
            || singleLineValue.first.map { $0 == " " || yamlSymbolsThatCantStartAPlainValue.contains($0) } == true
            || singleLineValue.last == " "
        guard needsQuotes else { return singleLineValue }
        let escapedValue = singleLineValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedValue)\""
    }
}

// MARK: - Frontmatter

/// Reads the small part of YAML that skill frontmatter uses: `key: value`,
/// quoted values, and `>` / `|` block values spread over indented lines.
/// Keys other than name and description are kept verbatim, with their
/// indented lines, so nothing a skill carries is lost.
nonisolated enum SkillFrontmatterParser {
    struct ParsedSkillFile: Equatable, Sendable {
        var frontmatterValues: [String: String]
        var unrecognizedFrontmatterLines: [String]
        var body: String
    }

    static let recognizedKeys: Set<String> = ["name", "description"]

    static func parse(_ skillMarkdown: String) -> ParsedSkillFile {
        let normalizedMarkdown = skillMarkdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let markdownLines = normalizedMarkdown.components(separatedBy: "\n")

        // Frontmatter only counts when it opens the file and is closed; an
        // unclosed block is ordinary markdown.
        // The closing "---" starts at the line's beginning; an indented one
        // is text inside a block value.
        guard markdownLines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingLineIndex = markdownLines.indices.dropFirst().first(where: {
                  markdownLines[$0].hasPrefix("---") && markdownLines[$0].trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return ParsedSkillFile(
                frontmatterValues: [:],
                unrecognizedFrontmatterLines: [],
                body: normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let frontmatterLines = Array(markdownLines[1..<closingLineIndex])
        let body = markdownLines[(closingLineIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var frontmatterValues: [String: String] = [:]
        var unrecognizedFrontmatterLines: [String] = []
        var lineIndex = 0
        while lineIndex < frontmatterLines.count {
            let topLevelLine = frontmatterLines[lineIndex]
            lineIndex += 1
            if topLevelLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Indented (or blank) lines that follow belong to this key.
            var continuationLines: [String] = []
            while lineIndex < frontmatterLines.count, isContinuationLine(frontmatterLines[lineIndex]) {
                continuationLines.append(frontmatterLines[lineIndex])
                lineIndex += 1
            }
            while let lastContinuationLine = continuationLines.last,
                  lastContinuationLine.trimmingCharacters(in: .whitespaces).isEmpty {
                continuationLines.removeLast()
            }

            guard let colonIndex = topLevelLine.firstIndex(of: ":") else {
                unrecognizedFrontmatterLines.append(topLevelLine)
                unrecognizedFrontmatterLines.append(contentsOf: continuationLines)
                continue
            }
            let key = topLevelLine[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let valueOnKeyLine = topLevelLine[topLevelLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if recognizedKeys.contains(key) {
                frontmatterValues[key] = scalarValue(valueOnKeyLine: valueOnKeyLine, continuationLines: continuationLines)
            } else {
                unrecognizedFrontmatterLines.append(topLevelLine)
                unrecognizedFrontmatterLines.append(contentsOf: continuationLines)
            }
        }

        return ParsedSkillFile(
            frontmatterValues: frontmatterValues,
            unrecognizedFrontmatterLines: unrecognizedFrontmatterLines,
            body: body
        )
    }

    private static func isContinuationLine(_ frontmatterLine: String) -> Bool {
        frontmatterLine.trimmingCharacters(in: .whitespaces).isEmpty
            || frontmatterLine.hasPrefix(" ")
            || frontmatterLine.hasPrefix("\t")
    }

    private static func scalarValue(valueOnKeyLine: String, continuationLines: [String]) -> String {
        let continuationTexts = continuationLines.map { $0.trimmingCharacters(in: .whitespaces) }

        // `>` folds the lines into one paragraph; `|` keeps the line breaks.
        // Chomping indicators (`>-`, `|+`) are accepted; values are trimmed.
        if let blockIndicator = valueOnKeyLine.first, blockIndicator == ">" || blockIndicator == "|" {
            if blockIndicator == "|" {
                return continuationTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var foldedParagraphs: [String] = []
            var currentParagraphWords: [String] = []
            for continuationText in continuationTexts {
                if continuationText.isEmpty {
                    foldedParagraphs.append(currentParagraphWords.joined(separator: " "))
                    currentParagraphWords = []
                } else {
                    currentParagraphWords.append(continuationText)
                }
            }
            foldedParagraphs.append(currentParagraphWords.joined(separator: " "))
            return foldedParagraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A quoted value may run on over indented lines; they join with
        // spaces, as YAML folds them.
        let joinedValue = ([valueOnKeyLine] + continuationTexts)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if joinedValue.count >= 2, joinedValue.hasPrefix("\""), joinedValue.hasSuffix("\"") {
            return unescapedDoubleQuotedText(String(joinedValue.dropFirst().dropLast()))
        }
        if joinedValue.count >= 2, joinedValue.hasPrefix("'"), joinedValue.hasSuffix("'") {
            return String(joinedValue.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }

        // A plain value may run on over indented lines too. " #" starts a
        // comment, which isn't part of the value ("C#" is).
        return ([valueOnKeyLine] + continuationTexts)
            .map(Self.textBeforeComment)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A plain value's text before a " #" comment, trimmed.
    private static func textBeforeComment(_ plainText: String) -> String {
        if plainText.hasPrefix("#") { return "" }
        guard let commentRange = plainText.range(of: " #") else { return plainText }
        return String(plainText[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func unescapedDoubleQuotedText(_ quotedText: String) -> String {
        var unescapedText = ""
        var isAfterBackslash = false
        var remainingCharacters = Substring(quotedText)
        while let character = remainingCharacters.popFirst() {
            if isAfterBackslash {
                switch character {
                case "n": unescapedText.append("\n")
                case "t": unescapedText.append("\t")
                case "u":
                    // \uXXXX: four hex digits naming a character.
                    let hexDigits = String(remainingCharacters.prefix(4))
                    if hexDigits.count == 4,
                       let scalarValue = UInt32(hexDigits, radix: 16),
                       let unicodeScalar = Unicode.Scalar(scalarValue) {
                        unescapedText.unicodeScalars.append(unicodeScalar)
                        remainingCharacters = remainingCharacters.dropFirst(4)
                    } else {
                        unescapedText.append(character)
                    }
                default: unescapedText.append(character)
                }
                isAfterBackslash = false
            } else if character == "\\" {
                isAfterBackslash = true
            } else {
                unescapedText.append(character)
            }
        }
        return unescapedText
    }
}

// MARK: - Skills from before SKILL.md

/// Phase one stored each skill as one file, skills/<name>.md:
///
///     # Deploying the web app
///     > Steps and gotchas for shipping the web app.
///
///     the body…
///
/// `ElfHome.migrateLegacySkillFilesIfNeeded()` moves those into SKILL.md
/// folders once.
nonisolated enum ElfLegacySkillMigration {
    static func skill(fromLegacyFileName legacyFileName: String, markdown: String) -> ElfSkill {
        var remainingLines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]
        func dropBlankLines() {
            while let firstLine = remainingLines.first, firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
                remainingLines = remainingLines.dropFirst()
            }
        }

        dropBlankLines()
        var name = legacyFileName.replacingOccurrences(of: "-", with: " ")
        if let firstLine = remainingLines.first, firstLine.hasPrefix("# ") {
            name = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            remainingLines = remainingLines.dropFirst()
        }
        dropBlankLines()
        var description = ""
        if let firstLine = remainingLines.first, firstLine.hasPrefix(">") {
            description = String(firstLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            remainingLines = remainingLines.dropFirst()
        }
        let body = remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ElfSkill(slug: ElfSkill.slug(forName: legacyFileName), name: name, description: description, body: body)
    }
}
