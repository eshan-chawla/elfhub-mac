//
//  ElfNamingPrompt.swift
//  elfhub
//
//  Naming the main elf. New users name it in onboarding; people who
//  finished onboarding before that step existed, and still have an elf
//  called "elf", get a one-time card above the chat. Also the sentence the
//  voice preview speaks, which introduces the elf by its name.
//

import Foundation

nonisolated enum ElfNamingPrompt {
    static let offeredDefaultsKey = "hasOfferedMainElfNaming"

    /// True once: after onboarding, while the main elf still has the name a
    /// new elf starts with, until the card was answered (or onboarding
    /// already asked).
    static func shouldOffer(hasCompletedOnboarding: Bool, mainElfName: String, wasOffered: Bool) -> Bool {
        guard hasCompletedOnboarding, !wasOffered else { return false }
        return ElfNameRules.foldedForComparison(mainElfName) == ElfNameRules.foldedForComparison(ElfConfiguration.Identity().name)
    }

    static func markOffered(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: offeredDefaultsKey)
    }

    static func wasOffered(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: offeredDefaultsKey)
    }
}

nonisolated enum ElfVoicePreview {
    /// What the voice preview says, in the elf's own name.
    static func sentence(forElfName elfName: String) -> String {
        let trimmedName = elfName.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenName = trimmedName.isEmpty ? ElfConfiguration.Identity().name : trimmedName
        return "Hi, I'm \(spokenName). This is how I'll sound."
    }
}
