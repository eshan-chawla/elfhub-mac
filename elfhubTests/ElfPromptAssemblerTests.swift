//
//  ElfPromptAssemblerTests.swift
//  elfhubTests
//
//  The order and content of the elf's part of the prompt, per role: the
//  main elf (the manager), a side elf the user called by name, and an elf
//  working on a task in the background.
//

import Foundation
import Testing
@testable import elfhub

struct ElfPromptAssemblerTests {

    private func promptText(role: ElfPromptRole, ownNotePaths: [String] = [], roster: [ElfRosterEntry] = []) -> String {
        var elfPromptContext = ElfPromptContext.starter
        elfPromptContext.elfName = "Juniper"
        return ElfPromptAssembler.elfSections(
            role: role,
            context: elfPromptContext,
            ownNotePaths: ownNotePaths,
            roster: roster
        ).joined(separator: "\n\n")
    }

    private let researcherRosterEntry = ElfRosterEntry(
        name: "Researcher",
        emoji: "🔎",
        description: "looks things up",
        topSkillNames: ["Flights"],
        canWorkInBackground: true
    )

    @Test func mainIsToldItIsTheManager() {
        let mainPromptText = promptText(role: .mainForeground)
        #expect(mainPromptText.hasPrefix("you're Juniper, the user's main elf and manager of their elves"))
    }

    @Test func aSideElfAndAWorkerAreToldWhoTheyAre() {
        #expect(promptText(role: .sideElfForeground).hasPrefix("you're Juniper, one of the user's elves"))
        let workerPromptText = promptText(role: .backgroundWorker(taskInstruction: "find flights to Lisbon"))
        #expect(workerPromptText.hasPrefix("you're Juniper, one of the user's elves, working in the background"))
        #expect(workerPromptText.contains("find flights to Lisbon"))
    }

    @Test func theSafetyRuleComesAfterEverythingTheUserCanEdit() {
        let mainPromptText = promptText(role: .mainForeground, ownNotePaths: ["files/trip.md"], roster: [researcherRosterEntry])
        let safetyRuleRange = mainPromptText.range(of: ElfPromptContext.screenContentSafetyRule)
        let soulRange = mainPromptText.range(of: "your soul")
        let notesRange = mainPromptText.range(of: "files/trip.md")
        let rosterRange = mainPromptText.range(of: "Researcher")
        let writingRulesRange = mainPromptText.range(of: ElfPromptContext.writingRules)
        #expect(safetyRuleRange != nil)
        #expect(soulRange!.lowerBound < notesRange!.lowerBound)
        #expect(notesRange!.lowerBound < rosterRange!.lowerBound)
        #expect(rosterRange!.lowerBound < writingRulesRange!.lowerBound)
        #expect(writingRulesRange!.lowerBound < safetyRuleRange!.lowerBound)
        #expect(mainPromptText.hasSuffix(ElfPromptContext.screenContentSafetyRule))
    }

    @Test func ownNotesIndexIsCapped() {
        let sixtyNotePaths = (1...60).map { noteNumber in "files/note-\(noteNumber).md" }
        let mainPromptText = promptText(role: .mainForeground, ownNotePaths: sixtyNotePaths)
        #expect(mainPromptText.contains("- files/note-50.md"))
        #expect(!mainPromptText.contains("- files/note-51.md"))
        #expect(mainPromptText.contains("(10 more)"))
    }

    @Test func rosterOnlyGoesToMain() {
        #expect(promptText(role: .mainForeground, roster: [researcherRosterEntry]).contains("🔎 Researcher: looks things up"))
        #expect(!promptText(role: .sideElfForeground, roster: [researcherRosterEntry]).contains("Researcher"))
        #expect(!promptText(role: .mainForeground).contains("your elves"))
    }

    @Test func writingRulesAreAlwaysPresent() {
        #expect(promptText(role: .mainForeground).contains(ElfPromptContext.writingRules))
        #expect(promptText(role: .sideElfForeground).contains(ElfPromptContext.writingRules))
        #expect(promptText(role: .backgroundWorker(taskInstruction: "x")).contains(ElfPromptContext.writingRules))
    }

    @Test func theElfsOwnFilesAreListedNewestFirst() throws {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()
        let olderNoteURL = home.filesDirectory.appendingPathComponent("older.md")
        let newerNoteURL = home.filesDirectory.appendingPathComponent("trips/newer.md")
        try FileManager.default.createDirectory(at: newerNoteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: olderNoteURL)
        try Data("b".utf8).write(to: newerNoteURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: olderNoteURL.path)
        try Data("hidden".utf8).write(to: home.filesDirectory.appendingPathComponent(".DS_Store"))
        #expect(home.ownNotePaths() == ["files/trips/newer.md", "files/older.md"])
        #expect(ElfPromptContext.reading(home: home).ownNotePaths == ["files/trips/newer.md", "files/older.md"])
    }

    @Test func elvesAreToldWhatBracketedNamesInTheHistoryMean() {
        #expect(promptText(role: .mainForeground).contains("never start your reply with a name in brackets"))
        #expect(promptText(role: .sideElfForeground).contains("never start your reply with a name in brackets"))
    }
}
