//
//  ElfTaskReportingTests.swift
//  elfhubTests
//
//  How finished background work reaches the user — spoken right away when
//  they're idle, otherwise mentioned at the start of the next reply — how
//  the main elf searches saved chats, and how a request to a side elf is
//  sorted into quick, long or screen work.
//

import Foundation
import Testing
@testable import elfhub

struct ElfTaskReportingTests {

    // MARK: Reporting

    @Test func idleSpeaksNow() {
        #expect(ElfTaskReportPlanner.plan(isVoiceIdle: true, isRecording: false, isReplyStreaming: false, areActionsRunning: false, speaksReports: true) == .speakNow)
    }

    @Test func busyWaitsForTheNextTurn() {
        #expect(ElfTaskReportPlanner.plan(isVoiceIdle: false, isRecording: false, isReplyStreaming: false, areActionsRunning: false, speaksReports: true) == .mentionNextTurn)
        #expect(ElfTaskReportPlanner.plan(isVoiceIdle: true, isRecording: true, isReplyStreaming: false, areActionsRunning: false, speaksReports: true) == .mentionNextTurn)
        #expect(ElfTaskReportPlanner.plan(isVoiceIdle: true, isRecording: false, isReplyStreaming: true, areActionsRunning: false, speaksReports: true) == .mentionNextTurn)
        #expect(ElfTaskReportPlanner.plan(isVoiceIdle: true, isRecording: false, isReplyStreaming: false, areActionsRunning: true, speaksReports: true) == .mentionNextTurn)
    }

    @Test func reportsSwitchedOffAreShownNotSpoken() {
        #expect(ElfTaskReportPlanner.plan(isVoiceIdle: true, isRecording: false, isReplyStreaming: false, areActionsRunning: false, speaksReports: false) == .showOnlyAndMentionNextTurn)
    }

    @Test func theStatusBlockListsUnreportedResultsRunningTasksAndQuestions() {
        var finishedTask = ElfTask(elfIdentifier: "juniper", instruction: "find flights")
        finishedTask.status = .done
        finishedTask.result = ElfTaskResult(summary: "TAP has a direct flight on the 3rd.", filePaths: ["files/flights.md"])
        var runningTask = ElfTask(elfIdentifier: "writer", instruction: "draft the post")
        runningTask.status = .running
        var askingTask = ElfTask(elfIdentifier: "juniper", instruction: "book a hotel")
        askingTask.status = .needsInput
        askingTask.pendingQuestion = "which area?"
        let statusBlock = ElfStatusBlock.text(
            unreportedFinishedTasks: [finishedTask],
            runningTasks: [runningTask],
            tasksWaitingForAnswers: [askingTask],
            elfNameForIdentifier: { $0 == "juniper" ? "Juniper" : "Writer" }
        )
        #expect(statusBlock?.hasPrefix("[elfhub status]") == true)
        #expect(statusBlock?.contains("Juniper finished \"find flights\": TAP has a direct flight on the 3rd.") == true)
        #expect(statusBlock?.contains("files/flights.md") == true)
        #expect(statusBlock?.contains("Writer is working on \"draft the post\"") == true)
        #expect(statusBlock?.contains("Juniper asks (task \(askingTask.id.uuidString.prefix(8).lowercased())): which area?") == true)
        #expect(ElfStatusBlock.text(unreportedFinishedTasks: [], runningTasks: [], tasksWaitingForAnswers: [], elfNameForIdentifier: { $0 }) == nil)
    }

    // MARK: Searching chats

    private func conversation(title: String, updatedAt: Date, messages: [(StoredChatMessage.Role, String)]) -> ChatConversation {
        var conversation = ChatConversation(title: title, createdAt: updatedAt)
        conversation.messages = messages.map { role, text in StoredChatMessage(role: role, text: text) }
        conversation.updatedAt = updatedAt
        return conversation
    }

    @Test func newestMatchesFirst() {
        let olderConversation = conversation(title: "Trip", updatedAt: Date(timeIntervalSince1970: 100), messages: [(.user, "flights to Lisbon?")])
        let newerConversation = conversation(title: "More trip", updatedAt: Date(timeIntervalSince1970: 200), messages: [(.assistant, "Lisbon in May is lovely")])
        let unrelatedConversation = conversation(title: "Code", updatedAt: Date(timeIntervalSince1970: 300), messages: [(.user, "fix the build")])
        let searchResults = ChatConversationSearch.search(query: "lisbon", in: [olderConversation, newerConversation, unrelatedConversation])
        #expect(searchResults.map(\.conversationTitle) == ["More trip", "Trip"])
    }

    @Test func snippetsAreCappedAndResultsLimited() {
        let longText = String(repeating: "word ", count: 200) + "lisbon " + String(repeating: "word ", count: 200)
        let conversations = (1...8).map { conversationNumber in
            conversation(title: "Chat \(conversationNumber)", updatedAt: Date(timeIntervalSince1970: Double(conversationNumber)), messages: [(.user, longText)])
        }
        let searchResults = ChatConversationSearch.search(query: "Lisbon", in: conversations)
        #expect(searchResults.count == ChatConversationSearch.maximumResultCount)
        #expect(searchResults.allSatisfy { $0.snippet.count <= ChatConversationSearch.maximumSnippetLength })
        #expect(searchResults.first?.snippet.contains("lisbon") == true)
    }

