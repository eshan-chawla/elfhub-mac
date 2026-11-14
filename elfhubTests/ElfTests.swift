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

    // MARK: - Names

    @Test func elfNamesRejectEmptyLongTagCharactersReservedAndDuplicates() {
        #expect(ElfNameRules.problems(forName: "  ", otherElfNames: []) == [.empty])
        #expect(ElfNameRules.problems(forName: String(repeating: "a", count: 33), otherElfNames: []) == [.tooLong(characterLimit: 32)])
        #expect(ElfNameRules.problems(forName: "Pip [1]", otherElfNames: []) == [.containsTagCharacters])
        #expect(ElfNameRules.problems(forName: "Ju:niper", otherElfNames: []) == [.containsTagCharacters])
        #expect(ElfNameRules.problems(forName: "MAIN", otherElfNames: []) == [.reservedWord("main")])
        #expect(ElfNameRules.problems(forName: "José", otherElfNames: ["jose"]) == [.duplicateOf(elfName: "jose")])
        #expect(ElfNameRules.problems(forName: "Juniper", otherElfNames: ["Pip"]) == [])
    }

    @Test func aWholeWordPrefixIsOnlyAWarning() {
        let problems = ElfNameRules.problems(forName: "Will", otherElfNames: ["Will Smith"])
        #expect(problems == [.wholeWordPrefixOf(elfName: "Will Smith")])
        #expect(problems.allSatisfy { problem in problem.isWarning })
        #expect(ElfNameRules.problems(forName: "Jun", otherElfNames: ["Juniper"]) == [])
    }

    @Test func identifiersAreSlugsThatCountUpAndNeverClaimMain() {
        #expect(ElfNameRules.uniqueIdentifier(forName: "Juniper", existingIdentifiers: ["main"]) == "juniper")
        #expect(ElfNameRules.uniqueIdentifier(forName: "Juniper", existingIdentifiers: ["main", "juniper", "juniper-2"]) == "juniper-3")
        #expect(ElfNameRules.uniqueIdentifier(forName: "🧝", existingIdentifiers: ["main"]) == "elf")
        #expect(ElfNameRules.uniqueIdentifier(forName: "!!!", existingIdentifiers: ["main", "elf"]) == "elf-2")
        #expect(ElfNameRules.uniqueIdentifier(forName: "Main", existingIdentifiers: ["main"]) == "main-2")
    }

    @Test func aliasesRoundTripAndDefaultToNone() throws {
        let identity = ElfConfiguration.Identity(name: "Juniper", aliases: ["June", "Juni"])
        let decodedIdentity = try JSONDecoder().decode(ElfConfiguration.Identity.self, from: JSONEncoder().encode(identity))
        #expect(decodedIdentity.aliases == ["June", "Juni"])
        let olderIdentity = try JSONDecoder().decode(ElfConfiguration.Identity.self, from: Data(#"{"name":"Pip"}"#.utf8))
        #expect(olderIdentity.aliases.isEmpty)
    }

    // MARK: - Roster

    private func makeTemporaryElvesDirectory() -> (elvesDirectory: URL, cleanUp: () -> Void) {
        let elvesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elves-\(UUID().uuidString)", isDirectory: true)
        return (elvesDirectory, { try? FileManager.default.removeItem(at: elvesDirectory) })
    }

    @Test func theRosterAlwaysHasMainFirst() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        #expect(elfManager.elves.map(\.id) == ["main"])
        _ = try elfManager.createElf(identity: .init(name: "Zed"))
        _ = try elfManager.createElf(identity: .init(name: "Ada"))
        #expect(elfManager.elves.map(\.id) == ["main", "ada", "zed"])
        #expect(elfManager.elf(withIdentifier: "ada")?.configuration.identity.name == "Ada")
    }

    @Test func strayItemsAreNotElvesAndFinderAdditionsAppearOnReload() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        try Data().write(to: elvesDirectory.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: elvesDirectory.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: elvesDirectory.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try ElfHome(directory: elvesDirectory.appendingPathComponent("pip")).createIfNeeded(configuration: ElfConfiguration(identity: .init(name: "Pip")))
        elfManager.reloadRoster()
        #expect(elfManager.elves.map(\.id) == ["main", "pip"])
    }

    @Test func creatingAndRenamingCheckTheNameRules() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        _ = try elfManager.createElf(identity: .init(name: "Juniper"))
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "Juniper")])) {
            try elfManager.createElf(identity: .init(name: "juniper"))
        }
        #expect(throws: ElfManagerError.invalidName([.reservedWord("everyone")])) {
            try elfManager.renameElf(withIdentifier: "juniper", to: "Everyone")
        }
        _ = try elfManager.createElf(identity: .init(name: "Will Smith"))
        _ = try elfManager.createElf(identity: .init(name: "Will"))   // a prefix is only a warning
        try elfManager.renameElf(withIdentifier: "main", to: "Pip")
        #expect(elfManager.mainElf.configuration.identity.name == "Pip")
        #expect(elfManager.mainElf.id == "main")
    }

    @Test func mainCannotBeDeletedAndOtherElvesCanBe() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        #expect(throws: ElfManagerError.cannotDeleteMainElf) { try elfManager.deleteElf(withIdentifier: "main") }
        #expect(throws: ElfManagerError.unknownElf("nobody")) { try elfManager.deleteElf(withIdentifier: "nobody") }
        let createdElf = try elfManager.createElf(identity: .init(name: "Ada"))
        try elfManager.deleteElf(withIdentifier: createdElf.id)
        #expect(!FileManager.default.fileExists(atPath: createdElf.home.directory.path))
        #expect(elfManager.elves.map(\.id) == ["main"])
    }

    @Test func theMainElfComesBackIfItsFolderIsRemoved() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        try FileManager.default.removeItem(at: elfManager.mainElf.home.directory)
        elfManager.reloadRoster()
        #expect(elfManager.elves.map(\.id) == ["main"])
        #expect(FileManager.default.fileExists(atPath: elfManager.mainElf.home.configurationURL.path))
    }

    @Test func newElfIdentifiersAvoidEverythingAlreadyOnDiskIgnoringCase() throws {
        #expect(ElfNameRules.uniqueIdentifier(forName: "Juniper", existingIdentifiers: ["Juniper"]) == "juniper-2")
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        try FileManager.default.createDirectory(at: elvesDirectory.appendingPathComponent("Juniper"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elvesDirectory.appendingPathComponent("pip"))
        elfManager.reloadRoster()
        #expect(try elfManager.createElf(identity: .init(name: "Juniper")).id == "juniper-2")
        #expect(try elfManager.createElf(identity: .init(name: "Pip")).id == "pip-2")
    }

    @Test func identityEditsLeaveTheNameToTheNameRules() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        let mainElfEditor = try ElfEditor(elfIdentifier: "main", elfManager: elfManager)
        try mainElfEditor.updateEmoji("🧝")
        try mainElfEditor.updateDescription("helps with everything")
        try mainElfEditor.updateBehaviour { behaviour in behaviour.tone = "calm" }
        #expect(mainElfEditor.elf.configuration.identity.name == "elf")
        #expect(elfManager.mainElf.home.readConfiguration().identity.name == "elf")
        #expect(elfManager.mainElf.configuration.identity.emoji == "🧝")
        #expect(elfManager.mainElf.configuration.behaviour.tone == "calm")
        #expect(mainElfEditor.isMainElf)
    }

    @Test func editingADroppedInSkillKeepsItsFolderAndExtraFiles() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        let mainElfEditor = try ElfEditor(elfIdentifier: "main", elfManager: elfManager)
        let skillFolderURL = mainElfEditor.home.skillsDirectory.appendingPathComponent("Deploy", isDirectory: true)
        try FileManager.default.createDirectory(at: skillFolderURL.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data("---\nname: Deploy\ndescription: old\n---\n\nsteps".utf8).write(to: skillFolderURL.appendingPathComponent("SKILL.md"))
        try Data("notes".utf8).write(to: skillFolderURL.appendingPathComponent("references/notes.md"))
        mainElfEditor.reload()

        var editedSkill = try #require(mainElfEditor.skills.first)
        editedSkill.description = "fixed typo"
        editedSkill.name = "Deploying"
        try mainElfEditor.saveSkill(editedSkill, isNewSkill: false)

        #expect(mainElfEditor.skills.map(\.slug) == ["Deploy"])
        #expect(mainElfEditor.skills.first?.name == "Deploying")
        #expect(mainElfEditor.skills.first?.description == "fixed typo")
        #expect(FileManager.default.fileExists(atPath: skillFolderURL.appendingPathComponent("references/notes.md").path))
    }

    @Test func aNewSkillCantReplaceAnExistingOne() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        let mainElfEditor = try ElfEditor(elfIdentifier: "main", elfManager: elfManager)
        try mainElfEditor.saveSkill(ElfSkill(name: "Deploy", description: "", body: "first"), isNewSkill: true)
        #expect(throws: ElfManagerError.skillAlreadyExists(name: "DEPLOY")) {
            try mainElfEditor.saveSkill(ElfSkill(name: "DEPLOY", description: "", body: "second"), isNewSkill: true)
        }
        #expect(mainElfEditor.skills.map(\.body) == ["first"])
    }

    // MARK: - Editing any elf

    @Test func anEditorEditsOnlyTheElfItWasOpenedFor() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Ada"))
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        try adaEditor.saveSoul("# soul\n\nbe brief")
        try adaEditor.updateDescription("keeps the books")
        #expect(elfManager.elf(withIdentifier: "ada")?.home.readSoul() == "# soul\n\nbe brief")
        #expect(elfManager.elf(withIdentifier: "ada")?.configuration.identity.description == "keeps the books")
        #expect(elfManager.mainElf.home.readSoul() == ElfHome.starterSoul)
        #expect(!adaEditor.isMainElf)
    }

    @Test func editingAnElfWhoseFolderWasRemovedFailsWithoutRecreatingIt() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Ada"))
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        let adaFolderURL = elvesDirectory.appendingPathComponent("ada", isDirectory: true)
        try FileManager.default.removeItem(at: adaFolderURL)
        #expect(throws: ElfManagerError.unknownElf("ada")) { try adaEditor.saveSoul("x") }
        #expect(throws: ElfManagerError.unknownElf("ada")) { try adaEditor.updateEmoji("🧝") }
        #expect(!FileManager.default.fileExists(atPath: adaFolderURL.path))
        #expect(elfManager.elf(withIdentifier: "ada") == nil)
    }

    @Test func anEditorForAnUnknownElfCannotBeOpened() {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        #expect(throws: ElfManagerError.unknownElf("nobody")) {
            _ = try ElfEditor(elfIdentifier: "nobody", elfManager: elfManager)
        }
    }

    @Test func theMainElfsPromptStillComesFromMainAfterOtherElvesAreEdited() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        try elfManager.createElf(identity: .init(name: "Ada"))
        try ElfEditor(elfIdentifier: "ada", elfManager: elfManager).saveSoul("# soul\n\nada only")
        #expect(elfManager.promptContext().soulText == ElfHome.starterSoul)
        #expect(elfManager.promptContext().elfName == "elf")
    }

    // MARK: - Aliases

    /// Juniper (also called "June") and Ada.
    private func makeElfManagerWithJuniperAndAda(elvesDirectory: URL) throws -> ElfManager {
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Juniper", aliases: ["June"]))
        try elfManager.createElf(identity: .init(name: "Ada"))
        return elfManager
    }

    @Test func aliasesAreCleanedOfRepeatsAndTheElfsOwnName() {
        #expect(ElfNameRules.cleanedAliases([" June ", "june", "Juniper", "", "Jun"], elfName: "Juniper") == ["June", "Jun"])
    }

    @Test func namesInUseListEveryOtherElfsNameAndAliases() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elvesDirectory: elvesDirectory)
        #expect(ElfNameRules.namesInUse(byElves: elfManager.elves, excludingElfWithIdentifier: "ada") == ["elf", "Juniper", "June"])
    }

    @Test func anAliasCannotBeAnotherElfsNameOrAlias() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elvesDirectory: elvesDirectory)
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        #expect(throws: ElfManagerError.invalidAlias(alias: "june", problems: [.duplicateOf(elfName: "June")])) {
            try adaEditor.updateAliases(["june"])
        }
        #expect(throws: ElfManagerError.invalidAlias(alias: "Juniper", problems: [.duplicateOf(elfName: "Juniper")])) {
            try adaEditor.updateAliases(["Juniper"])
        }
        #expect(throws: ElfManagerError.invalidAlias(alias: "everyone", problems: [.reservedWord("everyone")])) {
            try adaEditor.updateAliases(["everyone"])
        }
        #expect(elfManager.elf(withIdentifier: "ada")?.configuration.identity.aliases == [])
    }

    @Test func aNewElfOrRenameCannotTakeAnotherElfsAlias() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elvesDirectory: elvesDirectory)
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "June")])) {
            try elfManager.createElf(identity: .init(name: "June"))
        }
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "June")])) {
            try elfManager.renameElf(withIdentifier: "ada", to: "JUNE")
        }
    }

    @Test func anElfHasAtMostFiveAliases() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elvesDirectory: elvesDirectory)
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        #expect(throws: ElfManagerError.tooManyAliases(limit: 5)) {
            try adaEditor.updateAliases(["Axel", "Bram", "Cleo", "Dov", "Eli", "Fen"])
        }
    }

    @Test func validAliasesAreSavedCleaned() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elvesDirectory: elvesDirectory)
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        try adaEditor.updateAliases(["  Addy ", "addy"])
        #expect(elfManager.elf(withIdentifier: "ada")?.configuration.identity.aliases == ["Addy"])
        #expect(adaEditor.elf.configuration.identity.aliases == ["Addy"])
    }

    // MARK: - Starter elves

    @Test func starterElvesComeWithTheirIdentityAndSoul() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        let researcher = try elfManager.createElf(fromStarterTemplate: .researcher)
        #expect(researcher.id == "researcher")
        #expect(researcher.configuration.identity.name == "Researcher")
        #expect(researcher.configuration.identity.emoji == "🔎")
        #expect(researcher.home.readSoul().contains("## as a researcher"))
        #expect(researcher.home.readSoul().hasPrefix(ElfHome.starterSoul))
        let writer = try elfManager.createElf(fromStarterTemplate: .writer)
        #expect(writer.configuration.identity.emoji == "✍️")
        #expect(writer.home.readSoul().contains("## as a writer"))
    }

    @Test func starterElvesThatAreAlreadyThereAreNotOfferedAgain() throws {
        let (elvesDirectory, cleanUp) = makeTemporaryElvesDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory)
        #expect(elfManager.availableStarterTemplates == [.researcher, .writer])
        try elfManager.renameElf(withIdentifier: "main", to: "Researcher")
        #expect(elfManager.availableStarterTemplates == [.writer])
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "Researcher")])) {
            try elfManager.createElf(fromStarterTemplate: .researcher)
        }
    }

    @Test func starterNamesPassTheNameRules() {
        for starterTemplate in ElfStarterTemplate.allCases {
            #expect(ElfNameRules.problems(forName: starterTemplate.identity.name, otherElfNames: []).isEmpty)
        }
    }

    // MARK: - Naming the main elf

    @Test func theNamingCardIsOfferedOnceToElvesStillCalledElf() {
        #expect(ElfNamingPrompt.shouldOffer(hasCompletedOnboarding: true, mainElfName: "elf", wasOffered: false))
        #expect(ElfNamingPrompt.shouldOffer(hasCompletedOnboarding: true, mainElfName: " Elf ", wasOffered: false))
        #expect(!ElfNamingPrompt.shouldOffer(hasCompletedOnboarding: true, mainElfName: "elf", wasOffered: true))
        #expect(!ElfNamingPrompt.shouldOffer(hasCompletedOnboarding: true, mainElfName: "Juniper", wasOffered: false))
        #expect(!ElfNamingPrompt.shouldOffer(hasCompletedOnboarding: false, mainElfName: "elf", wasOffered: false))
    }

    @Test func keepingTheDefaultNameInOnboardingMeansNoCardLater() throws {
        let userDefaultsSuiteName = "ElfNamingPromptTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        #expect(!ElfNamingPrompt.wasOffered(userDefaults: userDefaults))
        ElfNamingPrompt.markOffered(userDefaults: userDefaults)
        #expect(!ElfNamingPrompt.shouldOffer(
            hasCompletedOnboarding: true,
            mainElfName: "elf",
            wasOffered: ElfNamingPrompt.wasOffered(userDefaults: userDefaults)
        ))
    }

    @Test func theVoicePreviewSaysTheElfsName() {
        #expect(ElfVoicePreview.sentence(forElfName: " Juniper ") == "Hi, I'm Juniper. This is how I'll sound.")
        #expect(ElfVoicePreview.sentence(forElfName: "") == "Hi, I'm elf. This is how I'll sound.")
    }

    @Test func emojiFieldKeepsOnlyTheFirstEmoji() {
        #expect(ElfNameRules.normalizedEmoji("🧝‍♀️ Juniper") == "🧝‍♀️")
        #expect(ElfNameRules.normalizedEmoji("👍🏽👍") == "👍🏽")
        #expect(ElfNameRules.normalizedEmoji("ab") == "")
        #expect(ElfNameRules.normalizedEmoji("  ") == "")
        #expect(ElfNameRules.normalizedEmoji("1") == "")
        #expect(ElfNameRules.normalizedEmoji("✍️") == "✍️")
        #expect(ElfNameRules.normalizedEmoji("🔎") == "🔎")
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

    @Test func dotPrefixedAndSymlinkedPathsCantReachAppOwnedFiles() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        #expect(throws: ElfHomeError.reservedPath("./.elfhub/local-settings.json")) {
            try home.resolvedURLForElfTool("./.elfhub/local-settings.json", access: .read)
        }
        #expect(throws: ElfHomeError.reservedPath("./elf.json")) { try home.resolvedURLForElfTool("./elf.json", access: .read) }
        #expect(throws: ElfHomeError.reservedPath("./soul.md")) { try home.resolvedURLForElfTool("./soul.md", access: .write) }
        try FileManager.default.createSymbolicLink(
            at: home.filesDirectory.appendingPathComponent("app-data"),
            withDestinationURL: home.appDataDirectory
        )
        #expect(throws: ElfHomeError.reservedPath("files/app-data/local-settings.json")) {
            try home.resolvedURLForElfTool("files/app-data/local-settings.json", access: .read)
        }
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
