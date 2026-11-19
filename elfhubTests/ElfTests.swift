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

    private func makeTemporaryElfsDirectory() -> (elfsDirectory: URL, cleanUp: () -> Void) {
        let elfsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elfs-\(UUID().uuidString)", isDirectory: true)
        return (elfsDirectory, { try? FileManager.default.removeItem(at: elfsDirectory) })
    }

    @Test func anUnreadableElfJSONIsNeverOverwritten() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        let sideElf = try elfManager.createElf(identity: .init(name: "Juniper"))
        // A hand edit that lost its closing braces.
        let damagedJSON = Data(#"{"identity": {"name": "Juniper""#.utf8)
        try damagedJSON.write(to: sideElf.home.configurationURL)
        #expect(sideElf.home.isConfigurationUnreadable)

        #expect(throws: ElfHomeError.configurationUnreadable) {
            try elfManager.renameElf(withIdentifier: sideElf.id, to: "Rowan")
        }
        let editor = try ElfEditor(elfIdentifier: sideElf.id, elfManager: elfManager)
        #expect(throws: ElfHomeError.configurationUnreadable) {
            try editor.updateBehaviour { behaviour in behaviour.tone = "calm" }
        }
        #expect(try Data(contentsOf: sideElf.home.configurationURL) == damagedJSON)
    }

    @Test func theRosterAlwaysHasMainFirst() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        #expect(elfManager.elfs.map(\.id) == ["main"])
        _ = try elfManager.createElf(identity: .init(name: "Zed"))
        _ = try elfManager.createElf(identity: .init(name: "Ada"))
        #expect(elfManager.elfs.map(\.id) == ["main", "ada", "zed"])
        #expect(elfManager.elf(withIdentifier: "ada")?.configuration.identity.name == "Ada")
    }

    @Test func strayItemsAreNotElfsAndFinderAdditionsAppearOnReload() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        try Data().write(to: elfsDirectory.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: elfsDirectory.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: elfsDirectory.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try ElfHome(directory: elfsDirectory.appendingPathComponent("pip")).createIfNeeded(configuration: ElfConfiguration(identity: .init(name: "Pip")))
        elfManager.reloadRoster()
        #expect(elfManager.elfs.map(\.id) == ["main", "pip"])
    }

    @Test func creatingAndRenamingCheckTheNameRules() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
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

    @Test func mainCannotBeDeletedAndOtherElfsCanBe() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
        #expect(throws: ElfManagerError.cannotDeleteMainElf) { try elfManager.deleteElf(withIdentifier: "main") }
        #expect(throws: ElfManagerError.unknownElf("nobody")) { try elfManager.deleteElf(withIdentifier: "nobody") }
        let createdElf = try elfManager.createElf(identity: .init(name: "Ada"))
        try elfManager.deleteElf(withIdentifier: createdElf.id)
        #expect(!FileManager.default.fileExists(atPath: createdElf.home.directory.path))
        #expect(elfManager.elfs.map(\.id) == ["main"])
    }

    @Test func theMainElfComesBackIfItsFolderIsRemoved() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        try FileManager.default.removeItem(at: elfManager.mainElf.home.directory)
        elfManager.reloadRoster()
        #expect(elfManager.elfs.map(\.id) == ["main"])
        #expect(FileManager.default.fileExists(atPath: elfManager.mainElf.home.configurationURL.path))
    }

    @Test func newElfIdentifiersAvoidEverythingAlreadyOnDiskIgnoringCase() throws {
        #expect(ElfNameRules.uniqueIdentifier(forName: "Juniper", existingIdentifiers: ["Juniper"]) == "juniper-2")
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        try FileManager.default.createDirectory(at: elfsDirectory.appendingPathComponent("Juniper"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elfsDirectory.appendingPathComponent("pip"))
        elfManager.reloadRoster()
        #expect(try elfManager.createElf(identity: .init(name: "Juniper")).id == "juniper-2")
        #expect(try elfManager.createElf(identity: .init(name: "Pip")).id == "pip-2")
    }

    @Test func identityEditsLeaveTheNameToTheNameRules() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
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
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
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
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        let mainElfEditor = try ElfEditor(elfIdentifier: "main", elfManager: elfManager)
        try mainElfEditor.saveSkill(ElfSkill(name: "Deploy", description: "", body: "first"), isNewSkill: true)
        #expect(throws: ElfManagerError.skillAlreadyExists(name: "DEPLOY")) {
            try mainElfEditor.saveSkill(ElfSkill(name: "DEPLOY", description: "", body: "second"), isNewSkill: true)
        }
        #expect(mainElfEditor.skills.map(\.body) == ["first"])
    }

    // MARK: - Editing any elf

    @Test func anEditorEditsOnlyTheElfItWasOpenedFor() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
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
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Ada"))
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        let adaFolderURL = elfsDirectory.appendingPathComponent("ada", isDirectory: true)
        try FileManager.default.removeItem(at: adaFolderURL)
        #expect(throws: ElfManagerError.unknownElf("ada")) { try adaEditor.saveSoul("x") }
        #expect(throws: ElfManagerError.unknownElf("ada")) { try adaEditor.updateEmoji("🧝") }
        #expect(!FileManager.default.fileExists(atPath: adaFolderURL.path))
        #expect(elfManager.elf(withIdentifier: "ada") == nil)
    }

    @Test func anEditorForAnUnknownElfCannotBeOpened() {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        #expect(throws: ElfManagerError.unknownElf("nobody")) {
            _ = try ElfEditor(elfIdentifier: "nobody", elfManager: elfManager)
        }
    }

    @Test func theMainElfsPromptStillComesFromMainAfterOtherElfsAreEdited() async throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        try elfManager.createElf(identity: .init(name: "Ada"))
        try ElfEditor(elfIdentifier: "ada", elfManager: elfManager).saveSoul("# soul\n\nada only")
        let elfPromptContext = await elfManager.promptContext()
        #expect(elfPromptContext.soulText == ElfHome.starterSoul)
        #expect(elfPromptContext.elfName == "elf")
    }

    // MARK: - Aliases

    /// Juniper (also called "June") and Ada.
    private func makeElfManagerWithJuniperAndAda(elfsDirectory: URL) throws -> ElfManager {
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Juniper", aliases: ["June"]))
        try elfManager.createElf(identity: .init(name: "Ada"))
        return elfManager
    }

    @Test func aliasesAreCleanedOfRepeatsAndTheElfsOwnName() {
        #expect(ElfNameRules.cleanedAliases([" June ", "june", "Juniper", "", "Jun"], elfName: "Juniper") == ["June", "Jun"])
    }

    @Test func namesInUseListEveryOtherElfsNameAndAliases() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elfsDirectory: elfsDirectory)
        #expect(ElfNameRules.namesInUse(byElfs: elfManager.elfs, excludingElfWithIdentifier: "ada") == ["elf", "Juniper", "June"])
    }

    @Test func anAliasCannotBeAnotherElfsNameOrAlias() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elfsDirectory: elfsDirectory)
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
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elfsDirectory: elfsDirectory)
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "June")])) {
            try elfManager.createElf(identity: .init(name: "June"))
        }
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "June")])) {
            try elfManager.renameElf(withIdentifier: "ada", to: "JUNE")
        }
    }

    @Test func anElfHasAtMostFiveAliases() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elfsDirectory: elfsDirectory)
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        #expect(throws: ElfManagerError.tooManyAliases(limit: 5)) {
            try adaEditor.updateAliases(["Axel", "Bram", "Cleo", "Dov", "Eli", "Fen"])
        }
    }

    @Test func validAliasesAreSavedCleaned() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = try makeElfManagerWithJuniperAndAda(elfsDirectory: elfsDirectory)
        let adaEditor = try ElfEditor(elfIdentifier: "ada", elfManager: elfManager)
        try adaEditor.updateAliases(["  Addy ", "addy"])
        #expect(elfManager.elf(withIdentifier: "ada")?.configuration.identity.aliases == ["Addy"])
        #expect(adaEditor.elf.configuration.identity.aliases == ["Addy"])
    }

    // MARK: - Starter elfs

    @Test func starterElfsComeWithTheirIdentityAndSoul() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
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

    @Test func starterElfsThatAreAlreadyThereAreNotOfferedAgain() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        #expect(elfManager.availableStarterTemplates == [.researcher, .writer])
        try elfManager.renameElf(withIdentifier: "main", to: "Researcher")
        #expect(elfManager.availableStarterTemplates == [.writer])
        #expect(throws: ElfManagerError.invalidName([.duplicateOf(elfName: "Researcher")])) {
            try elfManager.createElf(fromStarterTemplate: .researcher)
        }
    }

    @Test func starterElfsStartUncheckedInOnboarding() {
        #expect(ElfStarterTemplate.chosenByDefaultInOnboarding.isEmpty)
    }

    @Test func starterNamesPassTheNameRules() {
        for starterTemplate in ElfStarterTemplate.allCases {
            #expect(ElfNameRules.problems(forName: starterTemplate.identity.name, otherElfNames: []).isEmpty)
        }
    }

    // MARK: - Naming the main elf

    @Test func theNamingCardIsOfferedOnceToElfsStillCalledElf() {
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

    @Test func renamingTheMainElfAnywhereAnswersTheNamingCard() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let userDefaultsSuiteName = "ElfNamingPromptTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, namingPromptUserDefaults: userDefaults)

        // Renaming a side Elf doesn't count.
        let sideElf = try elfManager.createElf(identity: .init(name: "Zed"))
        try elfManager.renameElf(withIdentifier: sideElf.id, to: "Ada")
        #expect(!ElfNamingPrompt.wasOffered(userDefaults: userDefaults))

        try elfManager.renameElf(withIdentifier: ElfManager.mainElfIdentifier, to: "Alfred")
        #expect(ElfNamingPrompt.wasOffered(userDefaults: userDefaults))
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
        #expect(home.readUserNotes() == ElfHome.starterUserNotes)

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
        let overlongUserNotes = String(repeating: "a", count: ElfHome.userNotesCharacterLimit + 1)
        #expect(throws: ElfHomeError.self) { try home.writeUserNotes(overlongUserNotes) }
        #expect(home.readSoul() == ElfHome.starterSoul)
    }

    // MARK: - Prompt

    @Test func aFreshElfKeepsTodaysRulesAndTheScreenSafetyRule() {
        let systemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels,
            guidanceEncoding: .nativeTools,
            includesScreenActions: false
        )
        #expect(systemPrompt.hasPrefix("you're elf, the user's main Elf"))
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
        elfPromptContext.profileText = "# user\n\n- prefers metric units"
        elfPromptContext.behaviour = .init(replyLength: .short, tone: "calm", language: "French")
        elfPromptContext.skills = [ElfSkill(name: "Deploying", description: "how we ship", body: "run make deploy")]
        let systemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels,
            guidanceEncoding: .textTags,
            includesScreenActions: false,
            elfPromptContext: elfPromptContext
        )
        #expect(systemPrompt.hasPrefix("you're Pip, the user's main Elf"))
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

    @Test func theSkillsIndexIsCapped() {
        var elfPromptContext = ElfPromptContext.starter
        elfPromptContext.skills = (1...300).map { skillNumber in
            ElfSkill(name: "Skill number \(skillNumber)", description: String(repeating: "d", count: 40), body: "")
        }
        let promptText = elfPromptContext.promptSections.joined(separator: "\n\n")
        let indexLineCount = promptText.components(separatedBy: "\n").filter { $0.hasPrefix("- Skill number") }.count
        #expect(indexLineCount < 300)
        #expect(indexLineCount > 0)
        #expect(promptText.contains("\(300 - indexLineCount) more skills — ask for them by name"))
    }

    // MARK: - Gaps closed before elf tools

    @Test func aPathResolvesToTheRealFileNotTheLink() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let realFileURL = home.filesDirectory.appendingPathComponent("real.md")
        try Data("real".utf8).write(to: realFileURL)
        try FileManager.default.createSymbolicLink(
            at: home.filesDirectory.appendingPathComponent("link.md"),
            withDestinationURL: realFileURL
        )
        let resolvedURL = try home.resolvedURLInsideHome("files/link.md")
        #expect(resolvedURL.lastPathComponent == "real.md")
        #expect(resolvedURL.path == realFileURL.resolvingSymlinksInPath().path)
    }

    @Test func aMarkdownFileDroppedIntoSkillsLaterIsNotMigrated() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let droppedReadmeURL = home.skillsDirectory.appendingPathComponent("README.md")
        try Data("# Read me\n\nnot a skill".utf8).write(to: droppedReadmeURL)
        try home.createIfNeeded()
        #expect(FileManager.default.fileExists(atPath: droppedReadmeURL.path))
        #expect(home.readSkills().isEmpty)
    }

    @Test func multiLineDescriptionsKeepTheirLineBreaksWhenSaved() {
        let skill = ElfSkill(slug: "deploy", name: "Deploy", description: "first line\nsecond line", body: "steps")
        let parsedSkill = ElfSkill.parse(slug: "deploy", skillMarkdown: skill.skillMarkdown)
        #expect(parsedSkill.description == "first line\nsecond line")
        #expect(parsedSkill.name == "Deploy")
        #expect(parsedSkill.body == "steps")
    }

    @Test func trailingCommentsAreNotPartOfAPlainValue() {
        let parsedSkill = ElfSkill.parse(slug: "deploy", skillMarkdown: "---\nname: Deploy # the main one\ndescription: uses C# daily # a note\n---\nbody")
        #expect(parsedSkill.name == "Deploy")
        #expect(parsedSkill.description == "uses C# daily")
    }

    @Test func unicodeEscapesAreDecodedInDoubleQuotedValues() {
        let parsedSkill = ElfSkill.parse(slug: "cafe", skillMarkdown: "---\nname: \"Caf\\u00e9 notes\"\ndescription: \"\\u2014 dash\"\n---\nbody")
        #expect(parsedSkill.name == "Café notes")
        #expect(parsedSkill.description == "— dash")
    }

    @Test func multiLineQuotedValuesLoseTheirQuotes() {
        let parsedSkill = ElfSkill.parse(slug: "deploy", skillMarkdown: "---\nname: Deploy\ndescription: \"first part\n  second part\"\n---\nbody")
        #expect(parsedSkill.description == "first part second part")
    }

    @Test func anIndentedDashLineInsideABlockValueDoesNotCloseTheFrontmatter() {
        let parsedSkill = ElfSkill.parse(slug: "deploy", skillMarkdown: "---\nname: Deploy\ndescription: |\n  before\n  ---\n  after\n---\nbody")
        #expect(parsedSkill.description == "before\n---\nafter")
        #expect(parsedSkill.body == "body")
    }

    @Test func thePromptIsReadOffTheMainActor() async throws {
        let elfsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elfs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elfsDirectory) }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        try ElfEditor(editingMainElfOf: elfManager).saveSoul("# soul\n\nbe kind")
        let elfPromptContext = await elfManager.promptContext()
        #expect(elfPromptContext.soulText == "# soul\n\nbe kind")
    }

    // MARK: - Export

    @Test func exportsCarryTheWholeFolderAndOnlyWhatWasChosen() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try home.writeSkill(ElfSkill(name: "Deploying", description: "", body: "steps"))
        try home.writeUserNotes("# user\n\n- likes tea")
        try Data("notes".utf8).write(to: home.filesDirectory.appendingPathComponent("notes.md"))
        try home.writeFolderGrants([ElfFolderGrant(path: "/Users/me/Work", allowsWriting: true)])
        try ElfChangeLog(home: home).recordWrite(path: "files/changed.md", newText: "x", origin: .hub, influencedBy: [])
        try ElfTaskStore(home: home).save(ElfTask(elfIdentifier: "main", instruction: "x"))
        try home.writeLocalSettings(ElfLocalSettings(languageModelConfigurationIdentifier: UUID()))

        func packagedPaths(_ exportOptions: ElfExporter.Options) throws -> Set<String> {
            Set(try ElfExporter.packageFiles(home: home, configuration: home.readConfiguration(), options: exportOptions, chats: []).map(\.path))
        }
        let withProfile = try packagedPaths(ElfExporter.Options())
        #expect(withProfile.isSuperset(of: ["elf/elf.json", "elf/soul.md", "elf/skills/deploying/SKILL.md", "elf/user.md", "elf/files/notes.md", "elf/files/changed.md"]))
        #expect(withProfile.allSatisfy { $0.hasPrefix("elf/") })
        #expect(!withProfile.contains { $0.contains(".elfhub") || $0.contains("access.json") })
        #expect(!(try packagedPaths(ElfExporter.Options(includesProfile: false))).contains("elf/user.md"))
    }

    @Test func profileIsIncludedByDefaultAndChatsAreNot() {
        #expect(ElfExporter.Options().includesProfile)
        #expect(!ElfExporter.Options().includesChats)
    }

    @Test func chatsHoldOnlyThatElfsExchangesWithoutScreenshots() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        var conversation = ChatConversation(title: "Trip")
        let juniperExchange = conversation.appendExchange(userText: "Juniper, flights?", inputSource: .typed, speakingElfIdentifier: "juniper")
        conversation.setText("TAP.", ofMessageWithIdentifier: juniperExchange.assistantMessageIdentifier)
        conversation.messages[conversation.messages.count - 2].screenshotFileName = "shot.jpg"
        let mainExchange = conversation.appendExchange(userText: "thanks", inputSource: .typed)
        conversation.setText("sure.", ofMessageWithIdentifier: mainExchange.assistantMessageIdentifier)
        let packagedFiles = try ElfExporter.packageFiles(
            home: home,
            configuration: home.readConfiguration(),
            options: ElfExporter.Options(includesChats: true),
            chats: [conversation],
            exportedElfIdentifier: "juniper"
        )
        let chatFile = try #require(packagedFiles.first { $0.path.hasPrefix("chats/") })
        let exportedConversation = try ChatConversationStore.makeJSONDecoder().decode(ChatConversation.self, from: chatFile.data)
        #expect(exportedConversation.messages.map(\.text) == ["Juniper, flights?", "TAP."])
        #expect(exportedConversation.messages.allSatisfy { $0.screenshotFileName == nil })
    }

    @Test func exportRefusesFilesItsImportWouldRefuse() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        var randomBytes = Data(count: ElfImportValidator.maximumFileBytes + 1)
        randomBytes.withUnsafeMutableBytes { buffer in for byteIndex in buffer.indices { buffer[byteIndex] = UInt8.random(in: 0...255) } }
        try randomBytes.write(to: home.filesDirectory.appendingPathComponent("video.mov"))
        #expect(throws: ElfExportProblem.self) {
            _ = try ElfExporter.packageFiles(home: home, configuration: home.readConfiguration(), options: ElfExporter.Options(), chats: [])
        }
    }

    @Test func aRepetitiveFileStillImports() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try Data(String(repeating: "same line\n", count: 300_000).utf8).write(to: home.filesDirectory.appendingPathComponent("log.txt"))
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).elf")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try ElfExporter.export(home: home, configuration: home.readConfiguration(), options: .init(), chats: [], to: exportURL)
        #expect(try ElfImportValidator.validate(packageData: try Data(contentsOf: exportURL)).files.contains { $0.path == "elf/files/log.txt" })
    }

    @Test func elfToolsCannotReadAppFilesThroughLookalikeNames() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLForElfTool("acce\u{017F}s.json", access: .read) }
        #expect(throws: ElfHomeError.self) { try home.resolvedURLForElfTool("elf.j\u{017F}on", access: .read) }
    }

    @Test func anExportIsAZipNamedAfterTheElf() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).elf")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        var configuration = home.readConfiguration()
        configuration.identity.name = "Pip's Helper"
        try ElfExporter.export(home: home, configuration: configuration, options: .init(), chats: [], to: exportURL)
        let exportedBytes = try Data(contentsOf: exportURL)
        #expect(exportedBytes.prefix(2) == Data("PK".utf8))
        // What it writes passes the import checks.
        #expect(try ElfImportValidator.validate(packageData: exportedBytes).manifest.elf.name == "Pip's Helper")
        #expect(ElfExporter.packageBaseName(forElfName: "Pip's Helper") == "Pip-s-Helper")
    }
}
