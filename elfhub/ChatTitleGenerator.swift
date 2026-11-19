//
//  ChatTitleGenerator.swift
//  elfhub
//
//  Short, clean titles for the main Elf's chats. A chat starts out titled
//  with the first thing the user said — for a spoken question that's the raw
//  transcript, recognition slips included ("Circle the pire straight"). After
//  the first reply, one small request asks the user's own model for a 2–5
//  word title that fixes those slips. On by default; Settings › Privacy &
//  permissions switches it off. A title the user typed is never replaced, and
//  each chat is titled once. Side Elfs' chats keep their Elf's name.
//
//  This is one of the two requests elfhub makes without being asked in the
//  moment (the other is the main Elf's memory), and it only goes to the
//  model the user chose.
//

import Foundation

/// "Name chats automatically" — on unless the user turned it off.
nonisolated enum ChatTitleSettings {
    static let isEnabledKey = "namesChatsAutomatically"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: isEnabledKey) as? Bool ?? true
    }
}

enum ChatTitleGenerator {
    /// The most of the first exchange sent to the model.
    static let maximumExchangeCharacterCount = 2_000
    /// The longest title kept (the same cap as a first-message title).
    static let maximumTitleLength = 48

    static let titleInstruction = """
    Write a title for this chat in 2 to 5 words, in the language the user wrote in. \
    The user's message may be a speech transcript: fix obvious recognition mistakes. \
    Answer with the title only — no quotes, no ending punctuation, no explanation.
    """

    /// Whether this chat should get a generated title now: the main Elf's
    /// chat, right after its first reply came back, still titled with its
    /// first message.
    static func shouldGenerateTitle(for conversation: ChatConversation, isEnabled: Bool) -> Bool {
        guard isEnabled, conversation.elfIdentifier == nil else { return false }
        guard (conversation.titleSource ?? .firstMessage) == .firstMessage else { return false }
        guard conversation.messages.count == 2,
              let firstUserMessage = conversation.messages.first, firstUserMessage.role == .user,
              let firstReply = conversation.messages.last, firstReply.role == .assistant,
              !firstReply.isError,
              !firstReply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// The request: the first question and reply, capped, with low effort
    /// and a few output tokens.
    static func titleRequest(firstUserText: String, firstReplyText: String) -> LanguageModelRequest {
        let exchangeText = "User: \(firstUserText)\n\nAssistant: \(firstReplyText)"
        let cappedExchangeText = String(exchangeText.prefix(maximumExchangeCharacterCount))
        var titleRequest = LanguageModelRequest(
            systemPrompt: titleInstruction,
            userText: cappedExchangeText,
            maxOutputTokens: 64,
            reasoningEffort: .low
        )
        titleRequest.usageCategory = .other
        return titleRequest
    }

    /// The model's answer as a title: its first non-empty line, without
    /// quotes, a "Title:" prefix or ending punctuation, cut to the cap. Nil
    /// when nothing usable is left.
    static func cleanedTitle(fromModelAnswer modelAnswer: String) -> String? {
        guard let firstLine = modelAnswer
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }

        var title = firstLine
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count))
        }
        let surroundingCharacters = CharacterSet(charactersIn: "\"'“”‘’`*#").union(.whitespaces)
        title = title.trimmingCharacters(in: surroundingCharacters)
        while let lastCharacter = title.last, ".!?:;,".contains(lastCharacter) {
            title.removeLast()
        }
        title = title.trimmingCharacters(in: surroundingCharacters)
        guard !title.isEmpty else { return nil }
        if title.count > maximumTitleLength {
            title = String(title.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    /// Asks the model once; nil on any failure (the chat keeps its
    /// first-message title).
    static func generateTitle(
        firstUserText: String,
        firstReplyText: String,
        languageModelProvider: LanguageModelProvider
    ) async -> String? {
        let titleRequest = titleRequest(firstUserText: firstUserText, firstReplyText: firstReplyText)
        guard let titleResponse = try? await languageModelProvider.streamResponse(titleRequest, onStreamEvent: { _ in }) else {
            return nil
        }
        return cleanedTitle(fromModelAnswer: titleResponse.text)
    }
}

// MARK: - Organizing the chat list

/// The sidebar's chat list in groups by when each chat was last updated.
enum ChatListDateGroup: String, CaseIterable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case previousSevenDays = "Previous 7 days"
    case earlier = "Earlier"

    var id: Self { self }

    static func group(for updatedDate: Date, now: Date, calendar: Calendar) -> ChatListDateGroup {
        if calendar.isDate(updatedDate, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfSevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) else { return .earlier }
        if updatedDate >= startOfYesterday && updatedDate < startOfToday { return .yesterday }
        if updatedDate >= startOfSevenDaysAgo && updatedDate < startOfYesterday { return .previousSevenDays }
        // A date in the future (a clock change) counts as today.
        if updatedDate > now { return .today }
        return .earlier
    }

    /// The chats in their groups, in group order; each group keeps the
    /// order it was given (newest first), and empty groups are left out.
    static func groupedConversations(
        _ conversations: [ChatConversation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(group: ChatListDateGroup, conversations: [ChatConversation])] {
        var conversationsByGroup: [ChatListDateGroup: [ChatConversation]] = [:]
        for conversation in conversations {
            conversationsByGroup[group(for: conversation.updatedAt, now: now, calendar: calendar), default: []].append(conversation)
        }
        return allCases.compactMap { dateGroup in
            guard let groupConversations = conversationsByGroup[dateGroup], !groupConversations.isEmpty else { return nil }
            return (dateGroup, groupConversations)
        }
    }
}

/// The sidebar's search: every word of the query must appear in the
/// chat's title or in one of its messages, ignoring case and accents.
enum ChatListSearch {
    static func conversations(_ conversations: [ChatConversation], matching searchQuery: String) -> [ChatConversation] {
        let queryWords = searchQuery
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !queryWords.isEmpty else { return conversations }
        return conversations.filter { conversation in
            queryWords.allSatisfy { queryWord in
                conversation.title.localizedStandardContains(queryWord)
                    || conversation.messages.contains { message in message.text.localizedStandardContains(queryWord) }
            }
        }
    }
}
