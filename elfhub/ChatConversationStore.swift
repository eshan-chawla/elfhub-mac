//
//  ChatConversationStore.swift
//  elfhub
//
//  Keeps conversations on this Mac — never on a server. Each conversation is
//  one JSON file in ~/Library/Application Support/elfhub/Conversations,
//  holding what the user typed or said and the replies. Only when the user
//  turns it on, the screenshot each turn sent to the model is kept too, as a
//  JPEG under Conversations/Screenshots/<conversation id>/. The user can turn
//  saving off, reveal the folder, or delete everything in Settings.
//

import AppKit
import Combine
import Foundation

struct StoredChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    /// How the user's message arrived — typed in chat or spoken with push-to-talk.
    enum InputSource: String, Codable {
        case typed
        case spoken
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// True for an assistant bubble that shows an error instead of a reply,
    /// so it's never sent back to the model as conversation history.
    var isError: Bool
    var inputSource: InputSource
    /// File name of the screenshot sent with this (user) message, when the
    /// user chose to keep screenshots. Resolved by ChatConversationStore.
    var screenshotFileName: String?
    /// On a reply: the pointer and marks it drew on that screenshot, saved as
    /// data and drawn over the question's screenshot — never a second image.
    var screenGuidance: SavedScreenGuidance?
    /// On a question: what the user drew while asking, redrawn over the
    /// saved (original) screenshot for the "after" view.
    var userInk: SavedUserInk?
    /// On a reply: the notepad it wrote on screen, kept whole with the chat.
    var notepad: SavedNotepad?
    /// On a reply: files the elf changed in its folder, each with Undo.
    var fileChanges: [SavedElfFileChange]
    /// On a reply: the elf that answered, when it wasn't the main elf.
    var speakingElfIdentifier: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        isError: Bool = false,
        inputSource: InputSource = .typed,
        screenshotFileName: String? = nil,
        screenGuidance: SavedScreenGuidance? = nil,
        userInk: SavedUserInk? = nil,
        notepad: SavedNotepad? = nil,
        fileChanges: [SavedElfFileChange] = [],
        speakingElfIdentifier: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isError = isError
        self.inputSource = inputSource
        self.screenshotFileName = screenshotFileName
        self.screenGuidance = screenGuidance
        self.userInk = userInk
        self.notepad = notepad
        self.fileChanges = fileChanges
        self.speakingElfIdentifier = speakingElfIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, isError, inputSource, screenshotFileName, screenGuidance, userInk, notepad, fileChanges, speakingElfIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        // Chats saved before voice turns and screenshots were recorded.
        inputSource = try container.decodeIfPresent(InputSource.self, forKey: .inputSource) ?? .typed
        screenshotFileName = try container.decodeIfPresent(String.self, forKey: .screenshotFileName)
        screenGuidance = try container.decodeIfPresent(SavedScreenGuidance.self, forKey: .screenGuidance)
        userInk = try container.decodeIfPresent(SavedUserInk.self, forKey: .userInk)
        notepad = try container.decodeIfPresent(SavedNotepad.self, forKey: .notepad)
        fileChanges = try container.decodeIfPresent([SavedElfFileChange].self, forKey: .fileChanges) ?? []
        // Replies saved before side elves were all the main elf's.
        speakingElfIdentifier = try container.decodeIfPresent(String.self, forKey: .speakingElfIdentifier)
    }
}

/// A file an elf changed in its folder during a reply, shown under the
/// reply with Undo. The change itself is in the elf's change log.
struct SavedElfFileChange: Codable, Equatable {
    let changeEntryIdentifier: UUID
    let elfIdentifier: String
    /// "saved files/trip.md"
    let note: String
    var isUndone: Bool

    init(changeEntryIdentifier: UUID, elfIdentifier: String, note: String, isUndone: Bool = false) {
        self.changeEntryIdentifier = changeEntryIdentifier
        self.elfIdentifier = elfIdentifier
        self.note = note
        self.isUndone = isUndone
    }
}