    @Test func errorBubblesAreNotSearched() {
        var errorConversation = conversation(title: "Oops", updatedAt: Date(), messages: [])
        errorConversation.messages = [StoredChatMessage(role: .assistant, text: "Lisbon error", isError: true)]
        #expect(ChatConversationSearch.search(query: "lisbon", in: [errorConversation]).isEmpty)
        #expect(ChatConversationSearch.search(query: "  ", in: [errorConversation]).isEmpty)
    }

    // MARK: Sorting requests

    @Test func shortcutsDecideWithoutAModel() {
        #expect(ElfTaskClassifier.shortcutKind(for: "research flights to Lisbon") == .long)
        #expect(ElfTaskClassifier.shortcutKind(for: "can you draft the launch post") == .long)
        #expect(ElfTaskClassifier.shortcutKind(for: "look into why the build fails, in the background") == .long)
        #expect(ElfTaskClassifier.shortcutKind(for: "click the save button") == .screen)
        #expect(ElfTaskClassifier.shortcutKind(for: "fill in this form on my screen") == .screen)
        #expect(ElfTaskClassifier.shortcutKind(for: "what's this button?") == .quick)
        #expect(ElfTaskClassifier.shortcutKind(for: "explain this error") == .quick)
        #expect(ElfTaskClassifier.shortcutKind(for: "how tall is the Eiffel tower") == nil)
    }

    @Test func aModelAnswerIsReadLeniently() {
        #expect(ElfTaskClassifier.kind(fromModelAnswer: #"{"kind":"long"}"#) == .long)
        #expect(ElfTaskClassifier.kind(fromModelAnswer: "```json\n{\"kind\": \"screen\"}\n```") == .screen)
        #expect(ElfTaskClassifier.kind(fromModelAnswer: "I think it's quick") == .quick)
        #expect(ElfTaskClassifier.kind(fromModelAnswer: "garbage") == .quick)
    }

    @MainActor
    @Test func aSlowClassifierCountsAsQuick() async {
        let slowProvider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply(#"{"kind":"long"}"#)])
        slowProvider.responseDelayInSeconds = 10
        let startDate = Date()
        let requestKind = await ElfTaskClassifier.classify(requestText: "how tall is the Eiffel tower", languageModelProvider: slowProvider)
        #expect(requestKind == .quick)
        // Well before the model's 10 seconds, even with a busy main thread.
        #expect(Date().timeIntervalSince(startDate) < 6)
    }

    @MainActor
    @Test func aClassifierAnswerInTimeIsUsed() async {
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply(#"{"kind":"long"}"#)])
        #expect(await ElfTaskClassifier.classify(requestText: "how tall is the Eiffel tower", languageModelProvider: provider) == .long)
    }

    @Test func theReportSaysWhoFinishedWhat() {
        var finishedTask = ElfTask(elfIdentifier: "juniper", instruction: "find flights to Lisbon")
        finishedTask.status = .done
        finishedTask.result = ElfTaskResult(summary: "TAP flies direct on the 3rd.", filePaths: ["files/flights.md"])
        #expect(ElfTaskReportText.report(for: finishedTask, elfName: "Juniper") == "Juniper finished “find flights to Lisbon”: TAP flies direct on the 3rd.")
        finishedTask.status = .failed
        finishedTask.failureReason = "it ran out of time"
        #expect(ElfTaskReportText.report(for: finishedTask, elfName: "Juniper") == "Juniper couldn't finish “find flights to Lisbon”: it ran out of time.")
        var askingTask = ElfTask(elfIdentifier: "juniper", instruction: "book a hotel")
        askingTask.status = .needsInput
        askingTask.pendingQuestion = "which area?"
        #expect(ElfTaskReportText.report(for: askingTask, elfName: "Juniper") == "Juniper asks about “book a hotel”: which area?")
    }

    @Test func taskReportsAreSavedInChatAndOldChatsDecodeAsExchanges() throws {
        let savedMessageJSON = #"{"id":"6B1C5A3E-0000-4000-8000-000000000003","role":"assistant","text":"hi","createdAt":0}"#
        #expect(try JSONDecoder().decode(StoredChatMessage.self, from: Data(savedMessageJSON.utf8)).kind == .exchange)
        var conversation = ChatConversation()
        let taskIdentifier = UUID()
        conversation.appendTaskReport("Juniper finished it.", elfIdentifier: "juniper", taskIdentifier: taskIdentifier)
        let decodedConversation = try JSONDecoder().decode(ChatConversation.self, from: JSONEncoder().encode(conversation))
        #expect(decodedConversation.messages.last?.kind == .taskReport)
        #expect(decodedConversation.messages.last?.taskIdentifier == taskIdentifier)
        #expect(decodedConversation.messages.last?.speakingElfIdentifier == "juniper")
        #expect(decodedConversation.historyTurns(maximumTurnCount: 10).isEmpty)
    }
}
