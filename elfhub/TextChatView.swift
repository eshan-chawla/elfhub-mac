//
//  TextChatView.swift
//  elfhub
//
//  The in-app text-chat surface — available anytime, and the primary
//  experience in text-only mode. Typing a message runs the exact same pipeline
//  as voice (screenshot → active provider → pointing/actions), just with the
//  reply streamed as text instead of spoken. Speaking still happens if the
//  voice-output mode isn't Off.
//
//  Conversations are saved only on this Mac (ChatConversationStore) and hold
//  push-to-talk turns too, so everything the user asked shows up here. The
//  main window lists them in its sidebar (ChatConversationSidebarList); the
//  compact chat window uses a recent-chats menu in its header.
//

import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class TextChatViewModel: ObservableObject {
    /// The conversation on screen. Starts empty; it's saved once it has a message.
    @Published private(set) var activeConversation = ChatConversation()
    @Published private(set) var isResponding = false
    @Published var draft: String = ""
    /// The elf picked for the next message, if any (else: by name, or main).
    @Published var composerElfSelection = ChatComposerElfSelection()
    /// Shown above the chat whose turn the ChatGPT plan handed to the
    /// fallback model (or took over again), until the user dismisses it.
    @Published private(set) var languageModelSwitchChatNotice: LanguageModelSwitchChatNotice?

    /// The switch notice for the chat on screen, if it belongs to that chat.
    var visibleLanguageModelSwitchNotice: LanguageModelSwitchNotice? {
        guard let languageModelSwitchChatNotice,
              languageModelSwitchChatNotice.isShown(inConversationWithIdentifier: activeConversation.id) else { return nil }
        return languageModelSwitchChatNotice.switchNotice
    }

    let chatConversationStore: ChatConversationStore
    private let companionManager: CompanionManager
    private var currentTask: Task<Void, Never>?

    init(companionManager: CompanionManager, chatConversationStore: ChatConversationStore) {
        self.companionManager = companionManager
        self.chatConversationStore = chatConversationStore
    }

    var messages: [StoredChatMessage] {
        activeConversation.messages
    }

    /// What an empty chat says — the main window opens on chat, so this is
    /// also where people learn how to talk to elfhub.
    var emptyConversationHint: String {
        if companionManager.interactionInputMode.isVoiceInputEnabled {
            return "Hold \(companionManager.pushToTalkShortcutOption.displayText) anywhere to talk, or type below — elfhub can see your screen when you ask."
        }
        return "Type below to ask anything — elfhub can see your screen when you ask."
    }

    // MARK: Conversations

    /// Starts a fresh conversation; the model forgets the previous one.
    func startNewConversation() {
        guard !isResponding else { return }
        activeConversation = ChatConversation()
        companionManager.companionTurnPipeline.clearConversationHistory()
    }

    /// Reopens a saved conversation and gives the model its recent exchanges.
    func openConversation(withIdentifier conversationIdentifier: UUID) {
        guard !isResponding,
              let savedConversation = chatConversationStore.conversation(withIdentifier: conversationIdentifier) else { return }
        activeConversation = savedConversation
        companionManager.companionTurnPipeline.replaceConversationHistory(
            with: savedConversation.historyTurns(
                maximumTurnCount: CompanionTurnPipeline.maximumHistoryTurns,
                elfNameForIdentifier: { [companionManager] elfIdentifier in
                    companionManager.elfManager.elf(withIdentifier: elfIdentifier)?.configuration.identity.name
                }
            )
        )
    }

    func deleteConversation(withIdentifier conversationIdentifier: UUID) {
        guard !(isResponding && activeConversation.id == conversationIdentifier) else { return }
        chatConversationStore.deleteConversation(withIdentifier: conversationIdentifier)
        if activeConversation.id == conversationIdentifier {
            startNewConversation()
        }
    }

    // MARK: Sending

    func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        draft = ""

        // Who answers is decided now, so the reply is theirs from the start.
        let speakingElf = companionManager.addressedElf(
            for: trimmed,
            chosenElfIdentifier: composerElfSelection.takeElfIdentifierForSending()
        )
        let chosenElfIdentifier = speakingElf?.id ?? ElfManager.mainElfIdentifier
        var recordedExchange = beginExchange(userText: trimmed, inputSource: .typed, speakingElfIdentifier: speakingElf?.id)
        isResponding = true

        currentTask = Task { [weak self] in
            guard let self else { return }
            var rawReplyText = ""
            do {
                let turnResult = try await self.companionManager.respondToChatMessage(
                    trimmed,
                    chosenElfIdentifier: chosenElfIdentifier,
                    onTextChunk: { chunk in
                        rawReplyText += chunk
                        self.showStreamingReply(rawReplyText: rawReplyText, for: recordedExchange)
                    },
                    onElfFileChanged: { fileChange, elfIdentifier in
                        self.recordFileChange(fileChange, elfIdentifier: elfIdentifier, for: recordedExchange)
                    },
                    onLanguageModelSwitched: { switchNotice in
                        self.showLanguageModelSwitchNotice(
                            switchNotice,
                            inConversationWithIdentifier: recordedExchange.conversationIdentifier
                        )
                        guard case .switchedToFallback = switchNotice else { return }
                        recordedExchange = self.restartExchangeAfterLanguageModelSwitch(
                            recordedExchange,
                            userText: trimmed,
                            inputSource: .typed,
                            rawReplyTextSoFar: rawReplyText
                        )
                        rawReplyText = ""
                    }
                )
                self.completeExchange(recordedExchange, with: turnResult)
            } catch is CancellationError {
                self.saveInterruptedExchange(recordedExchange, rawReplyTextSoFar: rawReplyText)
            } catch {
                self.failExchange(recordedExchange, with: error)
            }
            self.isResponding = false
        }
    }

    /// Stops a typed reply that is still streaming (Esc). The send task's
    /// cancellation path saves what arrived so far as an interrupted reply.
    func stopCurrentReply() {
        guard isResponding else { return }
        currentTask?.cancel()
    }

    // MARK: Recording exchanges (typed and spoken)

    /// Where one question and its reply live, so the reply can be filled in
    /// even if the user switches to another chat while it streams.
    struct RecordedExchange {
        let conversationIdentifier: UUID
        let userMessageIdentifier: UUID
        let assistantMessageIdentifier: UUID
        /// The side elf answering (nil: the main elf).
        var speakingElfIdentifier: String? = nil
    }

    /// Adds the question and an empty reply bubble to the open conversation
    /// and saves it. A spoken question after a long quiet spell starts a new
    /// conversation instead (see `shouldStartNewConversation(forVoiceTurnAt:)`).
    func beginExchange(
        userText: String,
        inputSource: StoredChatMessage.InputSource,
        speakingElfIdentifier: String? = nil
    ) -> RecordedExchange {
        if inputSource == .spoken, !isResponding,
           activeConversation.shouldStartNewConversation(forVoiceTurnAt: Date()) {
            startNewConversation()
        }
        let exchangeIdentifiers = activeConversation.appendExchange(
            userText: userText,
            inputSource: inputSource,
            speakingElfIdentifier: speakingElfIdentifier
        )
        chatConversationStore.save(activeConversation)
        return RecordedExchange(
            conversationIdentifier: activeConversation.id,
            userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier,
            speakingElfIdentifier: speakingElfIdentifier
        )
    }

    /// Streams the reply into its bubble with guidance tags hidden (even
    /// half-written ones). Not saved until the turn ends.
    func showStreamingReply(rawReplyText: String, for recordedExchange: RecordedExchange) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: false) { conversation in
            conversation.setText(
                SpokenSentenceSegmenter.speakableText(fromPartialResponse: rawReplyText),
                ofMessageWithIdentifier: recordedExchange.assistantMessageIdentifier
            )
        }
    }

    /// The decoder's clean reply replaces the streamed text, and the
    /// screenshot the model saw is kept (with the marks drawn on it, as data)
    /// if the user turned that on.
    func completeExchange(_ recordedExchange: RecordedExchange, with turnResult: CompanionTurnPipeline.TurnResult) {
        let screenshotFileName = turnResult.originalScreenshotJPEGData.flatMap { originalScreenshotJPEGData in
            chatConversationStore.saveScreenshot(
                originalScreenshotJPEGData,
                forMessageWithIdentifier: recordedExchange.userMessageIdentifier,
                inConversationWithIdentifier: recordedExchange.conversationIdentifier
            )
        }
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.setText(
                turnResult.spokenText.isEmpty ? "…" : turnResult.spokenText,
                ofMessageWithIdentifier: recordedExchange.assistantMessageIdentifier
            )
            conversation.recordScreenshot(
                fileName: screenshotFileName,
                screenGuidance: turnResult.shownScreenGuidance,
                userInk: turnResult.shownUserInk,
                userMessageIdentifier: recordedExchange.userMessageIdentifier,
                assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier
            )
            conversation.recordNotepad(turnResult.shownNotepad, assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier)
            conversation.recordSpeakingElf(turnResult.elfIdentifier, assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier)
            conversation.recordFileChanges(
                turnResult.elfFileChanges.map { fileChange in
                    SavedElfFileChange(
                        changeEntryIdentifier: fileChange.id,
                        elfIdentifier: turnResult.elfIdentifier ?? ElfManager.mainElfIdentifier,
                        note: ElfFileTools.chatNote(for: fileChange)
                    )
                },
                assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier
            )
        }
    }

    /// "🧝 Juniper" above a reply a side elf gave; nil for the main elf's.
    func speakerLabel(for message: StoredChatMessage) -> String? {
        guard let speakingElfIdentifier = message.speakingElfIdentifier else { return nil }
        guard let speakingElf = companionManager.elfManager.elf(withIdentifier: speakingElfIdentifier) else {
            return speakingElfIdentifier
        }
        let identity = speakingElf.configuration.identity
        return identity.emoji.isEmpty ? identity.name : "\(identity.emoji) \(identity.name)"
    }

    /// Every elf, main first, for the composer's picker.
    var elvesForComposer: [Elf] {
        companionManager.elfManager.elves
    }

    /// Shows a file change under the reply as soon as the elf makes it, so
    /// a reply stopped with Esc still lists (and can undo) what it saved.
    func recordFileChange(_ fileChange: ElfChangeLogEntry, elfIdentifier: String, for recordedExchange: RecordedExchange) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.recordFileChanges(
                [SavedElfFileChange(changeEntryIdentifier: fileChange.id, elfIdentifier: elfIdentifier, note: ElfFileTools.chatNote(for: fileChange))],
                assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier
            )
        }
    }

    /// Undoes a file change shown under a reply, through that elf's change
    /// log. Throws `ElfChangeLogError.fileChangedSinceThisChange` when the
    /// file changed since, so the user can choose to undo anyway (`force`).
    func undoFileChange(_ savedFileChange: SavedElfFileChange, force: Bool) throws {
        guard let changedElf = companionManager.elfManager.elf(withIdentifier: savedFileChange.elfIdentifier) else {
            throw ElfManagerError.unknownElf(savedFileChange.elfIdentifier)
        }
        do {
            try ElfChangeLog(home: changedElf.home).undo(entryIdentifier: savedFileChange.changeEntryIdentifier, force: force)
        } catch ElfChangeLogError.alreadyUndone {
            // Undone from the hub already: just show it as undone.
        }
        updateConversation(withIdentifier: activeConversation.id, savingToDisk: true) { conversation in
            conversation.markFileChangeUndone(changeEntryIdentifier: savedFileChange.changeEntryIdentifier)
        }
    }

    /// Interrupted (the user spoke again or stopped it): keep whatever
    /// streamed so far, including any notepad lines already written. An
    /// empty reply is left out of the model's history.
    func saveInterruptedExchange(_ recordedExchange: RecordedExchange, rawReplyTextSoFar: String) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.recordNotepad(
                NotepadTagParser.notepad(fromResponseText: rawReplyTextSoFar),
                assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier
            )
        }
    }

    /// The ChatGPT plan stopped partway and the fallback model answers the
    /// same question from the start. A reply that had already begun is kept
    /// as interrupted and the new answer gets its own exchange in the same
    /// chat (even if the user has opened another one since); if nothing had
    /// streamed yet, the same reply bubble is reused.
    func restartExchangeAfterLanguageModelSwitch(
        _ recordedExchange: RecordedExchange,
        userText: String,
        inputSource: StoredChatMessage.InputSource,
        rawReplyTextSoFar: String
    ) -> RecordedExchange {
        guard !rawReplyTextSoFar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return recordedExchange
        }
        saveInterruptedExchange(recordedExchange, rawReplyTextSoFar: rawReplyTextSoFar)
        var restartedExchange = recordedExchange
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            let exchangeIdentifiers = conversation.appendExchange(
                userText: userText,
                inputSource: inputSource,
                speakingElfIdentifier: recordedExchange.speakingElfIdentifier
            )
            restartedExchange = RecordedExchange(
                conversationIdentifier: recordedExchange.conversationIdentifier,
                userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
                assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier,
                speakingElfIdentifier: recordedExchange.speakingElfIdentifier
            )
        }
        return restartedExchange
    }

    func showLanguageModelSwitchNotice(
        _ switchNotice: LanguageModelSwitchNotice,
        inConversationWithIdentifier conversationIdentifier: UUID
    ) {
        languageModelSwitchChatNotice = LanguageModelSwitchChatNotice(
            switchNotice: switchNotice,
            conversationIdentifier: conversationIdentifier
        )
    }

    func dismissLanguageModelSwitchNotice() {
        languageModelSwitchChatNotice = nil
    }

    func failExchange(_ recordedExchange: RecordedExchange, with error: Error) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.setText("⚠️ \(error.localizedDescription)", ofMessageWithIdentifier: recordedExchange.assistantMessageIdentifier)
            if let assistantMessageIndex = conversation.messages.firstIndex(where: { $0.id == recordedExchange.assistantMessageIdentifier }) {
                conversation.messages[assistantMessageIndex].isError = true
            }
        }
    }

    /// A background task's report, in the chat it came from (or the open
    /// one when that chat is gone or wasn't saved).
    func appendTaskReport(_ reportText: String, elfIdentifier: String, taskIdentifier: UUID, conversationIdentifier: UUID?) {
        let reportConversationIdentifier = conversationIdentifier.flatMap { originConversationIdentifier in
            originConversationIdentifier == activeConversation.id
                || chatConversationStore.conversation(withIdentifier: originConversationIdentifier) != nil
                ? originConversationIdentifier
                : nil
        } ?? activeConversation.id
        updateConversation(withIdentifier: reportConversationIdentifier, savingToDisk: true) { conversation in
            conversation.appendTaskReport(reportText, elfIdentifier: elfIdentifier, taskIdentifier: taskIdentifier)
        }
    }

    /// Applies a change to the conversation on screen, or — if the user has
    /// since opened another chat — to its saved copy.
    private func updateConversation(
        withIdentifier conversationIdentifier: UUID,
        savingToDisk: Bool,
        change: (inout ChatConversation) -> Void
    ) {
        if activeConversation.id == conversationIdentifier {
            change(&activeConversation)
            if savingToDisk {
                chatConversationStore.save(activeConversation)
            }
        } else if var savedConversation = chatConversationStore.conversation(withIdentifier: conversationIdentifier) {
            change(&savedConversation)
            if savingToDisk {
                chatConversationStore.save(savedConversation)
            }
        }
    }
}

