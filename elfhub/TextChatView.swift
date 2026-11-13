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
            with: savedConversation.historyTurns(maximumTurnCount: CompanionTurnPipeline.maximumHistoryTurns)
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

        let recordedExchange = beginExchange(userText: trimmed, inputSource: .typed)
        isResponding = true

        currentTask = Task { [weak self] in
            guard let self else { return }
            var rawReplyText = ""
            do {
                let turnResult = try await self.companionManager.respondToChatMessage(trimmed) { chunk in
                    rawReplyText += chunk
                    self.showStreamingReply(rawReplyText: rawReplyText, for: recordedExchange)
                }
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
    }

    /// Adds the question and an empty reply bubble to the open conversation
    /// and saves it. A spoken question after a long quiet spell starts a new
    /// conversation instead (see `shouldStartNewConversation(forVoiceTurnAt:)`).
    func beginExchange(userText: String, inputSource: StoredChatMessage.InputSource) -> RecordedExchange {
        if inputSource == .spoken, !isResponding,
           activeConversation.shouldStartNewConversation(forVoiceTurnAt: Date()) {
            startNewConversation()
        }
        let exchangeIdentifiers = activeConversation.appendExchange(userText: userText, inputSource: inputSource)
        chatConversationStore.save(activeConversation)
        return RecordedExchange(
            conversationIdentifier: activeConversation.id,
            userMessageIdentifier: exchangeIdentifiers.userMessageIdentifier,
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier
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

    func failExchange(_ recordedExchange: RecordedExchange, with error: Error) {
        updateConversation(withIdentifier: recordedExchange.conversationIdentifier, savingToDisk: true) { conversation in
            conversation.setText("⚠️ \(error.localizedDescription)", ofMessageWithIdentifier: recordedExchange.assistantMessageIdentifier)
            if let assistantMessageIndex = conversation.messages.firstIndex(where: { $0.id == recordedExchange.assistantMessageIdentifier }) {
                conversation.messages[assistantMessageIndex].isError = true
            }
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
                             : "Saving chats is off (Settings › Privacy & permissions).")
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

