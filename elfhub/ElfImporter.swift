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
    static let maximumToneCharacters = 200
    static let maximumLanguageCharacters = 80
    static let maximumDescriptionCharacters = 300

    static func preview(packageURL: URL, elfManager: ElfManager, configurations: [ProviderConfiguration]) throws -> ElfImportPreview {
        try preview(validatedPackage: try readAndValidate(packageURL: packageURL), elfManager: elfManager, configurations: configurations)
    }

    /// Reads (at most 110 MB, following links to the real file) and checks
    /// a .elf. Pure work on the file — run it off the main thread.
    nonisolated static func readAndValidate(packageURL: URL) throws -> ElfValidatedPackage {
        let resolvedPackageURL = packageURL.resolvingSymlinksInPath()
        guard let packageSize = (try? resolvedPackageURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({ resourceValues in
            resourceValues.isRegularFile == true ? resourceValues.fileSize : nil
        }) else { throw ElfImportRejection.notAnElfFile }
        guard packageSize <= maximumPackageBytes else { throw ElfImportRejection.tooLarge }
        guard let packageData = try? Data(contentsOf: resolvedPackageURL), packageData.count <= maximumPackageBytes else {
            throw ElfImportRejection.notAnElfFile
        }
        return try ElfImportValidator.validate(packageData: packageData)
    }

    static func preview(validatedPackage: ElfValidatedPackage, elfManager: ElfManager, configurations: [ProviderConfiguration]) throws -> ElfImportPreview {
        let elfFiles: [(path: String, data: Data)] = validatedPackage.files.compactMap { packagedFile in
            guard packagedFile.path.hasPrefix("elf/") else { return nil }
            return (String(packagedFile.path.dropFirst("elf/".count)), packagedFile.data)
        }
        var configuration = elfFiles.first { $0.path == "elf.json" }
            .flatMap { try? JSONDecoder().decode(ElfConfiguration.self, from: $0.data) } ?? ElfConfiguration()
        if configuration.identity.name.trimmingCharacters(in: .whitespaces).isEmpty {
            configuration.identity.name = validatedPackage.manifest.elf.name
        }
        // Within the editor's limits: a file can't hand an elf settings
        // the app itself would never save.
        configuration.behaviour.tone = String(configuration.behaviour.tone.prefix(maximumToneCharacters))
        configuration.behaviour.language = String(configuration.behaviour.language.prefix(maximumLanguageCharacters))
        configuration.identity.description = String(configuration.identity.description.prefix(maximumDescriptionCharacters))
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
            // Only the elf's own parts, judged by where the path really lands
            // (as elf tools' paths are), never the app's own files.
            let firstPathComponent = String(elfFile.path.split(separator: "/").first ?? "")
            guard ElfImportValidator.elfFolderTopLevelNames.contains(firstPathComponent),
                  let destinationURL = try? stagingHome.resolvedURLForElfTool(elfFile.path, access: .read) else { continue }
            var fileData = elfFile.data
            // Soul and notes within the editor's limits.
            if firstPathComponent == "soul.md" || firstPathComponent == "profile.md" {
                let characterLimit = firstPathComponent == "soul.md" ? ElfHome.soulCharacterLimit : ElfHome.profileCharacterLimit
                fileData = Data(String(String(decoding: fileData, as: UTF8.self).prefix(characterLimit)).utf8)
            }
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Written fresh: plain files, never executable.
            try fileData.write(to: destinationURL, options: .atomic)
        }
        // Belt and braces: whatever happened, no grants and no app data come
        // from the file.
        try? fileManager.removeItem(at: stagingHome.accessURL)
        try? fileManager.removeItem(at: stagingHome.appDataDirectory)

        var importedConfiguration = importPreview.configuration
        importedConfiguration.identity.name = importPreview.elfName
        importedConfiguration.identity.emoji = importPreview.emoji
        // At most five other names, none clashing with the elves here.
        let namesHere = ElfNameRules.namesInUse(byElves: elfManager.elves, excludingElfWithIdentifier: nil)
        importedConfiguration.identity.aliases = Array(
            ElfNameRules.cleanedAliases(importedConfiguration.identity.aliases, elfName: importPreview.elfName)
                .filter { alias in ElfNameRules.problems(forName: alias, otherElfNames: namesHere).allSatisfy(\.isWarning) }
                .prefix(ElfNameRules.maximumAliasCount)
        )
        // Whoever made the file decides nothing about this Mac: the web and
        // folders start off, until the user switches them on.
        importedConfiguration.capabilities = ElfConfiguration.Capabilities(webEnabled: false, allowsWebAndUserFoldersTogether: false)
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
            // Ordinary exchanges with new ids: nothing from the file can pose
            // as a task report or point at screenshots or changes here.
            importedChat.messages = exportedChat.messages.filter { $0.kind == .exchange }.map { exportedMessage in
                StoredChatMessage(
                    role: exportedMessage.role,
                    text: exportedMessage.text,
                    createdAt: exportedMessage.createdAt,
                    isError: exportedMessage.isError,
                    inputSource: exportedMessage.inputSource,
                    notepad: exportedMessage.notepad,
                    speakingElfIdentifier: exportedMessage.role == .assistant ? importedElf.id : nil
                )
            }
            importedChat.updatedAt = exportedChat.updatedAt
            onImportedChat(importedChat)
        }
        return importedElf
    }
}
