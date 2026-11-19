//
//  LiveCaptionTests.swift
//  elfhubTests
//
//  Live captions: off by default, word-aligned timing that follows the
//  voice, a transcript that keeps the newest text, and an overlay that shows
//  captions only when asked, never in the status pill.
//

import Combine
import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct LiveCaptionTests {

    // MARK: - Setting

    @Test func liveCaptionsAreOffByDefault() throws {
        let userDefaultsSuiteName = "LiveCaptionTests-\(UUID().uuidString)"
        let isolatedUserDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { isolatedUserDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        #expect(!LiveCaptionSettings.isEnabled(userDefaults: isolatedUserDefaults))
        isolatedUserDefaults.set(true, forKey: LiveCaptionSettings.isEnabledKey)
        #expect(LiveCaptionSettings.isEnabled(userDefaults: isolatedUserDefaults))
    }

    // MARK: - Word timing

    @Test func appleVoiceRangesRevealWholeWords() {
        let sentence = "Open the Share menu."
        #expect(SpokenWordTiming.revealedCharacterCount(inSentence: sentence, progress: .spokenThroughCharacterOffset(0)) == 0)
        // Partway into "the" reveals through the end of "the".
        #expect(SpokenWordTiming.revealedCharacterCount(inSentence: sentence, progress: .spokenThroughCharacterOffset(6)) == 8)
        #expect(SpokenWordTiming.revealedCharacterCount(inSentence: sentence, progress: .spokenThroughCharacterOffset(99)) == sentence.count)
    }

    @Test func audioProgressRevealsWordsInOrderAndEndsOnAWord() {
        let sentence = "Then pick Copy link, and paste it into your message."
        var previousRevealedCount = 0
        for step in 0...20 {
            let revealedCount = SpokenWordTiming.revealedCharacterCount(inSentence: sentence, playedFraction: Double(step) / 20)
            #expect(revealedCount >= previousRevealedCount, "never goes backwards")
            if revealedCount > 0 && revealedCount < sentence.count {
                let characterAfterReveal = sentence[sentence.index(sentence.startIndex, offsetBy: revealedCount)]
                #expect(characterAfterReveal.isWhitespace, "stops at the end of a word")
            }
            previousRevealedCount = revealedCount
        }
        #expect(SpokenWordTiming.revealedCharacterCount(inSentence: sentence, playedFraction: 1) == sentence.count)
        #expect(SpokenWordTiming.revealedCharacterCount(inSentence: sentence, playedFraction: 0) == 4, "the first word shows as it starts")
    }

    // MARK: - Transcript

    @Test func theTranscriptGrowsSentenceBySentenceAndNeverGoesBack() {
        var transcript = LiveCaptionTranscript()
        transcript.advance(sentence: "Open the menu.", revealedCharacterCount: 4)
        #expect(transcript.visibleText == "Open")
        transcript.advance(sentence: "Open the menu.", revealedCharacterCount: 2)
        #expect(transcript.visibleText == "Open", "late progress never hides words")
        transcript.advance(sentence: "Then pick Copy.", revealedCharacterCount: 4)
        #expect(transcript.visibleText == "Open the menu. Then", "a new sentence finishes the last one")
    }

    @Test func theTranscriptKeepsOnlyTheNewestText() {
        var transcript = LiveCaptionTranscript()
        for sentenceNumber in 0..<40 {
            let sentence = "Sentence number \(sentenceNumber) is here to fill the panel."
            transcript.advance(sentence: sentence, revealedCharacterCount: sentence.count)
        }
        #expect(transcript.visibleText.count <= LiveCaptionTranscript.maximumKeptCharacterCount + 80)
        #expect(transcript.visibleText.hasSuffix("Sentence number 39 is here to fill the panel."))
    }

    @Test func unspokenTextIsShownWholeAndReplacedAsItGrows() {
        var transcript = LiveCaptionTranscript()
        transcript.showUnspokenText("The answer")
        transcript.showUnspokenText("The answer is 42.")
        #expect(transcript.visibleText == "The answer is 42.")
    }

    // MARK: - Overlay

    private func makeOverlayModel() -> (CompanionEventBus, ScreenGuidanceOverlayModel) {
        let companionEventBus = CompanionEventBus()
        let overlayModel = ScreenGuidanceOverlayModel(
            eventBus: companionEventBus,
            audioPowerLevelPublisher: Just(CGFloat(0)).eraseToAnyPublisher()
        )
        return (companionEventBus, overlayModel)
    }

    /// The model receives events on the main queue; let them arrive.
    private func letEventsArrive() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test func spokenCaptionsGoInThePanelAndThinkingEndsWhenSpeechStarts() async {
        let (companionEventBus, overlayModel) = makeOverlayModel()
        companionEventBus.emit(.turnStarted(primaryFocusScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        companionEventBus.emit(.processingStarted)
        await letEventsArrive()
        #expect(overlayModel.statusPillPhase == .thinking)

        companionEventBus.emit(.speechStarted)
        companionEventBus.emit(.spokenCaptionAdvanced(sentence: "Open the menu.", revealedCharacterCount: 4))
        await letEventsArrive()
        #expect(overlayModel.statusPillPhase == .hidden, "the pill never carries the transcript")
        #expect(overlayModel.liveCaptionTranscript?.visibleText == "Open")
    }

    @Test func withCaptionsOffASpokenReplyShowsNoText() async {
        let (companionEventBus, overlayModel) = makeOverlayModel()
        companionEventBus.emit(.turnStarted(primaryFocusScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        companionEventBus.emit(.processingStarted)
        // With captions off, CompanionManager sends no spokenCaptionAdvanced.
        companionEventBus.emit(.speechStarted)
        await letEventsArrive()
        #expect(overlayModel.liveCaptionTranscript == nil)
        #expect(overlayModel.statusPillPhase == .hidden)
    }

    @Test func aNewTurnEscOrActingClearsTheCaptions() async {
        let (companionEventBus, overlayModel) = makeOverlayModel()
        companionEventBus.emit(.turnStarted(primaryFocusScreenFrame: nil))
        companionEventBus.emit(.unspokenCaptionAvailable("The answer is 42."))
        await letEventsArrive()
        #expect(overlayModel.liveCaptionTranscript?.visibleText == "The answer is 42.")

        companionEventBus.emit(.allGuidanceDismissed)
        await letEventsArrive()
        #expect(overlayModel.liveCaptionTranscript == nil)

        companionEventBus.emit(.unspokenCaptionAvailable("Again."))
        companionEventBus.emit(.actionsStarted(summary: "clicking Save"))
        await letEventsArrive()
        #expect(overlayModel.liveCaptionTranscript == nil)
        #expect(overlayModel.statusPillPhase == .acting(summary: "clicking Save"))

        companionEventBus.emit(.turnStarted(primaryFocusScreenFrame: nil))
        await letEventsArrive()
        #expect(overlayModel.liveCaptionTranscript == nil)
    }

    @Test func unspokenRepliesStayLongEnoughToRead() {
        #expect(ScreenGuidanceOverlayModel.unspokenCaptionLingerSeconds(forCharacterCount: 0) == 5)
        #expect(ScreenGuidanceOverlayModel.unspokenCaptionLingerSeconds(forCharacterCount: 100) == 10)
        #expect(ScreenGuidanceOverlayModel.unspokenCaptionLingerSeconds(forCharacterCount: 10_000) == 20)
    }
}
