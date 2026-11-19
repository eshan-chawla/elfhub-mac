//
//  SpokenConfirmationParserTests.swift
//  elfhubTests
//
//  How a spoken answer to a pending screen action is understood. A misheard
//  "yes" fires a real click or keystroke, so these rules are pinned down:
//  any "no" wins, words that merely contain "no" don't count, and a
//  consequential action needs its verb said back.
//

import Testing
@testable import elfhub

struct SpokenConfirmationParserTests {

    private func answer(_ transcript: String, requiredVerbs: [String] = []) -> SpokenConfirmationAnswer {
        SpokenConfirmationParser.interpret(transcript, requiredVerbKeywords: requiredVerbs)
    }

    private let sendVerbs = ConsentPolicy.utteranceKeywordsByEffect[.send] ?? []

    // MARK: - Ordinary actions

    @Test func plainAffirmativesConfirm() {
        #expect(answer("go") == .confirmed)
        #expect(answer("Yes.") == .confirmed)
        #expect(answer("yeah do it") == .confirmed)
        #expect(answer("okay go") == .confirmed)
        #expect(answer("go ahead please") == .confirmed)
    }

    /// A typed "Okay" or "continue" to a paused run used to read as a new
    /// request, which dropped the waiting step and lost the run.
    @Test func aBareOkayOrContinueIsAYes() {
        #expect(answer("Okay") == .confirmed)
        #expect(answer("ok.") == .confirmed)
        #expect(answer("alright, please") == .confirmed)
        #expect(answer("continue") == .confirmed)
        #expect(answer("okay, continue") == .confirmed)
        #expect(answer("proceed") == .confirmed)
        #expect(answer("keep going") == .confirmed)
        #expect(answer("please") == .unrelated, "filler alone that isn't okay is no answer")
        #expect(answer("okay, continue but don't send it") == .declined)
    }

    @Test func aBareOkayToAConsequentialActionAsksForTheVerb() {
        #expect(answer("okay", requiredVerbs: sendVerbs) == .needsVerbRestatement)
        #expect(answer("continue", requiredVerbs: sendVerbs) == .needsVerbRestatement)
        #expect(answer("okay send it", requiredVerbs: sendVerbs) == .confirmed)
    }

    @Test func anyNegativeWins() {
        #expect(answer("no") == .declined)
        #expect(answer("yes but don't send it") == .declined)
        #expect(answer("go ahead, wait, stop") == .declined)
        #expect(answer("never mind") == .declined)
        #expect(answer("Don’t") == .declined)
        #expect(answer("not yet") == .declined)
    }

    @Test func wordsThatOnlyContainNoAreNotNegatives() {
        // "now", "know" and "nothing" used to read as "no".
        #expect(answer("yes now") == .confirmed)
        #expect(answer("i know where it is") == .unrelated)
    }

    @Test func longOrOffTopicUtterancesAreANewRequest() {
        #expect(answer("what's the weather like tomorrow") == .unrelated)
        #expect(answer("okay so what about the other tab") == .unrelated)
        #expect(answer("yes and also could you explain how pivot tables work in detail") == .unrelated)
        #expect(answer("") == .unrelated)
    }

    // MARK: - Consequential actions

    @Test func consequentialActionNeedsItsVerbSaidBack() {
        #expect(answer("yes", requiredVerbs: sendVerbs) == .needsVerbRestatement)
        #expect(answer("go", requiredVerbs: sendVerbs) == .needsVerbRestatement)
        #expect(answer("yes send it", requiredVerbs: sendVerbs) == .confirmed)
        #expect(answer("send it", requiredVerbs: sendVerbs) == .confirmed)
        #expect(answer("okay, send it now", requiredVerbs: sendVerbs) == .confirmed)
    }

    @Test func consequentialActionStillLosesToANegative() {
        #expect(answer("don't send it", requiredVerbs: sendVerbs) == .declined)
        #expect(answer("no, send it later", requiredVerbs: sendVerbs) == .declined)
    }

    @Test func theWrongVerbIsNotAConfirmation() {
        let deleteVerbs = ConsentPolicy.utteranceKeywordsByEffect[.delete] ?? []
        #expect(answer("yes send it", requiredVerbs: deleteVerbs) == .needsVerbRestatement)
        #expect(answer("send it", requiredVerbs: deleteVerbs) == .unrelated)
    }

    @Test func multiWordVerbsAreRecognized() {
        let closeVerbs = ConsentPolicy.utteranceKeywordsByEffect[.closeOrQuit] ?? []
        #expect(answer("yes log out", requiredVerbs: closeVerbs) == .confirmed)
    }
}
