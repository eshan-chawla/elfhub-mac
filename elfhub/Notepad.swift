//
//  Notepad.swift
//  elfhub
//
//  The notepad is a floating window elfhub writes an explanation into while
//  it speaks — steps, a command, code, a short comparison. The model writes
//  it with silent tags in its reply:
//
//    [NOTEPAD:short title]          opens the notepad
//    [NOTEPAD_LINE:markdown line]   adds one line, placed just before the
//                                   sentence that talks about it
//
//  Every model uses tags for this (even ones that point with tools): tool
//  calls only arrive after the reply has finished streaming, and the lines
//  have to appear while elfhub is still talking. Tags are never spoken.
//
//  Pure and unit-tested: parsing, the saved notepad, its markdown blocks and
//  the plain-text / markdown copies.
//

import Foundation

/// One thing the notepad tags ask for, in reply order.
nonisolated enum NotepadItem: Equatable {
    case title(String)
    case line(String)
}

// MARK: - Parsing

// nonisolated: pure, and also used by the nonisolated guidance decoding.
nonisolated enum NotepadTagParser {

    static let defaultNotepadTitle = "Notes"
    /// Keeps a runaway reply from filling the screen.
    static let maximumNotepadLines = 40

    /// NOTEPAD_LINE first so the shorter name never claims its prefix.
    static let notepadTagPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\[(NOTEPAD_LINE|NOTEPAD):([^\]]*)\]"#
    )

    /// Every complete notepad tag in the reply, with where its "[" starts.
    static func notepadItemMatches(inResponseText responseText: String) -> [(item: NotepadItem, tagStartIndex: String.Index)] {
        guard let notepadTagPattern else { return [] }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        return notepadTagPattern.matches(in: responseText, range: fullRange).compactMap { match in
            guard let tagRange = Range(match.range, in: responseText),
                  let tagNameRange = Range(match.range(at: 1), in: responseText),
                  let tagContentRange = Range(match.range(at: 2), in: responseText) else { return nil }
            let tagContent = String(responseText[tagContentRange])
            let notepadItem: NotepadItem = responseText[tagNameRange] == "NOTEPAD"
                ? .title(tagContent.trimmingCharacters(in: .whitespacesAndNewlines))
                : .line(tagContent)
            return (notepadItem, tagRange.lowerBound)
        }
    }

    static func notepadItems(inResponseText responseText: String) -> [NotepadItem] {
        notepadItemMatches(inResponseText: responseText).map(\.item)
    }

    /// The notepad a reply wrote, or nil if it wrote no lines. A title only
    /// counts before the first line — that is when the window opens — so
    /// the saved notepad always matches what was on screen.
    static func notepad(fromResponseText responseText: String) -> SavedNotepad? {
        var notepadTitle: String?
        var markdownLines: [String] = []
        for notepadItem in notepadItems(inResponseText: responseText) {
            switch notepadItem {
            case let .title(titleText):
                if markdownLines.isEmpty, notepadTitle == nil, !titleText.isEmpty {
                    notepadTitle = titleText
                }
            case let .line(lineText):
                if markdownLines.count < maximumNotepadLines {
                    markdownLines.append(cleanedLine(lineText, previousLines: markdownLines))
                }
            }
        }
        guard !markdownLines.isEmpty else { return nil }
        return SavedNotepad(title: notepadTitle ?? defaultNotepadTitle, markdownLines: markdownLines)
    }

    /// Trims the space models put after the colon — except inside a code
    /// block, where leading spaces are indentation.
    static func cleanedLine(_ lineText: String, previousLines: [String]) -> String {
        let isInsideCodeBlock = previousLines.filter(NotepadBlock.isCodeFenceLine).count % 2 == 1
        let lineWithoutTrailingWhitespace = String(lineText.reversed().drop(while: \.isWhitespace).reversed())
        if isInsideCodeBlock && !NotepadBlock.isCodeFenceLine(lineText) {
            return lineWithoutTrailingWhitespace.trimmingCharacters(in: .newlines)
        }
        return lineWithoutTrailingWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingNotepadTags(from responseText: String) -> String {
        guard let notepadTagPattern else { return responseText }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        return notepadTagPattern.stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
    }
}

// MARK: - Saved Notepad