// MARK: - View

struct TextChatView: View {
    @ObservedObject var viewModel: TextChatViewModel
    @ObservedObject var chatConversationStore: ChatConversationStore
    /// The compact chat window switches chats from a menu in its header; the
    /// main window lists every chat in its sidebar instead.
    var showsRecentChatsMenu: Bool
    /// Set (main window only) while the language model still needs setup:
    /// shows a banner that opens Settings › Models.
    var onOpenModelSettings: (() -> Void)?
    /// Set when the user clicks a saved screenshot; shows it in a sheet.
    @State private var screenshotViewerRequest: ScreenshotViewerRequest?

    init(viewModel: TextChatViewModel, showsRecentChatsMenu: Bool, onOpenModelSettings: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.chatConversationStore = viewModel.chatConversationStore
        self.showsRecentChatsMenu = showsRecentChatsMenu
        self.onOpenModelSettings = onOpenModelSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().background(DS.Colors.borderSubtle)
            if let onOpenModelSettings {
                ModelSetupBanner(onOpenModelSettings: onOpenModelSettings)
            }
            if let visibleLanguageModelSwitchNotice = viewModel.visibleLanguageModelSwitchNotice {
                LanguageModelSwitchNoticeBanner(
                    switchNotice: visibleLanguageModelSwitchNotice,
                    onDismiss: viewModel.dismissLanguageModelSwitchNotice
                )
            }
            messageList
            Divider().background(DS.Colors.borderSubtle)
            composer
        }
        .background(DS.Colors.background)
        .sheet(item: $screenshotViewerRequest) { screenshotViewerRequest in
            ScreenshotViewerSheet(screenshotViewerRequest: screenshotViewerRequest)
        }
    }

    // MARK: Header

    private var chatHeader: some View {
        HStack(spacing: 8) {
            Text(viewModel.activeConversation.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if showsRecentChatsMenu {
                Menu {
                    if chatConversationStore.conversations.isEmpty {
                        Text("No saved chats yet")
                    }
                    ForEach(chatConversationStore.conversations.prefix(20)) { conversation in
                        Button(conversation.title) {
                            viewModel.openConversation(withIdentifier: conversation.id)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recent chats")
                .pointerCursor()

                Button(action: { viewModel.startNewConversation() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("New chat")
                .pointerCursor(isEnabled: !viewModel.isResponding)
                .disabled(viewModel.isResponding)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.messages.isEmpty {
                        Text(viewModel.emptyConversationHint)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.activeConversation.id) { _ in
                if let lastID = viewModel.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ message: StoredChatMessage) -> some View {
        let isFromUser = message.role == .user
        // The one saved screenshot lives on the question; the reply carries
        // only the marks it drew. Either bubble finds both.
        let screenshotExchange = viewModel.activeConversation.screenshotExchange(containingMessageWithIdentifier: message.id)
        let exchangeScreenshotFileURL = screenshotExchange.flatMap { screenshotExchange in
            chatConversationStore.screenshotFileURL(
                for: screenshotExchange.questionMessage,
                inConversationWithIdentifier: viewModel.activeConversation.id
            )
        }
        let exchangeScreenGuidance = screenshotExchange?.replyMessage?.screenGuidance
        let exchangeUserInk = screenshotExchange?.questionMessage.userInk
        // The question's "after" shows only what the user drew; the reply's
        // adds elfhub's pointer and marks on top.
        let screenGuidanceForThisRow = isFromUser ? nil : exchangeScreenGuidance
        let showsScreenshotRow = isFromUser || message.screenGuidance != nil
        return HStack {
            if isFromUser { Spacer(minLength: 40) }

            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 6) {
                if !isFromUser, message.kind == .taskReport || viewModel.speakerLabel(for: message) != nil {
                    HStack(spacing: 4) {
                        if message.kind == .taskReport {
                            // A background task's report, not a reply.
                            Image(systemName: "checklist")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text([viewModel.speakerLabel(for: message), message.kind == .taskReport ? "Task" : nil]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Push-to-talk questions are marked so a mixed conversation
                    // reads clearly.
                    if isFromUser && message.inputSource == .spoken {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                            .help("Asked with push-to-talk")
                    }
                    Text(message.text.isEmpty ? "…" : message.text)
                        .font(.system(size: 13))
                        .foregroundColor(isFromUser ? .white : DS.Colors.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFromUser ? DS.Colors.accent : Color.white.opacity(0.06))
                )

                if !isFromUser, let savedNotepad = message.notepad {
                    SavedNotepadCard(notepad: savedNotepad)
                }

                if !isFromUser {
                    ForEach(message.fileChanges, id: \.changeEntryIdentifier) { savedFileChange in
                        ChatFileChangeRow(viewModel: viewModel, savedFileChange: savedFileChange)
                    }
                }

                if showsScreenshotRow, let exchangeScreenshotFileURL {
                    CollapsibleScreenshotRow(
                        title: isFromUser ? "Screenshot" : "Screenshot with marks",
                        screenshotFileURL: exchangeScreenshotFileURL,
                        userInk: exchangeUserInk,
                        screenGuidance: screenGuidanceForThisRow,
                        onOpenViewer: { showsMarks in
                            screenshotViewerRequest = ScreenshotViewerRequest(
                                screenshotFileURL: exchangeScreenshotFileURL,
                                userInk: exchangeUserInk,
                                screenGuidance: screenGuidanceForThisRow,
                                initiallyShowsMarks: showsMarks
                            )
                        }
                    )
                }
            }

            if !isFromUser { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            ChatComposerElfPicker(viewModel: viewModel)

            TextField("Message elfhub…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .onSubmit { viewModel.sendDraft() }

            Button(action: { viewModel.sendDraft() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(viewModel.isResponding ? DS.Colors.textTertiary : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(viewModel.isResponding || viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }
}

// MARK: - Sidebar Chat List

/// Every saved chat, newest first, for the main window's sidebar — the main
/// window opens on chat, so this list is its navigation. "New chat" sits on
/// top; rows show a delete button on hover.
struct ChatConversationSidebarList: View {
    @ObservedObject var viewModel: TextChatViewModel
    @ObservedObject var chatConversationStore: ChatConversationStore
    /// Called after a chat is opened or started, so the window shows it.
    var onShowChat: () -> Void

    init(viewModel: TextChatViewModel, onShowChat: @escaping () -> Void) {
        self.viewModel = viewModel
        self.chatConversationStore = viewModel.chatConversationStore
        self.onShowChat = onShowChat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                viewModel.startNewConversation()
                onShowChat()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                    Text("New chat")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.accentSubtle)
                )
            }
            .buttonStyle(.plain)
            .help("Start a new chat")
            .pointerCursor(isEnabled: !viewModel.isResponding)
            .disabled(viewModel.isResponding)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if chatConversationStore.conversations.isEmpty {
                        Text(chatConversationStore.isSavingChatsEnabled
                             ? "Everything you ask — typed or spoken — is saved on this Mac and shows up here."
                             : "Saving chats is off (Settings › Privacy).")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                    ForEach(chatConversationStore.conversations) { conversation in
                        ConversationListRow(
                            conversation: conversation,
                            isSelected: conversation.id == viewModel.activeConversation.id,
                            isStreaming: viewModel.isResponding && conversation.id == viewModel.activeConversation.id,
                            onSelect: {
                                viewModel.openConversation(withIdentifier: conversation.id)
                                onShowChat()
                            },
                            onDelete: { viewModel.deleteConversation(withIdentifier: conversation.id) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Model Setup Banner

/// Shown above the chat while no language model is ready, since the main
/// window opens straight on chat and there's nothing else to say what's missing.
private struct ModelSetupBanner: View {
    let onOpenModelSettings: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenModelSettings) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Your language model needs setup")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("Settings › Models")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(DS.Colors.warning)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(DS.Colors.warning.opacity(isHovered ? 0.16 : 0.1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings › Models")
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

// MARK: - Language Model Switch Notice

/// Says the ChatGPT plan handed a turn to the fallback model (or answers
/// again), so typed chats see what the status pill said. Stays until closed.
/// After the usage limit, "Manage usage" (ChatGPT's usage settings) is its
/// main action, as OpenAI's guidelines ask; the click-through pill can't
/// hold a button, so this banner carries it.
private struct LanguageModelSwitchNoticeBanner: View {
    let switchNotice: LanguageModelSwitchNotice
    let onDismiss: () -> Void

    @State private var isCloseButtonHovered = false
    @State private var isManageUsageButtonHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text(switchNotice.message)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if switchNotice.offersManageUsage {
                Button {
                    NSWorkspace.shared.open(ChatGPTPlanOAuthConstants.manageUsageURL)
                } label: {
                    Text("Manage usage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(DS.Colors.textSecondary.opacity(isManageUsageButtonHovered ? 0.25 : 0.15))
                        )
                }
                .buttonStyle(.plain)
                .help("Open ChatGPT's usage settings in your browser")
                .onHover { isManageUsageButtonHovered = $0 }
                .pointerCursor()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DS.Colors.textSecondary.opacity(isCloseButtonHovered ? 0.15 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .onHover { isCloseButtonHovered = $0 }
            .pointerCursor()
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(DS.Colors.textSecondary.opacity(0.08))
    }
}

// MARK: - Conversation Row

/// One saved chat in the list: title and when it was last used. The delete
/// button appears on hover so the list stays calm.
private struct ConversationListRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    /// A reply is streaming into this chat right now.
    let isStreaming: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            if isStreaming {
                Circle()
                    .fill(DS.Colors.accentText)
                    .frame(width: 6, height: 6)
                    .help("Replying…")
            }
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete chat")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : (isHovered ? Color.white.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .contextMenu {
            Button("Delete chat", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - File changes under a reply

/// "saved files/trip.md · Undo" under a reply. When the file changed since,
/// the user is asked before the earlier version is put back.
private struct ChatFileChangeRow: View {
    @ObservedObject var viewModel: TextChatViewModel
    let savedFileChange: SavedElfFileChange

    @State private var isConfirmingForcedUndo = false
    @State private var undoErrorMessage: String?
    @State private var isUndoHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: savedFileChange.isUndone ? "arrow.uturn.backward" : "doc.text")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(savedFileChange.note)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .strikethrough(savedFileChange.isUndone)
                if savedFileChange.isUndone {
                    Text("undone")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    Button("Undo") { undo(force: false) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isUndoHovered ? DS.Colors.textPrimary : DS.Colors.accentText)
                        .onHover { isUndoHovered = $0 }
                        .pointerCursor()
                        .help("Put the file back the way it was")
                }
            }
            if let undoErrorMessage {
                Text(undoErrorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
        }
        .confirmationDialog("This file changed since then.", isPresented: $isConfirmingForcedUndo) {
            Button("Undo anyway", role: .destructive) { undo(force: true) }
        } message: {
            Text("Undoing puts back the earlier version. The newer one is kept in the elf's changes, so you can undo this too.")
        }
    }

    private func undo(force: Bool) {
        do {
            try viewModel.undoFileChange(savedFileChange, force: force)
            undoErrorMessage = nil
        } catch ElfChangeLogError.fileChangedSinceThisChange {
            isConfirmingForcedUndo = true
        } catch {
            undoErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Choosing the elf in chat

/// The elf picked in the chat's composer for the next message. It wins
/// over a name in the message, and goes back to "by name" after sending.
struct ChatComposerElfSelection: Equatable {
    var chosenElfIdentifier: String?

    mutating func takeElfIdentifierForSending() -> String? {
        defer { chosenElfIdentifier = nil }
        return chosenElfIdentifier
    }
}

/// The composer's elf picker: who the next message goes to. "By name" lets
/// a name in the message decide ("Juniper, …"), otherwise the main elf.
private struct ChatComposerElfPicker: View {
    @ObservedObject var viewModel: TextChatViewModel

    private var chosenElf: Elf? {
        viewModel.composerElfSelection.chosenElfIdentifier.flatMap { chosenElfIdentifier in
            viewModel.elvesForComposer.first { $0.id == chosenElfIdentifier }
        }
    }

    var body: some View {
        Menu {
            Button("By name (or the main elf)") { viewModel.composerElfSelection.chosenElfIdentifier = nil }
            Divider()
            ForEach(viewModel.elvesForComposer) { elf in
                let identity = elf.configuration.identity
                Button(identity.emoji.isEmpty ? identity.name : "\(identity.emoji) \(identity.name)") {
                    viewModel.composerElfSelection.chosenElfIdentifier = elf.id
                }
            }
        } label: {
            if let chosenElf {
                Text(chosenElf.configuration.identity.emoji.isEmpty ? chosenElf.configuration.identity.name : chosenElf.configuration.identity.emoji)
                    .font(.system(size: 12, weight: .medium))
            } else {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help(chosenElf.map { "Sending to \($0.configuration.identity.name)" } ?? "Who answers: by name, or the main elf")
    }
}
