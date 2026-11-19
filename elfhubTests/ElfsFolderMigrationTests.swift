//
//  ElfsFolderMigrationTests.swift
//  elfhubTests
//
//  elfhub 0.0.1 kept Elfs in Application Support/elfhub/Elves/; 0.0.2 moves
//  that folder to Elfs/ once, before the roster is read, so chats, change
//  history and tasks keep working.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfsFolderMigrationTests {

    private func makeTemporaryElfhubDataDirectory() -> (elfhubDataDirectory: URL, cleanUp: () -> Void) {
        let elfhubDataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elfhub-data-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: elfhubDataDirectory, withIntermediateDirectories: true)
        return (elfhubDataDirectory, { try? FileManager.default.removeItem(at: elfhubDataDirectory) })
    }

    private func writeOldMainElf(named elfName: String, in elvesDirectory: URL) throws -> ElfHome {
        let mainElfHome = ElfHome(directory: elvesDirectory.appendingPathComponent(ElfManager.mainElfIdentifier, isDirectory: true))
        try mainElfHome.createIfNeeded(configuration: ElfConfiguration(identity: .init(name: elfName)))
        return mainElfHome
    }

    @Test func aFreshInstallHasNothingToMove() {
        let (elfhubDataDirectory, cleanUp) = makeTemporaryElfhubDataDirectory()
        defer { cleanUp() }
        #expect(ElfsFolderMigration.moveLegacyElvesFolderIfNeeded(elfhubDataDirectory: elfhubDataDirectory) == .nothingToMove)
    }

    @Test func theOldElvesFolderBecomesElfsWithEverythingInside() throws {
        let (elfhubDataDirectory, cleanUp) = makeTemporaryElfhubDataDirectory()
        defer { cleanUp() }
        let elvesDirectory = elfhubDataDirectory.appendingPathComponent("Elves", isDirectory: true)
        let oldMainElfHome = try writeOldMainElf(named: "Juniper", in: elvesDirectory)
        try oldMainElfHome.writeUserNotes("likes tea")
        let changeLogFile = oldMainElfHome.appDataDirectory.appendingPathComponent("changes.jsonl")
        try Data("{\"path\":\"files/trip.md\"}\n".utf8).write(to: changeLogFile)

        #expect(ElfsFolderMigration.moveLegacyElvesFolderIfNeeded(elfhubDataDirectory: elfhubDataDirectory) == .moved)

        let elfsDirectory = elfhubDataDirectory.appendingPathComponent("Elfs", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: elvesDirectory.path))
        let movedMainElfHome = ElfHome(directory: elfsDirectory.appendingPathComponent(ElfManager.mainElfIdentifier, isDirectory: true))
        #expect(movedMainElfHome.readConfiguration().identity.name == "Juniper")
        #expect(movedMainElfHome.readUserNotes().contains("likes tea"))
        #expect(FileManager.default.fileExists(atPath: movedMainElfHome.appDataDirectory.appendingPathComponent("changes.jsonl").path))

        // Moving again finds nothing to do.
        #expect(ElfsFolderMigration.moveLegacyElvesFolderIfNeeded(elfhubDataDirectory: elfhubDataDirectory) == .nothingToMove)
    }

    @Test func whenBothFoldersExistElfsIsKeptAndElvesIsLeftAlone() throws {
        let (elfhubDataDirectory, cleanUp) = makeTemporaryElfhubDataDirectory()
        defer { cleanUp() }
        let elvesDirectory = elfhubDataDirectory.appendingPathComponent("Elves", isDirectory: true)
        let elfsDirectory = elfhubDataDirectory.appendingPathComponent("Elfs", isDirectory: true)
        _ = try writeOldMainElf(named: "Old", in: elvesDirectory)
        _ = try writeOldMainElf(named: "Current", in: elfsDirectory)

        #expect(ElfsFolderMigration.moveLegacyElvesFolderIfNeeded(elfhubDataDirectory: elfhubDataDirectory) == .keptBothFolders)
        #expect(FileManager.default.fileExists(atPath: elvesDirectory.path))
        let currentMainElfHome = ElfHome(directory: elfsDirectory.appendingPathComponent(ElfManager.mainElfIdentifier, isDirectory: true))
        #expect(currentMainElfHome.readConfiguration().identity.name == "Current")
    }

    @Test func theRosterMovesTheOldFolderBeforeItReads() throws {
        let (elfhubDataDirectory, cleanUp) = makeTemporaryElfhubDataDirectory()
        defer { cleanUp() }
        let elvesDirectory = elfhubDataDirectory.appendingPathComponent("Elves", isDirectory: true)
        _ = try writeOldMainElf(named: "Juniper", in: elvesDirectory)
        let sideElfHome = ElfHome(directory: elvesDirectory.appendingPathComponent("wren", isDirectory: true))
        try sideElfHome.createIfNeeded(configuration: ElfConfiguration(identity: .init(name: "Wren")))

        let elfManager = ElfManager(
            elfsDirectory: elfhubDataDirectory.appendingPathComponent("Elfs", isDirectory: true),
            deletedFolderDisposal: .removePermanently
        )

        #expect(elfManager.mainElf.configuration.identity.name == "Juniper")
        #expect(elfManager.elfs.map(\.id) == ["main", "wren"])
        #expect(!FileManager.default.fileExists(atPath: elvesDirectory.path))
    }

    @Test func aRosterOutsideAnElfsFolderNeverMovesItsSiblings() throws {
        let (elfhubDataDirectory, cleanUp) = makeTemporaryElfhubDataDirectory()
        defer { cleanUp() }
        let elvesDirectory = elfhubDataDirectory.appendingPathComponent("Elves", isDirectory: true)
        _ = try writeOldMainElf(named: "Juniper", in: elvesDirectory)

        _ = ElfManager(
            elfsDirectory: elfhubDataDirectory.appendingPathComponent("some-test-roster", isDirectory: true),
            deletedFolderDisposal: .removePermanently
        )

        #expect(FileManager.default.fileExists(atPath: elvesDirectory.path))
    }
}

