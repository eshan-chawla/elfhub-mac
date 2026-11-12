//
//  SystemVoiceCatalogTests.swift
//  elfhubTests
//
//  The voice chooser's list: most natural voices first, novelty voices only
//  when asked for, one entry per name and region (the best install wins),
//  search, and the selected voice always listed. Built from fixed voice
//  options so the result never depends on what's installed on the test Mac.
//

import Testing
@testable import elfhub

@MainActor
struct SystemVoiceCatalogTests {

    private func voiceOption(
        _ identifier: String,
        _ voiceName: String,
        _ languageCode: String = "en-US",
        _ qualityTier: SystemVoiceOption.QualityTier = .standard,
        isNoveltyVoice: Bool = false
    ) -> SystemVoiceOption {
        SystemVoiceOption(
            identifier: identifier,
            voiceName: voiceName,
            languageCode: languageCode,
            qualityTier: qualityTier,
            isNoveltyVoice: isNoveltyVoice
        )
    }

    private func sections(
        _ voiceOptions: [SystemVoiceOption],
        includesNoveltyVoices: Bool = false,
        searchText: String = "",
        selectedVoiceIdentifier: String? = nil
    ) -> [SystemVoiceCatalog.Section] {
        SystemVoiceCatalog.sections(
            from: voiceOptions,
            languagePrefix: "en",
            includesNoveltyVoices: includesNoveltyVoices,
            searchText: searchText,
            selectedVoiceIdentifier: selectedVoiceIdentifier
        )
    }

    @Test func naturalVoicesComeFirstThenStandardAndNoveltyIsHidden() {
        let result = sections([
            voiceOption("standard.fred", "Fred"),
            voiceOption("premium.tara", "Tara", "en-IN", .premium),
            voiceOption("enhanced.aaron", "Aaron (Enhanced)", "en-US", .enhanced),
            voiceOption("novelty.bells", "Bells", isNoveltyVoice: true)
        ])
        #expect(result.map(\.title) == [SystemVoiceCatalog.mostNaturalSectionTitle, SystemVoiceCatalog.standardSectionTitle])
        #expect(result[0].voiceOptions.map(\.id) == ["premium.tara", "enhanced.aaron"])
        #expect(result[1].voiceOptions.map(\.id) == ["standard.fred"])
    }

    @Test func noveltyVoicesAppearInTheirOwnSectionWhenAskedFor() {
        let result = sections([
            voiceOption("standard.fred", "Fred"),
            voiceOption("novelty.bells", "Bells", isNoveltyVoice: true)
        ], includesNoveltyVoices: true)
        #expect(result.last?.title == SystemVoiceCatalog.noveltySectionTitle)
        #expect(result.last?.voiceOptions.map(\.id) == ["novelty.bells"])
    }

    @Test func onlyVoicesForTheUsersLanguageAreListed() {
        let result = sections([
            voiceOption("english", "Fred", "en-US"),
            voiceOption("german", "Anna", "de-DE")
        ])
        #expect(result.flatMap(\.voiceOptions).map(\.id) == ["english"])
    }

    @Test func theBestInstallOfAVoiceWinsAndRegionsStaySeparate() {
        let result = sections([
            voiceOption("com.apple.voice.Tara", "Tara", "en-IN", .standard),
            voiceOption("com.apple.voice.Tara.premium", "Tara", "en-IN", .premium),
            voiceOption("com.apple.voice.super-compact.en-US.Samantha", "Samantha"),
            voiceOption("com.apple.voice.compact.en-US.Samantha", "Samantha"),
            voiceOption("com.apple.eloquence.en-US.Shelley", "Shelley", "en-US"),
            voiceOption("com.apple.eloquence.en-GB.Shelley", "Shelley", "en-GB")
        ])
        let listedIdentifiers = result.flatMap(\.voiceOptions).map(\.id)
        #expect(listedIdentifiers == [
            "com.apple.voice.Tara.premium",
            "com.apple.voice.compact.en-US.Samantha",
            "com.apple.eloquence.en-GB.Shelley",
            "com.apple.eloquence.en-US.Shelley"
        ])
    }

    @Test func searchMatchesVoiceNames() {
        let result = sections([
            voiceOption("tara", "Tara", "en-IN", .premium),
            voiceOption("fred", "Fred")
        ], searchText: "  tar ")
        #expect(result.flatMap(\.voiceOptions).map(\.id) == ["tara"])
    }

    @Test func theSelectedVoiceIsAlwaysListed() {
        let selectedNoveltyVoice = voiceOption("novelty.bells", "Bells", isNoveltyVoice: true)
        let result = sections([voiceOption("fred", "Fred"), selectedNoveltyVoice], selectedVoiceIdentifier: "novelty.bells")
        #expect(result.flatMap(\.voiceOptions).map(\.id).contains("novelty.bells"))

        // Even when a better install of the same voice is the one shown.
        let result2 = sections([
            voiceOption("com.apple.voice.Tara", "Tara", "en-IN", .standard),
            voiceOption("com.apple.voice.Tara.premium", "Tara", "en-IN", .premium)
        ], selectedVoiceIdentifier: "com.apple.voice.Tara")
        #expect(Set(result2.flatMap(\.voiceOptions).map(\.id)) == ["com.apple.voice.Tara", "com.apple.voice.Tara.premium"])
    }

    @Test func displayNamesDropTheQualitySuffixAndNameSiriVoices() {
        #expect(SystemVoiceOption.displayName(forVoiceName: "Aaron (Enhanced)", identifier: "com.apple.ttsbundle.siri_Aaron_en-US_premium") == "Aaron")
        #expect(SystemVoiceOption.displayName(forVoiceName: "Zoe (Premium)", identifier: "com.apple.voice.premium.en-US.Zoe") == "Zoe")
        #expect(SystemVoiceOption.displayName(forVoiceName: "Voice 2", identifier: "com.apple.siri.natural.Simone") == "Siri Voice 2")
        #expect(SystemVoiceOption.displayName(forVoiceName: "Fred", identifier: "com.apple.speech.synthesis.voice.Fred") == "Fred")
    }

    @Test func qualityBadgesSkipStandardVoices() {
        #expect(SystemVoiceOption.QualityTier.premium.badgeLabel == "Premium")
        #expect(SystemVoiceOption.QualityTier.enhanced.badgeLabel == "Enhanced")
        #expect(SystemVoiceOption.QualityTier.standard.badgeLabel == nil)
    }
}
