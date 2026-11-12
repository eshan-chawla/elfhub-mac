//
//  EscapeStopTests.swift
//  elfhubTests
//
//  When elfhub watches for Esc: only while there is something to stop —
//  guidance on screen, a voice turn listening / thinking / talking, or a
//  typed reply streaming. When idle, no Esc tap should run.
//

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
}
