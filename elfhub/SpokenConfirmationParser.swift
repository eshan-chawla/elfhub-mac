//
//  SpokenConfirmationParser.swift
//  elfhub
//
//  Understands the user's spoken answer while a screen action waits for
//  consent ("i can click Send — say go"). A misheard yes fires a real click
//  or keystroke, so the rules lean toward not acting:
//
//   - Any negative wins: "yes but don't send it" is a no.
//   - Words are compared whole, so "now", "know" and "nothing" never read
//     as "no".
//   - A consequential action (send, delete, buy, submit, close) needs its
//     verb said back — "yes, send it" — so a reflexive "yes" can't send an
//     email. A bare yes asks the user to say the verb.
//   - Anything long or off-topic is not an answer at all; the caller treats
//     it as a new request (and the pending action is dropped, never fired).
//
//  Pure and unit-tested.
//

import Foundation

enum SpokenConfirmationAnswer: Equatable {
    /// Do the pending action.
    case confirmed
    /// Don't do it.
    case declined
    /// The user said yes to a consequential action without naming it, e.g.
    /// "yes" to a send. Ask them to say the verb.
    case needsVerbRestatement
    /// Not an answer to the prompt; handle it as a new request.
    case unrelated
}

enum SpokenConfirmationParser {

    /// Any of these, as whole words anywhere in a short answer, means no.
    static let negativePhrases = [
        "no", "nope", "nah", "cancel", "stop", "abort", "negative", "not",
        "don't", "dont", "do not", "never", "never mind", "nevermind", "wait", "hold on"
    ]

    /// An answer that starts with one of these is a yes. "Continue" and its
    /// kin are what people type to a run paused on a card.
    static let affirmativePhrases = [
        "yes", "yeah", "yep", "yup", "sure", "absolutely", "correct", "confirm", "confirmed",
        "go", "go ahead", "do it", "please do", "ok go", "okay go", "ok do it", "okay do it",
        "continue", "proceed", "carry on", "go on", "keep going", "sounds good", "fine",
        "allow", "allowed", "approve", "approved"
    ]

    /// On their own, these are a yes ("Okay." to "can I click Save?").
    /// Before other words they're only filler ("okay, send it").
    static let affirmativeFillerWords: Set<String> = ["ok", "okay", "alright"]

    /// Words people put before the real answer ("okay, send it"). Skipped
    /// when looking at how the answer starts.
    static let leadingFillerWords: Set<String> = ["ok", "okay", "alright", "please", "um", "uh", "so", "then"]

    /// Answers are short. Anything longer is a new request, not a yes.
    static let maximumAnswerLengthInWords = 6

    /// - Parameter requiredVerbKeywords: words that name the pending action's
    ///   consequential effect (for a send: "send", "post", "reply", …). Empty
    ///   for an ordinary action, where a plain yes is enough.
    static func interpret(_ transcript: String, requiredVerbKeywords: [String]) -> SpokenConfirmationAnswer {
        let answerWords = UtteranceWords.words(in: transcript)
        guard !answerWords.isEmpty, answerWords.count <= maximumAnswerLengthInWords else {
            return .unrelated
        }

        let containsNegative = negativePhrases.contains { negativePhrase in
            UtteranceWords.firstIndex(ofPhrase: negativePhrase, in: answerWords) != nil
        }
        if containsNegative {
            return .declined
        }

        let answerWordsAfterFiller = Array(answerWords.drop { leadingFillerWords.contains($0) })
        // A bare "okay" (or "ok, please") is the whole answer, and it's a yes.
        let isOnlyAnAffirmativeFiller = answerWordsAfterFiller.isEmpty
            && answerWords.contains { affirmativeFillerWords.contains($0) }
        let startsWithAffirmative = isOnlyAnAffirmativeFiller || affirmativePhrases.contains { affirmativePhrase in
            UtteranceWords.firstIndex(ofPhrase: affirmativePhrase, in: answerWordsAfterFiller) == 0
        }

        if requiredVerbKeywords.isEmpty {
            return startsWithAffirmative ? .confirmed : .unrelated
        }

        let requiredVerbStartIndex = requiredVerbKeywords
            .compactMap { verbKeyword in UtteranceWords.firstIndex(ofPhrase: verbKeyword, in: answerWordsAfterFiller) }
            .min()
        let namesTheRequiredVerb = requiredVerbStartIndex != nil
        let startsWithTheRequiredVerb = requiredVerbStartIndex == 0

        if namesTheRequiredVerb && (startsWithAffirmative || startsWithTheRequiredVerb) {
            return .confirmed
        }
        if startsWithAffirmative {
            return .needsVerbRestatement
        }
        return .unrelated
    }
}
