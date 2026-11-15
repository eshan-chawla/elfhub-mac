//
//  ElfImporter.swift
//  elfhub
//
//  Importing a .elf: `preview` reads and checks the whole file (see
//  ElfImportValidator) and describes what would be added — writing
//  nothing. `install` unpacks it into Application Support/elfhub/Imports/
//  <uuid>/, checking every path again, then moves it into Elves/ as a new
//  elf: a name of its own if it clashes ("Juniper 2"), its web and folder
//  switches back to the defaults (an import can't grant itself more), no
//  folder grants, the model it was made with when this Mac has it (else the
//  main elf's), and its chats under new ids.
//

import Foundation

struct ElfImportPreview {
    let elfName: String
    let emoji: String
    let description: String
    /// Files in its folder (soul, skills, notes, files).
    let fileCount: Int
    let includesProfile: Bool
    let chats: [ChatConversation]
    var chatCount: Int { chats.count }
    /// This Mac's model matching the one it was made with, if any.
    let matchingConfigurationIdentifier: UUID?
    /// Said when it was made with a model this Mac doesn't have.
    let modelHint: String?
    let configuration: ElfConfiguration
    /// Its folder's files, as paths inside the folder ("files/trip.md").
    let elfFiles: [(path: String, data: Data)]
}

enum ElfImporter {
    /// A .elf larger than this isn't even read.
    static let maximumPackageBytes = 110 * 1024 * 1024

    static func preview(packageURL: URL, elfManager: ElfManager, configurations: [ProviderConfiguration]) throws -> ElfImportPreview {
        let packageSize = (try? FileManager.default.attributesOfItem(atPath: packageURL.path)[.size] as? Int) ?? 0
        guard packageSize <= maximumPackageBytes else { throw ElfImportRejection.tooLarge }
        guard let packageData = try? Data(contentsOf: packageURL) else { throw ElfImportRejection.notAnElfFile }
        let validatedPackage = try ElfImportValidator.validate(packageData: packageData)

        let elfFiles: [(path: String, data: Data)] = validatedPackage.files.compactMap { packagedFile in
            guard packagedFile.path.hasPrefix("elf/") else { return nil }
            return (String(packagedFile.path.dropFirst("elf/".count)), packagedFile.data)
        }
        var configuration = elfFiles.first { $0.path == "elf.json" }
            .flatMap { try? JSONDecoder().decode(ElfConfiguration.self, from: $0.data) } ?? ElfConfiguration()
        if configuration.identity.name.trimmingCharacters(in: .whitespaces).isEmpty {
            configuration.identity.name = validatedPackage.manifest.elf.name
        }
        let chatDecoder = ChatConversationStore.makeJSONDecoder()
        let chats = validatedPackage.files
            .filter { $0.path.hasPrefix("chats/") }
            .compactMap { try? chatDecoder.decode(ChatConversation.self, from: $0.data) }

        let preferredModels = configuration.preferredModels
        let matchingConfiguration = configurations.first { configuration in
            guard let preferredModelName = preferredModels?.languageModelName, !preferredModelName.isEmpty else { return false }
            return configuration.model == preferredModelName
                && (preferredModels?.languageModelPreset == nil || configuration.presetIdentifier == preferredModels?.languageModelPreset)
        }
        var modelHint: String?
        if matchingConfiguration == nil, let preferredModelName = preferredModels?.languageModelName, !preferredModelName.isEmpty {
            modelHint = "It was made with \(preferredModelName), which isn't set up here, so it will use your main elf's model until you pick one on its page."
        }

        return ElfImportPreview(
            elfName: uniqueName(startingFrom: configuration.identity.name, elfManager: elfManager),
            emoji: ElfNameRules.normalizedEmoji(configuration.identity.emoji),
            description: configuration.identity.description,
            fileCount: elfFiles.filter { $0.path != "elf.json" }.count,
            includesProfile: validatedPackage.manifest.includesProfile,
            chats: chats,
            matchingConfigurationIdentifier: matchingConfiguration?.id,
            modelHint: modelHint,
            configuration: configuration,
            elfFiles: elfFiles
        )
    }

