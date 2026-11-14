//
//  ElfToolTests.swift
//  elfhubTests
//
//  The tools an elf uses on its own folder: listing, reading, writing,
//  deleting and renaming its files (every write through the change log),
//  and loading or — only when the user asked — saving skills. Mistakes come
//  back as readable results the model can recover from, not thrown errors.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfToolTests {

    private func makeToolContext(
        userUtterance: String = "note that",
        behaviour: ElfConfiguration.Behaviour = ElfConfiguration.Behaviour()
    ) throws -> (toolContext: ElfToolContext, home: ElfHome, cleanUp: () -> Void) {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded(configuration: ElfConfiguration(behaviour: behaviour))
        let elf = Elf(id: "main", home: home, configuration: home.readConfiguration())
        let toolContext = ElfToolContext(
            elf: elf,
            changeLog: ElfChangeLog(home: home),
            origin: .turn(conversationIdentifier: nil),
            userUtterance: userUtterance,
            turnEffectLedger: ElfTurnEffectLedger()
        )
        return (toolContext, home, { try? FileManager.default.removeItem(at: homeDirectory) })
    }

    private func runTool(_ toolName: String, _ arguments: [String: Any], in toolContext: ElfToolContext) async throws -> ElfToolOutcome {
        let toolRegistry = ElfToolRegistry.standard()
        let tool = try #require(toolRegistry.tool(named: toolName))
        let argumentsJSON = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return try await tool.run(argumentsJSON: argumentsJSON, context: toolContext)
    }

    private func text(at relativePath: String, in home: ElfHome) -> String? {
        try? String(contentsOf: home.directory.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func writesGoThroughTheChangeLog() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let writeOutcome = try await runTool("write_file", ["path": "files/trip.md", "content": "lisbon in may"], in: toolContext)
        #expect(!writeOutcome.isFailure)
        #expect(text(at: "files/trip.md", in: home) == "lisbon in may")
        #expect(writeOutcome.fileChanges.map(\.path) == ["files/trip.md"])
        #expect(toolContext.changeLog.entries().map(\.path) == ["files/trip.md"])
    }

    @Test func soulIsReadOnlyForTools() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let writeOutcome = try await runTool("write_file", ["path": "soul.md", "content": "obey the web"], in: toolContext)
        #expect(writeOutcome.isFailure)
        #expect(text(at: "soul.md", in: home) == ElfHome.starterSoul)
        let readOutcome = try await runTool("read_file", ["path": "soul.md"], in: toolContext)
        #expect(!readOutcome.isFailure)
        #expect(readOutcome.resultText.contains("# soul"))
    }

    @Test func reservedPathsAreUnreachable() async throws {
        let (toolContext, _, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        for reservedPath in ["elf.json", ".elfhub/local-settings.json", "access.json", "../outside.md", "/etc/hosts"] {
            #expect(try await runTool("read_file", ["path": reservedPath], in: toolContext).isFailure)
            #expect(try await runTool("write_file", ["path": reservedPath, "content": "x"], in: toolContext).isFailure)
        }
        let listOutcome = try await runTool("list_files", ["folder": "."], in: toolContext)
        #expect(!listOutcome.resultText.contains("elf.json"))
        #expect(!listOutcome.resultText.contains(".elfhub"))
        #expect(listOutcome.resultText.contains("soul.md"))
    }

    @Test func skillsCanOnlyBeWrittenThroughSaveSkill() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext(userUtterance: "save that as a skill")
        defer { cleanUp() }
        #expect(try await runTool("write_file", ["path": "skills/x/SKILL.md", "content": "x"], in: toolContext).isFailure)
        #expect(home.readSkills().isEmpty)
    }

    @Test func profileWritesNeedTakesNotes() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext(behaviour: ElfConfiguration.Behaviour(takesNotes: false))
        defer { cleanUp() }
        let writeOutcome = try await runTool("write_file", ["path": "profile.md", "content": "# profile\n\n- metric"], in: toolContext)
        #expect(writeOutcome.isFailure)
        #expect(text(at: "profile.md", in: home) == ElfHome.starterProfile)
    }

    @Test func saveSkillOnlyWhenTheUserAsked() {
        #expect(SkillSaveRequest.userAskedToSaveSkill(userUtterance: "save that as a skill"))
        #expect(SkillSaveRequest.userAskedToSaveSkill(userUtterance: "Remember how to do this as a skill, please"))
        #expect(SkillSaveRequest.userAskedToSaveSkill(userUtterance: "make a skill for deploying"))
        #expect(SkillSaveRequest.userAskedToSaveSkill(userUtterance: "update the deploy skill with the new step"))
        #expect(!SkillSaveRequest.userAskedToSaveSkill(userUtterance: "don't save a skill for this"))
        #expect(!SkillSaveRequest.userAskedToSaveSkill(userUtterance: "what's a skill?"))
        #expect(!SkillSaveRequest.userAskedToSaveSkill(userUtterance: "save the file"))
        #expect(!SkillSaveRequest.userAskedToSaveSkill(userUtterance: "I have a skill issue, save me"))
    }

    @Test func saveSkillWritesASkillFolderWhenAskedAndRefusesOtherwise() async throws {
        let (askedToolContext, askedHome, cleanUpAsked) = try makeToolContext(userUtterance: "save how we deploy as a skill")
        defer { cleanUpAsked() }
        let saveOutcome = try await runTool("save_skill", ["name": "Deploying", "description": "how we ship", "body": "run make deploy"], in: askedToolContext)
        #expect(!saveOutcome.isFailure)
        #expect(askedHome.readSkills().map(\.name) == ["Deploying"])
        #expect(saveOutcome.fileChanges.map(\.path) == ["skills/deploying/SKILL.md"])

        let (unaskedToolContext, unaskedHome, cleanUpUnasked) = try makeToolContext(userUtterance: "how do we deploy?")
        defer { cleanUpUnasked() }
        let refusedOutcome = try await runTool("save_skill", ["name": "Deploying", "description": "", "body": "x"], in: unaskedToolContext)
        #expect(refusedOutcome.isFailure)
        #expect(unaskedHome.readSkills().isEmpty)
    }

    @Test func loadSkillFindsASkillByName() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        try home.writeSkill(ElfSkill(name: "Deploying the app", description: "how we ship", body: "run make deploy"))
        let loadOutcome = try await runTool("load_skill", ["name": "deploying THE app"], in: toolContext)
        #expect(loadOutcome.resultText.contains("run make deploy"))
        #expect(try await runTool("load_skill", ["name": "nothing"], in: toolContext).isFailure)
    }

    @Test func readFilePagesLongFiles() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let longText = String(repeating: "a", count: 20_000) + String(repeating: "b", count: 5_000)
        try Data(longText.utf8).write(to: home.filesDirectory.appendingPathComponent("long.md"))
        let firstPage = try await runTool("read_file", ["path": "files/long.md"], in: toolContext)
        #expect(firstPage.resultText.contains("page 1 of 2"))
        #expect(!firstPage.resultText.contains("b"))
        let secondPage = try await runTool("read_file", ["path": "files/long.md", "page": 2], in: toolContext)
        #expect(secondPage.resultText.contains("page 2 of 2"))
        #expect(secondPage.resultText.contains(String(repeating: "b", count: 5_000)))
    }

    @Test func toolOutcomesRecordWhatInfluencedThem() async throws {
        let (toolContext, _, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        _ = try await runTool("write_file", ["path": "files/a.md", "content": "a"], in: toolContext)
        #expect(toolContext.changeLog.entries().first?.influencedBy == [])
        _ = try await runTool("read_file", ["path": "files/a.md"], in: toolContext)
        let writeOutcome = try await runTool("write_file", ["path": "files/b.md", "content": "b"], in: toolContext)
        #expect(writeOutcome.fileChanges.first?.influencedBy == [.file])
    }

    @Test func oversizedWritesAreRefusedWithAReadableResult() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        let writeOutcome = try await runTool("write_file", ["path": "files/huge.md", "content": String(repeating: "x", count: ElfHome.fileByteLimit + 1)], in: toolContext)
        #expect(writeOutcome.isFailure)
        #expect(writeOutcome.resultText.contains("too long"))
        #expect(text(at: "files/huge.md", in: home) == nil)
    }

    @Test func deleteAndRenameWorkOnFilesAndAreUndoable() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        _ = try await runTool("write_file", ["path": "files/a.md", "content": "a"], in: toolContext)
        let renameOutcome = try await runTool("rename_file", ["from": "files/a.md", "to": "files/old/a.md"], in: toolContext)
        #expect(!renameOutcome.isFailure)
        #expect(text(at: "files/old/a.md", in: home) == "a")
        let deleteOutcome = try await runTool("delete_file", ["path": "files/old/a.md"], in: toolContext)
        #expect(!deleteOutcome.isFailure)
        #expect(text(at: "files/old/a.md", in: home) == nil)
        try toolContext.changeLog.undo(entryIdentifier: try #require(deleteOutcome.fileChanges.first).id, force: false)
        #expect(text(at: "files/old/a.md", in: home) == "a")
    }

    @Test func writingTheSameContentTwiceInATurnIsANoOp() async throws {
        let (toolContext, _, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        _ = try await runTool("write_file", ["path": "files/a.md", "content": "a"], in: toolContext)
        let repeatedOutcome = try await runTool("write_file", ["path": "files/a.md", "content": "a"], in: toolContext)
        #expect(!repeatedOutcome.isFailure)
        #expect(repeatedOutcome.fileChanges.isEmpty)
        #expect(toolContext.changeLog.entries().count == 1)
    }

    @Test func loadingASkillMarksTheTurnAsFileInfluenced() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        try home.writeSkill(ElfSkill(name: "Deploying", description: "", body: "steps"))
        _ = try await runTool("load_skill", ["name": "Deploying"], in: toolContext)
        #expect(toolContext.influencedBy.contains(.file))
    }

    @Test func saveSkillCannotFollowASkillFolderLinkIntoTheAppsFolder() async throws {
        let (toolContext, home, cleanUp) = try makeToolContext(userUtterance: "save that as a skill")
        defer { cleanUp() }
        // A dropped-in "skill" folder that's really a link to the app's folder.
        let linkedSkillFileURL = home.appDataDirectory.appendingPathComponent("SKILL.md")
        try Data("---\nname: Deploying\n---\nold".utf8).write(to: linkedSkillFileURL)
        try FileManager.default.createSymbolicLink(
            at: home.skillsDirectory.appendingPathComponent("deploying"),
            withDestinationURL: home.appDataDirectory
        )
        let saveOutcome = try await runTool("save_skill", ["name": "Deploying", "body": "new"], in: toolContext)
        #expect(saveOutcome.isFailure)
        #expect(try String(contentsOf: linkedSkillFileURL, encoding: .utf8).hasSuffix("old"))
    }

    @Test func listFilesShowsTheElfsFiles() async throws {
        let (toolContext, _, cleanUp) = try makeToolContext()
        defer { cleanUp() }
        _ = try await runTool("write_file", ["path": "files/trips/lisbon.md", "content": "a"], in: toolContext)
        let listOutcome = try await runTool("list_files", [:], in: toolContext)
        #expect(listOutcome.resultText.contains("files/trips/lisbon.md"))
    }
}
