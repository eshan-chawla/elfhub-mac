//
//  MainElfMemoryTests.swift
//  elfhubTests
//
//  The main Elf's memory: quiet chats of its own are folded into user.md
//  once, through the change log (undoable), only while the setting and note
//  taking are on, never while the user is busy.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct MainElfMemoryTests {

    private struct Fixture {
        let elfManager: ElfManager
        let chatConversationStore: ChatConversationStore
        let userDefaults: UserDefaults
        let cleanUp: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)", isDirectory: true)
        let userDefaultsSuiteName = "MainElfMemoryTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        let elfManager = ElfManager(
            elfsDirectory: rootDirectory.appendingPathComponent("roster", isDirectory: true),
            deletedFolderDisposal: .removePermanently
        )
        let chatConversationStore = ChatConversationStore(
            storageDirectoryURL: rootDirectory.appendingPathComponent("Conversations", isDirectory: true),
            userDefaults: userDefaults
        )
        return Fixture(
            elfManager: elfManager,
            chatConversationStore: chatConversationStore,
            userDefaults: userDefaults,
            cleanUp: {
                try? FileManager.default.removeItem(at: rootDirectory)
                userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
            }
        )
    }

    private func savedChat(_ question: String, _ answer: String, elfIdentifier: String? = nil, in chatConversationStore: ChatConversationStore) -> ChatConversation {
        var conversation = ChatConversation(title: question, messages: [
            StoredChatMessage(role: .user, text: question),
            StoredChatMessage(role: .assistant, text: answer),
        ])
        conversation.elfIdentifier = elfIdentifier
        chatConversationStore.save(conversation)
        return chatConversationStore.conversation(withIdentifier: conversation.id) ?? conversation
    }

    private static let updatedUserNotes = """
    # user
    ## About you
    - works on a Mac app called elfhub
    ## What we've talked about
    - 2026-11-16: renaming files in Finder
    """

    private func makeKeeper(
        _ fixture: Fixture,
        provider: ScriptedLanguageModelProvider,
        minutesFromNow: Double = 60,
        isUserBusy: Bool = false
    ) -> MainElfMemoryKeeper {
        MainElfMemoryKeeper(
            elfManager: fixture.elfManager,
            chatConversationStore: fixture.chatConversationStore,
            languageModelProvider: { provider },
            isUserBusy: { isUserBusy },
            now: { Date().addingTimeInterval(minutesFromNow * 60) },
            userDefaults: fixture.userDefaults
        )
    }

    // MARK: - Choosing chats

    @Test func onlyQuietUnfoldedChatsOfTheMainElfAreFoldedOldestFirst() throws {
        let now = Date()
        let olderQuiet = ChatConversation(id: UUID(), title: "older", messages: [
            StoredChatMessage(role: .user, text: "hi"), StoredChatMessage(role: .assistant, text: "hello"),
        ])
        var olderQuietDated = olderQuiet
        olderQuietDated.updatedAt = now.addingTimeInterval(-3 * 3600)
        var newerQuiet = olderQuiet
        newerQuiet = ChatConversation(id: UUID(), title: "newer", messages: olderQuiet.messages)
        newerQuiet.updatedAt = now.addingTimeInterval(-2 * 3600)
        var stillActive = ChatConversation(id: UUID(), title: "active", messages: olderQuiet.messages)
        stillActive.updatedAt = now.addingTimeInterval(-5 * 60)
        var sideElfThread = ChatConversation(id: UUID(), title: "wren", messages: olderQuiet.messages)
        sideElfThread.elfIdentifier = "wren"
        sideElfThread.updatedAt = now.addingTimeInterval(-3 * 3600)
        var onlyAnError = ChatConversation(id: UUID(), title: "error", messages: [
            StoredChatMessage(role: .user, text: "hi"), StoredChatMessage(role: .assistant, text: "failed", isError: true),
        ])
        onlyAnError.updatedAt = now.addingTimeInterval(-3 * 3600)
        var alreadyFolded = ChatConversation(id: UUID(), title: "folded", messages: olderQuiet.messages)
        alreadyFolded.updatedAt = now.addingTimeInterval(-3 * 3600)

        let chosen = MainElfMemoryPlanner.conversationsToFold(
            conversations: [newerQuiet, stillActive, sideElfThread, onlyAnError, alreadyFolded, olderQuietDated],
            foldedDateByConversationIdentifier: [alreadyFolded.id: alreadyFolded.updatedAt],
            now: now
        )
        #expect(chosen.map(\.title) == ["older", "newer"])

        let chosenWithoutWaiting = MainElfMemoryPlanner.conversationsToFold(
            conversations: [stillActive],
            foldedDateByConversationIdentifier: [:],
            now: now,
            requiresQuietPeriod: false
        )
        #expect(chosenWithoutWaiting.map(\.title) == ["active"])
    }

    @Test func chatsOlderThanTwoWeeksAreLeftToUpdateNow() {
        let now = Date()
        var oldChat = ChatConversation(id: UUID(), title: "old", messages: [
            StoredChatMessage(role: .user, text: "hi"), StoredChatMessage(role: .assistant, text: "hello"),
        ])
        oldChat.updatedAt = now.addingTimeInterval(-30 * 24 * 3600)
        #expect(MainElfMemoryPlanner.conversationsToFold(conversations: [oldChat], foldedDateByConversationIdentifier: [:], now: now).isEmpty)
        #expect(MainElfMemoryPlanner.conversationsToFold(conversations: [oldChat], foldedDateByConversationIdentifier: [:], now: now, requiresQuietPeriod: false).map(\.title) == ["old"])
    }

    @Test func theModelsReplyIsUsedOnlyWithBothSectionsAndWithinTheCap() {
        let currentUserNotes = ElfHome.starterUserNotes
        #expect(MainElfMemoryPlanner.updatedUserNotes(fromModelReply: Self.updatedUserNotes, currentUserNotes: currentUserNotes, characterLimit: 12_000) != nil)
        #expect(MainElfMemoryPlanner.updatedUserNotes(fromModelReply: "```markdown\n" + Self.updatedUserNotes + "\n```", currentUserNotes: currentUserNotes, characterLimit: 12_000) != nil)
        #expect(MainElfMemoryPlanner.updatedUserNotes(fromModelReply: "Sure! Here are some notes.", currentUserNotes: currentUserNotes, characterLimit: 12_000) == nil)
        #expect(MainElfMemoryPlanner.updatedUserNotes(fromModelReply: Self.updatedUserNotes, currentUserNotes: currentUserNotes, characterLimit: 40) == nil)
        #expect(MainElfMemoryPlanner.updatedUserNotes(fromModelReply: Self.updatedUserNotes, currentUserNotes: Self.updatedUserNotes, characterLimit: 12_000) == nil, "unchanged writes nothing")
    }

    @Test func theTranscriptKeepsTextAndNotepadsAndLeavesOutErrors() {
        let conversation = ChatConversation(title: "t", messages: [
            StoredChatMessage(role: .user, text: "how do I rename files?"),
            StoredChatMessage(role: .assistant, text: "Select them first.", notepad: SavedNotepad(title: "Rename", markdownLines: ["1. Select", "2. Rename"])),
            StoredChatMessage(role: .assistant, text: "network failed", isError: true),
        ])
        let transcript = MainElfMemoryPlanner.transcript(of: conversation, elfName: "Juniper")
        #expect(transcript.contains("user: how do I rename files?"))
        #expect(transcript.contains("Juniper: Select them first."))
        #expect(transcript.contains("1. Select / 2. Rename"))
        #expect(!transcript.contains("network failed"))
    }

    // MARK: - Running

    @Test func aQuietChatIsFoldedIntoUserMdThroughTheChangeLogOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let chat = savedChat("how do I rename files in Finder?", "Select them, then right-click.", in: fixture.chatConversationStore)
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply(Self.updatedUserNotes)], supportsToolCalling: false)
        let keeper = makeKeeper(fixture, provider: provider)

        let didChange = await keeper.foldNextQuietChatIfDue()
        #expect(didChange)
        let mainHome = fixture.elfManager.mainElf.home
        #expect(mainHome.readUserNotes().contains("works on a Mac app called elfhub"))
        let lastChange = try #require(ElfChangeLog(home: mainHome).entries().first)
        #expect(lastChange.path == "user.md")
        #expect(lastChange.origin == .memory(conversationIdentifier: chat.id))
        #expect(keeper.memoryState.lastUpdate?.conversationTitle == chat.title)

        // The model saw the current notes and the chat.
        let sentText = provider.receivedRequests.first?.messages.first.map { message in
            message.content.compactMap { block -> String? in if case let .text(text) = block { return text } else { return nil } }.joined()
        } ?? ""
        #expect(sentText.contains("## About you"))
        #expect(sentText.contains("how do I rename files in Finder?"))

        // Folded once: nothing more to do, and the change can be undone.
        #expect(await keeper.foldNextQuietChatIfDue() == false)
        #expect(provider.receivedRequests.count == 1)
        _ = try ElfChangeLog(home: mainHome).undo(entryIdentifier: lastChange.id, force: false)
        #expect(!mainHome.readUserNotes().contains("works on a Mac app"))
    }

    @Test func nothingRunsWhileOffBusyNotTakingNotesOrBeforeTheQuietPeriod() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = savedChat("hello", "hi there", in: fixture.chatConversationStore)
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply(Self.updatedUserNotes)], supportsToolCalling: false)

        #expect(await makeKeeper(fixture, provider: provider, minutesFromNow: 5).foldNextQuietChatIfDue() == false)
        #expect(await makeKeeper(fixture, provider: provider, isUserBusy: true).foldNextQuietChatIfDue() == false)

        fixture.userDefaults.set(false, forKey: MainElfMemorySettings.isEnabledKey)
        #expect(await makeKeeper(fixture, provider: provider).foldNextQuietChatIfDue() == false)
        fixture.userDefaults.set(true, forKey: MainElfMemorySettings.isEnabledKey)

        try ElfEditor(editingMainElfOf: fixture.elfManager).updateBehaviour { behaviour in behaviour.takesNotes = false }
        fixture.elfManager.reloadRoster()
        #expect(await makeKeeper(fixture, provider: provider).foldNextQuietChatIfDue() == false)

        #expect(provider.receivedRequests.isEmpty)
    }

    @Test func memoryIsOnByDefault() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        #expect(MainElfMemorySettings.isEnabled(userDefaults: fixture.userDefaults))
    }

    @Test func updateNowFoldsChatsThatAreStillActive() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = savedChat("what's my standup time?", "10am.", in: fixture.chatConversationStore)
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [ScriptedLanguageModelProvider.reply(Self.updatedUserNotes)], supportsToolCalling: false)
        let keeper = makeKeeper(fixture, provider: provider, minutesFromNow: 1)
        #expect(await keeper.updateNow())
        #expect(provider.receivedRequests.count == 1)
    }
}
