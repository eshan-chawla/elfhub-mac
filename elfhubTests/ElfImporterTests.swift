//
//  ElfImporterTests.swift
//  elfhubTests
//
//  Importing a .elf: a preview first (nothing written), then the elf is
//  installed beside the others — under a name of its own if it clashes,
//  with its chats under new ids, its web and folder switches reset, and the
//  model it was made with picked when this Mac has it (else main's).
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfImporterTests {

    private struct Fixture {
        let elfManager: ElfManager
        let importsDirectory: URL
        let rootDirectory: URL
    }

    private func makeFixture() -> Fixture {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        return Fixture(
            elfManager: ElfManager(elfsDirectory: rootDirectory.appendingPathComponent("Elfs", isDirectory: true), deletedFolderDisposal: .removePermanently),
            importsDirectory: rootDirectory.appendingPathComponent("Imports", isDirectory: true),
            rootDirectory: rootDirectory
        )
    }

    /// An exported Juniper (made in its own temporary roster).
    private func exportedJuniper(
        withChats: Bool = false,
        preferredModels: ElfConfiguration.PreferredModels? = nil,
        capabilities: ElfConfiguration.Capabilities = ElfConfiguration.Capabilities(webEnabled: true, allowsWebAndUserFoldersTogether: true)
    ) throws -> URL {
        let sourceFixture = makeFixture()
        let juniper = try sourceFixture.elfManager.createElf(identity: .init(name: "Juniper", emoji: "🧝", description: "finds flights"))
        try juniper.home.writeSoul("# soul\n\nbe brief")
        try Data("lisbon notes".utf8).write(to: juniper.home.filesDirectory.appendingPathComponent("trip.md"))
        var configuration = juniper.home.readConfiguration()
        configuration.preferredModels = preferredModels
        configuration.capabilities = capabilities
        var conversation = ChatConversation(title: "Trip")
        let exchange = conversation.appendExchange(userText: "Juniper, flights?", inputSource: .typed, speakingElfIdentifier: "juniper")
        conversation.setText("TAP.", ofMessageWithIdentifier: exchange.assistantMessageIdentifier)
        let exportURL = sourceFixture.rootDirectory.appendingPathComponent("Juniper.elf")
        try ElfExporter.export(
            home: juniper.home,
            configuration: configuration,
            options: ElfExporter.Options(includesChats: withChats),
            chats: [conversation],
            exportedElfIdentifier: "juniper",
            to: exportURL
        )
        return exportURL
    }

    @Test func exportThenImportRecreatesTheElf() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let packageURL = try exportedJuniper()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let importPreview = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [])
        #expect(importPreview.elfName == "Juniper")
        #expect(importPreview.fileCount >= 1)
        let importedElf = try ElfImporter.install(importPreview, elfManager: fixture.elfManager, importsDirectory: fixture.importsDirectory, onImportedChat: { _ in })
        #expect(importedElf.configuration.identity.emoji == "🧝")
        #expect(importedElf.home.readSoul() == "# soul\n\nbe brief")
        #expect(try String(contentsOf: importedElf.home.filesDirectory.appendingPathComponent("trip.md"), encoding: .utf8) == "lisbon notes")
        #expect(fixture.elfManager.elf(withIdentifier: importedElf.id) != nil)
    }

    @Test func aNameCollisionIsUniquified() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try fixture.elfManager.createElf(identity: .init(name: "Juniper"))
        let packageURL = try exportedJuniper()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let importPreview = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [])
        #expect(importPreview.elfName == "Juniper 2")
        let importedElf = try ElfImporter.install(importPreview, elfManager: fixture.elfManager, importsDirectory: fixture.importsDirectory, onImportedChat: { _ in })
        #expect(importedElf.configuration.identity.name == "Juniper 2")
        #expect(fixture.elfManager.elfs.count == 3)
    }

    @Test func webAndFolderSwitchesAreResetOnImport() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let packageURL = try exportedJuniper()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let importedElf = try ElfImporter.install(
            try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: []),
            elfManager: fixture.elfManager,
            importsDirectory: fixture.importsDirectory,
            onImportedChat: { _ in }
        )
        #expect(!importedElf.configuration.capabilities.isWebEnabled(isMainElf: false))
        #expect(!importedElf.configuration.capabilities.allowsWebAndUserFoldersTogether)
        #expect(importedElf.home.readFolderGrants().isEmpty)
    }

    @Test func theModelItWasMadeWithIsPickedWhenThisMacHasIt() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        var claudeConfiguration = ProviderConfiguration.directAnthropic()
        claudeConfiguration.model = "claude-sonnet-5-5"
        let packageURL = try exportedJuniper(preferredModels: .init(languageModelPreset: claudeConfiguration.presetIdentifier, languageModelName: "claude-sonnet-5-5"))
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let matchingPreview = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [claudeConfiguration])
        #expect(matchingPreview.matchingConfigurationIdentifier == claudeConfiguration.id)
        let importedElf = try ElfImporter.install(matchingPreview, elfManager: fixture.elfManager, importsDirectory: fixture.importsDirectory, onImportedChat: { _ in })
        #expect(importedElf.home.readLocalSettings().languageModelConfigurationIdentifier == claudeConfiguration.id)

        let unmatchedPreview = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [])
        #expect(unmatchedPreview.matchingConfigurationIdentifier == nil)
        #expect(unmatchedPreview.modelHint != nil)
    }

    @Test func importedChatsGetNewIdentifiersAndTheNewElf() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let packageURL = try exportedJuniper(withChats: true)
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let importPreview = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [])
        #expect(importPreview.chatCount == 1)
        var importedChats: [ChatConversation] = []
        let importedElf = try ElfImporter.install(importPreview, elfManager: fixture.elfManager, importsDirectory: fixture.importsDirectory, onImportedChat: { importedChats.append($0) })
        let importedChat = try #require(importedChats.first)
        #expect(importedChat.messages.last?.speakingElfIdentifier == importedElf.id)
        // It comes in as the imported elf's own ongoing chat.
        #expect(importedChat.elfIdentifier == importedElf.id)
        let exportedChat = try #require(importPreview.chats.first)
        #expect(importedChat.id != exportedChat.id)
    }

    @Test func aPreviewWritesNothing() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let packageURL = try exportedJuniper()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        _ = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [])
        #expect(!FileManager.default.fileExists(atPath: fixture.importsDirectory.path))
        #expect(fixture.elfManager.elfs.map(\.id) == ["main"])
    }

    @Test func aRefusedPackageSaysWhy() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try FileManager.default.createDirectory(at: fixture.rootDirectory, withIntermediateDirectories: true)
        let badPackageURL = fixture.rootDirectory.appendingPathComponent("bad.elf")
        try Data("not a zip".utf8).write(to: badPackageURL)
        #expect(throws: ElfImportRejection.notAnElfFile) {
            _ = try ElfImporter.preview(packageURL: badPackageURL, elfManager: fixture.elfManager, configurations: [])
        }
    }

    @Test func importedTextIsKeptWithinTheEditorsLimits() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let sourceFixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: sourceFixture.rootDirectory) }
        let juniper = try sourceFixture.elfManager.createElf(identity: .init(name: "Juniper"))
        // Written straight to disk, past the editor's limit.
        try Data(("# soul\n\n" + String(repeating: "x", count: ElfHome.soulCharacterLimit + 10)).utf8).write(to: juniper.home.soulURL)
        var configuration = juniper.home.readConfiguration()
        configuration.behaviour.tone = String(repeating: "t", count: 5_000)
        configuration.identity.aliases = (1...12).map { "Alias\($0)" }
        let exportURL = sourceFixture.rootDirectory.appendingPathComponent("Juniper.elf")
        try ElfExporter.export(home: juniper.home, configuration: configuration, options: ElfExporter.Options(), chats: [], exportedElfIdentifier: "juniper", to: exportURL)
        let importedElf = try ElfImporter.install(
            try ElfImporter.preview(packageURL: exportURL, elfManager: fixture.elfManager, configurations: []),
            elfManager: fixture.elfManager,
            importsDirectory: fixture.importsDirectory,
            onImportedChat: { _ in }
        )
        #expect(importedElf.home.readSoul().count <= ElfHome.soulCharacterLimit)
        #expect(importedElf.configuration.behaviour.tone.count <= ElfImporter.maximumToneCharacters)
        #expect(importedElf.configuration.identity.aliases.count <= ElfNameRules.maximumAliasCount)
    }

    @Test func importedChatsAreOrdinaryExchangesWithNewMessageIds() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let packageURL = try exportedJuniper(withChats: true)
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let importPreview = try ElfImporter.preview(packageURL: packageURL, elfManager: fixture.elfManager, configurations: [])
        var importedChats: [ChatConversation] = []
        try ElfImporter.install(importPreview, elfManager: fixture.elfManager, importsDirectory: fixture.importsDirectory, onImportedChat: { importedChats.append($0) })
        let exportedMessageIdentifiers = Set(importPreview.chats.flatMap(\.messages).map(\.id))
        let importedMessages = importedChats.flatMap(\.messages)
        #expect(importedMessages.allSatisfy { !exportedMessageIdentifiers.contains($0.id) && $0.kind == .exchange && $0.taskIdentifier == nil })
    }
}