@MainActor
struct UserNotesRenameTests {

    @Test func profileMdBecomesUserMdOnceWithItsNotes() throws {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try Data("# profile\n- likes tea\n".utf8).write(to: homeDirectory.appendingPathComponent("profile.md"))

        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()

        #expect(home.readUserNotes().contains("likes tea"))
        #expect(!FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent("profile.md").path))
        #expect(home.userNotesURL.lastPathComponent == "user.md")
    }

    @Test func aSideElfFrom001GetsItsProfileRenamedWhenTheRosterIsRead() throws {
        let elfsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elfs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elfsDirectory) }
        // A 0.0.1 side Elf: elf.json and profile.md, no user.md.
        let sideElfDirectory = elfsDirectory.appendingPathComponent("juniper", isDirectory: true)
        try FileManager.default.createDirectory(at: sideElfDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ElfConfiguration(identity: .init(name: "Juniper"))).write(to: sideElfDirectory.appendingPathComponent("elf.json"))
        try Data("# profile\n- likes tea\n".utf8).write(to: sideElfDirectory.appendingPathComponent("profile.md"))

        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        let sideElf = try #require(elfManager.elf(withIdentifier: "juniper"))
        #expect(sideElf.home.readUserNotes().contains("likes tea"))
        #expect(!FileManager.default.fileExists(atPath: sideElfDirectory.appendingPathComponent("profile.md").path))
    }

    @Test func aFreshUserMdHasTheTwoMemorySectionsAndCountsAsEmptyInThePrompt() {
        #expect(ElfHome.starterUserNotes.contains("## About you"))
        #expect(ElfHome.starterUserNotes.contains("## What we've talked about"))
        let promptContext = ElfPromptContext(
            elfName: "Juniper",
            soulText: ElfHome.starterSoul,
            profileText: ElfHome.starterUserNotes,
            behaviour: ElfConfiguration.Behaviour(),
            skills: []
        )
        #expect(promptContext.profileSection == nil)
    }

    @Test func aLegacyProfileFromA001ElfFileStillImportsAsUserMd() {
        #expect(ElfImportValidator.elfFolderTopLevelNames.contains("profile.md"))
        #expect(ElfImportValidator.elfFolderTopLevelNames.contains("user.md"))
    }
}
