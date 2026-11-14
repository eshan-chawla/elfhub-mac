//
//  StreamingSpeechPlayer.swift
//  elfhub
//
//  Plays a reply sentence by sentence as it streams in. While one sentence is
//  playing, the next is already being synthesized, so speech starts after the
//  first sentence and flows without gaps. If the chosen voice fails (e.g.
//  ElevenLabs unreachable), the rest of the reply continues on the on-device
//  voice instead of going silent.
//
//  One utterance at a time: starting a new one, or stop(), cuts off the old.
//
//  A sentence can carry an action to run as it starts (showing the notepad
//  line it talks about). Stopping runs the actions of sentences that never
//  played, so nothing that was written goes missing when speech is cut off.
//

import Foundation

@MainActor
final class StreamingSpeechPlayer {

    /// Fires when the first sentence starts playing.
    var onSpeechStarted: (() -> Void)?
    /// Fires when the last sentence of an utterance finishes (not when stopped).
    var onSpeechFinished: (() -> Void)?

    /// A sentence waiting to be spoken. Empty text is never synthesized —
    /// it only runs its start action, after the sentences queued before it.
    private struct QueuedSentence {
        let identifier = UUID()
        let text: String
    }

    private let onDeviceFallbackProvider: SpeechSynthesisProvider
    private var sentenceContinuation: AsyncStream<QueuedSentence>.Continuation?
    /// Start actions of the current utterance's sentences that haven't
    /// started yet, in order.
    private var pendingSentenceStartActions: [(sentenceIdentifier: UUID, action: () -> Void)] = []
    private var playbackTask: Task<Void, Never>?
    private var activeSpeechProvider: SpeechSynthesisProvider?
    /// Identifies the current utterance so a stopped one finishing late can't
    /// clear the state of the utterance that replaced it.
    private var currentUtteranceIdentifier: UUID?
    /// Lines to say after the current utterance ends (e.g. a consent prompt
    /// that arrives while the reply is still being spoken).
    private var followUpUtterances: [(text: String, speechProvider: SpeechSynthesisProvider)] = []

    init(onDeviceFallbackProvider: SpeechSynthesisProvider) {
        self.onDeviceFallbackProvider = onDeviceFallbackProvider
    }

    /// True from when an utterance starts until it finishes or is stopped.
    var isSpeaking: Bool {
        playbackTask != nil
    }

    /// Starts a new utterance spoken by `speechProvider`. Sentences are added
    /// with enqueue(sentence:) and the utterance is closed with finishUtterance().
    func startUtterance(using speechProvider: SpeechSynthesisProvider) {
        stopCurrentUtterance()

        let (sentenceStream, sentenceContinuation) = AsyncStream<QueuedSentence>.makeStream()
        self.sentenceContinuation = sentenceContinuation
        activeSpeechProvider = speechProvider
        let utteranceIdentifier = UUID()
        currentUtteranceIdentifier = utteranceIdentifier

        playbackTask = Task { @MainActor [weak self] in
            await self?.playSentences(
                from: sentenceStream,
                startingWith: speechProvider,
                utteranceIdentifier: utteranceIdentifier
            )
        }
    }

    /// Queues a sentence. `onSentenceStarted` runs right before it plays —
    /// or when speech is stopped first.
    func enqueue(sentence: String, onSentenceStarted: (() -> Void)? = nil) {
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentence.isEmpty || onSentenceStarted != nil else { return }
        guard let sentenceContinuation else {
            // No utterance to join: show what this sentence carries now.
            onSentenceStarted?()
            return
        }
        let queuedSentence = QueuedSentence(text: trimmedSentence)
        if let onSentenceStarted {
            pendingSentenceStartActions.append((queuedSentence.identifier, onSentenceStarted))
        }
        sentenceContinuation.yield(queuedSentence)
    }

    /// No more sentences are coming; playback ends after the queued ones.
    func finishUtterance() {
        sentenceContinuation?.finish()
        sentenceContinuation = nil
    }

    /// Convenience: speak a complete text as one utterance.
    func speakCompleteText(_ text: String, using speechProvider: SpeechSynthesisProvider) {
        startUtterance(using: speechProvider)
        var sentenceSegmenter = SpokenSentenceSegmenter()
        for spokenSentenceSegment in sentenceSegmenter.append(text) + sentenceSegmenter.finish() {
            enqueue(sentence: spokenSentenceSegment.text)
        }
        finishUtterance()
    }

    /// Speaks `text` once the current utterance finishes, or right away if
    /// nothing is playing — so a follow-up never cuts off the reply.
    func speakAfterCurrentUtterance(_ text: String, using speechProvider: SpeechSynthesisProvider) {
        if isSpeaking {
            followUpUtterances.append((text, speechProvider))
        } else {
            speakCompleteText(text, using: speechProvider)
        }
    }

    /// Cuts off speech immediately, including queued follow-ups.
    func stop() {
        followUpUtterances.removeAll()
        stopCurrentUtterance()
    }

