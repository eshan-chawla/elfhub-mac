//
//  ElfExporter.swift
//  elfhub
//
//  Packs an elf into a shareable `.elf` file (format 2, see ElfPackage):
//  always its config (elf.json, with the setup it was used with), soul.md,
//  skills/ and its whole files/ folder; user.md (its notes about the
//  user) unless switched off; and, when switched on, the chats with that
//  elf — its exchanges only, without screenshots. Never: keys, this Mac's
//  folder grants (access.json), its change history and backups, tasks or
//  per-Mac settings (.elfhub/), links, or hidden files.
//

import Foundation

enum ElfExporter {
    struct Options: Equatable, Sendable {
        /// Its notes about the user (user.md). On by default.
        var includesProfile = true
        /// Chats with this elf (its exchanges only). Off by default.
        var includesChats = false
    }

    /// Everything that goes into the package, under elf/ and chats/.
    /// `configuration` becomes the package's elf.json.
    static func packageFiles(
        home: ElfHome,
        configuration: ElfConfiguration,
        options: Options,
        chats: [ChatConversation],
        exportedElfIdentifier: String = ElfManager.mainElfIdentifier
    ) throws -> [ElfArchiveFileToWrite] {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var packageFiles = [ElfArchiveFileToWrite(path: "elf/elf.json", data: try jsonEncoder.encode(configuration))]
        if let soulData = try? Data(contentsOf: home.soulURL) {
            packageFiles.append(ElfArchiveFileToWrite(path: "elf/soul.md", data: soulData))
        }
        if options.includesProfile, let profileData = try? Data(contentsOf: home.userNotesURL) {
            packageFiles.append(ElfArchiveFileToWrite(path: "elf/user.md", data: profileData))
        }
        for folderName in ["skills", "files"] {
            packageFiles += try regularFiles(inside: home.directory.appendingPathComponent(folderName, isDirectory: true), packagePathPrefix: "elf/\(folderName)/")
                .filter { !isLeftOutOfExports(packagePath: $0.path) }
        }
        try checkThatItCanBeImported(packageFiles)
        if options.includesChats {
            let chatEncoder = ChatConversationStore.makeJSONEncoder()
            for conversation in chats {
                guard let exportedConversation = conversationWithOnlyExchanges(of: exportedElfIdentifier, from: conversation) else { continue }
                packageFiles.append(ElfArchiveFileToWrite(
                    path: "chats/\(exportedConversation.id.uuidString).json",
                    data: try chatEncoder.encode(exportedConversation)
                ))
            }
            // The chats count toward the same limits as the files, so an
            // export with chats never makes a file its own import refuses.
            guard packageFiles.count < ElfImportValidator.maximumEntryCount,
                  packageFiles.reduce(0, { $0 + $1.data.count }) <= ElfImportValidator.maximumTotalBytes else {
                throw ElfExportProblem.fileCannotBeShared(path: "chats", reason: "together with the files they're too large. Export without chats.")
            }
        }
        return packageFiles
    }

    /// Screen recipes (ScreenRecipeNotes) describe this Mac's apps and what
    /// the user did there, so they stay on this Mac.
    static func isLeftOutOfExports(packagePath: String) -> Bool {
        packagePath.hasPrefix("elf/" + ScreenRecipeNotes.notesFolder + "/")
    }

