//
//  SpokenSentenceSegmenter.swift
//  elfhub
//
//  Turns a model reply that is still streaming in into whole sentences that
//  can be spoken right away, so elfhub starts talking after the first
//  sentence instead of after the whole reply.
//
//  Guidance tags ([POINT:...], [HIGHLIGHT:...], [CLICK:...]) are silent, so they
//  are removed before speaking; a tag that has started but not yet closed is
//  held back until it does. Notepad tags ([NOTEPAD:...], [NOTEPAD_LINE:...])
//  are silent too, but each one travels with the sentence after it, so the
//  notepad line appears as elfhub starts talking about it. Pure and
//  unit-tested.
//

import Foundation

/// One sentence ready to speak, plus the notepad items to show as it starts.
/// The text is empty for notepad items written after the last sentence.
struct SpokenSentenceSegment: Equatable {
    let text: String
    let notepadItemsToShowFirst: [NotepadItem]
}

struct SpokenSentenceSegmenter {

    /// Sentences shorter than this are joined with the next one, so speech
    /// isn't chopped into tiny clips ("Sure." "Okay.").
    static let minimumSentenceLength = 24

    private static let guidanceTagNames = [
        "POINT", "CLICK", "DOUBLECLICK", "SCROLL", "TYPE", "KEY",
        "HIGHLIGHT", "CIRCLE", "ARROW", "UNDERLINE", "NOTE",
        "NOTEPAD", "NOTEPAD_LINE",
        "DELETE_FILE",
    ]

