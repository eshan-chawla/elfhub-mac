//
//  SideElfTurnTests.swift
//  elfhubTests
//
//  A side elf called by name answers the turn itself: with its own folder,
//  its own role and round cap, and a shorter history in which other
//  speakers' replies are marked with their names.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct SideElfTurnTests {

    private func elf(_ elfIdentifier: String, _ name: String) -> Elf {
        Elf(
            id: elfIdentifier,
            home: ElfHome(directory: URL(fileURLWithPath: "/tmp/side-elf-turn-tests/\(elfIdentifier)")),
            configuration: ElfConfiguration(identity: .init(name: name))
        )
    }

    private func historyTurns(count: Int, speakingElfName: (Int) -> String?) -> [LanguageModelHistoryTurn] {
        (1...count).map { turnNumber in
            LanguageModelHistoryTurn(
                userText: "question \(turnNumber)",
                assistantText: "answer \(turnNumber)",
                speakingElfName: speakingElfName(turnNumber)
            )
        }
    }

    @Test func aSideElfSeesOtherSpeakersPrefixed() {
        let storedHistory = historyTurns(count: 3) { turnNumber in turnNumber == 2 ? "Juniper" : nil }
        let juniperHistory = CompanionTurnPipeline.historyTurns(forSpeakingElfName: "Juniper", mainElfName: "Pip", from: storedHistory)
        #expect(juniperHistory.map(\.assistantText) == ["[Pip] answer 1", "answer 2", "[Pip] answer 3"])
        let mainHistory = CompanionTurnPipeline.historyTurns(forSpeakingElfName: nil, mainElfName: "Pip", from: storedHistory)
        #expect(mainHistory.map(\.assistantText) == ["answer 1", "[Juniper] answer 2", "answer 3"])
    }

    @Test func aSideElfGetsSixExchangesAndMainTen() {
        let storedHistory = historyTurns(count: 12) { _ in nil }
        #expect(CompanionTurnPipeline.historyTurns(forSpeakingElfName: "Juniper", mainElfName: "Pip", from: storedHistory).count == 6)
        #expect(CompanionTurnPipeline.historyTurns(forSpeakingElfName: nil, mainElfName: "Pip", from: storedHistory).count == 10)
        #expect(CompanionTurnPipeline.historyTurns(forSpeakingElfName: "Juniper", mainElfName: "Pip", from: storedHistory).first?.userText == "question 7")
    }

    @Test func aSideElfWorksInItsOwnFolderWithItsOwnRoleAndRounds() {
        let mainElf = elf("main", "Pip")
        let juniper = elf("juniper", "Juniper")
        let sideElfTurnSetup = CompanionTurnPipeline.elfTurnSetup(speakingElf: juniper, mainElf: mainElf)
        #expect(sideElfTurnSetup.elf?.id == "juniper")
        #expect(sideElfTurnSetup.role == .sideElfForeground)
        #expect(sideElfTurnSetup.maximumModelRounds == 4)
        let mainTurnSetup = CompanionTurnPipeline.elfTurnSetup(speakingElf: nil, mainElf: mainElf)
        #expect(mainTurnSetup.elf?.id == "main")
        #expect(mainTurnSetup.role == .mainForeground)
        #expect(mainTurnSetup.maximumModelRounds == 3)
        #expect(CompanionTurnPipeline.elfTurnSetup(speakingElf: mainElf, mainElf: mainElf).role == .mainForeground)
    }
}