/// A notepad as shown on screen and saved on the reply in chat history.
nonisolated struct SavedNotepad: Codable, Equatable {
    let title: String
    let markdownLines: [String]

    /// "Copy as Markdown": the title as a heading, then the lines as written.
    var markdownText: String {
        "# \(title)\n\n" + markdownLines.joined(separator: "\n")
    }

    /// "Copy": friendly text to paste anywhere — no #, **, backticks or
    /// fences. Bullets become "•", numbered steps keep their numbers.
    var plainText: String {
        var plainLines = [title, ""]
        for notepadBlock in NotepadBlock.blocks(fromMarkdownLines: markdownLines) {
            let plainBlockText = notepadBlock.kind == .code
                ? notepadBlock.text
                : NotepadBlock.plainText(fromInlineMarkdown: notepadBlock.text)
            switch notepadBlock.kind {
            case .heading:
                plainLines.append(plainBlockText)
            case .bullet:
                plainLines.append("• " + plainBlockText)
            case let .numbered(number):
                plainLines.append("\(number). " + plainBlockText)
            case .quote, .paragraph, .code:
                plainLines.append(plainBlockText)
            case .rule:
                plainLines.append("")
            }
        }
        return plainLines.joined(separator: "\n")
    }

    /// How the notepad is remembered in the model's history: the window
    /// isn't in screenshots, so this is how follow-ups ("what was step
    /// two?") can refer to it.
    var textForConversationHistory: String {
        "[notepad shown on screen: \(title)]\n" + markdownLines.joined(separator: "\n")
    }
}

// MARK: - Markdown Blocks

/// One rendered piece of a notepad. Lines are grouped only for code blocks
/// (everything between ``` fences); every other line is its own block.
nonisolated struct NotepadBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case bullet
        case numbered(number: String)
        case quote
        case rule
        case code
        case paragraph
    }

    let kind: Kind
    /// Inline markdown, without the line's block marker ("- ", "## ", …).
    /// For code, the raw lines joined with newlines.
    let text: String

    static func isCodeFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    static func blocks(fromMarkdownLines markdownLines: [String]) -> [NotepadBlock] {
        var notepadBlocks: [NotepadBlock] = []
        var openCodeBlockLines: [String]?

        for markdownLine in markdownLines {
            if isCodeFenceLine(markdownLine) {
                if let codeBlockLines = openCodeBlockLines {
                    notepadBlocks.append(NotepadBlock(kind: .code, text: codeBlockLines.joined(separator: "\n")))
                    openCodeBlockLines = nil
                } else {
                    openCodeBlockLines = []
                }
                continue
            }
            if openCodeBlockLines != nil {
                openCodeBlockLines?.append(markdownLine)
                continue
            }
            if let notepadBlock = block(fromSingleLine: markdownLine) {
                notepadBlocks.append(notepadBlock)
            }
        }

        // While streaming, the closing fence may not have arrived yet.
        if let codeBlockLines = openCodeBlockLines, !codeBlockLines.isEmpty {
            notepadBlocks.append(NotepadBlock(kind: .code, text: codeBlockLines.joined(separator: "\n")))
        }
        return notepadBlocks
    }

    private static func block(fromSingleLine markdownLine: String) -> NotepadBlock? {
        let trimmedLine = markdownLine.trimmingCharacters(in: .whitespaces)
        guard !trimmedLine.isEmpty else { return nil }

        if ["---", "***", "___"].contains(trimmedLine) {
            return NotepadBlock(kind: .rule, text: "")
        }

        let headingMarker = trimmedLine.prefix { $0 == "#" }
        if !headingMarker.isEmpty, headingMarker.count <= 6, trimmedLine.dropFirst(headingMarker.count).first == " " {
            let headingText = trimmedLine.dropFirst(headingMarker.count).trimmingCharacters(in: .whitespaces)
            return NotepadBlock(kind: .heading(level: min(headingMarker.count, 3)), text: headingText)
        }

        for bulletMarker in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(bulletMarker) {
            return NotepadBlock(kind: .bullet, text: String(trimmedLine.dropFirst(bulletMarker.count)))
        }

        if trimmedLine.hasPrefix(">") {
            return NotepadBlock(kind: .quote, text: trimmedLine.dropFirst().trimmingCharacters(in: .whitespaces))
        }

        let leadingDigits = trimmedLine.prefix { $0.isNumber }
        let textAfterDigits = trimmedLine.dropFirst(leadingDigits.count)
        if !leadingDigits.isEmpty, textAfterDigits.hasPrefix(". ") || textAfterDigits.hasPrefix(") ") {
            return NotepadBlock(
                kind: .numbered(number: String(leadingDigits)),
                text: String(textAfterDigits.dropFirst(2))
            )
        }

        return NotepadBlock(kind: .paragraph, text: trimmedLine)
    }

    /// **bold**, *italic*, `code` and links rendered; anything that isn't
    /// valid markdown shows as written.
    static func attributedText(fromInlineMarkdown inlineMarkdown: String) -> AttributedString {
        let inlineOnlyOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: inlineMarkdown, options: inlineOnlyOptions)) ?? AttributedString(inlineMarkdown)
    }

    static func plainText(fromInlineMarkdown inlineMarkdown: String) -> String {
        String(attributedText(fromInlineMarkdown: inlineMarkdown).characters)
    }
}