    /// Elf tag blocks ([FILE:…]…[/FILE], [SKILL:…]…[/SKILL]) whose content is
    /// never spoken.
    private static let completeSilentBlockPattern = try? NSRegularExpression(
        pattern: #"\[(FILE|SKILL):[^\]]*\][\s\S]*?\[/\1\]"#
    )
    private static let silentBlockOpenerPattern = try? NSRegularExpression(pattern: #"\[(FILE|SKILL):[^\]]*\]"#)

    private static let completeGuidanceTagPattern: NSRegularExpression? = {
        let tagNameAlternation = guidanceTagNames.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"\[(?:"# + tagNameAlternation + #"):[^\]]*\]"#)
    }()

    private var rawResponseText = ""
    /// How much of the speakable text has already been handed out.
    private var emittedSpeakableCharacterCount = 0
    /// How many of the reply's notepad items have been handed out.
    private var emittedNotepadItemCount = 0

    /// Adds newly streamed text and returns any sentences now complete.
    mutating func append(_ textDelta: String) -> [SpokenSentenceSegment] {
        rawResponseText += textDelta
        return takeCompleteSentences(isFinal: false)
    }

    /// Call once the reply is complete: returns whatever is left.
    mutating func finish() -> [SpokenSentenceSegment] {
        takeCompleteSentences(isFinal: true)
    }

    /// One model round ended and another may follow (it used a tool): the
    /// text held back waiting for the sentence to end is spoken now, so it
    /// isn't glued to the next round's first words.
    mutating func endOfModelRound() -> [SpokenSentenceSegment] {
        let heldBackSegments = takeCompleteSentences(isFinal: true)
        rawResponseText += "\n"
        return heldBackSegments + takeCompleteSentences(isFinal: false)
    }

    // MARK: - Speakable text

    /// The reply with complete guidance tags removed and any unfinished tag at
    /// the end cut off. Also used for the live caption.
    static func speakableText(fromPartialResponse partialResponseText: String) -> String {
        var speakableText = partialResponseText
        // Silent blocks go first, whole; an open one holds back everything
        // after it until it closes (and is dropped if it never does).
        if let completeSilentBlockPattern {
            speakableText = completeSilentBlockPattern.stringByReplacingMatches(
                in: speakableText, range: NSRange(speakableText.startIndex..., in: speakableText), withTemplate: ""
            )
        }
        if let openBlockMatch = silentBlockOpenerPattern?.firstMatch(
            in: speakableText, range: NSRange(speakableText.startIndex..., in: speakableText)
        ), let openBlockRange = Range(openBlockMatch.range, in: speakableText) {
            speakableText = String(speakableText[..<openBlockRange.lowerBound])
        }
        if let completeGuidanceTagPattern {
            let fullRange = NSRange(speakableText.startIndex..., in: speakableText)
            speakableText = completeGuidanceTagPattern.stringByReplacingMatches(
                in: speakableText, range: fullRange, withTemplate: ""
            )
        }
        if let unfinishedTagStart = startOfUnfinishedGuidanceTag(in: speakableText) {
            speakableText = String(speakableText[..<unfinishedTagStart])
        }
        return speakableText
    }

    /// The position of a trailing "[" that could still become a guidance tag
    /// (e.g. "[", "[POI", "[POINT:12,3"), or nil if there is none.
    private static func startOfUnfinishedGuidanceTag(in text: String) -> String.Index? {
        guard let lastOpeningBracket = text.lastIndex(of: "["),
              !text[lastOpeningBracket...].contains("]") else { return nil }
        let textAfterBracket = text[text.index(after: lastOpeningBracket)...]
        let tagNamePart = textAfterBracket.prefix { $0 != ":" }
        let possibleTagNames = guidanceTagNames + ElfToolTags.silentBlockTagNames
        let couldBeTagName = possibleTagNames.contains { $0.hasPrefix(tagNamePart) }
        // Once a colon follows a full tag name, everything up to "]" is the tag.
        let hasCompleteTagNameAndColon = textAfterBracket.contains(":") && possibleTagNames.contains(String(tagNamePart))
        return (couldBeTagName || hasCompleteTagNameAndColon) ? lastOpeningBracket : nil
    }

    // MARK: - Sentence splitting

    /// Each complete notepad tag and how much speakable text comes before
    /// it — the point in the speech where it belongs.
    private static func notepadItemsWithSpeakablePositions(
        inResponse responseText: String
    ) -> [(item: NotepadItem, speakableCharacterOffset: Int)] {
        NotepadTagParser.notepadItemMatches(inResponseText: responseText).map { notepadItemMatch in
            let textBeforeTag = String(responseText[..<notepadItemMatch.tagStartIndex])
            return (notepadItemMatch.item, speakableText(fromPartialResponse: textBeforeTag).count)
        }
    }

    /// Hands out the notepad items that come before `speakableCharacterOffset`
    /// (or all remaining ones), in order.
    private mutating func takeNotepadItems(
        from notepadItemsWithPositions: [(item: NotepadItem, speakableCharacterOffset: Int)],
        before speakableCharacterOffset: Int?
    ) -> [NotepadItem] {
        var takenNotepadItems: [NotepadItem] = []
        while emittedNotepadItemCount < notepadItemsWithPositions.count {
            let nextNotepadItem = notepadItemsWithPositions[emittedNotepadItemCount]
            if let speakableCharacterOffset, nextNotepadItem.speakableCharacterOffset >= speakableCharacterOffset {
                break
            }
            takenNotepadItems.append(nextNotepadItem.item)
            emittedNotepadItemCount += 1
        }
        return takenNotepadItems
    }

    /// True when a notepad item is the next thing after `speakableOffset`,
    /// with only whitespace before it.
    private static func isNotepadItemNext(
        afterSpeakableOffset speakableOffset: Int,
        notepadItemsWithPositions: [(item: NotepadItem, speakableCharacterOffset: Int)],
        unemittedCharacters: [Character],
        emittedSpeakableCharacterCount: Int
    ) -> Bool {
        guard let nextNotepadItemOffset = notepadItemsWithPositions
            .map(\.speakableCharacterOffset)
            .first(where: { $0 >= speakableOffset }) else { return false }
        let textBetween = unemittedCharacters[
            (speakableOffset - emittedSpeakableCharacterCount)..<(nextNotepadItemOffset - emittedSpeakableCharacterCount)
        ]
        return textBetween.allSatisfy(\.isWhitespace)
    }

    private mutating func takeCompleteSentences(isFinal: Bool) -> [SpokenSentenceSegment] {
        let notepadItemsWithPositions = Self.notepadItemsWithSpeakablePositions(inResponse: rawResponseText)
        var segments = takeCompleteSpokenSentences(isFinal: isFinal, notepadItemsWithPositions: notepadItemsWithPositions)
        if isFinal {
            let notepadItemsAfterLastSentence = takeNotepadItems(from: notepadItemsWithPositions, before: nil)
            if !notepadItemsAfterLastSentence.isEmpty {
                segments.append(SpokenSentenceSegment(text: "", notepadItemsToShowFirst: notepadItemsAfterLastSentence))
            }
        }
        return segments
    }

    private mutating func takeCompleteSpokenSentences(
        isFinal: Bool,
        notepadItemsWithPositions: [(item: NotepadItem, speakableCharacterOffset: Int)]
    ) -> [SpokenSentenceSegment] {
        let speakableText = Self.speakableText(fromPartialResponse: rawResponseText)
        guard speakableText.count > emittedSpeakableCharacterCount else { return [] }

        let unemittedText = String(speakableText.dropFirst(emittedSpeakableCharacterCount))
        var segments: [SpokenSentenceSegment] = []
        var consumedCharacterCount = 0
        var sentenceStartOffset = 0
        var characterOffset = 0
        let unemittedCharacters = Array(unemittedText)

        while characterOffset < unemittedCharacters.count {
            let character = unemittedCharacters[characterOffset]
            let isSentenceEndPunctuation = character == "." || character == "!" || character == "?"
            let nextCharacter: Character? = characterOffset + 1 < unemittedCharacters.count
                ? unemittedCharacters[characterOffset + 1] : nil
            let endsSentence = character == "\n"
                || (isSentenceEndPunctuation && (nextCharacter == " " || nextCharacter == "\n"))

            if endsSentence {
                let sentenceEndOffset = characterOffset + 1
                let candidateSentence = String(unemittedCharacters[sentenceStartOffset..<sentenceEndOffset])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Short sentences are normally joined, but never across a
                // notepad line: it has to appear between them.
                let notepadItemComesNext = !candidateSentence.isEmpty && Self.isNotepadItemNext(
                    afterSpeakableOffset: emittedSpeakableCharacterCount + sentenceEndOffset,
                    notepadItemsWithPositions: notepadItemsWithPositions,
                    unemittedCharacters: unemittedCharacters,
                    emittedSpeakableCharacterCount: emittedSpeakableCharacterCount
                )
                if candidateSentence.count >= Self.minimumSentenceLength || notepadItemComesNext {
                    segments.append(SpokenSentenceSegment(
                        text: candidateSentence,
                        notepadItemsToShowFirst: takeNotepadItems(
                            from: notepadItemsWithPositions,
                            before: emittedSpeakableCharacterCount + sentenceEndOffset
                        )
                    ))
                    sentenceStartOffset = sentenceEndOffset
                    consumedCharacterCount = sentenceEndOffset
                }
            }
            characterOffset += 1
        }

        if isFinal {
            let remainingText = String(unemittedCharacters[consumedCharacterCount...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty {
                segments.append(SpokenSentenceSegment(
                    text: remainingText,
                    notepadItemsToShowFirst: takeNotepadItems(
                        from: notepadItemsWithPositions,
                        before: emittedSpeakableCharacterCount + unemittedCharacters.count
                    )
                ))
            }
            consumedCharacterCount = unemittedCharacters.count
        }

        emittedSpeakableCharacterCount += consumedCharacterCount
        return segments
    }
}
