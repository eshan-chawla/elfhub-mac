//
//  WebSearchProvider.swift
//  elfhub
//
//  Web search for elves through a search service the user picks and pays
//  for themselves (key in the Keychain), or a SearXNG server they run.
//  Placeholder for phase 6.2.
//

import Foundation

struct WebSearchResult: Equatable {
    let title: String
    let url: URL
    let snippet: String
}

protocol WebSearchProvider {
    func search(query: String) async throws -> [WebSearchResult]
}