    private func stopCurrentUtterance() {
        sentenceContinuation?.finish()
        sentenceContinuation = nil
        playbackTask?.cancel()
        playbackTask = nil
        activeSpeechProvider?.stopPlayback()
        onDeviceFallbackProvider.stopPlayback()
        activeSpeechProvider = nil
        currentUtteranceIdentifier = nil
        runPendingSentenceStartActions()
    }

    private func runSentenceStartAction(ofSentenceWithIdentifier sentenceIdentifier: UUID) {
        guard let pendingActionIndex = pendingSentenceStartActions.firstIndex(where: { $0.sentenceIdentifier == sentenceIdentifier }) else {
            return
        }
        let pendingSentenceStartAction = pendingSentenceStartActions.remove(at: pendingActionIndex)
        pendingSentenceStartAction.action()
    }

    private func runPendingSentenceStartActions() {
        let pendingActions = pendingSentenceStartActions
        pendingSentenceStartActions.removeAll()
        for pendingSentenceStartAction in pendingActions {
            pendingSentenceStartAction.action()
        }
    }

    // MARK: - Playback loop

    private func playSentences(
        from sentenceStream: AsyncStream<QueuedSentence>,
        startingWith initialSpeechProvider: SpeechSynthesisProvider,
        utteranceIdentifier: UUID
    ) async {
        var sentenceIterator = sentenceStream.makeAsyncIterator()
        guard var currentSentence = await sentenceIterator.next(), !Task.isCancelled else {
            finishPlayback(ofUtterance: utteranceIdentifier)
            return
        }

        var speechProvider = initialSpeechProvider
        var currentPreparation = makePreparation(of: currentSentence.text, using: speechProvider)
        var hasAnnouncedSpeechStart = false

        while !Task.isCancelled {
            // Nil for a sentence with no words (it only shows its notepad lines).
            var preparedSpeech: PreparedSpeech?
            if let currentPreparation {
                do {
                    preparedSpeech = try await currentPreparation.value
                } catch {
                    // The chosen voice failed: continue this reply on-device.
                    print("⚠️ Speech: \(error.localizedDescription) — continuing with the on-device voice")
                    speechProvider = onDeviceFallbackProvider
                    if currentUtteranceIdentifier == utteranceIdentifier {
                        activeSpeechProvider = speechProvider
                    }
                    preparedSpeech = .onDeviceVoiceText(currentSentence.text)
                }
            }
            if Task.isCancelled { break }

            runSentenceStartAction(ofSentenceWithIdentifier: currentSentence.identifier)
            if preparedSpeech != nil, !hasAnnouncedSpeechStart {
                hasAnnouncedSpeechStart = true
                onSpeechStarted?()
            }

            // Play this sentence while waiting for (and preparing) the next.
            let providerPlayingThisSentence = speechProvider
            let preparedSpeechForThisSentence = preparedSpeech
            let sentencePlayback = Task { @MainActor in
                if let preparedSpeechForThisSentence {
                    await providerPlayingThisSentence.playPreparedSpeech(preparedSpeechForThisSentence)
                }
            }
            let nextSentence = await sentenceIterator.next()
            let nextPreparation = nextSentence.flatMap { makePreparation(of: $0.text, using: speechProvider) }
            await sentencePlayback.value

            guard let nextSentence, !Task.isCancelled else { break }
            currentSentence = nextSentence
            currentPreparation = nextPreparation
        }

        let wasStopped = Task.isCancelled
        finishPlayback(ofUtterance: utteranceIdentifier)
        if !wasStopped && hasAnnouncedSpeechStart {
            onSpeechFinished?()
        }
        if !wasStopped, !followUpUtterances.isEmpty {
            let nextFollowUpUtterance = followUpUtterances.removeFirst()
            speakCompleteText(nextFollowUpUtterance.text, using: nextFollowUpUtterance.speechProvider)
        }
    }

    /// Nil for empty text: there is nothing to say.
    private func makePreparation(of sentence: String, using speechProvider: SpeechSynthesisProvider) -> Task<PreparedSpeech, Error>? {
        guard !sentence.isEmpty else { return nil }
        return Task { @MainActor in
            try await speechProvider.prepareSpeech(for: sentence)
        }
    }

    private func finishPlayback(ofUtterance utteranceIdentifier: UUID) {
        guard currentUtteranceIdentifier == utteranceIdentifier else { return }
        playbackTask = nil
        activeSpeechProvider = nil
        currentUtteranceIdentifier = nil
    }
}

// MARK: - Streaming reply presentation

/// Presents one reply while it streams in: live captions in the status pill,
/// sentences queued for speech as soon as each one is complete (when a voice
/// is on), and notepad lines shown as the sentence after them starts — or as
/// soon as they arrive when the voice is off. Tags never reach speech or
/// captions.
@MainActor
final class StreamingReplyPresenter {
    private let companionEventBus: CompanionEventBus
    private let streamingSpeechPlayer: StreamingSpeechPlayer
    private let speaksReply: Bool
    private let notepadItemRevealer: NotepadItemRevealer
    private var sentenceSegmenter = SpokenSentenceSegmenter()
    private var rawReplyText = ""

