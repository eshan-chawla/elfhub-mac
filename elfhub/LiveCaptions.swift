//
//  LiveCaptions.swift
//  elfhub
//
//  Live captions: the words an Elf is saying, shown on screen as it says
//  them. Off by default (Settings › Controls) — people who listen don't need
//  a transcript in front of them. When on, captions follow the voice, not
//  the model's stream: each sentence appears as it starts playing and its
//  words are revealed as they're spoken, so the text never runs ahead of
//  what's heard. When a reply isn't spoken at all (voice off), its text is
//  shown as it's written, whatever the setting, because nothing else would
//  tell the user the answer outside the chat window.
//
//  Everything here is pure and tested; LiveCaptionPanel draws it and
//  ScreenGuidanceOverlayModel owns the timing.
//

import Foundation

// MARK: - Setting

nonisolated enum LiveCaptionSettings {
    /// Off unless the user turns it on in Settings › Controls.
    static let isEnabledKey = "showsLiveCaptions"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: isEnabledKey)
    }

    /// Whether spoken words are captioned. Unspoken replies (voice off) are
    /// always shown and don't go through this.
    static func showsSpokenCaptions(isEnabled: Bool) -> Bool {
        isEnabled
    }
}

// MARK: - Playback progress

/// How far a voice has got through the sentence it's playing.
nonisolated enum SpeechPlaybackProgress: Equatable, Sendable {
    /// Apple's voice reports the exact characters it's about to say: the
    /// end of that range.
    case spokenThroughCharacterOffset(Int)
    /// Audio voices (network, on-device models) only know how much of the
    /// audio has played, 0…1.
    case playedFraction(Double)
}

// MARK: - Word timing

/// Turns playback progress into how much of a sentence to reveal. Always
/// ends on a word boundary, so a caption never shows half a word.
nonisolated enum SpokenWordTiming {

    static func revealedCharacterCount(inSentence sentence: String, progress: SpeechPlaybackProgress) -> Int {
        switch progress {
        case let .spokenThroughCharacterOffset(characterOffset):
            return wordEnd(atOrAfter: characterOffset, inSentence: sentence)
        case let .playedFraction(playedFraction):
            return revealedCharacterCount(inSentence: sentence, playedFraction: playedFraction)
        }
    }

    /// Spreads the audio over the words by their length: a word is shown once
    /// the audio reaches its start, weighted by the characters before it.
    /// Long words take longer to say, so this tracks speech better than an
    /// even split per word.
    static func revealedCharacterCount(inSentence sentence: String, playedFraction: Double) -> Int {
        let clampedFraction = min(max(playedFraction, 0), 1)
        let sentenceLength = sentence.count
        guard sentenceLength > 0 else { return 0 }
        if clampedFraction >= 1 { return sentenceLength }
        let wordRanges = self.wordRanges(inSentence: sentence)
        guard !wordRanges.isEmpty else { return sentenceLength }
        let spokenCharacterBudget = clampedFraction * Double(sentenceLength)
        var revealedCount = 0
        for wordRange in wordRanges where Double(wordRange.lowerBound) <= spokenCharacterBudget {
            revealedCount = wordRange.upperBound
        }
        return revealedCount
    }

    /// The end of the word that contains (or starts at) `characterOffset`.
    static func wordEnd(atOrAfter characterOffset: Int, inSentence sentence: String) -> Int {
        let sentenceLength = sentence.count
        guard characterOffset > 0 else { return 0 }
        guard characterOffset < sentenceLength else { return sentenceLength }
        for wordRange in wordRanges(inSentence: sentence) where wordRange.upperBound >= characterOffset {
            return wordRange.upperBound
        }
        return sentenceLength
    }

    /// Character ranges of the words (runs of non-whitespace), in characters.
    static func wordRanges(inSentence sentence: String) -> [Range<Int>] {
        var wordRanges: [Range<Int>] = []
        var currentWordStart: Int?
        for (characterIndex, character) in sentence.enumerated() {
            if character.isWhitespace {
                if let wordStart = currentWordStart {
                    wordRanges.append(wordStart..<characterIndex)
                    currentWordStart = nil
                }
            } else if currentWordStart == nil {
                currentWordStart = characterIndex
            }
        }
        if let wordStart = currentWordStart {
            wordRanges.append(wordStart..<sentence.count)
        }
        return wordRanges
    }
}

// MARK: - Transcript

/// What the caption panel shows: the sentences already said, and the part
/// of the current one said so far. Older text is dropped once there's more
/// than the panel could ever show; the panel itself fades the top lines.
nonisolated struct LiveCaptionTranscript: Equatable, Sendable {
    /// Text kept for the panel, oldest first.
    static let maximumKeptCharacterCount = 600

    private(set) var finishedSentences: [String] = []
    private(set) var currentSentence = ""
    private(set) var revealedCharacterCount = 0

    /// Everything to show, joined with spaces.
    var visibleText: String {
        let currentSentencePrefix = String(currentSentence.prefix(revealedCharacterCount))
        return (finishedSentences + [currentSentencePrefix])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEmpty: Bool { visibleText.isEmpty }

    /// The voice moved on in `sentence`. A new sentence finishes the previous
    /// one (shown whole); within a sentence the reveal only ever grows.
    mutating func advance(sentence: String, revealedCharacterCount newRevealedCharacterCount: Int) {
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentence.isEmpty else { return }
        if trimmedSentence != currentSentence {
            if !currentSentence.isEmpty {
                finishedSentences.append(currentSentence)
            }
            currentSentence = trimmedSentence
            revealedCharacterCount = 0
        }
        revealedCharacterCount = min(max(revealedCharacterCount, newRevealedCharacterCount), currentSentence.count)
        trimToMaximumLength()
    }

    /// A reply that isn't spoken: shown whole as it's written. Replaces what
    /// was there, since `text` is the reply so far.
    mutating func showUnspokenText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        finishedSentences = []
        currentSentence = String(trimmedText.suffix(Self.maximumKeptCharacterCount))
        revealedCharacterCount = currentSentence.count
    }

    private mutating func trimToMaximumLength() {
        while finishedSentences.count > 0,
              finishedSentences.joined(separator: " ").count + currentSentence.count > Self.maximumKeptCharacterCount {
            finishedSentences.removeFirst()
        }
    }
}
