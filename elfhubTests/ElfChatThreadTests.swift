//
//  ElfChatThreadTests.swift
//  elfhubTests
//
//  Each side elf has one ongoing chat of its own: talking to Tom (by name or
//  with the picker) goes there, wherever the user is; his page shows it;
//  the sidebar's chat list is the main elf's; Tom's turns remember his own
//  chat and main's remember main's; an imported elf's chats become its own.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfChatThreadTests {

    private func makeIsolatedStore() -> (store: ChatConversationStore, cleanUp: () -> Void) {
        let storageDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("elf-threads-\(UUID().uuidString)", isDirectory: true)
        let userDefaultsSuiteName = "elf-threads-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        return (
            ChatConversationStore(storageDirectoryURL: storageDirectoryURL, userDefaults: userDefaults),
            {
                try? FileManager.default.removeItem(at: storageDirectoryURL)
                userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
            }
        )
    }

    private func conversation(elfIdentifier: String?, question: String, answer: String, at date: Date = Date()) -> ChatConversation {
        var conversation = elfIdentifier.map { ChatConversation.elfThread(elfIdentifier: $0, title: $0) } ?? ChatConversation(createdAt: date)
        let exchange = conversation.appendExchange(userText: question, inputSource: .typed, speakingElfIdentifier: elfIdentifier)
        conversation.setText(answer, ofMessageWithIdentifier: exchange.assistantMessageIdentifier)
        return conversation
    }

    // MARK: - Saved chats

    @Test func chatsSavedBeforeThreadsExistedAreMainsChats() throws {
        let savedJSON = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","title":"old","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z","messages":[]}"#
        let decodedConversation = try ChatConversationStore.makeJSONDecoder().decode(ChatConversation.self, from: Data(savedJSON.utf8))
        #expect(decodedConversation.elfIdentifier == nil)
    }

    @Test func anElfsThreadIsFoundAndKeptOutOfMainsChatList() {
        let (store, cleanUp) = makeIsolatedStore()
        defer { cleanUp() }
        let mainChat = conversation(elfIdentifier: nil, question: "hi", answer: "hello")
        let tomThread = conversation(elfIdentifier: "tom", question: "Tom, price?", answer: "$1999")
        let goneElfThread = conversation(elfIdentifier: "juniper", question: "Juniper, flights?", answer: "TAP")
        store.save(mainChat)
        store.save(tomThread)
        store.save(goneElfThread)

        #expect(store.elfThread(forElfIdentifier: "tom")?.id == tomThread.id)
        #expect(store.elfThread(forElfIdentifier: "nobody") == nil)
        // Juniper was deleted: its chat shows with main's rather than vanish.
        let mainChatList = store.mainConversations(existingElfIdentifiers: ["main", "tom"])
        #expect(Set(mainChatList.map(\.id)) == [mainChat.id, goneElfThread.id])
    }

    @Test func aDeletedElfsChatBecomesAMainChatWithoutMovingInTheList() {
        let (store, cleanUp) = makeIsolatedStore()
        defer { cleanUp() }
        store.save(conversation(elfIdentifier: "juniper", question: "Juniper, flights?", answer: "TAP"))
        store.save(conversation(elfIdentifier: nil, question: "hi", answer: "hello"))
        let orderBefore = store.conversations.map(\.id)
        let updatedDatesBefore = store.conversations.map(\.updatedAt)

        store.detachElfThreads(ofElfsNotIn: ["main", "tom"])
        #expect(store.conversations.allSatisfy { $0.elfIdentifier == nil })
        #expect(store.conversations.map(\.id) == orderBefore)
        #expect(store.conversations.map(\.updatedAt) == updatedDatesBefore)
        // A new elf that happens to get the same name starts its own chat.
        #expect(store.elfThread(forElfIdentifier: "juniper") == nil)

        // Never when the roster looks empty (main is always there).
        store.save(conversation(elfIdentifier: "tom", question: "Tom?", answer: "yes"))
        store.detachElfThreads(ofElfsNotIn: [])
        #expect(store.elfThread(forElfIdentifier: "tom") != nil)
    }

    // MARK: - Where an exchange goes

    @Test func talkingToASideElfGoesToItsThreadWhereverTheUserIs() {
        let mainChat = ChatConversation()
        let tomThread = ChatConversation.elfThread(elfIdentifier: "tom", title: "Tom")
        #expect(ChatThreadRouting.destination(speakingElfIdentifier: "tom", activeConversation: mainChat) == .elfThread("tom"))
        #expect(ChatThreadRouting.destination(speakingElfIdentifier: "tom", activeConversation: tomThread) == .activeConversation)
        #expect(ChatThreadRouting.destination(speakingElfIdentifier: "juniper", activeConversation: tomThread) == .elfThread("juniper"))
    }

    @Test func talkingToMainGoesToMainsChatEvenFromAnElfsPage() {
        let mainChat = ChatConversation()
        let tomThread = ChatConversation.elfThread(elfIdentifier: "tom", title: "Tom")
        #expect(ChatThreadRouting.destination(speakingElfIdentifier: nil, activeConversation: mainChat) == .activeConversation)
        #expect(ChatThreadRouting.destination(speakingElfIdentifier: ElfManager.mainElfIdentifier, activeConversation: mainChat) == .activeConversation)
        #expect(ChatThreadRouting.destination(speakingElfIdentifier: nil, activeConversation: tomThread) == .mainChat)
    }

    // MARK: - What each elf remembers

    @Test func aSideElfRemembersItsOwnThreadAndMainItsOwnChat() {
        let mainHistory = [LanguageModelHistoryTurn(userText: "main question", assistantText: "main answer", speakingElfName: nil)]
        let tomThreadHistory = (1...8).map { turnNumber in
            LanguageModelHistoryTurn(userText: "tom question \(turnNumber)", assistantText: "tom answer \(turnNumber)", speakingElfName: "Tom")
        }
        let tomTurnHistory = CompanionTurnPipeline.historyTurnsForTurn(
            speakingElfName: "Tom",
            mainElfName: "Alfred",
            mainConversationHistory: mainHistory,
            speakingElfThreadHistory: tomThreadHistory
        )
        #expect(tomTurnHistory.map(\.userText) == (3...8).map { "tom question \($0)" })
        #expect(tomTurnHistory.allSatisfy { !$0.assistantText.hasPrefix("[") })

        let mainTurnHistory = CompanionTurnPipeline.historyTurnsForTurn(
            speakingElfName: nil,
            mainElfName: "Alfred",
            mainConversationHistory: mainHistory,
            speakingElfThreadHistory: tomThreadHistory
        )
        #expect(mainTurnHistory.map(\.userText) == ["main question"])
        #expect(CompanionTurnPipeline.recordsInMainConversationHistory(speakingElfName: nil))
        #expect(!CompanionTurnPipeline.recordsInMainConversationHistory(speakingElfName: "Tom"))
    }

    // MARK: - Imported chats

    @Test func importedChatsBecomeOneThreadForTheElfInOrder() throws {
        func importedChat(question: String, answer: String, secondsSince1970: TimeInterval) -> ChatConversation {
            let messageDate = Date(timeIntervalSince1970: secondsSince1970)
            return ChatConversation(createdAt: messageDate, messages: [
                StoredChatMessage(role: .user, text: question, createdAt: messageDate),
                StoredChatMessage(role: .assistant, text: answer, createdAt: messageDate.addingTimeInterval(1), speakingElfIdentifier: "juniper"),
            ])
        }
        let earlierChat = importedChat(question: "first", answer: "one", secondsSince1970: 1_000)
        let laterChat = importedChat(question: "second", answer: "two", secondsSince1970: 2_000)
        let mergedThread = try #require(ChatConversation.mergedElfThread(from: [laterChat, earlierChat], elfIdentifier: "juniper", title: "Juniper"))
        #expect(mergedThread.elfIdentifier == "juniper")
        #expect(mergedThread.messages.map(\.text) == ["first", "one", "second", "two"])
        #expect(ChatConversation.mergedElfThread(from: [], elfIdentifier: "juniper", title: "Juniper") == nil)
    }
}
