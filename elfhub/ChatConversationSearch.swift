//
//  ChatConversationSearch.swift
//  elfhub
//
//  A quick local search over the chats saved on this Mac, for the main
//  elf's search_chats tool: every word of the query must appear (case and
//  accents ignored), newest chats first, a few results with a short snippet
//  around the first match. Error bubbles are left out.
//

import Foundation

nonisolated struct ChatConversationSearchResult: Equatable, Sendable {
    let conversationIdentifier: UUID
    let conversationTitle: String
    let updatedAt: Date
    let snippet: String
}

enum ChatConversationSearch {
    static let maximumResultCount = 5
    static let maximumSnippetLength = 300

    static func search(query: String, in conversations: [ChatConversation]) -> [ChatConversationSearchResult] {
        let queryWords = UtteranceWords.words(in: fold(query))
        guard !queryWords.isEmpty else { return [] }
        var searchResults: [ChatConversationSearchResult] = []
        for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let searchableTexts = [conversation.title] + conversation.messages.filter { !$0.isError }.map(\.text)
            let foldedConversationText = fold(searchableTexts.joined(separator: "\n"))
            guard queryWords.allSatisfy({ foldedConversationText.contains($0) }) else { continue }
            let matchingText = searchableTexts.dropFirst().first { fold($0).contains(queryWords[0]) } ?? conversation.title
            searchResults.append(ChatConversationSearchResult(
                conversationIdentifier: conversation.id,
                conversationTitle: conversation.title,
                updatedAt: conversation.updatedAt,
                snippet: snippet(of: matchingText, around: queryWords[0])
            ))
            if searchResults.count == maximumResultCount { break }
        }
        return searchResults
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Up to `maximumSnippetLength` characters around the first match.
    private static func snippet(of text: String, around foldedQueryWord: String) -> String {
        let foldedText = fold(text)
        guard text.count > maximumSnippetLength,
              let matchRange = foldedText.range(of: foldedQueryWord) else {
            return String(text.prefix(maximumSnippetLength))
        }
        let matchOffset = foldedText.distance(from: foldedText.startIndex, to: matchRange.lowerBound)
        let snippetStartOffset = max(0, min(matchOffset - maximumSnippetLength / 2, text.count - maximumSnippetLength + 2))
        let snippetBody = String(text.dropFirst(snippetStartOffset).prefix(maximumSnippetLength - 2))
        return (snippetStartOffset > 0 ? "…" : "") + snippetBody + (snippetStartOffset + snippetBody.count < text.count ? "…" : "")
    }
}
