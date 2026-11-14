//
//  ElfTests.swift
//  elfhubTests
//
//  The elf's home folder, elf.json, skills, the part of the prompt that makes
//  the model this elf, and exports.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfTests {

    private func makeTemporaryHome() throws -> (home: ElfHome, cleanUp: () -> Void) {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()
        return (home, { try? FileManager.default.removeItem(at: homeDirectory) })
    }

    // MARK: - elf.json

    @Test func configurationRoundTripsThroughJSON() throws {
        let configuration = ElfConfiguration(
            identity: .init(name: "Pip", emoji: "🧝", description: "helps with the web app"),
            behaviour: .init(replyLength: .short, tone: "calm", language: "British English", takesNotes: false),
            preferredModels: .init(speechToText: "appleOnDevice", languageModelPreset: "anthropic", languageModelName: "claude-sonnet-5-5", voiceOutput: "system", voiceName: nil)
        )
        let decodedConfiguration = try JSONDecoder().decode(ElfConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decodedConfiguration == configuration)
    }

    @Test func configurationFromAnOlderOrPartialFileStillLoads() throws {
        let partialJSON = Data(#"{"identity":{"name":"Pip"},"behaviour":{"replyLength":"somethingNew"}}"#.utf8)
        let configuration = try JSONDecoder().decode(ElfConfiguration.self, from: partialJSON)
        #expect(configuration.identity.name == "Pip")
        #expect(configuration.identity.emoji == "")
        #expect(configuration.behaviour.replyLength == .followSoul)
        #expect(configuration.behaviour.takesNotes)
        #expect(!configuration.behaviour.fileAccessEnabled)
        #expect(configuration.schemaVersion == ElfConfiguration.currentSchemaVersion)
    }

    // MARK: - Skills

    @Test func skillRoundTripsThroughSkillMarkdownAndKeepsUnknownKeys() {
        let skill = ElfSkill(
            slug: "deploying-the-web-app",
            name: "Deploying the web app",
            description: "Steps: shipping to production",
            body: "1. run the tests\n2. tag a release",
            unrecognizedFrontmatterLines: ["license: MIT", "metadata:", "  hermes:", "    tags: [deploy, web]"]
        )
        #expect(skill.skillMarkdown.hasPrefix("---\nname: Deploying the web app\ndescription: \"Steps: shipping to production\"\n"))
        #expect(ElfSkill.parse(slug: skill.slug, skillMarkdown: skill.skillMarkdown) == skill)
    }

    @Test func hermesSkillWithBlockScalarDescriptionParses() {
        let hermesSkill = "---\nname: arxiv-search\ndescription: >\n  Search arXiv papers\n  and summarise them.\nversion: 1.2.0\n---\n\n# arXiv\n\nUse the API."
        let parsedSkill = ElfSkill.parse(slug: "arxiv-search", skillMarkdown: hermesSkill)
        #expect(parsedSkill.name == "arxiv-search")
        #expect(parsedSkill.description == "Search arXiv papers and summarise them.")
        #expect(parsedSkill.body == "# arXiv\n\nUse the API.")
        #expect(parsedSkill.unrecognizedFrontmatterLines == ["version: 1.2.0"])
    }

    @Test func windowsLineEndingsParseLikeUnixOnes() {
        let unixSkill = "---\nname: Notes\ndescription: how I take notes\n---\n\nbody line"
        let windowsSkill = unixSkill.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(ElfSkill.parse(slug: "notes", skillMarkdown: windowsSkill) == ElfSkill.parse(slug: "notes", skillMarkdown: unixSkill))
    }

    @Test func skillWithoutFrontmatterOrWithUnclosedFrontmatterIsNamedAfterItsFolder() {
        let plainSkill = ElfSkill.parse(slug: "release-notes", skillMarkdown: "just some notes\nmore")
        #expect(plainSkill.name == "release notes")
        #expect(plainSkill.description == "")
        #expect(plainSkill.body == "just some notes\nmore")
        let unclosedSkill = ElfSkill.parse(slug: "half-done", skillMarkdown: "---\nname: Broken\nbody without end")
        #expect(unclosedSkill.name == "half done")
        #expect(unclosedSkill.body == "---\nname: Broken\nbody without end")
    }

    @Test func skillSlugsAreSafe() {
        #expect(ElfSkill.slug(forName: "Deploying the Web App!") == "deploying-the-web-app")
        #expect(ElfSkill.slug(forName: "../../etc/passwd") == "etc-passwd")
        #expect(ElfSkill.slug(forName: "   ") == "skill")
    }

    @Test func skillFoldersWithoutSkillFilesAreSkipped() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: home.skillsDirectory.appendingPathComponent("empty-folder"), withIntermediateDirectories: true)
        try home.writeSkill(ElfSkill(name: "Real skill", description: "", body: "steps"))
        #expect(home.readSkills().map(\.slug) == ["real-skill"])
    }

    @Test func legacySingleFileSkillsMoveIntoSkillFolders() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let legacySkillURL = home.skillsDirectory.appendingPathComponent("deploying.md")
        try Data("# Deploying\n> how we ship\n\nrun the script".utf8).write(to: legacySkillURL)
        home.migrateLegacySkillFilesIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: legacySkillURL.path))
        let migratedSkill = try #require(home.readSkills().first)
        #expect(migratedSkill.slug == "deploying")
        #expect(migratedSkill.name == "Deploying")
        #expect(migratedSkill.description == "how we ship")
        #expect(migratedSkill.body == "run the script")
    }

    // MARK: - Home

    @Test func aNewHomeHasItsFoldersAndStarterFiles() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: home.configurationURL.path))
        #expect(fileManager.fileExists(atPath: home.skillsDirectory.path))
        #expect(fileManager.fileExists(atPath: home.filesDirectory.path))
        #expect(home.readSoul() == ElfHome.starterSoul)
        #expect(home.readProfile() == ElfHome.starterProfile)

        // Creating again never overwrites the user's edits.
        try home.writeSoul("# soul\n\nalways answer in british english.")
        try home.createIfNeeded()
        #expect(home.readSoul().contains("british english"))
    }

    @Test func skillsAreSavedListedAndDeleted() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try home.writeSkill(ElfSkill(name: "Zed editor", description: "", body: "uses vim mode"))
        try home.writeSkill(ElfSkill(name: "Alpha tool", description: "the build tool", body: "run alpha build"))
        #expect(home.readSkills().map(\.name) == ["Alpha tool", "Zed editor"])
        try home.deleteSkill(slug: "zed-editor")
        #expect(home.readSkills().map(\.name) == ["Alpha tool"])
    }

    @Test func pathsCantLeaveTheHome() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLInsideHome("../outside.md") }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLInsideHome("/etc/hosts") }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLInsideHome("~/Desktop/x.md") }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLInsideHome("files/../../outside.md") }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLInsideHome("") }

        // A symlink inside the home that points out is caught too.
        let linkURL = home.filesDirectory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(throws: ElfHomeError.self) { try home.resolvedURLInsideHome("files/escape/secret.txt") }

        #expect(try home.resolvedURLInsideHome("files/notes/today.md").lastPathComponent == "today.md")
        #expect(try home.resolvedURLInsideHome("skills/new-skill.md").lastPathComponent == "new-skill.md")
    }

    @Test func elfToolsCantReachAppOwnedFilesOrWriteTheSoul() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        for reservedPath in [".elfhub/changes.jsonl", ".ELFHUB/tasks/1.json", "elf.json", "access.json"] {
            #expect(throws: ElfHomeError.reservedPath(reservedPath)) { try home.resolvedURLForElfTool(reservedPath, access: .read) }
        }
        #expect(throws: ElfHomeError.reservedPath("soul.md")) { try home.resolvedURLForElfTool("soul.md", access: .write) }
        #expect(try home.resolvedURLForElfTool("soul.md", access: .read).lastPathComponent == "soul.md")
        #expect(try home.resolvedURLForElfTool("files/notes/elfhub-ideas.md", access: .write).lastPathComponent == "elfhub-ideas.md")
        #expect(throws: ElfHomeError.self) { try home.resolvedURLForElfTool("../main/soul.md", access: .read) }
    }

    @Test func localSettingsRoundTripAndStartEmpty() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        #expect(FileManager.default.fileExists(atPath: home.appDataDirectory.path))
        #expect(home.readLocalSettings() == ElfLocalSettings())
        let localSettings = ElfLocalSettings(
            languageModelConfigurationIdentifier: UUID(),
            voice: ElfVoiceSelection(speechOutputModeRawValue: "system", voiceIdentifier: "com.apple.voice.premium.en-GB.Malcolm")
        )
        try home.writeLocalSettings(localSettings)
        #expect(home.readLocalSettings() == localSettings)
        try Data("{not json".utf8).write(to: home.localSettingsURL)
        #expect(home.readLocalSettings() == ElfLocalSettings())
    }

    @Test func overlongTextIsRefused() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let overlongText = String(repeating: "a", count: ElfHome.soulCharacterLimit + 1)
        #expect(throws: ElfHomeError.self) { try home.writeSoul(overlongText) }
        #expect(throws: ElfHomeError.self) { try home.writeProfile(overlongText) }
        #expect(home.readSoul() == ElfHome.starterSoul)
    }

    // MARK: - Prompt

    @Test func aFreshElfKeepsTodaysRulesAndTheScreenSafetyRule() {
        let systemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels,
            guidanceEncoding: .nativeTools,
            includesScreenActions: false
        )
        #expect(systemPrompt.hasPrefix("you're elf, an elf"))
        #expect(systemPrompt.contains("all lowercase, casual, warm. no emojis."))
        #expect(systemPrompt.contains("never say \"simply\" or \"just\"."))
        #expect(systemPrompt.contains(ElfPromptContext.screenContentSafetyRule))
        #expect(!systemPrompt.contains("what you know about the user"))
        #expect(!systemPrompt.contains("skills you've learned"))
        #expect(!systemPrompt.contains("the user's settings for you"))
    }

    @Test func soulProfileSettingsAndSkillsShapeThePrompt() {
        var elfPromptContext = ElfPromptContext.starter
        elfPromptContext.elfName = "Pip"
        elfPromptContext.soulText = "# soul\n\nalways answer like a pirate."
        elfPromptContext.profileText = "# profile\n\n- prefers metric units"
        elfPromptContext.behaviour = .init(replyLength: .short, tone: "calm", language: "French")
        elfPromptContext.skills = [ElfSkill(name: "Deploying", description: "how we ship", body: "run make deploy")]
        let systemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels,
            guidanceEncoding: .textTags,
            includesScreenActions: false,
            elfPromptContext: elfPromptContext
        )
        #expect(systemPrompt.hasPrefix("you're Pip, an elf"))
        #expect(systemPrompt.contains("always answer like a pirate."))
        #expect(!systemPrompt.contains("all lowercase, casual, warm"))
        #expect(systemPrompt.contains("- prefers metric units"))
        #expect(systemPrompt.contains("always reply in French."))
        #expect(systemPrompt.contains("tone: calm."))
        #expect(systemPrompt.contains("one or two sentences, even when asked"))
        #expect(systemPrompt.contains("- Deploying: how we ship"))
        #expect(systemPrompt.contains("## Deploying\nrun make deploy"))
        // Editing the soul never removes the app's own safety rule or mechanics.
        #expect(systemPrompt.contains(ElfPromptContext.screenContentSafetyRule))
        #expect(systemPrompt.contains("[NOTEPAD:"))
    }

    @Test func skillsBeyondTheBudgetAreListedByTitleOnly() {
        var elfPromptContext = ElfPromptContext.starter
        let longBody = String(repeating: "x", count: ElfPromptContext.inlineSkillsCharacterBudget - 100)
        elfPromptContext.skills = [
            ElfSkill(name: "Big one", description: "", body: longBody),
            ElfSkill(name: "Second", description: "another", body: String(repeating: "y", count: 500)),
        ]
        let promptText = elfPromptContext.promptSections.joined(separator: "\n\n")
        #expect(promptText.contains("- Second: another"))
        #expect(promptText.contains("## Big one"))
        #expect(!promptText.contains("## Second"))
        #expect(promptText.contains("listed by title only"))
    }

    // MARK: - Export

    @Test func exportsCarryOnlyWhatWasChosen() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try home.writeSkill(ElfSkill(name: "Deploying", description: "", body: "steps"))
        try home.writeProfile("# profile\n\n- likes tea")
        try Data("notes".utf8).write(to: home.filesDirectory.appendingPathComponent("notes.md"))
        try Data(#"{"allowedFolders":["/Users/me/Work"]}"#.utf8).write(to: home.accessURL)

        func stagedItemNames(_ exportOptions: ElfExporter.Options) throws -> Set<String> {
            let stagedDirectory = try ElfExporter.stageExport(home: home, configuration: home.readConfiguration(), options: exportOptions)
            defer { try? FileManager.default.removeItem(at: stagedDirectory.deletingLastPathComponent()) }
            return Set(try FileManager.default.contentsOfDirectory(atPath: stagedDirectory.path))
        }

        #expect(try stagedItemNames(.init()) == ["elf.json", "soul.md", "skills"])
        #expect(try stagedItemNames(.init(includesProfile: true)) == ["elf.json", "soul.md", "skills", "profile.md"])
        #expect(try stagedItemNames(.init(includesProfile: true, includesFiles: true)) == ["elf.json", "soul.md", "skills", "profile.md", "files"])
    }

    @Test func anExportIsAZipNamedAfterTheElf() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).elf")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        var configuration = home.readConfiguration()
        configuration.identity.name = "Pip's Helper"
        try ElfExporter.export(home: home, configuration: configuration, options: .init(), to: exportURL)
        let exportedBytes = try Data(contentsOf: exportURL)
        #expect(exportedBytes.prefix(2) == Data("PK".utf8))
        #expect(ElfExporter.packageBaseName(forElfName: "Pip's Helper") == "Pip-s-Helper")
    }
}