    /// Pass nil as the speech provider for caption-only (voice off).
    init(
        companionEventBus: CompanionEventBus,
        streamingSpeechPlayer: StreamingSpeechPlayer,
        speechProvider: SpeechSynthesisProvider?
    ) {
        self.companionEventBus = companionEventBus
        self.streamingSpeechPlayer = streamingSpeechPlayer
        self.speaksReply = speechProvider != nil
        self.notepadItemRevealer = NotepadItemRevealer(companionEventBus: companionEventBus)
        if let speechProvider {
            streamingSpeechPlayer.startUtterance(using: speechProvider)
        }
    }

    func receive(replyTextDelta: String) {
        rawReplyText += replyTextDelta
        let liveCaption = SpokenSentenceSegmenter.speakableText(fromPartialResponse: rawReplyText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveCaption.isEmpty {
            companionEventBus.emit(.responseCaptionAvailable(liveCaption))
        }
        present(sentenceSegmenter.append(replyTextDelta))
    }

    /// A model round ended and another may follow: speak what was held
    /// back waiting for its sentence to end.
    func markEndOfModelRound() {
        rawReplyText += "\n"
        present(sentenceSegmenter.endOfModelRound())
    }

    /// The reply is complete. `finalSpokenText` is the decoder's tag-free text,
    /// used for the final caption.
    func finish(finalSpokenText: String) {
        present(sentenceSegmenter.finish())
        if speaksReply {
            streamingSpeechPlayer.finishUtterance()
        }
        let finalCaption = finalSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalCaption.isEmpty {
            companionEventBus.emit(.responseCaptionAvailable(finalCaption))
        }
    }

    /// The turn failed or was interrupted: stop any partial speech, but keep
    /// every notepad line already written — the chat saves them too.
    func abandon() {
        if speaksReply {
            streamingSpeechPlayer.stop()
        }
        notepadItemRevealer.revealAllRemaining(of: NotepadTagParser.notepadItems(inResponseText: rawReplyText))
    }

    private func present(_ spokenSentenceSegments: [SpokenSentenceSegment]) {
        for spokenSentenceSegment in spokenSentenceSegments {
            let notepadItems = spokenSentenceSegment.notepadItemsToShowFirst
            if speaksReply {
                // Captures the revealer, not this presenter: the player may
                // run it after the turn (and this presenter) is done.
                let notepadItemRevealer = self.notepadItemRevealer
                streamingSpeechPlayer.enqueue(
                    sentence: spokenSentenceSegment.text,
                    onSentenceStarted: notepadItems.isEmpty ? nil : { notepadItemRevealer.reveal(notepadItems) }
                )
            } else {
                notepadItemRevealer.reveal(notepadItems)
            }
        }
    }
}

/// Turns one reply's notepad items into notepad events, in order, applying
/// the same rules as `NotepadTagParser.notepad(fromResponseText:)` so the
/// window always matches what the chat saves: the title only before the
/// first line (otherwise "Notes"), at most `maximumNotepadLines` lines.
@MainActor
final class NotepadItemRevealer {
    private let companionEventBus: CompanionEventBus
    /// Items handed to reveal(_:) so far, kept or not — the position in the reply.
    private var revealedNotepadItemCount = 0
    private var hasOpenedNotepad = false
    private var pendingNotepadTitle: String?
    private var writtenMarkdownLines: [String] = []

    init(companionEventBus: CompanionEventBus) {
        self.companionEventBus = companionEventBus
    }

    func reveal(_ notepadItems: [NotepadItem]) {
        for notepadItem in notepadItems {
            revealedNotepadItemCount += 1
            switch notepadItem {
            case let .title(titleText):
                let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hasOpenedNotepad, pendingNotepadTitle == nil, !trimmedTitle.isEmpty {
                    pendingNotepadTitle = trimmedTitle
                }
            case let .line(lineText):
                guard writtenMarkdownLines.count < NotepadTagParser.maximumNotepadLines else { continue }
                if !hasOpenedNotepad {
                    hasOpenedNotepad = true
                    companionEventBus.emit(.notepadOpened(title: pendingNotepadTitle ?? NotepadTagParser.defaultNotepadTitle))
                }
                let cleanedLine = NotepadTagParser.cleanedLine(lineText, previousLines: writtenMarkdownLines)
                writtenMarkdownLines.append(cleanedLine)
                companionEventBus.emit(.notepadLineWritten(cleanedLine))
            }
        }
    }

    /// Shows whatever of `allNotepadItemsInReply` hasn't been shown yet.
    func revealAllRemaining(of allNotepadItemsInReply: [NotepadItem]) {
        guard allNotepadItemsInReply.count > revealedNotepadItemCount else { return }
        reveal(Array(allNotepadItemsInReply.dropFirst(revealedNotepadItemCount)))
    }
}
