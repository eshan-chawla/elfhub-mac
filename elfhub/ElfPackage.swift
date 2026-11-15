//
//  ElfPackage.swift
//  elfhub
//
//  The .elf file format (version 2) and the checks an import makes before
//  anything touches disk. A .elf is a zip:
//
//    manifest.json         ElfPackageManifest: format, version, the elf,
//                          every entry with its size and SHA-256
//    elf/…                 the elf's folder (elf.json, soul.md, skills/,
//                          files/, profile.md when included)
//    chats/<uuid>.json     chats with that elf, when included
//
//  ElfImportValidator reads the zip's directory first and refuses, before
//  extracting anything: damaged or encrypted entries, zip64, more than 5,000
//  entries, more than 100 MB in all or 10 MB in one file, compression above
//  100:1, paths that are absolute, contain .., backslashes or control
//  characters, aren't UTF-8 or go deeper than 12 folders, names outside the
//  layout, duplicates that differ only in case, links, a missing or damaged
//  manifest, a newer format, and any entry whose checksum doesn't match.
//  macOS's __MACOSX/ and .DS_Store are ignored.
//

import CryptoKit
import Foundation

nonisolated struct ElfPackageIdentity: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var emoji: String
    var description: String
}

nonisolated struct ElfPackageEntry: Codable, Equatable, Sendable {
    var path: String
    var size: Int
    var sha256: String
}

nonisolated struct ElfPackageTotals: Codable, Equatable, Sendable {
    var entryCount: Int
    var byteCount: Int
}

nonisolated struct ElfPackageManifest: Codable, Equatable, Sendable {
    static let fileName = "manifest.json"
    static let formatIdentifier = "com.elfhub.elf"
    static let currentFormatVersion = 2

    var format: String
    var formatVersion: Int
    var createdBy: String
    var elf: ElfPackageIdentity
    var entries: [ElfPackageEntry]
    var includesChats: Bool
    var includesProfile: Bool
    var totals: ElfPackageTotals
}

/// Why an import was refused, in words for the user.
nonisolated enum ElfImportRejection: LocalizedError, Equatable {
    case notAnElfFile
    case madeByAnEarlyTestBuild
    case missingOrDamagedManifest
    case madeByANewerElfhub
    case tooManyEntries
    case tooLarge
    case unsupportedEntry(String)
    case unsafePath(String)
    case unexpectedEntry(String)
    case duplicateEntry(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .notAnElfFile: return "This isn't a .elf file elfhub can read."
        case .madeByAnEarlyTestBuild: return "This .elf was made by an early test build and can't be imported."
        case .missingOrDamagedManifest: return "This .elf is missing its description of what's inside, or it's damaged."
        case .madeByANewerElfhub: return "This .elf was made by a newer elfhub. Update elfhub to import it."
        case .tooManyEntries: return "This .elf has too many files."
        case .tooLarge: return "This .elf is too large, or one of its files is."
        case let .unsupportedEntry(path): return "\(path) is stored in a way elfhub doesn't import (encrypted, a link, or zip64)."
        case let .unsafePath(path): return "\(path) has a name elfhub won't write."
        case let .unexpectedEntry(path): return "\(path) doesn't belong in a .elf file."
        case let .duplicateEntry(path): return "\(path) appears twice."
        case let .checksumMismatch(path): return "\(path) doesn't match the file's description — it may have been changed."
        }
    }
}

/// A package that passed every check, with its files in memory.
nonisolated struct ElfValidatedPackage: Sendable {
    let manifest: ElfPackageManifest
    let files: [(path: String, data: Data)]
}

