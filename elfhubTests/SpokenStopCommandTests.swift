//
//  SpokenStopCommandTests.swift
//  elfhubTests
//
//  Saying "stop" while elfhub acts (no push-to-talk): stop, cancel, wait,
//  hold on, enough — as a word on its own, in any case, with punctuation —
//  but not "don't stop", "keep going without stopping", or "stopwatch".
//  Only the newest words count, so an old "stop" in a long partial
//  transcript isn't heard twice.
//

import Foundation
import Testing
@testable import elfhub

struct SpokenStopCommandTests {

    @Test func stopWordsAreHeard() {
        for transcript in ["stop", "Stop!", "okay stop", "wait", "hold on", "cancel that", "STOP STOP"] {
            #expect(SpokenStopCommand.isStopCommand(transcript), "\(transcript) should stop")
        }
    }

    @Test func otherSentencesArent() {
        for transcript in ["don't stop", "do not stop", "never stop", "keep going without stopping", "open the stopwatch", "no wait isn't needed... actually don't wait", "the bus stop", ""] {
            #expect(!SpokenStopCommand.isStopCommand(transcript), "\(transcript) shouldn't stop")
        }
    }

    @Test func whileElfhubIsTalkingOnlyStopCounts() {
        // Its own narration ("i'll wait for it to load", "pressing cancel")
        // may leak past echo cancellation; "stop" still works.
        #expect(!SpokenStopCommand.isStopCommand("i'll wait for it", whileElfhubIsSpeaking: true))
        #expect(!SpokenStopCommand.isStopCommand("now pressing cancel", whileElfhubIsSpeaking: true))
        #expect(SpokenStopCommand.isStopCommand("stop", whileElfhubIsSpeaking: true))
        // "is that enough?" isn't a stop.
        #expect(!SpokenStopCommand.isStopCommand("is that enough"))
    }

    @Test func onlyTheNewestWordsCount() {
        #expect(SpokenStopCommand.isStopCommand("i was saying something long and now stop", newestWordCount: 3))
        #expect(!SpokenStopCommand.isStopCommand("stop it was a joke and now carry on doing it", newestWordCount: 3))
    }
}
