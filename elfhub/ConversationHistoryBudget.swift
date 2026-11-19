//
//  ConversationHistoryBudget.swift
//  elfhub
//
//  Keeps the chat history sent with each turn small, whatever was said.
//  The model gets the last ten exchanges (six for a side Elf), but one long
//  answer with a full notepad could otherwise make every later turn costly.
//  So in what's sent — never in the chat itself — each message is cut to a
//  set length (its start and end kept, the middle marked as shortened), and
//  the whole history to a total, dropping the oldest exchanges first. The
//  newest exchange is always kept.
//

import Foundation

enum ConversationHistoryBudget {
    /// The most of one question the history keeps.
    static let maximumUserTextCharacters = 2_000
    /// The most of one reply (with its notepad and footnotes) the history keeps.
    static let maximumAssistantTextCharacters = 3_000
    /// The most the whole history may hold.
    static let maximumTotalCharacters = 12_000

    static let shortenedMarker = "\n…(shortened)…\n"

    /// The text, or its start and end around a "shortened" mark so it fits
    /// `characterLimit`. The start gets two thirds: it usually says what the
    /// message is about; the end, how it finished.
    static func shortened(_ text: String, toAtMost characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        let roomForText = max(0, characterLimit - shortenedMarker.count)
        let keptStartLength = roomForText * 2 / 3
        let keptEndLength = roomForText - keptStartLength
        return String(text.prefix(keptStartLength)) + shortenedMarker + String(text.suffix(keptEndLength))
    }

    /// The exchanges to send: each shortened to its limits, then as many of
    /// the newest as fit the total (the newest always).
    static func fitted(_ historyTurns: [LanguageModelHistoryTurn]) -> [LanguageModelHistoryTurn] {
        let shortenedTurns = historyTurns.map { historyTurn in
            LanguageModelHistoryTurn(
                userText: shortened(historyTurn.userText, toAtMost: maximumUserTextCharacters),
                assistantText: shortened(historyTurn.assistantText, toAtMost: maximumAssistantTextCharacters),
                speakingElfName: historyTurn.speakingElfName
            )
        }

        var keptTurnsNewestFirst: [LanguageModelHistoryTurn] = []
        var keptCharacterCount = 0
        for historyTurn in shortenedTurns.reversed() {
            let turnCharacterCount = historyTurn.userText.count + historyTurn.assistantText.count
            let isNewestTurn = keptTurnsNewestFirst.isEmpty
            guard isNewestTurn || keptCharacterCount + turnCharacterCount <= maximumTotalCharacters else { break }
            keptTurnsNewestFirst.append(historyTurn)
            keptCharacterCount += turnCharacterCount
        }
        return keptTurnsNewestFirst.reversed()
    }
}