nonisolated enum ElfImportValidator {
    static let maximumEntryCount = 5_000
    static let maximumTotalBytes = 100 * 1024 * 1024
    static let maximumFileBytes = 10 * 1024 * 1024
    static let maximumCompressionRatio = 100
    static let maximumPathDepth = 12

    static func validate(packageData: Data) throws -> ElfValidatedPackage {
        let archiveEntries: [ElfArchiveEntry]
        do {
            archiveEntries = try ElfArchive.entries(in: packageData)
        } catch {
            throw ElfImportRejection.notAnElfFile
        }
        let keptEntries = archiveEntries.filter { !isIgnoredJunk($0.path) && !$0.isDirectory }
        guard keptEntries.count <= maximumEntryCount else { throw ElfImportRejection.tooManyEntries }
        // Exports from the early test builds had no manifest and kept
        // elf.json at the top (or in one folder), not under elf/.
        let hasManifest = keptEntries.contains { $0.path == ElfPackageManifest.fileName }
        if !hasManifest, keptEntries.contains(where: { $0.path == "elf.json" || ($0.path.hasSuffix("/elf.json") && !$0.path.hasPrefix("elf/")) }) {
            throw ElfImportRejection.madeByAnEarlyTestBuild
        }

        var totalBytes = 0
        var foldedPathsSeen: Set<String> = []
        for archiveEntry in keptEntries {
            guard !archiveEntry.isEncrypted, !archiveEntry.isSymbolicLink, !archiveEntry.needsZip64 else {
                throw ElfImportRejection.unsupportedEntry(archiveEntry.path)
            }
            switch archiveEntry.compressionMethod {
            case .store, .deflate: break
            case .other: throw ElfImportRejection.unsupportedEntry(archiveEntry.path)
            }
            guard String(data: archiveEntry.rawPathBytes, encoding: .utf8) != nil, isSafePath(archiveEntry.path) else {
                throw ElfImportRejection.unsafePath(archiveEntry.path)
            }
            guard isInTheLayout(archiveEntry.path) else { throw ElfImportRejection.unexpectedEntry(archiveEntry.path) }
            let foldedPath = archiveEntry.path.lowercased()
            guard !foldedPathsSeen.contains(foldedPath) else { throw ElfImportRejection.duplicateEntry(archiveEntry.path) }
            foldedPathsSeen.insert(foldedPath)
            guard archiveEntry.uncompressedSize <= maximumFileBytes else { throw ElfImportRejection.tooLarge }
            if archiveEntry.uncompressedSize > 0 {
                let compressionRatio = archiveEntry.uncompressedSize / max(1, archiveEntry.compressedSize)
                guard compressionRatio <= maximumCompressionRatio else { throw ElfImportRejection.tooLarge }
            }
            totalBytes += archiveEntry.uncompressedSize
            guard totalBytes <= maximumTotalBytes else { throw ElfImportRejection.tooLarge }
        }

        guard let manifestEntry = keptEntries.first(where: { $0.path == ElfPackageManifest.fileName }) else {
            throw ElfImportRejection.missingOrDamagedManifest
        }
        guard let manifestData = try? ElfArchive.extract(manifestEntry, from: packageData),
              let packageManifest = try? JSONDecoder().decode(ElfPackageManifest.self, from: manifestData),
              packageManifest.format == ElfPackageManifest.formatIdentifier else {
            throw ElfImportRejection.missingOrDamagedManifest
        }
        guard packageManifest.formatVersion <= ElfPackageManifest.currentFormatVersion else {
            throw ElfImportRejection.madeByANewerElfhub
        }

        var manifestEntriesByPath: [String: ElfPackageEntry] = [:]
        for manifestPackageEntry in packageManifest.entries {
            manifestEntriesByPath[manifestPackageEntry.path] = manifestPackageEntry
        }
        var validatedFiles: [(path: String, data: Data)] = []
        for archiveEntry in keptEntries where archiveEntry.path != ElfPackageManifest.fileName {
            guard let manifestPackageEntry = manifestEntriesByPath.removeValue(forKey: archiveEntry.path) else {
                throw ElfImportRejection.checksumMismatch(archiveEntry.path)
            }
            let entryData: Data
            do {
                entryData = try ElfArchive.extract(archiveEntry, from: packageData)
            } catch {
                throw ElfImportRejection.checksumMismatch(archiveEntry.path)
            }
            guard entryData.count == manifestPackageEntry.size, sha256Hex(entryData) == manifestPackageEntry.sha256 else {
                throw ElfImportRejection.checksumMismatch(archiveEntry.path)
            }
            validatedFiles.append((archiveEntry.path, entryData))
        }
        if let missingPath = manifestEntriesByPath.keys.sorted().first {
            throw ElfImportRejection.checksumMismatch(missingPath)
        }
        return ElfValidatedPackage(manifest: packageManifest, files: validatedFiles)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// macOS's resource-fork folder and Finder's .DS_Store files.
    static func isIgnoredJunk(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || (path as NSString).lastPathComponent == ".DS_Store"
    }

    /// Relative, plain names only, at most 12 folders deep.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.hasPrefix("~") else { return false }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pathComponents.count <= maximumPathDepth + 1 else { return false }
        return pathComponents.allSatisfy { pathComponent in
            !pathComponent.isEmpty && pathComponent != "." && pathComponent != ".."
        }
    }

    /// manifest.json, the elf's folder under elf/, and chats/<uuid>.json.
    static func isInTheLayout(_ path: String) -> Bool {
        if path == ElfPackageManifest.fileName || path.hasPrefix("elf/") { return true }
        let pathComponents = path.split(separator: "/")
        if pathComponents.count == 2, pathComponents[0] == "chats", pathComponents[1].hasSuffix(".json") {
            return UUID(uuidString: String(pathComponents[1].dropLast(".json".count))) != nil
        }
        return false
    }
}
