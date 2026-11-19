//
//  ConsentPromptTimingTests.swift
//  elfhubTests
//
//  A consent prompt asked during a step-by-step run is said while the run
//  waits for it — right after what the reply has said so far — not after the
//  whole turn, and one whose card was already answered isn't said at all.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
private final class RecordingSpeechSynthesisProvider: SpeechSynthesisProvider {
    private(set) var playedSentences: [String] = []
    var isPlaying: Bool { false }

    func prepareSpeech(for sentence: String) async throws -> PreparedSpeech {
        .onDeviceVoiceText(sentence)
    }

    func playPreparedSpeech(
        _ preparedSpeech: PreparedSpeech,
        onPlaybackProgress: @escaping @MainActor (SpeechPlaybackProgress) -> Void
    ) async {
        if case let .onDeviceVoiceText(sentence) = preparedSpeech {
            playedSentences.append(sentence)
        }
    }

    func stopPlayback() {}
}

@MainActor
struct ConsentPromptTimingTests {

    private let consentPrompt = "i can click the account button. press return or say go and i'll do it."

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func aPromptDuringAnOpenReplyIsSaidBeforeTheTurnEnds() async {
        let recordingProvider = RecordingSpeechSynthesisProvider()
        let streamingSpeechPlayer = StreamingSpeechPlayer(onDeviceFallbackProvider: recordingProvider)
        streamingSpeechPlayer.startUtterance(using: recordingProvider)
        streamingSpeechPlayer.enqueue(sentence: "I'll open the account switcher in the top right.")

        // The run waits on the card; the reply's utterance is still open.
        streamingSpeechPlayer.speakAfterCurrentUtterance(consentPrompt, using: recordingProvider)
        await waitUntil { recordingProvider.playedSentences.joined(separator: " ").contains("press return or say go") }

        #expect(recordingProvider.playedSentences.first == "I'll open the account switcher in the top right.")
        #expect(recordingProvider.playedSentences.dropFirst().joined(separator: " ").contains("press return or say go"),
                "the prompt is said while the turn is still going, not queued after it")
        #expect(streamingSpeechPlayer.isSpeaking, "the reply's utterance was never closed")
        streamingSpeechPlayer.stop()
    }

    @Test func aPromptArrivingMidRoundWaitsForTheRoundsLastSentence() async {
        let recordingProvider = RecordingSpeechSynthesisProvider()
        let streamingSpeechPlayer = StreamingSpeechPlayer(onDeviceFallbackProvider: recordingProvider)
        let streamingReplyPresenter = StreamingReplyPresenter(
            companionEventBus: CompanionEventBus(),
            streamingSpeechPlayer: streamingSpeechPlayer,
            speechProvider: recordingProvider
        )
        streamingReplyPresenter.receive(replyTextDelta: "The personal account is listed, so I'll click it.")
        streamingSpeechPlayer.speakAfterCurrentUtterance(consentPrompt, using: recordingProvider)
        streamingReplyPresenter.markEndOfModelRound()
        await waitUntil { recordingProvider.playedSentences.joined(separator: " ").contains("press return or say go") }

        #expect(recordingProvider.playedSentences.first == "The personal account is listed, so I'll click it.")
        #expect(recordingProvider.playedSentences.dropFirst().joined(separator: " ").contains("press return or say go"))
        streamingSpeechPlayer.stop()
    }

    @Test func aPromptForAnAnsweredCardIsNotSaid() async {
        let recordingProvider = RecordingSpeechSynthesisProvider()
        let streamingSpeechPlayer = StreamingSpeechPlayer(onDeviceFallbackProvider: recordingProvider)
        streamingSpeechPlayer.startUtterance(using: recordingProvider)
        streamingSpeechPlayer.speakAfterCurrentUtterance(consentPrompt, using: recordingProvider, isStillWanted: { false })
        streamingSpeechPlayer.enqueue(sentence: "You're now in your personal Gmail.")
        streamingSpeechPlayer.finishUtterance()
        await waitUntil { !streamingSpeechPlayer.isSpeaking }

        #expect(recordingProvider.playedSentences == ["You're now in your personal Gmail."])
    }

    @Test func aFollowUpForAnAnsweredCardIsDropped() async {
        let recordingProvider = RecordingSpeechSynthesisProvider()
        let streamingSpeechPlayer = StreamingSpeechPlayer(onDeviceFallbackProvider: recordingProvider)
        var isCardPending = true
        streamingSpeechPlayer.startUtterance(using: recordingProvider)
        streamingSpeechPlayer.enqueue(sentence: "Here is the whole reply, already closed.")
        streamingSpeechPlayer.finishUtterance()
        streamingSpeechPlayer.speakAfterCurrentUtterance(consentPrompt, using: recordingProvider, isStillWanted: { isCardPending })
        isCardPending = false
        await waitUntil { !streamingSpeechPlayer.isSpeaking }
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(recordingProvider.playedSentences == ["Here is the whole reply, already closed."])
    }
}
