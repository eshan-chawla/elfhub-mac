//
//  ElfNameSuggestions.swift
//  elfhub
//
//  The names onboarding suggests for the main Elf, so nobody starts with a
//  blank field or the placeholder "elf". Every name here is short, easy for
//  speech recognition to hear, passes ElfNameRules, and isn't an everyday
//  word (ElfAddressRouter.everydayWordNames) — so "Juniper, open Safari"
//  reaches the Elf without needing a pause after its name.
//

import Foundation

nonisolated enum ElfNameSuggestions {
    static let names: [String] = [
        "Juniper", "Rowan", "Wren", "Juno", "Otto",
        "Nell", "Linden", "Briar", "Fennel", "Marlo",
    ]

    /// A first suggestion, chosen with `randomIndex` (pass a random number;
    /// tests pass a fixed one) and skipping names other Elfs already use.
    static func firstSuggestion(otherElfNames: [String], randomIndex: Int) -> String {
        let availableNames = names(notUsedBy: otherElfNames)
        guard !availableNames.isEmpty else { return names[0] }
        let wrappedIndex = ((randomIndex % availableNames.count) + availableNames.count) % availableNames.count
        return availableNames[wrappedIndex]
    }

    /// The next suggestion after `currentName` ("Suggest another"), cycling
    /// through the list and skipping names other Elfs already use. A name
    /// the user typed themselves starts the cycle from the top.
    static func suggestion(after currentName: String, otherElfNames: [String]) -> String {
        let availableNames = names(notUsedBy: otherElfNames)
        guard !availableNames.isEmpty else { return names[0] }
        let foldedCurrentName = ElfNameRules.foldedForComparison(currentName)
        guard let currentIndex = availableNames.firstIndex(where: { ElfNameRules.foldedForComparison($0) == foldedCurrentName }) else {
            return availableNames[0]
        }
        return availableNames[(currentIndex + 1) % availableNames.count]
    }

    private static func names(notUsedBy otherElfNames: [String]) -> [String] {
        let foldedOtherElfNames = Set(otherElfNames.map(ElfNameRules.foldedForComparison))
        return names.filter { !foldedOtherElfNames.contains(ElfNameRules.foldedForComparison($0)) }
    }
}