struct ChatConversation: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [StoredChatMessage]

    static let untitledConversationTitle = "New chat"

    init(id: UUID = UUID(), title: String = ChatConversation.untitledConversationTitle, createdAt: Date = Date(), messages: [StoredChatMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = messages
    }

    /// Adds the user's message and an empty reply bubble that the streamed
    /// reply fills in. The first message also names the conversation.
    @discardableResult
    mutating func appendExchange(
        userText: String,
        inputSource: StoredChatMessage.InputSource,
        speakingElfIdentifier: String? = nil
    ) -> (userMessageIdentifier: UUID, assistantMessageIdentifier: UUID) {
        if messages.isEmpty {
            title = ChatConversation.title(forFirstUserMessage: userText)
        }
        let userMessage = StoredChatMessage(role: .user, text: userText, inputSource: inputSource)
        // A side elf's reply is marked from the start, so a reply stopped
        // with Esc or restarted on the fallback model stays its.
        let assistantMessage = StoredChatMessage(
            role: .assistant,
            text: "",
            speakingElfIdentifier: speakingElfIdentifier == ElfManager.mainElfIdentifier ? nil : speakingElfIdentifier
        )
        messages.append(userMessage)
        messages.append(assistantMessage)
        return (userMessage.id, assistantMessage.id)
    }

    mutating func setText(_ text: String, ofMessageWithIdentifier messageIdentifier: UUID) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageIdentifier }) else { return }
        messages[messageIndex].text = text
    }

    /// Attaches a turn's saved screenshot: the file name and the user's own
    /// drawing to the question, elfhub's marks to the reply. Without a saved
    /// file nothing is recorded, so marks never exist without an image.
    mutating func recordScreenshot(
        fileName screenshotFileName: String?,
        screenGuidance: SavedScreenGuidance?,
        userInk: SavedUserInk? = nil,
        userMessageIdentifier: UUID,
        assistantMessageIdentifier: UUID
    ) {
        guard let screenshotFileName,
              let userMessageIndex = messages.firstIndex(where: { $0.id == userMessageIdentifier }) else { return }
        messages[userMessageIndex].screenshotFileName = screenshotFileName
        messages[userMessageIndex].userInk = userInk
        if let assistantMessageIndex = messages.firstIndex(where: { $0.id == assistantMessageIdentifier }) {
            messages[assistantMessageIndex].screenGuidance = screenGuidance
        }
    }

    /// Keeps the notepad a reply wrote with that reply.
    mutating func recordFileChanges(_ fileChanges: [SavedElfFileChange], assistantMessageIdentifier: UUID) {
        guard !fileChanges.isEmpty,
              let assistantMessageIndex = messages.firstIndex(where: { $0.id == assistantMessageIdentifier }) else { return }
        let alreadyShownChangeIdentifiers = Set(messages[assistantMessageIndex].fileChanges.map(\.changeEntryIdentifier))
        messages[assistantMessageIndex].fileChanges += fileChanges.filter { !alreadyShownChangeIdentifiers.contains($0.changeEntryIdentifier) }
    }

    /// Marks a reply as answered by a side elf (nil or main: the main elf).
    mutating func recordSpeakingElf(_ speakingElfIdentifier: String?, assistantMessageIdentifier: UUID) {
        guard let assistantMessageIndex = messages.firstIndex(where: { $0.id == assistantMessageIdentifier }) else { return }
        messages[assistantMessageIndex].speakingElfIdentifier =
            speakingElfIdentifier == ElfManager.mainElfIdentifier ? nil : speakingElfIdentifier
    }

    mutating func markFileChangeUndone(changeEntryIdentifier: UUID) {
        for messageIndex in messages.indices {
            for fileChangeIndex in messages[messageIndex].fileChanges.indices
            where messages[messageIndex].fileChanges[fileChangeIndex].changeEntryIdentifier == changeEntryIdentifier {
                messages[messageIndex].fileChanges[fileChangeIndex].isUndone = true
            }
        }
    }

    mutating func recordNotepad(_ notepad: SavedNotepad?, assistantMessageIdentifier: UUID) {
        guard let notepad,
              let assistantMessageIndex = messages.firstIndex(where: { $0.id == assistantMessageIdentifier }) else { return }
        messages[assistantMessageIndex].notepad = notepad
    }

    /// The question that carries a screenshot and its reply, found from
    /// either bubble: a reply needs its question's screenshot, a question
    /// needs its reply's marks. Nil when that exchange has no screenshot.
    func screenshotExchange(
        containingMessageWithIdentifier messageIdentifier: UUID
    ) -> (questionMessage: StoredChatMessage, replyMessage: StoredChatMessage?)? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageIdentifier }) else { return nil }

        let questionIndex: Int
        if messages[messageIndex].role == .user {
            questionIndex = messageIndex
        } else if let precedingQuestionIndex = messages[..<messageIndex].lastIndex(where: { $0.role == .user }) {
            questionIndex = precedingQuestionIndex
        } else {
            return nil
        }

        let questionMessage = messages[questionIndex]
        guard questionMessage.screenshotFileName != nil else { return nil }
        let replyIndex = questionIndex + 1
        let replyMessage = replyIndex < messages.count && messages[replyIndex].role == .assistant
            ? messages[replyIndex]
            : nil
        return (questionMessage, replyMessage)
    }

    /// Push-to-talk turns join the open conversation, but after half an hour
    /// of quiet a new question is very likely a new topic — starting a fresh
    /// conversation keeps the history list readable and the model unconfused.
    static let quietPeriodBeforeNewVoiceConversation: TimeInterval = 30 * 60

    func shouldStartNewConversation(forVoiceTurnAt voiceTurnDate: Date) -> Bool {
        guard let lastMessageDate = messages.last?.createdAt else { return false }
        return voiceTurnDate.timeIntervalSince(lastMessageDate) > Self.quietPeriodBeforeNewVoiceConversation
    }

    /// Completed user → assistant exchanges, oldest first, for giving the
    /// model the conversation so far when the user reopens a chat. Error
    /// bubbles and unanswered messages are left out.
    /// `elfNameForIdentifier` names the side elves that answered, so each
    /// elf can tell its own replies from the others'.
    func historyTurns(
        maximumTurnCount: Int,
        elfNameForIdentifier: (String) -> String? = { _ in nil }
    ) -> [LanguageModelHistoryTurn] {
        var historyTurns: [LanguageModelHistoryTurn] = []
        var pendingUserText: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingUserText = message.text
            case .assistant:
                if let userText = pendingUserText, !message.isError, !message.text.isEmpty {
                    // Same as a live turn: the model remembers its notepad.
                    let assistantText = message.notepad.map { message.text + "\n\n" + $0.textForConversationHistory } ?? message.text
                    historyTurns.append(LanguageModelHistoryTurn(
                        userText: userText,
                        assistantText: assistantText,
                        speakingElfName: message.speakingElfIdentifier.flatMap(elfNameForIdentifier)
                    ))
                }
                pendingUserText = nil
            }
        }
        return Array(historyTurns.suffix(maximumTurnCount))
    }

    /// A short title from the first thing the user typed.
    static func title(forFirstUserMessage firstUserMessage: String) -> String {
        let singleLineMessage = firstUserMessage
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLineMessage.isEmpty else { return untitledConversationTitle }
        let maximumTitleLength = 48
        if singleLineMessage.count <= maximumTitleLength {
            return singleLineMessage
        }
        return String(singleLineMessage.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

@MainActor
final class ChatConversationStore: ObservableObject {
    /// Saved conversations, most recently updated first.
    @Published private(set) var conversations: [ChatConversation] = []
    /// When off, chats live only in memory and disappear when elfhub quits.
    @Published private(set) var isSavingChatsEnabled: Bool
    /// Off by default: screenshots can show anything on screen, so keeping
    /// them is the user's explicit choice. Only applies while chats are saved.
    @Published private(set) var isSavingScreenshotsEnabled: Bool

    let storageDirectoryURL: URL
    private let userDefaults: UserDefaults

    private static let isSavingChatsEnabledKey = "isSavingChatsOnThisMacEnabled"
    private static let isSavingScreenshotsEnabledKey = "isSavingChatScreenshotsOnThisMacEnabled"

    nonisolated static var defaultStorageDirectoryURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportDirectoryURL
            .appendingPathComponent("elfhub", isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
    }

    init(
        storageDirectoryURL: URL = ChatConversationStore.defaultStorageDirectoryURL,
        userDefaults: UserDefaults = .standard
    ) {
        self.storageDirectoryURL = storageDirectoryURL
        self.userDefaults = userDefaults
        self.isSavingChatsEnabled = userDefaults.object(forKey: Self.isSavingChatsEnabledKey) as? Bool ?? true
        self.isSavingScreenshotsEnabled = userDefaults.bool(forKey: Self.isSavingScreenshotsEnabledKey)
        conversations = isSavingChatsEnabled ? loadConversationsFromDisk() : []
    }

    // MARK: - Reading

    func conversation(withIdentifier conversationIdentifier: UUID) -> ChatConversation? {
        conversations.first { $0.id == conversationIdentifier }
    }

    // MARK: - Writing

    /// Adds or replaces a conversation and writes it to disk. Empty
    /// conversations stay out of the list until the first message.
    func save(_ conversation: ChatConversation) {
        guard !conversation.messages.isEmpty else { return }
        var updatedConversation = conversation
        updatedConversation.updatedAt = Date()

        conversations.removeAll { $0.id == updatedConversation.id }
        conversations.insert(updatedConversation, at: 0)

        guard isSavingChatsEnabled else { return }
        writeConversationToDisk(updatedConversation)
    }

    func deleteConversation(withIdentifier conversationIdentifier: UUID) {
        conversations.removeAll { $0.id == conversationIdentifier }
        try? FileManager.default.removeItem(at: fileURL(forConversationIdentifier: conversationIdentifier))
        try? FileManager.default.removeItem(at: screenshotDirectoryURL(forConversationIdentifier: conversationIdentifier))
    }

    /// Removes every saved chat from memory and disk.
    func deleteAllConversations() {
        conversations.removeAll()
        let savedConversationFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for savedConversationFileURL in savedConversationFileURLs where savedConversationFileURL.pathExtension == "json" {
            try? FileManager.default.removeItem(at: savedConversationFileURL)
        }
        deleteAllScreenshots()
    }

    /// Turning saving on writes the chats from this session to disk; turning
    /// it off stops writing but keeps existing files until the user deletes them.
    func setSavingChatsEnabled(_ enabled: Bool) {
        isSavingChatsEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isSavingChatsEnabledKey)
        if enabled {
            for conversation in conversations {
                writeConversationToDisk(conversation)
            }
        }
    }

    // MARK: - Screenshots

    /// Screenshots are kept only while both settings are on.
    var canSaveScreenshots: Bool {
        isSavingChatsEnabled && isSavingScreenshotsEnabled
    }

    /// Turning it off stops keeping new screenshots; ones already saved stay
    /// until the user deletes them (or the chats they belong to).
    func setSavingScreenshotsEnabled(_ enabled: Bool) {
        isSavingScreenshotsEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isSavingScreenshotsEnabledKey)
    }

    /// Writes the screenshot a user message was sent with and returns its file
    /// name for `StoredChatMessage.screenshotFileName`; nil when screenshots
    /// aren't being kept or the write failed.
    func saveScreenshot(
        _ screenshotJPEGData: Data,
        forMessageWithIdentifier messageIdentifier: UUID,
        inConversationWithIdentifier conversationIdentifier: UUID
    ) -> String? {
        guard canSaveScreenshots else { return nil }
        let screenshotDirectoryURL = screenshotDirectoryURL(forConversationIdentifier: conversationIdentifier)
        let screenshotFileName = "\(messageIdentifier.uuidString).jpg"
        do {
            try FileManager.default.createDirectory(at: screenshotDirectoryURL, withIntermediateDirectories: true)
            try screenshotJPEGData.write(to: screenshotDirectoryURL.appendingPathComponent(screenshotFileName), options: .atomic)
            return screenshotFileName
        } catch {
            print("⚠️ Chat history: couldn't save screenshot: \(error.localizedDescription)")
            return nil
        }
    }

    /// The saved screenshot for a message, or nil if it has none or the file
    /// was deleted (e.g. with "Delete saved screenshots").
    func screenshotFileURL(for message: StoredChatMessage, inConversationWithIdentifier conversationIdentifier: UUID) -> URL? {
        guard let screenshotFileName = message.screenshotFileName else { return nil }
        let screenshotFileURL = screenshotDirectoryURL(forConversationIdentifier: conversationIdentifier)
            .appendingPathComponent(screenshotFileName)
        return FileManager.default.fileExists(atPath: screenshotFileURL.path) ? screenshotFileURL : nil
    }

    /// Removes every saved screenshot; the chats themselves stay.
    func deleteAllScreenshots() {
        try? FileManager.default.removeItem(at: screenshotsRootDirectoryURL)
        objectWillChange.send()
    }

    /// Disk space used by saved screenshots, shown in Settings.
    func screenshotStorageSizeInBytes() -> Int64 {
        guard let screenshotFileEnumerator = FileManager.default.enumerator(
            at: screenshotsRootDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var totalSizeInBytes: Int64 = 0
        for case let screenshotFileURL as URL in screenshotFileEnumerator {
            let fileSizeInBytes = (try? screenshotFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalSizeInBytes += Int64(fileSizeInBytes)
        }
        return totalSizeInBytes
    }

    private var screenshotsRootDirectoryURL: URL {
        storageDirectoryURL.appendingPathComponent("Screenshots", isDirectory: true)
    }

    private func screenshotDirectoryURL(forConversationIdentifier conversationIdentifier: UUID) -> URL {
        screenshotsRootDirectoryURL.appendingPathComponent(conversationIdentifier.uuidString, isDirectory: true)
    }

    func revealStorageFolderInFinder() {
        try? FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([storageDirectoryURL])
    }

    // MARK: - Disk

    private func fileURL(forConversationIdentifier conversationIdentifier: UUID) -> URL {
        storageDirectoryURL.appendingPathComponent("\(conversationIdentifier.uuidString).json")
    }

    private func writeConversationToDisk(_ conversation: ChatConversation) {
        do {
            try FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
            let conversationData = try Self.makeJSONEncoder().encode(conversation)
            try conversationData.write(to: fileURL(forConversationIdentifier: conversation.id), options: .atomic)
        } catch {
            print("⚠️ Chat history: couldn't save conversation: \(error.localizedDescription)")
        }
    }

    private func loadConversationsFromDisk() -> [ChatConversation] {
        let savedConversationFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let jsonDecoder = Self.makeJSONDecoder()
        return savedConversationFileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { savedConversationFileURL in
                guard let conversationData = try? Data(contentsOf: savedConversationFileURL) else { return nil }
                return try? jsonDecoder.decode(ChatConversation.self, from: conversationData)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func makeJSONEncoder() -> JSONEncoder {
        let jsonEncoder = JSONEncoder()
        // ISO 8601 with milliseconds: plain .iso8601 drops fractions of a
        // second, so chats saved within the same second reloaded in random order.
        jsonEncoder.dateEncodingStrategy = .custom { date, encoder in
            var singleValueContainer = encoder.singleValueContainer()
            try singleValueContainer.encode(makeISO8601DateFormatter(includesFractionalSeconds: true).string(from: date))
        }
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return jsonEncoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let jsonDecoder = JSONDecoder()
        // Accepts dates with and without milliseconds (earlier saves had none).
        jsonDecoder.dateDecodingStrategy = .custom { decoder in
            let singleValueContainer = try decoder.singleValueContainer()
            let dateText = try singleValueContainer.decode(String.self)
            if let date = makeISO8601DateFormatter(includesFractionalSeconds: true).date(from: dateText)
                ?? makeISO8601DateFormatter(includesFractionalSeconds: false).date(from: dateText) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: singleValueContainer, debugDescription: "Not an ISO 8601 date: \(dateText)")
        }
        return jsonDecoder
    }

    private nonisolated static func makeISO8601DateFormatter(includesFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let iso8601DateFormatter = ISO8601DateFormatter()
        iso8601DateFormatter.formatOptions = includesFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return iso8601DateFormatter
    }
}
