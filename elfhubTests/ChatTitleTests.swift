//
//  ChatTitleTests.swift
//  elfhubTests
//
//  Chat titles: generated once after the first reply of a main chat (never
//  over a title the user typed), cleaned from the model's answer, renamed
//  without moving the chat; and the sidebar's date groups and search.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ChatTitleTests {

    private func conversationWithFirstExchange(userText: String = "circle the pire straight", replyText: String = "Circled the pie chart.") -> ChatConversation {
        var conversation = ChatConversation()
        conversation.appendExchange(userText: userText, inputSource: .spoken)
        conversation.messages[1].text = replyText
        return conversation
    }

    // MARK: - When a title is generated

    @Test func aMainChatGetsATitleAfterItsFirstReply() {
        let conversation = conversationWithFirstExchange()
        #expect(conversation.titleSource == .firstMessage)
        #expect(ChatTitleGenerator.shouldGenerateTitle(for: conversation, isEnabled: true))
    }

    @Test func noTitleWhenOffRenamedAlreadyGeneratedOrLater() {
        let conversation = conversationWithFirstExchange()
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: conversation, isEnabled: false))

        var renamedConversation = conversation
        renamedConversation.titleSource = .userRenamed
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: renamedConversation, isEnabled: true))

        var generatedConversation = conversation
        generatedConversation.titleSource = .generated
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: generatedConversation, isEnabled: true))

        var longerConversation = conversation
        longerConversation.appendExchange(userText: "and now?", inputSource: .typed)
        longerConversation.messages[3].text = "Done."
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: longerConversation, isEnabled: true))
    }

    @Test func noTitleForSideElfChatsOrFailedReplies() {
        var elfThread = ChatConversation.elfThread(elfIdentifier: "juniper", title: "Juniper")
        elfThread.appendExchange(userText: "look this up", inputSource: .typed, speakingElfIdentifier: "juniper")
        elfThread.messages[1].text = "Found it."
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: elfThread, isEnabled: true))

        var failedConversation = conversationWithFirstExchange()
        failedConversation.messages[1].isError = true
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: failedConversation, isEnabled: true))

        let emptyReplyConversation = conversationWithFirstExchange(replyText: "  ")
        #expect(!ChatTitleGenerator.shouldGenerateTitle(for: emptyReplyConversation, isEnabled: true))
    }

    @Test func chatsSavedBeforeTitlesWereTrackedStillLoadAndCanBeTitled() throws {
        var conversation = conversationWithFirstExchange()
        conversation.titleSource = nil
        let encodedConversation = try ChatConversationStore.makeJSONEncoder().encode(conversation)
        let encodedText = String(decoding: encodedConversation, as: UTF8.self)
        #expect(!encodedText.contains("titleSource"))
        let decodedConversation = try ChatConversationStore.makeJSONDecoder().decode(ChatConversation.self, from: encodedConversation)
        #expect(decodedConversation.titleSource == nil)
        #expect(ChatTitleGenerator.shouldGenerateTitle(for: decodedConversation, isEnabled: true))
    }

    @Test func onByDefault() throws {
        let userDefaultsSuiteName = "ChatTitleTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        #expect(ChatTitleSettings.isEnabled(userDefaults: userDefaults))
        userDefaults.set(false, forKey: ChatTitleSettings.isEnabledKey)
        #expect(!ChatTitleSettings.isEnabled(userDefaults: userDefaults))
    }

    // MARK: - The request and the answer

    @Test func theRequestIsSmallAndCapped() {
        let longReply = String(repeating: "word ", count: 2_000)
        let titleRequest = ChatTitleGenerator.titleRequest(firstUserText: "where is the buy state?", firstReplyText: longReply)
        #expect(titleRequest.maxOutputTokens == 64)
        #expect(titleRequest.reasoningEffort == .low)
        #expect(titleRequest.usageCategory == .other)
        #expect(titleRequest.systemPrompt == ChatTitleGenerator.titleInstruction)
        let sentText = titleRequest.messages.flatMap(\.content).compactMap { contentBlock -> String? in
            if case let .text(text) = contentBlock { return text }
            return nil
        }.joined()
        #expect(sentText.hasPrefix("User: where is the buy state?"))
        #expect(sentText.count <= ChatTitleGenerator.maximumExchangeCharacterCount)
    }

    @Test func theAnswerIsCleanedIntoATitle() {
        #expect(ChatTitleGenerator.cleanedTitle(fromModelAnswer: "\"Circle the Pie Chart.\"") == "Circle the Pie Chart")
        #expect(ChatTitleGenerator.cleanedTitle(fromModelAnswer: "Title: Find the Buy Button") == "Find the Buy Button")
        #expect(ChatTitleGenerator.cleanedTitle(fromModelAnswer: "\n\n  **Weekend plans**  \nmore text") == "Weekend plans")
        #expect(ChatTitleGenerator.cleanedTitle(fromModelAnswer: "“Fix the build!”") == "Fix the build")
        #expect(ChatTitleGenerator.cleanedTitle(fromModelAnswer: "  ") == nil)
        #expect(ChatTitleGenerator.cleanedTitle(fromModelAnswer: "\"...\"") == nil)

        let longAnswer = String(repeating: "Long ", count: 20)
        let cleanedLongTitle = ChatTitleGenerator.cleanedTitle(fromModelAnswer: longAnswer)
        #expect(cleanedLongTitle?.hasSuffix("…") == true)
        #expect((cleanedLongTitle?.count ?? 0) <= ChatTitleGenerator.maximumTitleLength + 1)
    }

    // MARK: - Renaming

    @Test func renamingKeepsTheChatInPlaceAndRemembersWhoNamedIt() throws {
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elfhub-chat-title-tests-\(UUID().uuidString)", isDirectory: true)
        let userDefaultsSuiteName = "ChatTitleTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer {
            try? FileManager.default.removeItem(at: storageDirectoryURL)
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        let chatConversationStore = ChatConversationStore(storageDirectoryURL: storageDirectoryURL, userDefaults: userDefaults)
        let olderConversation = conversationWithFirstExchange(userText: "older")
        chatConversationStore.save(olderConversation)
        let newerConversation = conversationWithFirstExchange(userText: "newer")
        chatConversationStore.save(newerConversation)
        let updatedDateBeforeRenaming = try #require(chatConversationStore.conversation(withIdentifier: olderConversation.id)?.updatedAt)

        #expect(chatConversationStore.renameConversation(withIdentifier: olderConversation.id, to: "  Trip ideas  ", source: .userRenamed))
        #expect(!chatConversationStore.renameConversation(withIdentifier: olderConversation.id, to: "   ", source: .userRenamed))

        let renamedConversation = try #require(chatConversationStore.conversation(withIdentifier: olderConversation.id))
        #expect(renamedConversation.title == "Trip ideas")
        #expect(renamedConversation.titleSource == .userRenamed)
        #expect(renamedConversation.updatedAt == updatedDateBeforeRenaming)
        #expect(chatConversationStore.conversations.map(\.id) == [newerConversation.id, olderConversation.id])

        // Written to disk: a fresh store reads the new title back.
        let reloadedStore = ChatConversationStore(storageDirectoryURL: storageDirectoryURL, userDefaults: userDefaults)
        #expect(reloadedStore.conversation(withIdentifier: olderConversation.id)?.title == "Trip ideas")
        #expect(reloadedStore.conversation(withIdentifier: olderConversation.id)?.titleSource == .userRenamed)
    }

    // MARK: - Date groups

    @Test func chatsAreGroupedByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 0, minute: 10)))

        func conversation(updatedAt updatedDate: Date) -> ChatConversation {
            var conversation = ChatConversation()
            conversation.updatedAt = updatedDate
            return conversation
        }
        let justAfterMidnight = conversation(updatedAt: now.addingTimeInterval(-5 * 60))
        let justBeforeMidnight = conversation(updatedAt: now.addingTimeInterval(-15 * 60))
        let sixDaysAgo = conversation(updatedAt: try #require(calendar.date(byAdding: .day, value: -6, to: now)))
        let eightDaysAgo = conversation(updatedAt: try #require(calendar.date(byAdding: .day, value: -8, to: now)))

        let groupedConversations = ChatListDateGroup.groupedConversations(
            [justAfterMidnight, justBeforeMidnight, sixDaysAgo, eightDaysAgo],
            now: now,
            calendar: calendar
        )
        #expect(groupedConversations.map(\.group) == [.today, .yesterday, .previousSevenDays, .earlier])
        #expect(groupedConversations.map { $0.conversations.map(\.id) } == [[justAfterMidnight.id], [justBeforeMidnight.id], [sixDaysAgo.id], [eightDaysAgo.id]])

        let onlyToday = ChatListDateGroup.groupedConversations([justAfterMidnight], now: now, calendar: calendar)
        #expect(onlyToday.map(\.group) == [.today])
    }

    // MARK: - Search

    @Test func searchMatchesTitlesAndMessagesIgnoringCaseAndAccents() {
        var cafeConversation = conversationWithFirstExchange(userText: "Best café nearby?", replyText: "Try the one on Queen Street.")
        cafeConversation.title = "Coffee"
        let buildConversation = conversationWithFirstExchange(userText: "why does the build fail", replyText: "A missing import.")
        let conversations = [cafeConversation, buildConversation]

        #expect(ChatListSearch.conversations(conversations, matching: "").map(\.id) == conversations.map(\.id))
        #expect(ChatListSearch.conversations(conversations, matching: "COFFEE").map(\.id) == [cafeConversation.id])
        #expect(ChatListSearch.conversations(conversations, matching: "cafe").map(\.id) == [cafeConversation.id])
        #expect(ChatListSearch.conversations(conversations, matching: "queen street").map(\.id) == [cafeConversation.id])
        #expect(ChatListSearch.conversations(conversations, matching: "missing import").map(\.id) == [buildConversation.id])
        #expect(ChatListSearch.conversations(conversations, matching: "queen import").isEmpty)
    }
}
