//
//  ElfAddressRouter.swift
//  elfhub
//
//  Which elf the user is talking to, from what they said or typed. Calling
//  an elf by one of its names routes to it:
//
//    "Juniper, what's this?"         a leading name (with a comma, or an
//                                    uncommon name without one)
//    "hey Juniper …"                 hey + name
//    "ask Juniper to …", "tell …"    ask / tell + name
//    "what's this, Juniper?"         a trailing name after a comma
//    "Juniper"                       the name alone
//
//  Everything else stays with the main elf: a name mid-sentence ("I think
//  Juniper did it"), a possessive ("Juniper's notes"), and a name that's
//  also an everyday word ("Will", "Writer") said without a comma or "hey".
//  Case and accents don't matter, fillers before the name ("um, okay") are
//  skipped, and the longest name wins ("Will Smith" over "Will"). The main
//  elf's own names route to the main elf.
//

import Foundation

nonisolated struct ElfAddressRoute: Equatable, Sendable {
    let elfIdentifier: String
    /// What the user said to that elf, without its name.
    let textForElf: String
    /// The name as it was matched (folded).
    let matchedName: String
}

nonisolated enum ElfAddressRouter {
    static let fillerWords: Set<String> = ["um", "uh", "erm", "er", "ok", "okay", "so", "well", "oh", "hmm", "alright"]
    static let greetingWords: Set<String> = ["hey", "hi", "yo"]
    static let requestWords: Set<String> = ["ask", "tell"]

    /// Names that are also everyday words, so said without a comma or "hey"
    /// they're more likely part of the sentence ("will you…").
    static let everydayWordNames: Set<String> = [
        "will", "may", "june", "april", "august", "max", "rose", "grace", "hope", "joy", "faith", "ray",
        "mark", "bill", "sky", "river", "summer", "autumn", "iris", "ivy", "pat", "art", "frank", "dawn",
        "hunter", "chase", "sunny", "penny", "holly", "daisy", "echo", "nova", "sage", "scout", "buddy",
        "writer", "researcher", "helper", "assistant", "coach", "tutor", "editor", "scribe",
    ]

    /// Every elf's names and aliases, for the speech recognizer to listen
    /// for, main first.
    static func dictationKeyterms(for elves: [Elf]) -> [String] {
        elves.flatMap { [$0.configuration.identity.name] + $0.configuration.identity.aliases }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The elf `transcript` is addressed to, or nil for the main elf.
    static func route(transcript: String, elves: [Elf]) -> ElfAddressRoute? {
        let transcriptWords = words(in: transcript)
        guard !transcriptWords.isEmpty else { return nil }
        let candidateNames = candidateNames(for: elves)

        var startIndex = 0
        while startIndex < transcriptWords.count, fillerWords.contains(transcriptWords[startIndex].foldedText) {
            startIndex += 1
        }
        guard startIndex < transcriptWords.count else { return nil }
        let firstWord = transcriptWords[startIndex].foldedText

        // "hey Juniper …", "ask Juniper to …" (an optional "the" before role
        // names: "tell the writer …").
        if greetingWords.contains(firstWord) || requestWords.contains(firstWord) {
            var nameStartIndex = startIndex + 1
            if nameStartIndex < transcriptWords.count, transcriptWords[nameStartIndex].foldedText == "the" {
                nameStartIndex += 1
            }
            if let nameMatch = matchName(at: nameStartIndex, in: transcriptWords, candidateNames: candidateNames), !nameMatch.isPossessive {
                var textForElf = textAfter(wordIndex: nameMatch.lastWordIndex, in: transcriptWords, transcript: transcript)
                if requestWords.contains(firstWord), textForElf.lowercased().hasPrefix("to ") {
                    textForElf = String(textForElf.dropFirst(3))
                }
                return route(to: nameMatch.candidateName, textForElf: textForElf)
            }
        }

        // "Juniper, …" / "Juniper …" / "Juniper".
        if let nameMatch = matchName(at: startIndex, in: transcriptWords, candidateNames: candidateNames), !nameMatch.isPossessive {
            let isLastWord = nameMatch.lastWordIndex == transcriptWords.count - 1
            let separatorAfterName = transcriptWords[nameMatch.lastWordIndex].punctuationAfter
            let isFollowedByAPause = isLastWord || separatorAfterName.contains(",") || separatorAfterName.contains(":")
                || separatorAfterName.contains("!") || separatorAfterName.contains("?") || separatorAfterName.contains("—")
            if isFollowedByAPause || !nameMatch.candidateName.isEverydayWord {
                return route(
                    to: nameMatch.candidateName,
                    textForElf: textAfter(wordIndex: nameMatch.lastWordIndex, in: transcriptWords, transcript: transcript)
                )
            }
            if nameMatch.candidateName.elfIdentifier == ElfManager.mainElfIdentifier { return nil }
        }

        // "…, Juniper?"
        for candidateName in candidateNames {
            let nameWordCount = candidateName.foldedWords.count
            let nameStartIndex = transcriptWords.count - nameWordCount
            guard nameStartIndex > startIndex,
                  let nameMatch = matchName(at: nameStartIndex, in: transcriptWords, candidateNames: [candidateName]),
                  !nameMatch.isPossessive,
                  transcriptWords[nameStartIndex - 1].punctuationAfter.contains(",") else { continue }
            let textBeforeName = String(transcript[..<transcriptWords[nameStartIndex - 1].range.upperBound])
            let closingPunctuation = transcriptWords[transcriptWords.count - 1].punctuationAfter
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return route(to: candidateName, textForElf: textBeforeName + closingPunctuation)
        }
        return nil
    }

    // MARK: Matching

    struct CandidateName: Sendable {
        let elfIdentifier: String
        let foldedName: String
        let foldedWords: [String]
        let isEverydayWord: Bool
    }

    struct TranscriptWord: Sendable {
        let range: Range<String.Index>
        let foldedText: String
        /// The punctuation (and spaces) between this word and the next.
        let punctuationAfter: String
    }

    private struct NameMatch {
        let candidateName: CandidateName
        let lastWordIndex: Int
        let isPossessive: Bool
    }

    /// Every name and alias of every elf, longest first.
    private static func candidateNames(for elves: [Elf]) -> [CandidateName] {
        elves.flatMap { elf -> [CandidateName] in
            ([elf.configuration.identity.name] + elf.configuration.identity.aliases).compactMap { name in
                let foldedName = ElfNameRules.foldedForComparison(name)
                let foldedWords = foldedName.split(separator: " ").map(String.init)
                guard !foldedWords.isEmpty else { return nil }
                return CandidateName(
                    elfIdentifier: elf.id,
                    foldedName: foldedName,
                    foldedWords: foldedWords,
                    isEverydayWord: foldedWords.count == 1 && everydayWordNames.contains(foldedName)
                )
            }
        }
        .sorted { $0.foldedWords.count > $1.foldedWords.count }
    }

    private static func matchName(at wordIndex: Int, in transcriptWords: [TranscriptWord], candidateNames: [CandidateName]) -> NameMatch? {
        for candidateName in candidateNames {
            let nameWordCount = candidateName.foldedWords.count
            guard wordIndex >= 0, wordIndex + nameWordCount <= transcriptWords.count else { continue }
            var isPossessive = false
            var allWordsMatch = true
            for (offset, nameWord) in candidateName.foldedWords.enumerated() {
                var transcriptWord = transcriptWords[wordIndex + offset].foldedText
                let isLastNameWord = offset == nameWordCount - 1
                if isLastNameWord, transcriptWord.hasSuffix("'s"), transcriptWord != nameWord {
                    transcriptWord = String(transcriptWord.dropLast(2))
                    isPossessive = true
                }
                if transcriptWord != nameWord {
                    allWordsMatch = false
                    break
                }
            }
            if allWordsMatch {
                return NameMatch(candidateName: candidateName, lastWordIndex: wordIndex + nameWordCount - 1, isPossessive: isPossessive)
            }
        }
        return nil
    }

    private static func route(to candidateName: CandidateName, textForElf: String) -> ElfAddressRoute? {
        guard candidateName.elfIdentifier != ElfManager.mainElfIdentifier else { return nil }
        return ElfAddressRoute(
            elfIdentifier: candidateName.elfIdentifier,
            textForElf: textForElf.trimmingCharacters(in: .whitespacesAndNewlines),
            matchedName: candidateName.foldedName
        )
    }

    /// The transcript after a word and its punctuation.
    private static func textAfter(wordIndex: Int, in transcriptWords: [TranscriptWord], transcript: String) -> String {
        let textAfterWord = transcript[transcriptWords[wordIndex].range.upperBound...]
        return String(textAfterWord.drop { character in
            character.isWhitespace || ",:;.!?—-".contains(character)
        })
    }

    /// The transcript's words with where they are and what follows them.
    static func words(in transcript: String) -> [TranscriptWord] {
        let normalizedTranscript = transcript
        guard let wordPattern = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#) else { return [] }
        let wordMatches = wordPattern.matches(in: normalizedTranscript, range: NSRange(normalizedTranscript.startIndex..., in: normalizedTranscript))
        var transcriptWords: [TranscriptWord] = []
        for (matchIndex, wordMatch) in wordMatches.enumerated() {
            guard let wordRange = Range(wordMatch.range, in: normalizedTranscript) else { continue }
            let nextWordStart = matchIndex + 1 < wordMatches.count
                ? Range(wordMatches[matchIndex + 1].range, in: normalizedTranscript)?.lowerBound ?? normalizedTranscript.endIndex
                : normalizedTranscript.endIndex
            let foldedText = ElfNameRules.foldedForComparison(String(normalizedTranscript[wordRange]))
                .replacingOccurrences(of: "’", with: "'")
            transcriptWords.append(TranscriptWord(
                range: wordRange,
                foldedText: foldedText,
                punctuationAfter: String(normalizedTranscript[wordRange.upperBound..<nextWordStart])
            ))
        }
        return transcriptWords
    }
}
