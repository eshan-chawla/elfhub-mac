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
    /// An action on screen is waiting for a yes or no, which can be typed —
    /// even while a run is responding.
    @Published private(set) var isScreenActionWaitingForAnswer = false
    private var pendingScreenActionConsentCancellable: AnyCancellable?

    /// The composer can send while idle, or to answer a waiting action.
    var canSendDraft: Bool { !isResponding || isScreenActionWaitingForAnswer }
    @Published var draft: String = ""
    /// The elf picked for the next message, if any (else: by name, or main).
    @Published var composerElfSelection = ChatComposerElfSelection()
    /// Shown above the chat whose turn the ChatGPT plan handed to the
    /// fallback model (or took over again), until the user dismisses it.
    @Published private(set) var languageModelSwitchChatNotice: LanguageModelSwitchChatNotice?
    /// Set when a message typed in the main elf's chat went to a side elf:
    /// the main window opens that elf's page, where the reply is.
    @Published var elfThreadToShowForTypedMessage: String?
    /// The main elf's chat that was open before an elf's chat was shown, so
    /// going back to the chat (or talking to main) continues it.
    private var lastMainConversationIdentifier: UUID?
    /// A saved chat the user opened themselves from the list: typing in it
    /// continues it, however long it was quiet.
    private var conversationReopenedByUserIdentifier: UUID?

    /// Said at the top of a chat that started by itself because the last
    /// one had been quiet for a while, with a way back to it.
    struct QuietChatRestartNotice: Equatable {
        let conversationIdentifier: UUID
        let previousConversationIdentifier: UUID
        let quietDuration: TimeInterval

        var message: String {
            let quietText = Duration.seconds(quietDuration).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1))
            return "New chat — the last one had been quiet for \(quietText)."
        }
    }
    @Published private(set) var quietChatRestartNotice: QuietChatRestartNotice?

    var visibleQuietChatRestartNotice: QuietChatRestartNotice? {
        guard let quietChatRestartNotice, quietChatRestartNotice.conversationIdentifier == activeConversation.id else { return nil }
        return quietChatRestartNotice
    }

    func dismissQuietChatRestartNotice() {
        quietChatRestartNotice = nil
    }

    /// Back to the chat that went quiet, to carry on there.
    func returnToChatBeforeQuietRestart() {
        guard let quietChatRestartNotice else { return }
        self.quietChatRestartNotice = nil
        openConversation(withIdentifier: quietChatRestartNotice.previousConversationIdentifier)
    }

    /// Whether the chat on screen is a side elf's own ongoing chat.
    var isShowingElfThread: Bool {
        activeConversation.elfIdentifier != nil
    }

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
        pendingScreenActionConsentCancellable = companionManager.screenActionCoordinator.$pendingConsent
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] isWaiting in self?.isScreenActionWaitingForAnswer = isWaiting }
    }

    var messages: [StoredChatMessage] {
        activeConversation.messages
    }

    /// What an empty chat says — the main window opens on chat, so this is
    /// also where people learn how to talk to elfhub.
    var emptyConversationHint: String {
        if let elfIdentifier = activeConversation.elfIdentifier {
            let elfName = elfName(forIdentifier: elfIdentifier)
            return "This is your chat with \(elfName). Type below, or say “\(elfName), …” anywhere — whatever you ask \(elfName) lands here, and so do the tasks you give it."
        }
        if companionManager.interactionInputMode.isVoiceInputEnabled {
            return "Hold \(companionManager.pushToTalkShortcutOption.displayText) anywhere to talk, or type below — elfhub can see your screen when you ask."
        }
        return "Type below to ask anything — elfhub can see your screen when you ask."
    }

    /// The serif heading on an empty chat, in the Elf's name.
    var emptyConversationHeading: String {
        let elfIdentifier = activeConversation.elfIdentifier ?? ElfManager.mainElfIdentifier
        return "What can \(elfName(forIdentifier: elfIdentifier)) help with?"
    }

    /// The chat's title: "Chat with Tom" for an elf's own chat.
    var chatTitle: String {
        guard let elfIdentifier = activeConversation.elfIdentifier else { return activeConversation.title }
        return "Chat with \(elfName(forIdentifier: elfIdentifier))"
    }

    var composerPlaceholder: String {
        // The Elf answers, not the app: the empty chat already asks in its name.
        guard let elfIdentifier = activeConversation.elfIdentifier else { return "Message \(elfName(forIdentifier: ElfManager.mainElfIdentifier))…" }
        return "Message \(elfName(forIdentifier: elfIdentifier))…"
    }

    /// The main elf's chats (and those of elfs since deleted) — the
    /// sidebar's list and the compact window's menu.
    var mainConversations: [ChatConversation] {
        chatConversationStore.mainConversations(existingElfIdentifiers: Set(companionManager.elfManager.elfs.map(\.id)))
    }

    // MARK: Conversations

    /// Starts a fresh conversation; the model forgets the previous one.
    func startNewConversation() {
        guard !isResponding else { return }
        activeConversation = ChatConversation()
        lastMainConversationIdentifier = nil
        conversationReopenedByUserIdentifier = nil
        companionManager.companionTurnPipeline.clearConversationHistory()
    }

    /// Shows a side elf's one ongoing chat (empty until the first message).
    /// The main elf's history stays as it is: its chat is still where
    /// talking to main goes.
    func openElfThread(forElfIdentifier elfIdentifier: String) {
        guard activeConversation.elfIdentifier != elfIdentifier else { return }
        if activeConversation.elfIdentifier == nil, !activeConversation.messages.isEmpty {
            lastMainConversationIdentifier = activeConversation.id
        }
        activeConversation = chatConversationStore.elfThread(forElfIdentifier: elfIdentifier)
            ?? ChatConversation.elfThread(elfIdentifier: elfIdentifier, title: elfName(forIdentifier: elfIdentifier))
        composerElfSelection = ChatComposerElfSelection()
    }

    /// An elf was deleted (or its folder removed): its chat becomes an
    /// ordinary chat of the main elf's, also when it's on screen.
    func detachChatsOfElfsThatAreGone(existingElfIdentifiers: Set<String>) {
        chatConversationStore.detachElfThreads(ofElfsNotIn: existingElfIdentifiers)
        if let activeElfIdentifier = activeConversation.elfIdentifier,
           existingElfIdentifiers.contains(ElfManager.mainElfIdentifier),
           !existingElfIdentifiers.contains(activeElfIdentifier) {
            activeConversation.elfIdentifier = nil
        }
    }

    /// Back to the main elf's chat after an elf's page: the one that was
    /// open, else a new one.
    func showMainChat() {
        guard isShowingElfThread else { return }
        // The main elf's history wasn't touched while the elf's chat was
        // on screen, so it still matches this chat.
        activeConversation = lastMainConversationIdentifier.flatMap { chatConversationStore.conversation(withIdentifier: $0) }
            ?? ChatConversation()
    }

    /// Clicking the main Elf: the chat you had with it most recently. The
    /// chat already open stays if it's one of main's with messages; else the
    /// newest saved one; else a new chat.
    func showMostRecentMainChat() {
        guard !isResponding else { return }
        if activeConversation.elfIdentifier == nil, !activeConversation.messages.isEmpty { return }
        if let mostRecentMainConversation = mainConversations.max(by: { $0.updatedAt < $1.updatedAt }) {
            // Not picked from the list: after a quiet spell, the next
            // question still starts a new chat.
            openConversation(withIdentifier: mostRecentMainConversation.id, isChosenByUser: false)
        } else {
            showMainChat()
        }
    }

    private func elfName(forIdentifier elfIdentifier: String) -> String {
        companionManager.elfManager.elf(withIdentifier: elfIdentifier)?.configuration.identity.name ?? elfIdentifier
    }

    /// Reopens a saved conversation and gives the model its recent exchanges.
    /// `isChosenByUser`: picked from the chat list, so typing there
    /// continues it even after a long quiet spell.
    func openConversation(withIdentifier conversationIdentifier: UUID, isChosenByUser: Bool = true) {
        guard !isResponding,
              let savedConversation = chatConversationStore.conversation(withIdentifier: conversationIdentifier) else { return }
        // An elf's chat opens on its page instead.
        if let elfIdentifier = savedConversation.elfIdentifier, companionManager.elfManager.elf(withIdentifier: elfIdentifier) != nil {
            openElfThread(forElfIdentifier: elfIdentifier)
            return
        }
        activeConversation = savedConversation
        lastMainConversationIdentifier = savedConversation.id
        conversationReopenedByUserIdentifier = isChosenByUser ? savedConversation.id : nil
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
        guard !trimmed.isEmpty else { return }
        // "yes", "no" or "yes, send it" answers an action that's waiting.
        if isScreenActionWaitingForAnswer, companionManager.answerPendingScreenActionConfirmation(typedText: trimmed) {
            draft = ""
            return
        }
        guard !isResponding else { return }
        draft = ""

        // Who answers is decided now, so the reply is theirs from the start.
        // In an elf's own chat, that elf answers.
        let pickedElfIdentifier = composerElfSelection.takeElfIdentifierForSending()
        let speakingElf = companionManager.addressedElf(
            for: trimmed,
            chosenElfIdentifier: activeConversation.elfIdentifier ?? pickedElfIdentifier
        )
        let chosenElfIdentifier = speakingElf?.id ?? ElfManager.mainElfIdentifier
        var recordedExchange = beginExchange(userText: trimmed, inputSource: .typed, speakingElfIdentifier: speakingElf?.id)
        isResponding = true
        // Typed in main's chat to a side elf: show its chat, where the
        // question and the reply now are.
        if recordedExchange.conversationIdentifier != activeConversation.id, let sideElfIdentifier = recordedExchange.speakingElfIdentifier {
            elfThreadToShowForTypedMessage = sideElfIdentifier
            openElfThread(forElfIdentifier: sideElfIdentifier)
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            var rawReplyText = ""
            do {
                let turnResult = try await self.companionManager.respondToChatMessage(
                    trimmed,
                    chosenElfIdentifier: chosenElfIdentifier,
                    conversationIdentifier: recordedExchange.conversationIdentifier,
                    onTextChunk: { chunk in
                        rawReplyText += chunk
                        self.showStreamingReply(rawReplyText: rawReplyText, for: recordedExchange)
                    },
                    onElfFileChanged: { fileChange, elfIdentifier in
                        self.recordFileChange(fileChange, elfIdentifier: elfIdentifier, for: recordedExchange)
                    },
                    onScreenStepPerformed: { stepDescription in
                        self.recordScreenStep(stepDescription, for: recordedExchange)
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
                // Esc can land as a run ends on its own: the turn returns
                // instead of throwing, and is marked where it stopped.
                self.completeExchange(recordedExchange, with: turnResult, wasStoppedByUser: Task.isCancelled)
            } catch where ReplyStopDetection.isStoppedByUser(error, taskIsCancelled: Task.isCancelled) {
                // Esc: keep what arrived and mark where it stopped — not an
                // error (see ReplyStopDetection).
                self.saveInterruptedExchange(recordedExchange, rawReplyTextSoFar: rawReplyText)
            } catch {
                self.failExchange(recordedExchange, with: error)
                self.companionManager.errorReportPresenter.offerReport(for: error, origin: .typedChat)
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

    /// Adds the question and an empty reply bubble and saves it — in the
    /// side elf's own chat when one answers, else in the main elf's chat
    /// (see ChatThreadRouting). A question to main after a long quiet
    /// spell starts a new chat instead, spoken or typed — unless it's typed
    /// in a chat the user reopened themselves
    /// (see `ChatConversation.startsNewConversation(forQuestionAt:…)`).
    func beginExchange(
        userText: String,
        inputSource: StoredChatMessage.InputSource,
        speakingElfIdentifier: String? = nil,
        questionDate: Date = Date()
    ) -> RecordedExchange {
        switch ChatThreadRouting.destination(speakingElfIdentifier: speakingElfIdentifier, activeConversation: activeConversation) {
        case .activeConversation:
            if !isResponding, activeConversation.startsNewConversation(
                forQuestionAt: questionDate,
                inputSource: inputSource,
                wasReopenedByUser: conversationReopenedByUserIdentifier == activeConversation.id
            ) {
                let quietConversation = activeConversation
                startNewConversation()
                quietChatRestartNotice = QuietChatRestartNotice(
                    conversationIdentifier: activeConversation.id,
                    previousConversationIdentifier: quietConversation.id,
                    quietDuration: quietConversation.quietDuration(at: questionDate) ?? 0
                )
            }
            return appendExchange(userText: userText, inputSource: inputSource, speakingElfIdentifier: speakingElfIdentifier, to: &activeConversation)
        case let .elfThread(elfIdentifier):
            var elfThread = chatConversationStore.elfThread(forElfIdentifier: elfIdentifier)
                ?? ChatConversation.elfThread(elfIdentifier: elfIdentifier, title: elfName(forIdentifier: elfIdentifier))
            return appendExchange(userText: userText, inputSource: inputSource, speakingElfIdentifier: speakingElfIdentifier, to: &elfThread)
        case .mainChat:
            var mainChat = lastMainConversationIdentifier.flatMap { chatConversationStore.conversation(withIdentifier: $0) }
                ?? ChatConversation()
            // Talking to main from an elf's page: main's last chat, or a new
            // one after a quiet spell (it wasn't reopened on purpose).
            if mainChat.startsNewConversation(forQuestionAt: questionDate, inputSource: inputSource, wasReopenedByUser: false) {
                mainChat = ChatConversation()
                companionManager.companionTurnPipeline.clearConversationHistory()
            }
            let recordedExchange = appendExchange(userText: userText, inputSource: inputSource, speakingElfIdentifier: nil, to: &mainChat)
            lastMainConversationIdentifier = mainChat.id
            return recordedExchange
        }
    }

    private func appendExchange(
        userText: String,
        inputSource: StoredChatMessage.InputSource,
        speakingElfIdentifier: String?,
        to conversation: inout ChatConversation
    ) -> RecordedExchange {
        let exchangeIdentifiers = conversation.appendExchange(
            userText: userText,
            inputSource: inputSource,
            speakingElfIdentifier: speakingElfIdentifier
        )
        chatConversationStore.save(conversation)
        return RecordedExchange(
            conversationIdentifier: conversation.id,
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
    func completeExchange(_ recordedExchange: RecordedExchange, with turnResult: CompanionTurnPipeline.TurnResult, wasStoppedByUser: Bool = false) {
        let screenshotFileName = turnResult.originalScreenshotJPEGData.flatMap { originalScreenshotJPEGData in
            chatConversationStore.saveScreenshot(
                originalScreenshotJPEGData,
                forMessageWithIdentifier: recordedExchange.userMessageIdentifier,
                inConversationWithIdentifier: recordedExchange.conversationIdentifier
            )
        }
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.setText(
                // A stopped reply with no text says so in its bubble instead.
                turnResult.spokenText.isEmpty ? (wasStoppedByUser ? "" : "…") : turnResult.spokenText,
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
            if wasStoppedByUser {
                conversation.markStoppedByUser(assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier)
            }
        }
        generateTitleIfNeeded(forConversationWithIdentifier: recordedExchange.conversationIdentifier)
    }

    // MARK: Titles

    /// The user's own title for a saved chat, from the chat list. A
    /// generated title never replaces it.
    func renameConversation(withIdentifier conversationIdentifier: UUID, to newTitle: String) {
        applyTitle(newTitle, source: .userRenamed, toConversationWithIdentifier: conversationIdentifier)
    }

    /// After a main chat's first reply, one small request to the user's
    /// model for a short title (see ChatTitleGenerator). Never in the
    /// unit-test host, never blocks the turn; a failure keeps the
    /// first-message title.
    private func generateTitleIfNeeded(forConversationWithIdentifier conversationIdentifier: UUID) {
        guard !CompanionManager.isRunningUnitTests else { return }
        let conversation = activeConversation.id == conversationIdentifier
            ? activeConversation
            : chatConversationStore.conversation(withIdentifier: conversationIdentifier)
        guard let conversation,
              ChatTitleGenerator.shouldGenerateTitle(for: conversation, isEnabled: ChatTitleSettings.isEnabled()),
              let firstUserText = conversation.messages.first?.text,
              let firstReplyText = conversation.messages.last?.text else { return }
        let providerConfigurationStore = companionManager.providerConfigurationStore
        guard let titleConfiguration = providerConfigurationStore.configurationForNextTurn(),
              let titleLanguageModelProvider = try? providerConfigurationStore.makeProvider(for: titleConfiguration) else { return }
        Task { [weak self] in
            guard let generatedTitle = await ChatTitleGenerator.generateTitle(
                firstUserText: firstUserText,
                firstReplyText: firstReplyText,
                languageModelProvider: titleLanguageModelProvider
            ) else { return }
            self?.applyGeneratedTitle(generatedTitle, toConversationWithIdentifier: conversationIdentifier)
        }
    }

    /// Only while the chat still carries its first-message title: the user
    /// may have renamed it while the request was out.
    private func applyGeneratedTitle(_ generatedTitle: String, toConversationWithIdentifier conversationIdentifier: UUID) {
        let currentTitleSource = activeConversation.id == conversationIdentifier
            ? activeConversation.titleSource
            : chatConversationStore.conversation(withIdentifier: conversationIdentifier)?.titleSource
        guard (currentTitleSource ?? .firstMessage) == .firstMessage else { return }
        applyTitle(generatedTitle, source: .generated, toConversationWithIdentifier: conversationIdentifier)
    }

    /// Sets the title on the saved chat and, when it's on screen, on the
    /// copy shown here — the next save of the open chat writes this copy,
    /// so both must agree.
    private func applyTitle(_ newTitle: String, source: ChatTitleSource, toConversationWithIdentifier conversationIdentifier: UUID) {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        chatConversationStore.renameConversation(withIdentifier: conversationIdentifier, to: trimmedTitle, source: source)
        if activeConversation.id == conversationIdentifier {
            activeConversation.title = trimmedTitle
            activeConversation.titleSource = source
        }
    }

    /// "Juniper" above a reply a side Elf gave; nil for the main Elf's.
    func speakerLabel(for message: StoredChatMessage) -> String? {
        guard let speakingElfIdentifier = message.speakingElfIdentifier else { return nil }
        guard let speakingElf = companionManager.elfManager.elf(withIdentifier: speakingElfIdentifier) else {
            return speakingElfIdentifier
        }
        return speakingElf.configuration.identity.name
    }

    /// The avatar beside a reply: the Elf that gave it (the main Elf when
    /// none is recorded), with its picture or color, or just its name and a
    /// fill when that Elf is gone.
    func speakerAvatar(for message: StoredChatMessage, size: CGFloat) -> ElfAvatar {
        let speakingElfIdentifier = message.speakingElfIdentifier ?? ElfManager.mainElfIdentifier
        guard let speakingElf = companionManager.elfManager.elf(withIdentifier: speakingElfIdentifier) else {
            return ElfAvatar(
                name: speakingElfIdentifier,
                fillIndex: ElfAvatarAppearance.fillIndex(forElfIdentifier: speakingElfIdentifier, avatarColorIndex: nil),
                size: size
            )
        }
        return ElfAvatar(elf: speakingElf, size: size)
    }

    /// Every elf, main first, for the composer's picker.
    var elfsForComposer: [Elf] {
        companionManager.elfManager.elfs
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
    /// A reply the user stopped (Esc, or speaking again): what streamed so
    /// far stays in its bubble, the screen steps already taken stay listed
    /// under it, and it's marked as stopped there — never shown as an error.
    /// A reply cut short because the ChatGPT plan handed the turn to the
    /// fallback model is kept the same way, without the stop mark.
    func saveInterruptedExchange(_ recordedExchange: RecordedExchange, rawReplyTextSoFar: String, wasStoppedByUser: Bool = true) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.setText(
                SpokenSentenceSegmenter.speakableText(fromPartialResponse: rawReplyTextSoFar)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                ofMessageWithIdentifier: recordedExchange.assistantMessageIdentifier
            )
            conversation.recordNotepad(
                NotepadTagParser.notepad(fromResponseText: rawReplyTextSoFar),
                assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier
            )
            if wasStoppedByUser {
                conversation.markStoppedByUser(assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier)
            }
        }
    }

    /// A step a screen run just took, listed under the reply as it happens.
    func recordScreenStep(_ stepDescription: String, for recordedExchange: RecordedExchange) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.recordScreenStep(stepDescription, assistantMessageIdentifier: recordedExchange.assistantMessageIdentifier)
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
        saveInterruptedExchange(recordedExchange, rawReplyTextSoFar: rawReplyTextSoFar, wasStoppedByUser: false)
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

    /// "Try again" under a failed reply: asks the same question again, as a
    /// new message, in the chat that's open.
    func retryQuestion(beforeFailedReplyWithIdentifier failedReplyIdentifier: UUID) {
        guard !isResponding,
              let failedReplyIndex = activeConversation.messages.firstIndex(where: { $0.id == failedReplyIdentifier }),
              let questionMessage = activeConversation.messages[..<failedReplyIndex].last(where: { $0.role == .user }) else { return }
        draft = questionMessage.text
        sendDraft()
    }

    /// Where a failed reply's "Model settings" button leads.
    func openModelSettings() {
        companionManager.openProviderSettings()
    }

    func failExchange(_ recordedExchange: RecordedExchange, with error: Error) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.setText(error.localizedDescription, ofMessageWithIdentifier: recordedExchange.assistantMessageIdentifier)
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
    /// In the main window the header is the title bar band: as tall as it,
    /// draggable, without the line under it.
    var headerIsInTitleBar = false
    /// Set when the user clicks a saved screenshot; shows it in a sheet.
    @State private var screenshotViewerRequest: ScreenshotViewerRequest?
    /// Whether the end of the chat is on screen (see the bottom anchor).
    @State private var isChatBottomVisible = true

    init(
        viewModel: TextChatViewModel,
        showsRecentChatsMenu: Bool,
        onOpenModelSettings: (() -> Void)? = nil,
        headerIsInTitleBar: Bool = false
    ) {
        self.viewModel = viewModel
        self.chatConversationStore = viewModel.chatConversationStore
        self.showsRecentChatsMenu = showsRecentChatsMenu
        self.onOpenModelSettings = onOpenModelSettings
        self.headerIsInTitleBar = headerIsInTitleBar
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            if !headerIsInTitleBar {
                Divider().background(DS.Colors.borderSubtle)
            }
            if let onOpenModelSettings {
                ModelSetupBanner(onOpenModelSettings: onOpenModelSettings)
            }
            if let visibleQuietChatRestartNotice = viewModel.visibleQuietChatRestartNotice {
                QuietChatRestartNoticeBanner(
                    notice: visibleQuietChatRestartNotice,
                    onReturnToPreviousChat: viewModel.returnToChatBeforeQuietRestart,
                    onDismiss: viewModel.dismissQuietChatRestartNotice
                )
            }
            if let visibleLanguageModelSwitchNotice = viewModel.visibleLanguageModelSwitchNotice {
                LanguageModelSwitchNoticeBanner(
                    switchNotice: visibleLanguageModelSwitchNotice,
                    onDismiss: viewModel.dismissLanguageModelSwitchNotice
                )
            }
            // No rule above the composer: it's its own rounded box.
            messageList
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
            Text(viewModel.chatTitle)
                .font(DS.Typography.interface(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if showsRecentChatsMenu {
                Menu {
                    if viewModel.mainConversations.isEmpty {
                        Text("No saved chats yet")
                    }
                    ForEach(viewModel.mainConversations.prefix(20)) { conversation in
                        Button(conversation.title) {
                            viewModel.openConversation(withIdentifier: conversation.id)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(DS.Typography.interface(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recent chats")
                .pointerCursor()

                Button(action: { viewModel.startNewConversation() }) {
                    Image(systemName: "square.and.pencil")
                        .font(DS.Typography.interface(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("New chat")
                .pointerCursor(isEnabled: !viewModel.isResponding)
                .disabled(viewModel.isResponding)
            }
        }
        .padding(.horizontal, headerIsInTitleBar ? 20 : 16)
        .padding(.vertical, headerIsInTitleBar ? 0 : 10)
        .frame(height: headerIsInTitleBar ? MainWindowChrome.titleBarHeight : nil)
        .background {
            if headerIsInTitleBar {
                WindowDragArea()
            }
        }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.messages.isEmpty {
                        // An empty chat: a serif question, then how to talk.
                        VStack(spacing: 12) {
                            Text(viewModel.emptyConversationHeading)
                                .font(DS.Typography.fraunces(size: 32))
                                .tracking(DS.Typography.frauncesTracking(size: 32))
                                .foregroundColor(DS.Colors.textPrimary)
                                .multilineTextAlignment(.center)
                            Text(viewModel.emptyConversationHint)
                                .font(DS.Typography.interface(size: 13))
                                .foregroundColor(DS.Colors.textTertiary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 420)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 72)
                    }
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    // Seen only when the user is at the bottom of the chat:
                    // then a streaming reply is followed as it grows.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.chatBottomAnchorIdentifier)
                        .onAppear { isChatBottomVisible = true }
                        .onDisappear { isChatBottomVisible = false }
                }
                // One reading column, centered, however wide the window.
                .frame(maxWidth: Self.readingColumnWidth)
                .frame(maxWidth: .infinity)
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
            // A long reply grows below the fold; keep it in view while the
            // user hasn't scrolled up to read something else.
            .onChange(of: viewModel.messages.last?.text.count ?? 0) { _ in
                // Spoken turns stream into the chat too, so any growth counts.
                guard isChatBottomVisible else { return }
                proxy.scrollTo(Self.chatBottomAnchorIdentifier, anchor: .bottom)
            }
        }
    }

    private static let chatBottomAnchorIdentifier = "chat-bottom"

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
        return HStack(alignment: .top, spacing: 10) {
            // An Elf is a rounded square, a person a circle (brand chapter 07).
            if isFromUser {
                Spacer(minLength: 40)
            } else {
                viewModel.speakerAvatar(for: message, size: 28)
            }

            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 6) {
                if !isFromUser, message.kind == .taskReport || viewModel.speakerLabel(for: message) != nil {
                    HStack(spacing: 4) {
                        if message.kind == .taskReport {
                            // A background task's report, not a reply.
                            Image(systemName: "checklist")
                                .font(DS.Typography.interface(size: 10, weight: .medium))
                        }
                        Text([viewModel.speakerLabel(for: message), message.kind == .taskReport ? "Task" : nil]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                    }
                    .font(DS.Typography.interface(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Push-to-talk questions are marked so a mixed conversation
                    // reads clearly.
                    if isFromUser && message.inputSource == .spoken {
                        Image(systemName: "mic.fill")
                            .font(DS.Typography.interface(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .help("Asked with push-to-talk")
                    }
                    if !isFromUser && message.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(DS.Typography.interface(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.destructive)
                            .accessibilityLabel("Error")
                    }
                    Text(Self.bubbleText(for: message))
                        .font(DS.Typography.body)
                        .foregroundColor(Self.bubbleTextColor(for: message))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                // Your messages sit in a quiet grey bubble; the Elf's reply
                // is plain text on the page.
                .padding(.horizontal, isFromUser ? 14 : 2)
                .padding(.vertical, isFromUser ? 10 : 4)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                        .fill(isFromUser ? DS.Colors.surface2 : Color.clear)
                )

                if !isFromUser && message.isError {
                    // A failed reply isn't a dead end: ask again, or fix the
                    // model (most failures are a key, a model name or a limit).
                    HStack(spacing: 8) {
                        Button("Try again") {
                            viewModel.retryQuestion(beforeFailedReplyWithIdentifier: message.id)
                        }
                        .buttonStyle(DSButtonStyle(kind: .secondary, size: .small))
                        .disabled(viewModel.isResponding)
                        .pointerCursor(isEnabled: !viewModel.isResponding)
                        Button("Model settings") {
                            viewModel.openModelSettings()
                        }
                        .buttonStyle(DSButtonStyle(kind: .ghost, size: .small))
                        .pointerCursor()
                    }
                }

                if !isFromUser, let savedNotepad = message.notepad {
                    SavedNotepadCard(notepad: savedNotepad)
                }

                if !isFromUser {
                    ForEach(message.fileChanges, id: \.changeEntryIdentifier) { savedFileChange in
                        ChatFileChangeRow(viewModel: viewModel, savedFileChange: savedFileChange)
                    }
                }

                if !isFromUser, !message.screenSteps.isEmpty || message.wasStoppedByUser {
                    ReplyScreenStepsAndStopView(
                        screenSteps: message.screenSteps,
                        wasStoppedByUser: message.wasStoppedByUser
                    )
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

            if isFromUser {
                PersonAvatar(size: 28)
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    /// What a bubble says: the text, "…" while a reply hasn't started, or
    /// that it was stopped before it said anything.
    static func bubbleText(for message: StoredChatMessage) -> String {
        // Older builds saved errors starting with a warning emoji.
        if message.isError, message.text.hasPrefix("⚠️ ") {
            return String(message.text.dropFirst("⚠️ ".count))
        }
        guard message.text.isEmpty else { return message.text }
        if message.wasStoppedByUser {
            return message.screenSteps.isEmpty ? "Stopped before replying." : "Stopped before saying anything."
        }
        return "…"
    }

    static func bubbleTextColor(for message: StoredChatMessage) -> Color {
        if message.role == .assistant && message.isError { return DS.Colors.destructive }
        if message.text.isEmpty && message.wasStoppedByUser { return DS.Colors.textTertiary }
        return DS.Colors.textPrimary
    }

    /// The chat's reading column: messages and the composer share it.
    static let readingColumnWidth: CGFloat = 760

    /// One rounded box: the message on top, the Elf picker and send below.
    private var composer: some View {
        let canSend = viewModel.canSendDraft && !viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
        // A typed answer to an action that's waiting still goes through Send.
        let showsStopButton = viewModel.isResponding && !canSend
        return VStack(alignment: .leading, spacing: 10) {
            TextField(viewModel.composerPlaceholder, text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Typography.interface(size: 14))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...8)
                .onSubmit { viewModel.sendDraft() }

            HStack(spacing: 8) {
                // In an elf's own chat, that elf answers: no picker.
                if !viewModel.isShowingElfThread {
                    ChatComposerElfPicker(viewModel: viewModel)
                }
                Spacer()
                if showsStopButton {
                    // While a reply streams, the send button stops it (the
                    // same as Esc): what arrived is kept as interrupted.
                    Button(action: { viewModel.stopCurrentReply() }) {
                        Image(systemName: "stop.fill")
                            .font(DS.Typography.interface(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Stop the reply (esc)")
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: { viewModel.sendDraft() }) {
                        Image(systemName: "arrow.up")
                            .font(DS.Typography.interface(size: 13, weight: .semibold))
                            .foregroundColor(canSend ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                                    .fill(canSend ? DS.Colors.accent : DS.Colors.surface3)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor(isEnabled: canSend)
                    .disabled(!canSend)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous)
                .strokeBorder(DS.Colors.borderStrong, lineWidth: 1)
        )
        .dsShadow(.small)
        .frame(maxWidth: Self.readingColumnWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 4)
    }
}

// MARK: - Sidebar Chat List

/// The main Elf's chats in the main window's sidebar. Two sizes:
/// - Recents (the default, every launch): the newest few chats, one line
///   each, and "All chats" when there are more — so the sidebar stays calm.
/// - All chats: every chat with a search field, grouped Today / Yesterday /
///   Previous 7 days / Earlier, and "Show less" to go back.
/// Right-click a chat to rename or delete it (delete asks first).
struct ChatConversationSidebarList: View {
    @ObservedObject var viewModel: TextChatViewModel
    @ObservedObject var chatConversationStore: ChatConversationStore
    /// Called after a chat is opened or started, so the window shows it.
    var onShowChat: () -> Void
    /// Whether the chat is the page showing; the open chat is only marked
    /// selected then, so an Elf's page or Settings has one selection.
    var isChatShowing: Bool
    /// False: only the newest `recentChatCount` chats. True: every chat,
    /// searchable and grouped by day.
    var isShowingAllChats: Bool
    /// The search field takes the keyboard when the full list opens from
    /// the sidebar's "Search chats" row.
    var focusesSearchField: Bool
    var onShowAllChats: () -> Void
    var onShowFewerChats: () -> Void

    /// Filters the full list by title and message text.
    @State private var searchQuery = ""
    /// The chat whose title is being edited in place.
    @State private var conversationBeingRenamedIdentifier: UUID?
    /// The chat waiting for "Delete chat?" to be answered.
    @State private var conversationPendingDeletion: ChatConversation?

    /// How many chats Recents shows.
    static let recentChatCount = 5

    init(
        viewModel: TextChatViewModel,
        isChatShowing: Bool = true,
        isShowingAllChats: Bool,
        focusesSearchField: Bool = false,
        onShowAllChats: @escaping () -> Void,
        onShowFewerChats: @escaping () -> Void,
        onShowChat: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.chatConversationStore = viewModel.chatConversationStore
        self.isChatShowing = isChatShowing
        self.isShowingAllChats = isShowingAllChats
        self.focusesSearchField = focusesSearchField
        self.onShowAllChats = onShowAllChats
        self.onShowFewerChats = onShowFewerChats
        self.onShowChat = onShowChat
    }

    /// The chats Recents lists: the newest few.
    static func recentConversations(_ mainConversations: [ChatConversation]) -> [ChatConversation] {
        Array(mainConversations.prefix(recentChatCount))
    }

    var body: some View {
        let mainConversations = viewModel.mainConversations
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isShowingAllChats ? "All chats" : "Recents")
                    .dsLabelStyle()
                    .foregroundColor(DS.Colors.sidebarTextMuted)
                Spacer()
                if isShowingAllChats {
                    SidebarTextButton(title: "Show less", action: {
                        searchQuery = ""
                        onShowFewerChats()
                    })
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            if isShowingAllChats {
                ChatListSearchField(searchQuery: $searchQuery, focusesOnAppear: focusesSearchField)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if mainConversations.isEmpty {
                        Text(chatConversationStore.isSavingChatsEnabled
                             ? "Your chats — typed or spoken — show up here."
                             : "Saving chats is off (Settings › Privacy & permissions).")
                            .font(DS.Typography.interface(size: 11))
                            .foregroundColor(DS.Colors.sidebarTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                    }
                    if isShowingAllChats {
                        let matchingConversations = ChatListSearch.conversations(mainConversations, matching: searchQuery)
                        if !mainConversations.isEmpty && matchingConversations.isEmpty {
                            Text("No chats match “\(searchQuery.trimmingCharacters(in: .whitespaces))”.")
                                .font(DS.Typography.interface(size: 11))
                                .foregroundColor(DS.Colors.sidebarTextMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, 2)
                        }
                        ForEach(ChatListDateGroup.groupedConversations(matchingConversations), id: \.group) { dateGroupWithConversations in
                            Text(dateGroupWithConversations.group.rawValue)
                                .font(DS.Typography.interface(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.sidebarTextMuted.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(dateGroupWithConversations.conversations) { conversation in
                                conversationRow(conversation)
                            }
                        }
                    } else {
                        ForEach(Self.recentConversations(mainConversations)) { conversation in
                            conversationRow(conversation)
                        }
                        if mainConversations.count > Self.recentChatCount {
                            SidebarTextButton(title: "All chats (\(mainConversations.count))", action: onShowAllChats)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { conversationPendingDeletion != nil },
                set: { isPresented in if !isPresented { conversationPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: conversationPendingDeletion
        ) { conversationToDelete in
            Button("Delete chat", role: .destructive) {
                viewModel.deleteConversation(withIdentifier: conversationToDelete.id)
                conversationPendingDeletion = nil
            }
        } message: { conversationToDelete in
            Text("“\(conversationToDelete.title)” and its saved screenshots are removed from this Mac. It can't be undone.")
        }
    }

    private func conversationRow(_ conversation: ChatConversation) -> some View {
        ConversationListRow(
            conversation: conversation,
            isSelected: isChatShowing && conversation.id == viewModel.activeConversation.id,
            isStreaming: viewModel.isResponding && conversation.id == viewModel.activeConversation.id,
            isRenaming: conversationBeingRenamedIdentifier == conversation.id,
            onSelect: {
                viewModel.openConversation(withIdentifier: conversation.id)
                onShowChat()
            },
            onStartRenaming: { conversationBeingRenamedIdentifier = conversation.id },
            onFinishRenaming: { newTitle in
                if let newTitle {
                    viewModel.renameConversation(withIdentifier: conversation.id, to: newTitle)
                }
                conversationBeingRenamedIdentifier = nil
            },
            onDelete: { conversationPendingDeletion = conversation }
        )
    }
}

/// A small text-only button in the sidebar ("All chats", "Show less"):
/// muted, ink on hover.
private struct SidebarTextButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(isHovered ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// The search field above the full chat list. Esc clears it.
private struct ChatListSearchField: View {
    @Binding var searchQuery: String
    var focusesOnAppear: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Typography.interface(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.sidebarTextMuted)
            TextField("Search chats", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.sidebarText)
                .focused($isFocused)
                .onExitCommand { searchQuery = "" }
                .onAppear { if focusesOnAppear { isFocused = true } }
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.sidebarTextMuted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.sidebarHover)
        )
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
                    .font(DS.Typography.interface(size: 11, weight: .semibold))
                Text("Your language model needs setup")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                Spacer()
                Text("Settings › Models")
                    .font(DS.Typography.interface(size: 11, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
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
                .font(DS.Typography.interface(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text(switchNotice.message)
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if switchNotice.offersManageUsage {
                Button {
                    NSWorkspace.shared.open(ChatGPTPlanOAuthConstants.manageUsageURL)
                } label: {
                    Text("Manage usage")
                        .font(DS.Typography.interface(size: 11, weight: .semibold))
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
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
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

/// "New chat — the last one had been quiet for 2 hours", with a way back.
private struct QuietChatRestartNoticeBanner: View {
    let notice: TextChatViewModel.QuietChatRestartNotice
    let onReturnToPreviousChat: () -> Void
    let onDismiss: () -> Void

    @State private var isReturnButtonHovered = false
    @State private var isCloseButtonHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble")
                .font(DS.Typography.interface(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text(notice.message)
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onReturnToPreviousChat) {
                Text("Back to that chat")
                    .font(DS.Typography.interface(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(DS.Colors.textSecondary.opacity(isReturnButtonHovered ? 0.25 : 0.15))
                    )
            }
            .buttonStyle(.plain)
            .help("Open the chat that went quiet, to carry on there")
            .onHover { isReturnButtonHovered = $0 }
            .pointerCursor()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
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
    /// The title is an editable field (Rename… from the context menu).
    let isRenaming: Bool
    let onSelect: () -> Void
    let onStartRenaming: () -> Void
    /// The new title on Return or when the field loses focus; nil on Esc.
    let onFinishRenaming: (String?) -> Void
    /// Asks first (the list shows the confirmation).
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var titleDraft = ""
    @FocusState private var isTitleFieldFocused: Bool
    /// Return, Esc and losing focus can all end one rename (Esc also takes
    /// the focus away); only the first one counts.
    @State private var hasFinishedRenaming = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Chat title", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.interface(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.sidebarText)
                        .focused($isTitleFieldFocused)
                        .onSubmit { finishRenaming(withTitle: titleDraft) }
                        .onExitCommand { finishRenaming(withTitle: nil) }
                        .onAppear {
                            titleDraft = conversation.title
                            hasFinishedRenaming = false
                            isTitleFieldFocused = true
                        }
                        .onChange(of: isTitleFieldFocused) { _, isFocused in
                            // Clicking elsewhere saves, like Return.
                            if !isFocused { finishRenaming(withTitle: titleDraft) }
                        }
                } else {
                    Text(conversation.title)
                        .font(DS.Typography.interface(size: 13))
                        .foregroundColor(isSelected || isHovered ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if isStreaming {
                Circle()
                    .fill(isSelected ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                    .frame(width: 6, height: 6)
                    .help("Replying…")
            }
            if isHovered && !isRenaming {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(DS.Typography.interface(size: 10, weight: .medium))
                        .foregroundColor(isSelected ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                }
                .buttonStyle(.plain)
                .help("Delete chat…")
                .pointerCursor()
            }
        }
        // One line per chat; when it was last used is in the tooltip.
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(isSelected ? DS.Colors.sidebarSelected : (isHovered ? DS.Colors.sidebarHover : Color.clear))
        )
        .contentShape(Rectangle())
        .help(conversation.updatedAt.formatted(.relative(presentation: .named)))
        .onTapGesture { if !isRenaming { onSelect() } }
        // A tap gesture isn't a button to VoiceOver: say what the row does.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if !isRenaming { onSelect() } }
        .accessibilityAction(named: "Rename", onStartRenaming)
        .accessibilityAction(named: "Delete chat", onDelete)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .contextMenu {
            Button("Rename…", action: onStartRenaming)
            Divider()
            Button("Delete chat…", role: .destructive, action: onDelete)
        }
    }

    private func finishRenaming(withTitle newTitle: String?) {
        guard !hasFinishedRenaming else { return }
        hasFinishedRenaming = true
        onFinishRenaming(newTitle)
    }
}

// MARK: - Screen steps and where a reply stopped

/// Under a reply: the steps it took on the screen, in order, and — when the
/// user stopped it with Esc (or by speaking again) — a marker at the point
/// it stopped: after its last step, or partway through its text. Folded to
/// a one-line summary once there are more than a few steps.
struct ReplyScreenStepsAndStopView: View {
    let screenSteps: [String]
    let wasStoppedByUser: Bool

    /// Up to this many steps show without folding.
    private static let stepsShownUnfolded = 4

    @State private var isExpanded = false

    private var showsEveryStep: Bool { isExpanded || screenSteps.count <= Self.stepsShownUnfolded }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !screenSteps.isEmpty {
                if screenSteps.count > Self.stepsShownUnfolded {
                    Button(action: { isExpanded.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(DS.Typography.interface(size: 9, weight: .semibold))
                            Text("\(screenSteps.count) steps on screen")
                        }
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isExpanded ? "Hide the steps" : "Show every step")
                }
                if showsEveryStep {
                    ForEach(Array(screenSteps.enumerated()), id: \.offset) { stepIndex, stepDescription in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(stepIndex + 1).")
                                .font(DS.Typography.interface(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                                .frame(minWidth: 16, alignment: .trailing)
                            Text(stepDescription)
                                .font(DS.Typography.interface(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if wasStoppedByUser {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle")
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                    Text(Self.stopNote(stepCount: screenSteps.count))
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Where the reply stopped, said plainly.
    static func stopNote(stepCount: Int) -> String {
        switch stepCount {
        case 0: return "You stopped it here"
        case 1: return "You stopped it here, after 1 step on screen"
        default: return "You stopped it here, after \(stepCount) steps on screen"
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
                    .font(DS.Typography.interface(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(savedFileChange.note)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .strikethrough(savedFileChange.isUndone)
                if savedFileChange.isUndone {
                    Text("undone")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    Button("Undo") { undo(force: false) }
                        .buttonStyle(.plain)
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                        .foregroundColor(isUndoHovered ? DS.Colors.textPrimary : DS.Colors.accentText)
                        .onHover { isUndoHovered = $0 }
                        .pointerCursor()
                        .help("Put the file back the way it was")
                }
            }
            if let undoErrorMessage {
                Text(undoErrorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
        }
        .confirmationDialog("This file changed since then.", isPresented: $isConfirmingForcedUndo) {
            Button("Undo anyway", role: .destructive) { undo(force: true) }
        } message: {
            Text("Undoing puts back the earlier version. The newer one is kept in the Elf's changes, so you can undo this too.")
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
            viewModel.elfsForComposer.first { $0.id == chosenElfIdentifier }
        }
    }

    var body: some View {
        Menu {
            Button("By name (or the main Elf)") { viewModel.composerElfSelection.chosenElfIdentifier = nil }
            Divider()
            ForEach(viewModel.elfsForComposer) { elf in
                Button(elf.configuration.identity.name) {
                    viewModel.composerElfSelection.chosenElfIdentifier = elf.id
                }
            }
        } label: {
            if let chosenElf {
                ElfAvatar(elf: chosenElf, size: 22)
            } else {
                Image(systemName: "person.2")
                    .font(DS.Typography.interface(size: 12))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help(chosenElf.map { "Sending to \($0.configuration.identity.name)" } ?? "Who answers: by name, or the main Elf")
    }
}
