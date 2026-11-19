//
//  EscapeStopTests.swift
//  elfhubTests
//
//  When elfhub watches for Esc: only while there is something to stop —
//  guidance on screen, a voice turn listening / thinking / talking, or a
//  typed reply streaming. When idle, no Esc tap should run.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct EscapeStopTests {

    @Test func idleWithNothingOnScreenDoesNotWatchEscape() {
        #expect(!CompanionManager.shouldListenForEscape(
            hasVisibleGuidance: false,
            voiceState: .idle,
            isChatReplyStreaming: false
        ))
    }

    @Test func everyBusyVoiceStateWatchesEscape() {
        for busyVoiceState in [CompanionVoiceState.listening, .processing, .responding] {
            #expect(CompanionManager.shouldListenForEscape(
                hasVisibleGuidance: false,
                voiceState: busyVoiceState,
                isChatReplyStreaming: false
            ))
        }
    }

    @Test func streamingTypedReplyWatchesEscape() {
        #expect(CompanionManager.shouldListenForEscape(
            hasVisibleGuidance: false,
            voiceState: .idle,
            isChatReplyStreaming: true
        ))
    }

    @Test func visibleGuidanceWatchesEscape() {
        #expect(CompanionManager.shouldListenForEscape(
            hasVisibleGuidance: true,
            voiceState: .idle,
            isChatReplyStreaming: false
        ))
    }

    // MARK: - A stopped reply is kept, not shown as an error

    @Test func aCancelledRequestCountsAsStoppedWhateverItThrew() {
        #expect(ReplyStopDetection.isStoppedByUser(CancellationError(), taskIsCancelled: false))
        // URLSession's own error when the turn's task stops its request.
        #expect(ReplyStopDetection.isStoppedByUser(URLError(.cancelled), taskIsCancelled: false))
        // Whatever a provider makes of a cut-off stream, once the task was cancelled.
        #expect(ReplyStopDetection.isStoppedByUser(LanguageModelProviderError.invalidResponse, taskIsCancelled: true))
        // Real failures stay failures.
        #expect(!ReplyStopDetection.isStoppedByUser(LanguageModelProviderError.invalidResponse, taskIsCancelled: false))
        #expect(!ReplyStopDetection.isStoppedByUser(URLError(.notConnectedToInternet), taskIsCancelled: false))
    }

    @Test func aStoppedReplyKeepsItsTextAndStepsAndSaysWhereItStopped() throws {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "export the report", inputSource: .spoken)
        conversation.setText("Opening the File menu", ofMessageWithIdentifier: exchangeIdentifiers.assistantMessageIdentifier)
        conversation.recordScreenStep("click “File”", assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier)
        conversation.recordScreenStep("click “Export…”", assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier)
        conversation.markStoppedByUser(assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier)

        let reply = try #require(conversation.messages.last)
        #expect(reply.text == "Opening the File menu")
        #expect(reply.screenSteps == ["click “File”", "click “Export…”"])
        #expect(reply.wasStoppedByUser)
        #expect(!reply.isError)
        #expect(ReplyScreenStepsAndStopView.stopNote(stepCount: reply.screenSteps.count) == "You stopped it here, after 2 steps on screen")
        #expect(ReplyScreenStepsAndStopView.stopNote(stepCount: 1) == "You stopped it here, after 1 step on screen")
        #expect(ReplyScreenStepsAndStopView.stopNote(stepCount: 0) == "You stopped it here")

        // Saved and read back.
        let encodedConversation = try ChatConversationStore.makeJSONEncoder().encode(conversation)
        let decodedReply = try #require(try ChatConversationStore.makeJSONDecoder().decode(ChatConversation.self, from: encodedConversation).messages.last)
        #expect(decodedReply.screenSteps == reply.screenSteps)
        #expect(decodedReply.wasStoppedByUser)
    }

    @Test func aReplyStoppedBeforeItSaidAnythingSaysSo() {
        var stoppedReply = StoredChatMessage(role: .assistant, text: "", wasStoppedByUser: true)
        #expect(TextChatView.bubbleText(for: stoppedReply) == "Stopped before replying.")
        stoppedReply.screenSteps = ["click “Send”"]
        #expect(TextChatView.bubbleText(for: stoppedReply) == "Stopped before saying anything.")
        #expect(TextChatView.bubbleText(for: StoredChatMessage(role: .assistant, text: "")) == "…")
        #expect(TextChatView.bubbleText(for: StoredChatMessage(role: .assistant, text: "Done.", wasStoppedByUser: true)) == "Done.")
    }

    @Test func repliesSavedBeforeStepsWereRecordedStillLoad() throws {
        let savedMessageJSON = #"{"id":"6B1C5A3E-0000-4000-8000-000000000002","role":"assistant","text":"hi","createdAt":0}"#
        let decodedMessage = try JSONDecoder().decode(StoredChatMessage.self, from: Data(savedMessageJSON.utf8))
        #expect(decodedMessage.screenSteps.isEmpty)
        #expect(!decodedMessage.wasStoppedByUser)
    }
}