    /// The name, or "Name 2", "Name 3"… — whatever the name rules accept
    /// next to the elves already here ("Imported elf" when the name itself
    /// can't be used).
    static func uniqueName(startingFrom proposedName: String, elfManager: ElfManager) -> String {
        let otherElfNames = ElfNameRules.namesInUse(byElves: elfManager.elves, excludingElfWithIdentifier: nil)
        func isUsable(_ candidateName: String) -> Bool {
            ElfNameRules.problems(forName: candidateName, otherElfNames: otherElfNames).allSatisfy(\.isWarning)
        }
        let trimmedName = String(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ElfNameRules.nameCharacterLimit - 3))
        let baseName = ElfNameRules.problems(forName: trimmedName, otherElfNames: []).allSatisfy(\.isWarning) ? trimmedName : "Imported elf"
        if isUsable(baseName) { return baseName }
        for suffixNumber in 2...99 where isUsable("\(baseName) \(suffixNumber)") {
            return "\(baseName) \(suffixNumber)"
        }
        return "Imported elf \(Int.random(in: 100...999))"
    }

    /// Unpacks and adds the elf; chats are handed to `onImportedChat`.
    @discardableResult
    static func install(
        _ importPreview: ElfImportPreview,
        elfManager: ElfManager,
        importsDirectory: URL = ElfHome.defaultElvesDirectory.deletingLastPathComponent().appendingPathComponent("Imports", isDirectory: true),
        onImportedChat: (ChatConversation) -> Void
    ) throws -> Elf {
        let fileManager = FileManager.default
        let stagingDirectory = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var hasMovedIntoElves = false
        defer { if !hasMovedIntoElves { try? fileManager.removeItem(at: stagingDirectory) } }

        let stagingHome = ElfHome(directory: stagingDirectory)
        for elfFile in importPreview.elfFiles where elfFile.path != "elf.json" {
            // Never the app's own files, whatever the package says.
            let firstPathComponent = elfFile.path.split(separator: "/").first.map { $0.lowercased() } ?? ""
            guard !ElfHome.pathsReservedForTheApp.contains(firstPathComponent) else { continue }
            let destinationURL = try stagingHome.resolvedURLInsideHome(elfFile.path)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Written fresh: plain files, never executable.
            try elfFile.data.write(to: destinationURL, options: .atomic)
        }

        var importedConfiguration = importPreview.configuration
        importedConfiguration.identity.name = importPreview.elfName
        importedConfiguration.identity.emoji = importPreview.emoji
        importedConfiguration.identity.aliases = ElfNameRules.cleanedAliases(importedConfiguration.identity.aliases, elfName: importPreview.elfName)
            .filter { alias in
                ElfNameRules.problems(forName: alias, otherElfNames: ElfNameRules.namesInUse(byElves: elfManager.elves, excludingElfWithIdentifier: nil))
                    .allSatisfy(\.isWarning)
            }
        // Whoever made the file decides nothing about this Mac.
        importedConfiguration.capabilities = ElfConfiguration.Capabilities()
        try stagingHome.writeConfiguration(importedConfiguration)
        try stagingHome.createIfNeeded(configuration: importedConfiguration)
        try stagingHome.writeLocalSettings(ElfLocalSettings(languageModelConfigurationIdentifier: importPreview.matchingConfigurationIdentifier))

        let elvesDirectory = elfManager.mainElf.home.directory.deletingLastPathComponent()
        let elvesFolderItemNames = (try? fileManager.contentsOfDirectory(atPath: elvesDirectory.path)) ?? []
        let elfIdentifier = ElfNameRules.uniqueIdentifier(
            forName: importPreview.elfName,
            existingIdentifiers: Set(elfManager.elves.map(\.id)).union(elvesFolderItemNames)
        )
        let elfDirectory = elvesDirectory.appendingPathComponent(elfIdentifier, isDirectory: true)
        try fileManager.moveItem(at: stagingDirectory, to: elfDirectory)
        hasMovedIntoElves = true
        elfManager.reloadRoster()
        guard let importedElf = elfManager.elf(withIdentifier: elfIdentifier) else { throw ElfManagerError.unknownElf(elfIdentifier) }

        for exportedChat in importPreview.chats {
            var importedChat = ChatConversation(id: UUID(), title: exportedChat.title, createdAt: exportedChat.createdAt, messages: [])
            importedChat.messages = exportedChat.messages.map { exportedMessage in
                var importedMessage = exportedMessage
                if importedMessage.role == .assistant {
                    importedMessage.speakingElfIdentifier = importedElf.id
                }
                importedMessage.screenshotFileName = nil
                importedMessage.fileChanges = []
                return importedMessage
            }
            importedChat.updatedAt = exportedChat.updatedAt
            onImportedChat(importedChat)
        }
        return importedElf
    }
}
