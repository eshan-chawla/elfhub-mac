//
//  ConversationHistoryBudgetTests.swift
//  elfhubTests
//
//  The history sent with each turn stays small: long messages keep their
//  start and end, the oldest exchanges go first when the total is over,
//  the newest always stays, and short chats are sent as they are.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ConversationHistoryBudgetTests {

    private func turn(_ userText: String, _ assistantText: String) -> LanguageModelHistoryTurn {
        LanguageModelHistoryTurn(userText: userText, assistantText: assistantText)
    }

    @Test func shortChatsAreSentAsTheyAre() {
        let historyTurns = (1...10).map { turn("question \($0)", "answer \($0)") }
        let fittedTurns = ConversationHistoryBudget.fitted(historyTurns)
        #expect(fittedTurns.map(\.userText) == historyTurns.map(\.userText))
        #expect(fittedTurns.map(\.assistantText) == historyTurns.map(\.assistantText))
    }

    @Test func aLongReplyKeepsItsStartAndEnd() {
        let longReply = "START " + String(repeating: "middle ", count: 2_000) + " END"
        let fittedTurn = ConversationHistoryBudget.fitted([turn("q", longReply)])[0]
        #expect(fittedTurn.assistantText.count <= ConversationHistoryBudget.maximumAssistantTextCharacters)
        #expect(fittedTurn.assistantText.hasPrefix("START "))
        #expect(fittedTurn.assistantText.hasSuffix(" END"))
        #expect(fittedTurn.assistantText.contains(ConversationHistoryBudget.shortenedMarker))
    }

    @Test func aLongQuestionIsShortenedToo() {
        let longQuestion = String(repeating: "q", count: 10_000)
        let fittedTurn = ConversationHistoryBudget.fitted([turn(longQuestion, "a")])[0]
        #expect(fittedTurn.userText.count <= ConversationHistoryBudget.maximumUserTextCharacters)
    }

    @Test func theOldestExchangesGoFirstWhenTheTotalIsOver() {
        let longReply = String(repeating: "x", count: 5_000)
        let historyTurns = (1...10).map { turn("question \($0)", longReply) }
        let fittedTurns = ConversationHistoryBudget.fitted(historyTurns)
        let totalCharacters = fittedTurns.reduce(0) { $0 + $1.userText.count + $1.assistantText.count }
        #expect(totalCharacters <= ConversationHistoryBudget.maximumTotalCharacters)
        #expect(fittedTurns.last?.userText == "question 10")
        #expect(fittedTurns.count < 10)
        // What's kept is the newest, in order.
        #expect(fittedTurns.map(\.userText) == historyTurns.suffix(fittedTurns.count).map(\.userText))
    }

    @Test func theNewestExchangeIsAlwaysKept() {
        let fittedTurns = ConversationHistoryBudget.fitted([turn(String(repeating: "q", count: 9_000), String(repeating: "a", count: 9_000))])
        #expect(fittedTurns.count == 1)
    }

    @Test func theTurnsHistoryIsKeptWithinTheBudget() {
        let longReply = String(repeating: "y", count: 8_000)
        let storedTurns = (1...10).map { turn("question \($0)", longReply) }
        let sentTurns = CompanionTurnPipeline.historyTurns(forSpeakingElfName: nil, mainElfName: "Wren", from: storedTurns)
        let totalCharacters = sentTurns.reduce(0) { $0 + $1.userText.count + $1.assistantText.count }
        #expect(totalCharacters <= ConversationHistoryBudget.maximumTotalCharacters)
        #expect(sentTurns.last?.userText == "question 10")
    }
}
