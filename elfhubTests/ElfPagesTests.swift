//
//  ElfPagesTests.swift
//  elfhubTests
//
//  The Elf pages' data: the files an Elf's Work view lists (never the app's
//  own data, never outside its folder), how user.md is split into the
//  memory sections, and which tasks the main Elf handed out.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfPagesTests {

    private func makeHome() throws -> (ElfHome, () -> Void) {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-pages-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()
        return (home, { try? FileManager.default.removeItem(at: homeDirectory) })
    }

    @Test func theFilesListShowsTheElfsFilesButNeverTheAppsDataOrLinksOut() throws {
        let (home, cleanUp) = try makeHome()
        defer { cleanUp() }
        let outsideDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outsideDirectory.appendingPathComponent("secret.txt"))

        try FileManager.default.createDirectory(at: home.filesDirectory.appendingPathComponent("trips"), withIntermediateDirectories: true)
        try Data("rome".utf8).write(to: home.filesDirectory.appendingPathComponent("trips/rome.md"))
        try Data("notes".utf8).write(to: home.filesDirectory.appendingPathComponent("notes.md"))
        try Data("{}".utf8).write(to: home.appDataDirectory.appendingPathComponent("changes.jsonl"))
        try FileManager.default.createSymbolicLink(at: home.filesDirectory.appendingPathComponent("outside"), withDestinationURL: outsideDirectory)

        let listedPaths = home.fileEntries().map(\.path)
        #expect(listedPaths.contains("user.md"))
        #expect(listedPaths.contains("soul.md"))
        #expect(listedPaths.contains("files/notes.md"))
        #expect(listedPaths.contains("files/trips/rome.md"))
        #expect(!listedPaths.contains { $0.hasPrefix(".elfhub") || $0 == "elf.json" || $0 == "access.json" })
        #expect(!listedPaths.contains { $0.contains("secret") })

        let folderGroups = ElfFileEntry.groupedByFolder(home.fileEntries())
        #expect(folderGroups.first?.folderPath == "", "the Elf's own top-level files come first")
        #expect(folderGroups.map(\.folderPath).contains("files/trips"))
    }

    @Test func userMdSplitsIntoTheMemorySections() {
        let sections = UserNotesSections(userNotesText: """
        # user
        ## About you
        - works on elfhub
        - likes short answers
        ## What we've talked about
        - 2026-11-16: renaming files
        ## Projects
        - the Mac app
        """)
        #expect(sections.aboutYouLines == ["works on elfhub", "likes short answers"])
        #expect(sections.talkedAboutLines == ["2026-11-16: renaming files"])
        #expect(sections.otherLines == ["the Mac app"])
        #expect(UserNotesSections(userNotesText: ElfHome.starterUserNotes) == UserNotesSections(userNotesText: ""))
    }

    @Test func olderTaskFilesWereNotHandedOutByTheMainElf() throws {
        let olderTaskJSON = #"{"id":"6E3E3C8A-6D0B-4C8B-9D2C-6A0D1D7A9F10","elfIdentifier":"wren","instruction":"research"}"#
        let olderTask = try JSONDecoder().decode(ElfTask.self, from: Data(olderTaskJSON.utf8))
        #expect(!olderTask.wasAssignedByMainElf)
        let roundTripped = try JSONDecoder().decode(ElfTask.self, from: JSONEncoder().encode(ElfTask(elfIdentifier: "wren", instruction: "x", wasAssignedByMainElf: true)))
        #expect(roundTripped.wasAssignedByMainElf)
    }
}
