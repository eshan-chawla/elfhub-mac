//
//  ChatHistoryTests.swift
//  elfhubTests
//
//  Conversation history covers voice turns as well as typed ones, and —
//  only when the user turns it on — keeps the screenshot each turn sent.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct ChatHistoryTests {

    /// A throwaway folder and settings domain, so tests never touch the
    /// user's real chats or preferences.
    @MainActor private struct IsolatedChatStorage {
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elfhub-chat-history-tests-\(UUID().uuidString)", isDirectory: true)
        let userDefaultsSuiteName = "elfhub-chat-history-tests-\(UUID().uuidString)"

        var userDefaults: UserDefaults { UserDefaults(suiteName: userDefaultsSuiteName)! }

        func makeStore() -> ChatConversationStore {
            ChatConversationStore(storageDirectoryURL: storageDirectoryURL, userDefaults: userDefaults)
        }

        func removeEverything() {
            try? FileManager.default.removeItem(at: storageDirectoryURL)
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
    }

    private let sampleJPEGData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])

    private func makeConversationWithOneExchange() -> (conversation: ChatConversation, userMessageIdentifier: UUID) {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "what's this?", inputSource: .spoken)
        conversation.messages[1].text = "a settings window"
        return (conversation, exchangeIdentifiers.userMessageIdentifier)
    }

    // MARK: - Messages

    @Test func messagesSavedBeforeVoiceAndScreenshotsStillLoad() throws {
        let legacyMessageJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","text":"hi","createdAt":"2026-10-31T10:00:00Z","isError":false}
        """
        let decodedMessage = try ChatConversationStore.makeJSONDecoder()
            .decode(StoredChatMessage.self, from: Data(legacyMessageJSON.utf8))
        #expect(decodedMessage.inputSource == .typed)
        #expect(decodedMessage.screenshotFileName == nil)
    }

    @Test func appendingAnExchangeAddsTheQuestionAndAnEmptyReply() {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "open my downloads", inputSource: .spoken)

        #expect(conversation.title == "open my downloads")
        #expect(conversation.messages.map(\.role) == [.user, .assistant])
        #expect(conversation.messages[0].inputSource == .spoken)
        #expect(conversation.messages[0].id == exchangeIdentifiers.userMessageIdentifier)
        #expect(conversation.messages[1].id == exchangeIdentifiers.assistantMessageIdentifier)
        #expect(conversation.messages[1].text.isEmpty)

        // The title comes from the first question only.
        conversation.appendExchange(userText: "and sort by date", inputSource: .typed)
        #expect(conversation.title == "open my downloads")
        #expect(conversation.messages[2].inputSource == .typed)
    }

    @Test func settingReplyTextOnlyTouchesThatMessage() {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "hi", inputSource: .typed)
        conversation.setText("hello!", ofMessageWithIdentifier: exchangeIdentifiers.assistantMessageIdentifier)
        conversation.setText("ignored", ofMessageWithIdentifier: UUID())
        #expect(conversation.messages.map(\.text) == ["hi", "hello!"])
    }

    @Test func voiceTurnAfterAQuietHalfHourStartsANewConversation() {
        let emptyConversation = ChatConversation()
        #expect(!emptyConversation.shouldStartNewConversation(forVoiceTurnAt: Date()))

        let lastMessageDate = Date(timeIntervalSince1970: 1_000_000)
        let conversation = ChatConversation(messages: [
            StoredChatMessage(role: .user, text: "hi", createdAt: lastMessageDate),
        ])
        #expect(!conversation.shouldStartNewConversation(forVoiceTurnAt: lastMessageDate.addingTimeInterval(29 * 60)))
        #expect(conversation.shouldStartNewConversation(forVoiceTurnAt: lastMessageDate.addingTimeInterval(31 * 60)))
    }

    // MARK: - Screenshots

    @Test func screenshotsAreOffByDefaultAndNotSaved() {
        let isolatedChatStorage = IsolatedChatStorage()
        defer { isolatedChatStorage.removeEverything() }
        let chatConversationStore = isolatedChatStorage.makeStore()
        let (conversation, userMessageIdentifier) = makeConversationWithOneExchange()

        #expect(!chatConversationStore.isSavingScreenshotsEnabled)
        #expect(chatConversationStore.saveScreenshot(
            sampleJPEGData,
            forMessageWithIdentifier: userMessageIdentifier,
            inConversationWithIdentifier: conversation.id
        ) == nil)
        #expect(chatConversationStore.screenshotStorageSizeInBytes() == 0)
    }

    @Test func savedScreenshotIsFoundForItsMessageAndSurvivesReload() throws {
        let isolatedChatStorage = IsolatedChatStorage()
        defer { isolatedChatStorage.removeEverything() }
        let chatConversationStore = isolatedChatStorage.makeStore()
        chatConversationStore.setSavingScreenshotsEnabled(true)
        var (conversation, userMessageIdentifier) = makeConversationWithOneExchange()

        let screenshotFileName = try #require(chatConversationStore.saveScreenshot(
            sampleJPEGData,
            forMessageWithIdentifier: userMessageIdentifier,
            inConversationWithIdentifier: conversation.id
        ))
        conversation.messages[0].screenshotFileName = screenshotFileName
        chatConversationStore.save(conversation)

        let reloadedStore = isolatedChatStorage.makeStore()
        #expect(reloadedStore.isSavingScreenshotsEnabled)
        let reloadedUserMessage = try #require(reloadedStore.conversation(withIdentifier: conversation.id)?.messages.first)
        let screenshotFileURL = try #require(reloadedStore.screenshotFileURL(for: reloadedUserMessage, inConversationWithIdentifier: conversation.id))
        #expect(try Data(contentsOf: screenshotFileURL) == sampleJPEGData)
        #expect(reloadedStore.screenshotStorageSizeInBytes() == Int64(sampleJPEGData.count))
    }

    @Test func screenshotsAreNotSavedWhileSavingChatsIsOff() {
        let isolatedChatStorage = IsolatedChatStorage()
        defer { isolatedChatStorage.removeEverything() }
        let chatConversationStore = isolatedChatStorage.makeStore()
        chatConversationStore.setSavingScreenshotsEnabled(true)
        chatConversationStore.setSavingChatsEnabled(false)
        let (conversation, userMessageIdentifier) = makeConversationWithOneExchange()

        #expect(!chatConversationStore.canSaveScreenshots)
        #expect(chatConversationStore.saveScreenshot(
            sampleJPEGData,
            forMessageWithIdentifier: userMessageIdentifier,
            inConversationWithIdentifier: conversation.id
        ) == nil)
    }

    @Test func deletingAChatDeletesItsScreenshots() throws {
        let isolatedChatStorage = IsolatedChatStorage()
        defer { isolatedChatStorage.removeEverything() }
        let chatConversationStore = isolatedChatStorage.makeStore()
        chatConversationStore.setSavingScreenshotsEnabled(true)
        var (conversation, userMessageIdentifier) = makeConversationWithOneExchange()
        conversation.messages[0].screenshotFileName = try #require(chatConversationStore.saveScreenshot(
            sampleJPEGData,
            forMessageWithIdentifier: userMessageIdentifier,
            inConversationWithIdentifier: conversation.id
        ))
        chatConversationStore.save(conversation)

        chatConversationStore.deleteConversation(withIdentifier: conversation.id)
        #expect(chatConversationStore.screenshotFileURL(for: conversation.messages[0], inConversationWithIdentifier: conversation.id) == nil)
        #expect(chatConversationStore.screenshotStorageSizeInBytes() == 0)
    }

    @Test func deletingAllScreenshotsKeepsTheChats() throws {
        let isolatedChatStorage = IsolatedChatStorage()
        defer { isolatedChatStorage.removeEverything() }
        let chatConversationStore = isolatedChatStorage.makeStore()
        chatConversationStore.setSavingScreenshotsEnabled(true)
        var (conversation, userMessageIdentifier) = makeConversationWithOneExchange()
        conversation.messages[0].screenshotFileName = try #require(chatConversationStore.saveScreenshot(
            sampleJPEGData,
            forMessageWithIdentifier: userMessageIdentifier,
            inConversationWithIdentifier: conversation.id
        ))
        chatConversationStore.save(conversation)

        chatConversationStore.deleteAllScreenshots()
        #expect(chatConversationStore.screenshotStorageSizeInBytes() == 0)
        #expect(chatConversationStore.screenshotFileURL(for: conversation.messages[0], inConversationWithIdentifier: conversation.id) == nil)
        #expect(isolatedChatStorage.makeStore().conversations.map(\.id) == [conversation.id])
    }

    // MARK: - Marks drawn by the AI (saved as data, never as a second image)

    private let capturedDisplayFrame = CGRect(x: 1440, y: -200, width: 1920, height: 1080)

    @Test func guidanceIsSavedRelativeToTheCapturedDisplay() throws {
        let otherDisplayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let placedPointer = PlacedPointer(
            appKitGlobalPoint: CGPoint(x: 1540, y: 100),
            displayFrame: capturedDisplayFrame,
            label: "save",
            highlightedElementFrame: CGRect(x: 1500, y: 50, width: 80, height: 20)
        )
        let placedAnnotations = [
            PlacedAnnotation(shape: .highlight(frame: CGRect(x: 1640, y: 0, width: 100, height: 50)), label: "here", displayFrame: capturedDisplayFrame),
            PlacedAnnotation(shape: .circle(center: CGPoint(x: 1940, y: 300), radius: 30), label: nil, displayFrame: capturedDisplayFrame),
            PlacedAnnotation(shape: .note(anchor: CGPoint(x: 10, y: 10), text: "elsewhere"), label: nil, displayFrame: otherDisplayFrame),
        ]

        let savedScreenGuidance = try #require(SavedScreenGuidance(
            pointer: placedPointer,
            annotations: placedAnnotations,
            displayFrame: capturedDisplayFrame
        ))
        #expect(savedScreenGuidance.displaySizeInPoints == CGSize(width: 1920, height: 1080))
        #expect(savedScreenGuidance.pointer?.tipPoint == CGPoint(x: 100, y: 300))
        #expect(savedScreenGuidance.pointer?.highlightedElementFrame == CGRect(x: 60, y: 250, width: 80, height: 20))
        #expect(savedScreenGuidance.annotations.map(\.shape) == [
            .highlight(frame: CGRect(x: 200, y: 200, width: 100, height: 50)),
            .circle(center: CGPoint(x: 500, y: 500), radius: 30),
        ])

        // Rebuilt for drawing on a local frame at the origin.
        #expect(savedScreenGuidance.localScreenFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(savedScreenGuidance.placedPointer?.appKitGlobalPoint == CGPoint(x: 100, y: 300))
        #expect(savedScreenGuidance.placedAnnotations.first?.label == "here")

        #expect(SavedScreenGuidance(pointer: nil, annotations: [], displayFrame: capturedDisplayFrame) == nil)
        #expect(SavedScreenGuidance(pointer: nil, annotations: [placedAnnotations[2]], displayFrame: capturedDisplayFrame) == nil)
    }

    @Test func savedGuidanceRoundTripsEveryShape() throws {
        let everyShapeAnnotations: [PlacedAnnotation] = [
            .init(shape: .highlight(frame: CGRect(x: 1, y: 2, width: 3, height: 4)), label: "box", displayFrame: .zero),
            .init(shape: .circle(center: CGPoint(x: 5, y: 6), radius: 7), label: nil, displayFrame: .zero),
            .init(shape: .arrow(tail: CGPoint(x: 8, y: 9), head: CGPoint(x: 10, y: 11)), label: "look", displayFrame: .zero),
            .init(shape: .underline(start: CGPoint(x: 12, y: 13), end: CGPoint(x: 14, y: 15)), label: nil, displayFrame: .zero),
            .init(shape: .note(anchor: CGPoint(x: 16, y: 17), text: "off by one"), label: nil, displayFrame: .zero),
        ]
        let savedScreenGuidance = try #require(SavedScreenGuidance(
            pointer: PlacedPointer(appKitGlobalPoint: CGPoint(x: 20, y: 30), displayFrame: .zero, label: "tip", highlightedElementFrame: CGRect(x: 1, y: 1, width: 2, height: 2)),
            annotations: everyShapeAnnotations,
            displayFrame: .zero
        ))
        let encodedGuidance = try ChatConversationStore.makeJSONEncoder().encode(savedScreenGuidance)
        let decodedGuidance = try ChatConversationStore.makeJSONDecoder().decode(SavedScreenGuidance.self, from: encodedGuidance)
        #expect(decodedGuidance == savedScreenGuidance)
    }

    @Test func messagesWithoutGuidanceStillLoad() throws {
        let legacyMessageJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"hi","createdAt":"2026-10-31T10:00:00Z","isError":false}
        """
        let decodedMessage = try ChatConversationStore.makeJSONDecoder()
            .decode(StoredChatMessage.self, from: Data(legacyMessageJSON.utf8))
        #expect(decodedMessage.screenGuidance == nil)
    }

    private var sampleGuidance: SavedScreenGuidance {
        SavedScreenGuidance(
            pointer: PlacedPointer(appKitGlobalPoint: CGPoint(x: 5, y: 5), displayFrame: .zero, label: nil, highlightedElementFrame: nil),
            annotations: [],
            displayFrame: .zero
        )!
    }

    @Test func marksAreOnlyKeptWithASavedScreenshot() {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "where?", inputSource: .typed)
        let conversationBeforeRecording = conversation

        conversation.recordScreenshot(
            fileName: nil,
            screenGuidance: sampleGuidance,
            userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier
        )
        #expect(conversation == conversationBeforeRecording)

        conversation.recordScreenshot(
            fileName: "shot.jpg",
            screenGuidance: sampleGuidance,
            userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier
        )
        #expect(conversation.messages[0].screenshotFileName == "shot.jpg")
        #expect(conversation.messages[0].screenGuidance == nil)
        #expect(conversation.messages[1].screenGuidance == sampleGuidance)
        #expect(conversation.messages[1].screenshotFileName == nil) // one image, referenced from the question
    }

    @Test func screenshotExchangeIsFoundFromEitherBubble() throws {
        var conversation = ChatConversation()
        let firstExchange = conversation.appendExchange(userText: "first", inputSource: .typed)
        let secondExchange = conversation.appendExchange(userText: "second", inputSource: .spoken)
        conversation.recordScreenshot(
            fileName: "second.jpg",
            screenGuidance: sampleGuidance,
            userMessageIdentifier: secondExchange.userMessageIdentifier,
            assistantMessageIdentifier: secondExchange.assistantMessageIdentifier
        )

        let fromQuestion = try #require(conversation.screenshotExchange(containingMessageWithIdentifier: secondExchange.userMessageIdentifier))
        #expect(fromQuestion.questionMessage.screenshotFileName == "second.jpg")
        #expect(fromQuestion.replyMessage?.screenGuidance == sampleGuidance)

        let fromReply = try #require(conversation.screenshotExchange(containingMessageWithIdentifier: secondExchange.assistantMessageIdentifier))
        #expect(fromReply.questionMessage.id == secondExchange.userMessageIdentifier)

        #expect(conversation.screenshotExchange(containingMessageWithIdentifier: firstExchange.userMessageIdentifier) == nil)
        #expect(conversation.screenshotExchange(containingMessageWithIdentifier: firstExchange.assistantMessageIdentifier) == nil)
        #expect(conversation.screenshotExchange(containingMessageWithIdentifier: UUID()) == nil)
    }

    // MARK: - The user's own drawing (before / after, from one image)

    @Test func userInkIsSavedRelativeToTheCapturedDisplay() throws {
        var strokeOnCapturedDisplay = UserInkStroke(startingAt: CGPoint(x: 1540, y: 100))
        strokeOnCapturedDisplay.append(CGPoint(x: 1600, y: 100))
        let strokeOnOtherDisplay = UserInkStroke(startingAt: CGPoint(x: 10, y: 10))

        let savedUserInk = try #require(SavedUserInk(
            userInkStrokes: [strokeOnCapturedDisplay, strokeOnOtherDisplay],
            displayFrame: capturedDisplayFrame
        ))
        #expect(savedUserInk.displaySizeInPoints == CGSize(width: 1920, height: 1080))
        #expect(savedUserInk.strokes == [[CGPoint(x: 100, y: 300), CGPoint(x: 160, y: 300)]])
        #expect(savedUserInk.localScreenFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(savedUserInk.userInkStrokes.map(\.points) == savedUserInk.strokes)

        #expect(SavedUserInk(userInkStrokes: [strokeOnOtherDisplay], displayFrame: capturedDisplayFrame) == nil)
        #expect(SavedUserInk(userInkStrokes: [], displayFrame: capturedDisplayFrame) == nil)

        let encodedUserInk = try ChatConversationStore.makeJSONEncoder().encode(savedUserInk)
        #expect(try ChatConversationStore.makeJSONDecoder().decode(SavedUserInk.self, from: encodedUserInk) == savedUserInk)
    }

    @Test func messagesWithoutUserInkStillLoad() throws {
        let legacyMessageJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","text":"hi","createdAt":"2026-10-31T10:00:00Z","isError":false}
        """
        let decodedMessage = try ChatConversationStore.makeJSONDecoder()
            .decode(StoredChatMessage.self, from: Data(legacyMessageJSON.utf8))
        #expect(decodedMessage.userInk == nil)
    }

    @Test func userInkIsKeptOnTheQuestionOnlyWithASavedScreenshot() throws {
        let savedUserInk = try #require(SavedUserInk(
            userInkStrokes: [UserInkStroke(startingAt: CGPoint(x: 5, y: 5))],
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "this one", inputSource: .spoken)

        conversation.recordScreenshot(
            fileName: nil,
            screenGuidance: nil,
            userInk: savedUserInk,
            userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier
        )
        #expect(conversation.messages[0].userInk == nil)

        conversation.recordScreenshot(
            fileName: "shot.jpg",
            screenGuidance: nil,
            userInk: savedUserInk,
            userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier
        )
        #expect(conversation.messages[0].userInk == savedUserInk)
        #expect(conversation.messages[1].userInk == nil)
    }
}
