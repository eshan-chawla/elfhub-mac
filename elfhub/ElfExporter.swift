//
//  ElfExporter.swift
//  elfhub
//
//  Packs an elf into a shareable `.elf` file (a zip of part of its home):
//  always elf.json, soul.md and skills/; profile.md (notes about the user)
//  and files/ only when the user switches them on. Nothing outside the elf's
//  home is ever included, and neither is access.json (this Mac's grants to
//  the user's folders).
//

import Foundation

nonisolated enum ElfExporter {
    struct Options: Equatable, Sendable {
        var includesProfile = false
        var includesFiles = false
    }

    /// The home's top-level items that go into an export.
    static func exportedItemNames(options: Options) -> [String] {
        var exportedItemNames = ["elf.json", "soul.md", "skills"]
        if options.includesProfile { exportedItemNames.append("profile.md") }
        if options.includesFiles { exportedItemNames.append("files") }
        return exportedItemNames
    }

    /// Stages the chosen parts in a temporary folder named after the elf.
    /// `configuration` is written as the export's elf.json (with the current
    /// setup filled into `preferredModels`).
    static func stageExport(home: ElfHome, configuration: ElfConfiguration, options: Options) throws -> URL {
        let fileManager = FileManager.default
        let stagingParentDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("elf-export-\(UUID().uuidString)", isDirectory: true)
        let stagedElfDirectory = stagingParentDirectory
            .appendingPathComponent(packageBaseName(forElfName: configuration.identity.name), isDirectory: true)
        try fileManager.createDirectory(at: stagedElfDirectory, withIntermediateDirectories: true)

        let stagedHome = ElfHome(directory: stagedElfDirectory)
        try stagedHome.writeConfiguration(configuration)
        for exportedItemName in exportedItemNames(options: options) where exportedItemName != "elf.json" {
            let sourceURL = home.directory.appendingPathComponent(exportedItemName)
            let destinationURL = stagedElfDirectory.appendingPathComponent(exportedItemName)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } else if exportedItemName == "skills" || exportedItemName == "files" {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            }
        }
        // Symlinks could point anywhere on this Mac; never ship them.
        try removeSymbolicLinks(inside: stagedElfDirectory)
        return stagedElfDirectory
    }

    /// Writes the `.elf` file to `destinationURL`, replacing an existing file.
    static func export(home: ElfHome, configuration: ElfConfiguration, options: Options, to destinationURL: URL) throws {
        let stagedElfDirectory = try stageExport(home: home, configuration: configuration, options: options)
        defer { try? FileManager.default.removeItem(at: stagedElfDirectory.deletingLastPathComponent()) }

        var coordinationError: NSError?
        var copyError: Error?
        // Reading a folder "for uploading" hands back a zip of it.
        NSFileCoordinator().coordinate(
            readingItemAt: stagedElfDirectory,
            options: .forUploading,
            error: &coordinationError
        ) { zippedElfURL in
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: zippedElfURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    /// "Ada's Helper" → "Ada-s-Helper"; used for the package and its folder.
    static func packageBaseName(forElfName elfName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitizedName = String(elfName.unicodeScalars.map { allowedCharacters.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitizedName.isEmpty ? "elf" : sanitizedName
    }

    private static func removeSymbolicLinks(inside directoryURL: URL) throws {
        guard let directoryEnumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return }
        for case let itemURL as URL in directoryEnumerator
        where (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            try FileManager.default.removeItem(at: itemURL)
        }
    }
}
