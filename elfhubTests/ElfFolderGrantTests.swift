//
//  ElfFolderGrantTests.swift
//  elfhubTests
//
//  The user's folders: an elf reaches only folders the user granted it
//  (read-only unless writing is switched on), never past them through
//  "..", links or other paths; every change it makes there is backed up and
//  undoable; and the grants stay on this Mac, never in an export.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfFolderGrantTests {

    private struct Fixture {
        let home: ElfHome
        let grantedFolder: URL
        let outsideFolder: URL
        let rootDirectory: URL
    }

    private func makeFixture(allowsWriting: Bool) throws -> Fixture {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: rootDirectory.appendingPathComponent("elf", isDirectory: true))
        try home.createIfNeeded()
        let grantedFolder = rootDirectory.appendingPathComponent("Documents/Trip", isDirectory: true)
        let outsideFolder = rootDirectory.appendingPathComponent("Documents/Private", isDirectory: true)
        try FileManager.default.createDirectory(at: grantedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        try Data("itinerary".utf8).write(to: grantedFolder.appendingPathComponent("plan.md"))
        try Data("secret".utf8).write(to: outsideFolder.appendingPathComponent("diary.md"))
        try home.writeFolderGrants([ElfFolderGrant(path: grantedFolder.path, allowsWriting: allowsWriting)])
        return Fixture(home: home, grantedFolder: grantedFolder, outsideFolder: outsideFolder, rootDirectory: rootDirectory)
    }

    private func toolContext(_ fixture: Fixture) -> ElfToolContext {
        ElfToolContext(
            elf: Elf(id: "juniper", home: fixture.home, configuration: fixture.home.readConfiguration()),
            changeLog: ElfChangeLog(home: fixture.home),
            origin: .turn(conversationIdentifier: nil),
            userUtterance: "update my trip plan",
            turnEffectLedger: ElfTurnEffectLedger()
        )
    }

    private func run(_ toolName: String, _ arguments: [String: Any], _ fixture: Fixture, context: ElfToolContext? = nil) async throws -> ElfToolOutcome {
        let tool = try #require(ElfFolderTools.tools(grants: fixture.home.readFolderGrants()).first { $0.definition.name == toolName })
        let argumentsJSON = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return try await tool.run(argumentsJSON: argumentsJSON, context: context ?? toolContext(fixture))
    }

    @Test func grantedFilesCanBeReadAndOthersCannot() async throws {
        let fixture = try makeFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let readOutcome = try await run("read_user_file", ["path": fixture.grantedFolder.appendingPathComponent("plan.md").path], fixture)
        #expect(readOutcome.resultText.contains("itinerary"))
        #expect(try await run("read_user_file", ["path": fixture.outsideFolder.appendingPathComponent("diary.md").path], fixture).isFailure)
        let escapingPath = fixture.grantedFolder.path + "/../Private/diary.md"
        let escapingOutcome = try await run("read_user_file", ["path": escapingPath], fixture)
        #expect(escapingOutcome.isFailure)
        #expect(!escapingOutcome.resultText.contains("secret"))
        let listOutcome = try await run("list_user_folder", [:], fixture)
        #expect(listOutcome.resultText.contains(fixture.grantedFolder.path))
    }

    @Test func linksOutOfAGrantAreRefused() async throws {
        let fixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try FileManager.default.createSymbolicLink(
            at: fixture.grantedFolder.appendingPathComponent("sneaky.md"),
            withDestinationURL: fixture.outsideFolder.appendingPathComponent("diary.md")
        )
        #expect(try await run("read_user_file", ["path": fixture.grantedFolder.appendingPathComponent("sneaky.md").path], fixture).isFailure)
        #expect(try await run("write_user_file", ["path": fixture.grantedFolder.appendingPathComponent("sneaky.md").path, "content": "x"], fixture).isFailure)
        #expect(try String(contentsOf: fixture.outsideFolder.appendingPathComponent("diary.md"), encoding: .utf8) == "secret")
    }

    @Test func writesNeedTheWriteSwitch() async throws {
        let readOnlyFixture = try makeFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: readOnlyFixture.rootDirectory) }
        #expect(!ElfFolderTools.tools(grants: readOnlyFixture.home.readFolderGrants()).contains { $0.definition.name == "write_user_file" })
        let writableFixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: writableFixture.rootDirectory) }
        #expect(ElfFolderTools.tools(grants: writableFixture.home.readFolderGrants()).contains { $0.definition.name == "write_user_file" })
    }

    @Test func userFileWritesAreBackedUpAndUndoable() async throws {
        let fixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let planPath = fixture.grantedFolder.appendingPathComponent("plan.md").path
        let writeOutcome = try await run("write_user_file", ["path": planPath, "content": "new itinerary"], fixture)
        #expect(!writeOutcome.isFailure)
        #expect(try String(contentsOfFile: planPath, encoding: .utf8) == "new itinerary")
        let fileChange = try #require(writeOutcome.fileChanges.first)
        try ElfChangeLog(home: fixture.home).undo(entryIdentifier: fileChange.id, force: false)
        #expect(try String(contentsOfFile: planPath, encoding: .utf8) == "itinerary")
    }

    @Test func foldersAfterTheWebAreRefusedInTheSameTask() async throws {
        let fixture = try makeFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let webContext = toolContext(fixture)
        webContext.usedResources.insert(.web)
        #expect(try await run("read_user_file", ["path": fixture.grantedFolder.appendingPathComponent("plan.md").path], fixture, context: webContext).isFailure)
    }

    @Test func grantsAreNeverExported() throws {
        let fixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let packagedPaths = try ElfExporter.packageFiles(home: fixture.home, configuration: fixture.home.readConfiguration(), options: ElfExporter.Options(), chats: []).map(\.path)
        #expect(!packagedPaths.contains { $0.contains("access.json") })
        #expect(throws: ElfHomeError.self) { try fixture.home.resolvedURLForElfTool("access.json", access: .read) }
    }

    // MARK: Review fixes

    @Test func elfhubsOwnDataIsNeverReachableThroughAGrant() async throws {
        let fixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        // A grant that contains the elf's own folder.
        try fixture.home.writeFolderGrants([ElfFolderGrant(path: fixture.rootDirectory.path, allowsWriting: true)])
        let accessFilePath = fixture.home.accessURL.path
        #expect(try await run("read_user_file", ["path": fixture.home.configurationURL.path], fixture).isFailure)
        #expect(try await run("write_user_file", ["path": accessFilePath, "content": "[]"], fixture).isFailure)
        #expect(fixture.home.readFolderGrants().count == 1)
    }

    @Test func foldersThatAreTooBroadCannotBeGranted() {
        let homeFolder = URL(fileURLWithPath: NSHomeDirectory())
        #expect(ElfFolderTools.grantProblem(forFolder: URL(fileURLWithPath: "/")) != nil)
        #expect(ElfFolderTools.grantProblem(forFolder: URL(fileURLWithPath: "/Users")) != nil)
        #expect(ElfFolderTools.grantProblem(forFolder: homeFolder) != nil)
        #expect(ElfFolderTools.grantProblem(forFolder: homeFolder.appendingPathComponent("Library")) != nil)
        #expect(ElfFolderTools.grantProblem(forFolder: homeFolder.appendingPathComponent("Library/Application Support/elfhub/Elves")) != nil)
        #expect(ElfFolderTools.grantProblem(forFolder: homeFolder.appendingPathComponent("Documents/Trip")) == nil)
    }

    @Test func largeOrNonTextFilesAreNotOverwrittenAndDotFoldersAreLeftAlone() async throws {
        let fixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let bigFileURL = fixture.grantedFolder.appendingPathComponent("big.csv")
        try Data(repeating: 0x41, count: ElfHome.fileByteLimit + 1).write(to: bigFileURL)
        #expect(try await run("write_user_file", ["path": bigFileURL.path, "content": "x"], fixture).isFailure)
        let binaryFileURL = fixture.grantedFolder.appendingPathComponent("report.docx")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: binaryFileURL)
        #expect(try await run("write_user_file", ["path": binaryFileURL.path, "content": "x"], fixture).isFailure)
        let gitConfigPath = fixture.grantedFolder.appendingPathComponent(".git/config").path
        #expect(try await run("write_user_file", ["path": gitConfigPath, "content": "x"], fixture).isFailure)
    }

    @Test func removingAGrantStopsToolsAlreadyHanded() async throws {
        let fixture = try makeFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let readTool = try #require(ElfFolderTools.tools(grants: fixture.home.readFolderGrants()).first { $0.definition.name == "read_user_file" })
        try fixture.home.writeFolderGrants([])
        let argumentsJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["path": fixture.grantedFolder.appendingPathComponent("plan.md").path]), as: UTF8.self)
        #expect(try await readTool.run(argumentsJSON: argumentsJSON, context: toolContext(fixture)).isFailure)
    }

    @Test func specialFilesAreNotRead() async throws {
        let fixture = try makeFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let pipePath = fixture.grantedFolder.appendingPathComponent("pipe").path
        #expect(mkfifo(pipePath, 0o600) == 0)
        #expect(try await run("read_user_file", ["path": pipePath], fixture).isFailure)
    }

    @Test func aBadPathDoesNotLockOutTheWeb() async throws {
        let fixture = try makeFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let context = toolContext(fixture)
        _ = try await run("read_user_file", ["path": fixture.outsideFolder.appendingPathComponent("diary.md").path], fixture, context: context)
        #expect(!context.usedResources.contains(.userFolders))
    }
}
