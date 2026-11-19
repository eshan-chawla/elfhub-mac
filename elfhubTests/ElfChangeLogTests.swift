//
//  ElfChangeLogTests.swift
//  elfhubTests
//
//  Every write an elf makes in its folder is recorded with a backup so it
//  can be undone — refused when the file changed since, unless forced —
//  and an undo can itself be undone. The log prunes itself and lives where
//  elf tools can't reach it.
//

import Foundation
import Testing
@testable import elfhub

struct ElfChangeLogTests {

    private func makeTemporaryHome() throws -> (home: ElfHome, changeLog: ElfChangeLog, cleanUp: () -> Void) {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()
        return (home, ElfChangeLog(home: home), { try? FileManager.default.removeItem(at: homeDirectory) })
    }

    private func text(at relativePath: String, in home: ElfHome) -> String? {
        try? String(contentsOf: home.directory.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func undoingACreateDeletesTheFile() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let createEntry = try changeLog.recordWrite(path: "files/trip.md", newText: "lisbon", origin: .hub, influencedBy: [])
        #expect(createEntry.operation == .create)
        #expect(text(at: "files/trip.md", in: home) == "lisbon")
        try changeLog.undo(entryIdentifier: createEntry.id, force: false)
        #expect(text(at: "files/trip.md", in: home) == nil)
    }

    @Test func undoingAModifyRestoresThePreviousText() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "files/trip.md", newText: "lisbon", origin: .hub, influencedBy: [])
        let modifyEntry = try changeLog.recordWrite(path: "files/trip.md", newText: "porto", origin: .hub, influencedBy: [])
        #expect(modifyEntry.operation == .modify)
        try changeLog.undo(entryIdentifier: modifyEntry.id, force: false)
        #expect(text(at: "files/trip.md", in: home) == "lisbon")
    }

    @Test func undoingADeleteRestoresTheFile() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "user.md", newText: "# user\n\n- metric", origin: .hub, influencedBy: [])
        let deleteEntry = try changeLog.recordDelete(path: "user.md", origin: .hub, influencedBy: [])
        #expect(text(at: "user.md", in: home) == nil)
        try changeLog.undo(entryIdentifier: deleteEntry.id, force: false)
        #expect(text(at: "user.md", in: home) == "# user\n\n- metric")
    }

    @Test func undoingARenameMovesItBack() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "files/a.md", newText: "x", origin: .hub, influencedBy: [])
        let renameEntry = try changeLog.recordRename(from: "files/a.md", to: "files/old/b.md", origin: .hub, influencedBy: [])
        #expect(text(at: "files/old/b.md", in: home) == "x")
        try changeLog.undo(entryIdentifier: renameEntry.id, force: false)
        #expect(text(at: "files/a.md", in: home) == "x")
        #expect(text(at: "files/old/b.md", in: home) == nil)
    }

    @Test func undoIsRefusedWhenTheFileChangedSince() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let createEntry = try changeLog.recordWrite(path: "files/trip.md", newText: "lisbon", origin: .hub, influencedBy: [])
        try Data("edited by hand".utf8).write(to: home.directory.appendingPathComponent("files/trip.md"))
        #expect(throws: ElfChangeLogError.fileChangedSinceThisChange(path: "files/trip.md")) {
            try changeLog.undo(entryIdentifier: createEntry.id, force: false)
        }
        #expect(text(at: "files/trip.md", in: home) == "edited by hand")
    }

    @Test func forceUndoesAnyway() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "files/trip.md", newText: "lisbon", origin: .hub, influencedBy: [])
        let modifyEntry = try changeLog.recordWrite(path: "files/trip.md", newText: "porto", origin: .hub, influencedBy: [])
        try Data("edited by hand".utf8).write(to: home.directory.appendingPathComponent("files/trip.md"))
        try changeLog.undo(entryIdentifier: modifyEntry.id, force: true)
        #expect(text(at: "files/trip.md", in: home) == "lisbon")
    }

    @Test func anUndoneChangeCannotBeUndoneTwice() throws {
        let (_, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let createEntry = try changeLog.recordWrite(path: "files/trip.md", newText: "lisbon", origin: .hub, influencedBy: [])
        try changeLog.undo(entryIdentifier: createEntry.id, force: false)
        #expect(throws: ElfChangeLogError.alreadyUndone) {
            try changeLog.undo(entryIdentifier: createEntry.id, force: false)
        }
        #expect(throws: ElfChangeLogError.unknownEntry) {
            try changeLog.undo(entryIdentifier: UUID(), force: false)
        }
    }

    @Test func undoingAnUndoRedoesTheChange() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "files/trip.md", newText: "lisbon", origin: .hub, influencedBy: [])
        let modifyEntry = try changeLog.recordWrite(path: "files/trip.md", newText: "porto", origin: .hub, influencedBy: [])
        let revertEntry = try changeLog.undo(entryIdentifier: modifyEntry.id, force: false)
        #expect(revertEntry.operation == .revert)
        #expect(revertEntry.revertsEntryIdentifier == modifyEntry.id)
        #expect(changeLog.entries().first { $0.id == modifyEntry.id }?.revertedByEntryIdentifier == revertEntry.id)
        try changeLog.undo(entryIdentifier: revertEntry.id, force: false)
        #expect(text(at: "files/trip.md", in: home) == "porto")
    }

    @Test func entriesAreNewestFirstAndKeepTheirOriginAndInfluence() throws {
        let (_, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let conversationIdentifier = UUID()
        try changeLog.recordWrite(path: "files/a.md", newText: "a", origin: .turn(conversationIdentifier: conversationIdentifier), influencedBy: [])
        try changeLog.recordWrite(path: "files/b.md", newText: "b", origin: .hub, influencedBy: [.web, .file])
        let entries = changeLog.entries()
        #expect(entries.map(\.path) == ["files/b.md", "files/a.md"])
        #expect(entries.first?.influencedBy == [.web, .file])
        #expect(entries.last?.origin == .turn(conversationIdentifier: conversationIdentifier))
    }

    @Test func pruneKeeps500EntriesAnd30Days() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        for writeNumber in 1...510 {
            try changeLog.recordWrite(path: "files/n.md", newText: "\(writeNumber)", origin: .hub, influencedBy: [])
        }
        try changeLog.prune(now: Date())
        #expect(changeLog.entries().count == 500)
        try changeLog.prune(now: Date(timeIntervalSinceNow: 31 * 24 * 3600))
        #expect(changeLog.entries().isEmpty)
        let backupFileNames = try FileManager.default.contentsOfDirectory(atPath: changeLog.backupsDirectory.path)
        #expect(backupFileNames.isEmpty)
        #expect(text(at: "files/n.md", in: home) == "510")
    }

    @Test func pruneKeepsBackupsUnder20MB() throws {
        let (_, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let largeText = String(repeating: "x", count: 200_000)
        for writeNumber in 1...120 {
            try changeLog.recordWrite(path: "files/big-\(writeNumber).md", newText: largeText + "\(writeNumber)", origin: .hub, influencedBy: [])
        }
        try changeLog.prune(now: Date(timeIntervalSinceNow: 2 * 24 * 3600))
        #expect(changeLog.backupsByteCount() <= ElfChangeLog.maximumBackupsByteCount)
        #expect(!changeLog.entries().isEmpty)
    }

    @Test func backupsAreStoredOncePerContent() throws {
        let (_, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "files/a.md", newText: "same", origin: .hub, influencedBy: [])
        try changeLog.recordWrite(path: "files/b.md", newText: "same", origin: .hub, influencedBy: [])
        let backupFileNames = try FileManager.default.contentsOfDirectory(atPath: changeLog.backupsDirectory.path)
        #expect(backupFileNames.count == 1)
    }

    @Test func theLogLivesWhereElfToolsCannotReachIt() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try changeLog.recordWrite(path: "files/a.md", newText: "a", origin: .hub, influencedBy: [])
        #expect(throws: ElfHomeError.self) { try home.resolvedURLForElfTool(".elfhub/changes.jsonl", access: .read) }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLForElfTool(".elfhub/change-backups", access: .read) }
    }

    @Test func aWriteIntoAnElfWhoseFolderIsGoneIsRefused() throws {
        let (home, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try FileManager.default.removeItem(at: home.directory)
        #expect(throws: (any Error).self) {
            try changeLog.recordWrite(path: "files/a.md", newText: "a", origin: .hub, influencedBy: [])
        }
        #expect(!FileManager.default.fileExists(atPath: home.directory.path))
    }

    @Test func todaysChangesAreNeverPrunedForSize() throws {
        let (_, changeLog, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let largeText = String(repeating: "x", count: 200_000)
        for writeNumber in 1...120 {
            try changeLog.recordWrite(path: "files/big-\(writeNumber).md", newText: largeText + "\(writeNumber)", origin: .hub, influencedBy: [])
        }
        try changeLog.prune(now: Date())
        #expect(changeLog.entries().count == 120)
    }

    @Test func undoNeverWritesIntoElfhubsOwnFolder() throws {
        #expect(ElfChangeLog.isInsideElfhubData("/Users/someone/Library/Application Support/elfhub/Elfs/main/access.json", elfhubDataFolderPath: "/Users/someone/Library/Application Support/elfhub"))
        #expect(!ElfChangeLog.isInsideElfhubData("/Users/someone/Documents/plan.md", elfhubDataFolderPath: "/Users/someone/Library/Application Support/elfhub"))
    }
}