    /// Writes the `.elf` file to `destinationURL`, replacing an existing file.
    static func export(
        home: ElfHome,
        configuration: ElfConfiguration,
        options: Options,
        chats: [ChatConversation],
        exportedElfIdentifier: String = ElfManager.mainElfIdentifier,
        to destinationURL: URL
    ) throws {
        let packageFiles = try packageFiles(
            home: home,
            configuration: configuration,
            options: options,
            chats: chats,
            exportedElfIdentifier: exportedElfIdentifier
        )
        let packageManifest = ElfPackageManifest(
            format: ElfPackageManifest.formatIdentifier,
            formatVersion: ElfPackageManifest.currentFormatVersion,
            createdBy: "elfhub " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
            elf: ElfPackageIdentity(
                id: exportedElfIdentifier,
                name: configuration.identity.name,
                emoji: configuration.identity.emoji,
                description: configuration.identity.description
            ),
            entries: packageFiles.map { ElfPackageEntry(path: $0.path, size: $0.data.count, sha256: ElfImportValidator.sha256Hex($0.data)) },
            includesChats: options.includesChats,
            includesProfile: options.includesProfile,
            totals: ElfPackageTotals(entryCount: packageFiles.count, byteCount: packageFiles.reduce(0) { $0 + $1.data.count })
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestFile = ElfArchiveFileToWrite(path: ElfPackageManifest.fileName, data: try manifestEncoder.encode(packageManifest))
        let zipData = try ElfArchive.zipData(files: [manifestFile] + packageFiles)
        try zipData.write(to: destinationURL, options: .atomic)
    }

    /// The conversation with only this elf's exchanges (its replies and the
    /// questions before them), without screenshots or undo links; nil when
    /// it has none.
    static func conversationWithOnlyExchanges(of exportedElfIdentifier: String, from conversation: ChatConversation) -> ChatConversation? {
        let isMainElf = exportedElfIdentifier == ElfManager.mainElfIdentifier
        var keptMessages: [StoredChatMessage] = []
        var pendingQuestion: StoredChatMessage?
        for message in conversation.messages {
            switch message.role {
            case .user:
                pendingQuestion = message
            case .assistant:
                let isThisElfsReply = isMainElf ? message.speakingElfIdentifier == nil : message.speakingElfIdentifier == exportedElfIdentifier
                guard isThisElfsReply, message.kind == .exchange, !message.isError, let question = pendingQuestion else { continue }
                for keptMessage in [question, message] {
                    var cleanedMessage = keptMessage
                    cleanedMessage.screenshotFileName = nil
                    cleanedMessage.fileChanges = []
                    // Nothing taken from the screen: no marks, no drawing.
                    cleanedMessage.screenGuidance = nil
                    cleanedMessage.userInk = nil
                    keptMessages.append(cleanedMessage)
                }
                pendingQuestion = nil
            }
        }
        guard !keptMessages.isEmpty else { return nil }
        var exportedConversation = conversation
        exportedConversation.messages = keptMessages
        return exportedConversation
    }

    /// "Ada's Helper" → "Ada-s-Helper"; used for the package's file name.
    static func packageBaseName(forElfName elfName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitizedName = String(elfName.unicodeScalars.map { allowedCharacters.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitizedName.isEmpty ? "elf" : sanitizedName
    }

    /// An export its own import would refuse fails here, naming the file.
    private static func checkThatItCanBeImported(_ packageFiles: [ElfArchiveFileToWrite]) throws {
        guard packageFiles.count < ElfImportValidator.maximumEntryCount else {
            throw ElfExportProblem.fileCannotBeShared(path: "files/", reason: "there are more than \(ElfImportValidator.maximumEntryCount) files.")
        }
        guard packageFiles.reduce(0, { $0 + $1.data.count }) <= ElfImportValidator.maximumTotalBytes else {
            throw ElfExportProblem.fileCannotBeShared(path: "files/", reason: "together they're over 100 MB.")
        }
        var foldedPathsSeen: Set<String> = []
        for packageFile in packageFiles {
            let shownPath = String(packageFile.path.dropFirst("elf/".count))
            guard ElfImportValidator.isSafePath(packageFile.path) else {
                throw ElfExportProblem.fileCannotBeShared(path: shownPath, reason: "its name or folder depth can't be shared.")
            }
            guard foldedPathsSeen.insert(ElfImportValidator.foldedForDiskComparison(packageFile.path)).inserted else {
                throw ElfExportProblem.fileCannotBeShared(path: shownPath, reason: "another file has the same name apart from capitals.")
            }
        }
    }

    /// Every plain, visible file under a folder (links and hidden files
    /// left out), as package paths. A file too large to import is refused
    /// before it's read.
    private static func regularFiles(inside folderURL: URL, packagePathPrefix: String) throws -> [ElfArchiveFileToWrite] {
        guard let folderEnumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let resolvedFolderPath = folderURL.resolvingSymlinksInPath().path
        var regularFiles: [ElfArchiveFileToWrite] = []
        for case let fileURL as URL in folderEnumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard resourceValues?.isSymbolicLink != true, resourceValues?.isRegularFile == true else { continue }
            let filePath = fileURL.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(resolvedFolderPath + "/") else { continue }
            let pathInsideFolder = String(filePath.dropFirst(resolvedFolderPath.count + 1))
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard fileSize <= ElfImportValidator.maximumFileBytes else {
                throw ElfExportProblem.fileCannotBeShared(path: packagePathPrefix.dropFirst("elf/".count) + pathInsideFolder, reason: "it's over 10 MB.")
            }
            regularFiles.append(ElfArchiveFileToWrite(path: packagePathPrefix + pathInsideFolder, data: try Data(contentsOf: fileURL)))
        }
        return regularFiles.sorted { $0.path < $1.path }
    }
}

/// Why an elf can't be exported as it is.
nonisolated enum ElfExportProblem: LocalizedError, Equatable {
    case fileCannotBeShared(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .fileCannotBeShared(path, reason): return "\(path) can't go in a .elf file: \(reason)"
        }
    }
}
