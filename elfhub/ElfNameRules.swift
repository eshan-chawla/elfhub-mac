//
//  ElfNameRules.swift
//  elfhub
//
//  What makes a good elf name. Names are how the user reaches an elf by
//  voice ("Juniper, …") and how elfs are written into silent tags, so they
//  must be short, tellable apart when spoken (case and accents don't count),
//  free of tag characters, and not words that mean something else to
//  elfhub ("main", "everyone"). Also turns a name into the elf's folder id.
//

import Foundation

nonisolated enum ElfNameProblem: Equatable, Sendable {
    case empty
    case tooLong(characterLimit: Int)
    /// `[`, `]` and `:` would break the silent tags that name elfs.
    case containsTagCharacters
    case reservedWord(String)
    case duplicateOf(elfName: String)
    /// The name is the first word(s) of another elf's name ("Will" and
    /// "Will Smith"), so saying it out loud may reach either elf.
    case wholeWordPrefixOf(elfName: String)

    /// Warnings can be saved anyway; every other problem blocks the name.
    var isWarning: Bool {
        if case .wholeWordPrefixOf = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .empty:
            return "Give the Elf a name."
        case let .tooLong(characterLimit):
            return "Keep the name to \(characterLimit) characters or fewer."
        case .containsTagCharacters:
            return "Names can't contain [, ] or :."
        case let .reservedWord(reservedWord):
            return "\"\(reservedWord)\" means something else to elfhub. Pick another name."
        case let .duplicateOf(elfName):
            return "You already have an Elf called \(elfName)."
        case let .wholeWordPrefixOf(elfName):
            return "It's the start of \(elfName)'s name, so saying it out loud may reach either Elf."
        }
    }
}

nonisolated enum ElfNameRules {
    static let nameCharacterLimit = 32
    /// Other names an elf answers to ("June" for Juniper).
    static let maximumAliasCount = 5
    static let reservedNames: Set<String> = ["main", "elfhub", "all", "everyone", "me", "you"]
    private static let tagCharacters: Set<Character> = ["[", "]", ":"]

    /// Everything wrong with `proposedName`, compared against the names of
    /// the other elfs (leave out the elf being renamed). An empty name is
    /// reported alone.
    static func problems(forName proposedName: String, otherElfNames: [String]) -> [ElfNameProblem] {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return [.empty] }

        var problems: [ElfNameProblem] = []
        if trimmedName.count > nameCharacterLimit {
            problems.append(.tooLong(characterLimit: nameCharacterLimit))
        }
        if trimmedName.contains(where: { tagCharacters.contains($0) }) {
            problems.append(.containsTagCharacters)
        }

        let foldedName = foldedForComparison(trimmedName)
        if reservedNames.contains(foldedName) {
            problems.append(.reservedWord(foldedName))
        }

        if let duplicateElfName = otherElfNames.first(where: { foldedForComparison($0) == foldedName }) {
            problems.append(.duplicateOf(elfName: duplicateElfName))
        } else if let overlappingElfName = otherElfNames.first(where: {
            isWholeWordPrefix(foldedName, of: foldedForComparison($0)) || isWholeWordPrefix(foldedForComparison($0), of: foldedName)
        }) {
            problems.append(.wholeWordPrefixOf(elfName: overlappingElfName))
        }
        return problems
    }

    /// How two names are compared: trimmed, inner spaces collapsed, case and
    /// accents ignored ("  José  Luis" → "jose luis").
    static func foldedForComparison(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The new elf's folder id: its name as a slug ("Juniper" → "juniper";
    /// "elf" when nothing usable is left), counting up past ids in use
    /// ("juniper-2"), and never "main", which belongs to the main elf. Ids
    /// in use are compared ignoring case, as the Mac's disk compares folder
    /// names.
    static func uniqueIdentifier(forName name: String, existingIdentifiers: Set<String>) -> String {
        let baseIdentifier = ElfSkill.slug(forName: name, fallback: "elf")
        let identifiersInUse = Set(existingIdentifiers.map { $0.lowercased() }).union([ElfManager.mainElfIdentifier])
        if !identifiersInUse.contains(baseIdentifier) {
            return baseIdentifier
        }
        var suffixNumber = 2
        while identifiersInUse.contains("\(baseIdentifier)-\(suffixNumber)") {
            suffixNumber += 1
        }
        return "\(baseIdentifier)-\(suffixNumber)"
    }

    /// Every name the user could already say to reach an elf: each elf's
    /// name followed by its aliases, roster order, leaving out one elf (the
    /// one being renamed or given aliases; nil for a new elf).
    static func namesInUse(byElfs elfs: [Elf], excludingElfWithIdentifier excludedElfIdentifier: String?) -> [String] {
        elfs
            .filter { $0.id != excludedElfIdentifier }
            .flatMap { [$0.configuration.identity.name] + $0.configuration.identity.aliases }
    }

    /// Aliases as the user meant them: trimmed, empty ones dropped, and any
    /// that repeat the elf's own name or an earlier alias (ignoring case and
    /// accents) dropped, keeping the order.
    static func cleanedAliases(_ proposedAliases: [String], elfName: String) -> [String] {
        var foldedNamesSeen: Set<String> = [foldedForComparison(elfName)]
        var cleanedAliases: [String] = []
        for proposedAlias in proposedAliases {
            let trimmedAlias = proposedAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAlias.isEmpty else { continue }
            let foldedAlias = foldedForComparison(trimmedAlias)
            guard !foldedNamesSeen.contains(foldedAlias) else { continue }
            foldedNamesSeen.insert(foldedAlias)
            cleanedAliases.append(trimmedAlias)
        }
        return cleanedAliases
    }

    /// The one emoji an elf goes by: the first emoji of whatever was typed
    /// or pasted ("🧝‍♀️ Juniper" → "🧝‍♀️"), kept whole with its skin tone or
    /// joined parts, or nothing when the text doesn't start with one.
    /// Digits and "#" can be drawn as emoji but aren't on their own.
    static func normalizedEmoji(_ proposedEmoji: String) -> String {
        let trimmedText = proposedEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedText.first else { return "" }
        let unicodeScalars = firstCharacter.unicodeScalars
        let variationSelectorForEmoji: Unicode.Scalar = "\u{FE0F}"
        let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
        let startsWithEmojiPresentation = unicodeScalars.first?.properties.isEmojiPresentation ?? false
        // A selector or joiner only makes an emoji of something that can be
        // one ("☺️"), never of a letter ("A️").
        let firstScalarCanBeEmoji = unicodeScalars.first?.properties.isEmoji ?? false
        let asksForEmojiPresentation = firstScalarCanBeEmoji
            && (unicodeScalars.contains(variationSelectorForEmoji) || unicodeScalars.contains(zeroWidthJoiner))
        return startsWithEmojiPresentation || asksForEmojiPresentation ? String(firstCharacter) : ""
    }

    /// "will" is a whole-word prefix of "will smith"; "jun" isn't one of
    /// "juniper", and a name isn't a prefix of itself.
    private static func isWholeWordPrefix(_ shorterFoldedName: String, of longerFoldedName: String) -> Bool {
        let shorterNameWords = shorterFoldedName.split(separator: " ")
        let longerNameWords = longerFoldedName.split(separator: " ")
        guard !shorterNameWords.isEmpty, shorterNameWords.count < longerNameWords.count else { return false }
        return Array(longerNameWords.prefix(shorterNameWords.count)) == shorterNameWords
    }
}
