//
//  OnboardingV2Tests.swift
//  elfhubTests
//
//  The 0.0.2 onboarding: the main Elf starts with a suggested name instead
//  of "elf", and the natural voice is offered, downloaded and switched to
//  only by the rules the user agreed to.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct OnboardingV2Tests {

    // MARK: - Name suggestions

    @Test func everySuggestedNamePassesTheNameRulesAndRoutesWithoutAPause() {
        let starterElfNames = ElfStarterTemplate.allCases.map(\.identity.name)
        for suggestedName in ElfNameSuggestions.names {
            #expect(ElfNameRules.problems(forName: suggestedName, otherElfNames: starterElfNames).isEmpty, "\(suggestedName) passes the name rules")
            #expect(!ElfAddressRouter.everydayWordNames.contains(ElfNameRules.foldedForComparison(suggestedName)), "\(suggestedName) isn't an everyday word")
            #expect(ElfNameRules.foldedForComparison(suggestedName) != ElfNameRules.foldedForComparison(ElfConfiguration.Identity().name))
        }
        #expect(Set(ElfNameSuggestions.names.map(ElfNameRules.foldedForComparison)).count == ElfNameSuggestions.names.count)
    }

    @Test func aSuggestedNameReachesItsElfWhenSpokenFirst() throws {
        for suggestedName in ElfNameSuggestions.names {
            let sideElf = Elf(
                id: suggestedName.lowercased(),
                home: ElfHome(directory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(suggestedName)")),
                configuration: ElfConfiguration(identity: .init(name: suggestedName))
            )
            let mainElf = Elf(
                id: ElfManager.mainElfIdentifier,
                home: ElfHome(directory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-main")),
                configuration: ElfConfiguration(identity: .init(name: "Otherone"))
            )
            let route = ElfAddressRouter.route(transcript: "\(suggestedName) open my calendar", elfs: [mainElf, sideElf])
            #expect(route?.elfIdentifier == sideElf.id, "\(suggestedName) is heard as a name without a pause")
        }
    }

    @Test func theFirstSuggestionSkipsNamesOtherElfsUse() {
        let otherElfNames = ElfNameSuggestions.names.dropLast().map { $0 }
        #expect(ElfNameSuggestions.firstSuggestion(otherElfNames: otherElfNames, randomIndex: 3) == ElfNameSuggestions.names.last)
        #expect(ElfNameSuggestions.firstSuggestion(otherElfNames: [], randomIndex: -1) == ElfNameSuggestions.names.last)
        #expect(ElfNameSuggestions.firstSuggestion(otherElfNames: [], randomIndex: 0) == ElfNameSuggestions.names[0])
    }

    @Test func suggestAnotherCyclesAndStartsOverAfterATypedName() {
        let names = ElfNameSuggestions.names
        #expect(ElfNameSuggestions.suggestion(after: names[0], otherElfNames: []) == names[1])
        #expect(ElfNameSuggestions.suggestion(after: names[names.count - 1], otherElfNames: []) == names[0])
        #expect(ElfNameSuggestions.suggestion(after: "Bartholomew", otherElfNames: []) == names[0])
        #expect(ElfNameSuggestions.suggestion(after: names[0].uppercased(), otherElfNames: []) == names[1])
        #expect(ElfNameSuggestions.suggestion(after: names[0], otherElfNames: [names[1]]) == names[2])
    }

    // MARK: - Natural voice

    @Test func theNaturalVoiceIsKokoroFromTheCatalogWithItsFeaturedVoices() throws {
        let naturalVoiceModel = try #require(OnboardingNaturalVoice.recommendedModel)
        #expect(naturalVoiceModel.kind == .textToSpeech)
        #expect(naturalVoiceModel.approximateDownloadSizeInGigabytes < 1)
        #expect(OnboardingNaturalVoice.defaultVoiceIdentifier == "af_heart")
        #expect(OnboardingNaturalVoice.featuredVoices.allSatisfy { $0.displayName.contains("·") })
    }

    @Test func theDownloadIsOfferedOnlyWhileRepliesUseApplesVoice() {
        let kokoro = OnboardingNaturalVoice.modelIdentifier
        #expect(OnboardingNaturalVoice.shouldOfferDownload(currentSpeechOutputMode: .system, activeTextToSpeechModelIdentifier: nil, installedModelIdentifiers: []))
        #expect(!OnboardingNaturalVoice.shouldOfferDownload(currentSpeechOutputMode: .onDeviceModel, activeTextToSpeechModelIdentifier: kokoro, installedModelIdentifiers: [kokoro]))
        #expect(!OnboardingNaturalVoice.shouldOfferDownload(currentSpeechOutputMode: .elevenLabs, activeTextToSpeechModelIdentifier: nil, installedModelIdentifiers: []))
        #expect(!OnboardingNaturalVoice.shouldOfferDownload(currentSpeechOutputMode: .off, activeTextToSpeechModelIdentifier: nil, installedModelIdentifiers: []))
    }

    @Test func aFinishedDownloadBecomesTheVoiceOnlyIfTheUserDidntChangeIt() {
        #expect(OnboardingNaturalVoice.shouldSwitchToDownloadedVoice(currentSpeechOutputMode: .system, speechOutputModeWhenDownloadStarted: .system))
        #expect(!OnboardingNaturalVoice.shouldSwitchToDownloadedVoice(currentSpeechOutputMode: .elevenLabs, speechOutputModeWhenDownloadStarted: .system))
        #expect(!OnboardingNaturalVoice.shouldSwitchToDownloadedVoice(currentSpeechOutputMode: .off, speechOutputModeWhenDownloadStarted: .off))
    }

    @Test func featuredKokoroVoicesComeFirstThenTheRestAlphabetically() {
        let ordered = OnDeviceVoiceModelCatalog.orderedWithFeaturedVoicesFirst(
            ["zf_xiaoyi", "bm_george", "af_heart", "am_adam"],
            repositoryIdentifier: OnboardingNaturalVoice.modelIdentifier
        )
        #expect(ordered == ["af_heart", "bm_george", "am_adam", "zf_xiaoyi"])
        #expect(OnDeviceVoiceModelCatalog.orderedWithFeaturedVoicesFirst(["b", "a"], repositoryIdentifier: "someone/other") == ["a", "b"])
        #expect(OnboardingNaturalVoice.featuredVoices.map(\.id) == OnDeviceVoiceModelCatalog.featuredVoiceIdentifiers(forModelIdentifier: OnboardingNaturalVoice.modelIdentifier))
    }
}
