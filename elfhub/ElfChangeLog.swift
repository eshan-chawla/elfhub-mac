//
//  ElfChangeLog.swift
//  elfhub
//
//  Every change to a file in an elf's folder — by the elf's tools, the hub
//  or an import — goes through here: the change is made, recorded in
//  .elfhub/changes.jsonl, and the content before and after is kept in
//  .elfhub/change-backups/<sha256> (each content stored once). Any change
//  can be undone, which is recorded as a change of its own, so an undo can
//  be undone too. An undo is refused when the file changed since (someone
//  edited it by hand, say) unless the user forces it. The log keeps the
//  last 500 changes from the last 30 days and at most 20 MB of backups.
//  It lives in .elfhub/, which elf tools can never reach.
//

import CryptoKit
import Foundation

nonisolated struct ElfChangeLogEntry: Codable, Equatable, Identifiable, Sendable {
    enum Operation: String, Codable, Sendable {
        case create
        case modify
        case delete
        case rename
        /// An undo of another entry (`revertsEntryIdentifier`).
        case revert
    }

    /// Who made the change.
    enum Origin: Codable, Equatable, Hashable, Sendable {
        /// A reply in a conversation (nil when it isn't saved).
        case turn(conversationIdentifier: UUID?)
        /// A background task.
        case task(taskIdentifier: UUID)
        /// The user, in the Elves hub.
        case hub
        /// An imported `.elf` file.
        case `import`
    }

    /// Content the elf had read before making the change, which may have
    /// steered it (text on screen, in a file, on a web page). The hub
    /// shows a warning on such changes.
    enum Influence: String, Codable, Hashable, Sendable {
        case screen
        case file
        case web
    }

    let id: UUID
    let date: Date
    /// The file's path inside the elf's folder ("files/trip.md").
    let path: String
    /// For a rename: where the file went.
    let renamedToPath: String?
    let operation: Operation
    /// The content before the change; nil when the file didn't exist.
    let previousContentSHA256: String?
    /// The content after the change; nil when the file no longer exists.
    let newContentSHA256: String?
    let origin: Origin
    let influencedBy: Set<Influence>
    /// For an undo: the entry it undid.
    let revertsEntryIdentifier: UUID?
    /// The undo of this entry, if it was undone. Worked out when reading
    /// the log, never stored.
    var revertedByEntryIdentifier: UUID?

    var isUndone: Bool { revertedByEntryIdentifier != nil }
}

nonisolated enum ElfChangeLogError: LocalizedError, Equatable {
    case fileChangedSinceThisChange(path: String)
    case alreadyUndone
    case unknownEntry
    case missingBackup(path: String)
    /// The elf's folder is gone (deleted, or removed in Finder).
    case elfFolderGone

    var errorDescription: String? {
        switch self {
        case let .fileChangedSinceThisChange(path):
            return "\(path) changed since then. Undo anyway to put back the earlier version?"
        case .alreadyUndone:
            return "That change was already undone."
        case .unknownEntry:
            return "That change isn't in the list any more."
        case let .missingBackup(path):
            return "The earlier version of \(path) is no longer kept, so this can't be undone."
        case .elfFolderGone:
            return "This elf's folder is gone."
        }
    }
}

nonisolated struct ElfChangeLog {
    static let maximumEntryCount = 500
    static let maximumEntryAge: TimeInterval = 30 * 24 * 3600
    static let maximumBackupsByteCount = 20 * 1024 * 1024

    let home: ElfHome

    init(home: ElfHome) {
        self.home = home
    }

    var logFileURL: URL { home.appDataDirectory.appendingPathComponent("changes.jsonl") }
    var backupsDirectory: URL { home.appDataDirectory.appendingPathComponent("change-backups", isDirectory: true) }

    // MARK: Recording changes

    /// Writes `newText` to the file (making its folders) and records it.
    @discardableResult
    func recordWrite(
        path: String,
        newText: String,
        origin: ElfChangeLogEntry.Origin,
        influencedBy: Set<ElfChangeLogEntry.Influence>
    ) throws -> ElfChangeLogEntry {
        try requireElfFolder()
        let fileURL = try home.resolvedURLInsideHome(path)
        let previousContent = try? Data(contentsOf: fileURL)
        let newContent = Data(newText.utf8)
        let previousContentSHA256 = try previousContent.map(storeBackup)
        let newContentSHA256 = try storeBackup(newContent)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try newContent.write(to: fileURL, options: .atomic)
        return try appendEntry(ElfChangeLogEntry(
            id: UUID(),
            date: Date(),
            path: path,
            renamedToPath: nil,
            operation: previousContent == nil ? .create : .modify,
            previousContentSHA256: previousContentSHA256,
            newContentSHA256: newContentSHA256,
            origin: origin,
            influencedBy: influencedBy,
            revertsEntryIdentifier: nil
        ))
    }

    /// Deletes the file and records it (with a backup to restore).
    @discardableResult
    func recordDelete(
        path: String,
        origin: ElfChangeLogEntry.Origin,
        influencedBy: Set<ElfChangeLogEntry.Influence>
    ) throws -> ElfChangeLogEntry {
        try requireElfFolder()
        let fileURL = try home.resolvedURLInsideHome(path)
        let previousContent = try Data(contentsOf: fileURL)
        let previousContentSHA256 = try storeBackup(previousContent)
        try FileManager.default.removeItem(at: fileURL)
        return try appendEntry(ElfChangeLogEntry(
            id: UUID(),
            date: Date(),
            path: path,
            renamedToPath: nil,
            operation: .delete,
            previousContentSHA256: previousContentSHA256,
            newContentSHA256: nil,
            origin: origin,
            influencedBy: influencedBy,
            revertsEntryIdentifier: nil
        ))
    }

    /// Moves the file (making the new folders) and records it.
    @discardableResult
    func recordRename(
        from originalPath: String,
        to newPath: String,
        origin: ElfChangeLogEntry.Origin,
        influencedBy: Set<ElfChangeLogEntry.Influence>
    ) throws -> ElfChangeLogEntry {
        try requireElfFolder()
        let originalFileURL = try home.resolvedURLInsideHome(originalPath)
        let newFileURL = try home.resolvedURLInsideHome(newPath)
        let contentSHA256 = Self.sha256(of: try Data(contentsOf: originalFileURL))
        try FileManager.default.createDirectory(at: newFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalFileURL, to: newFileURL)
        return try appendEntry(ElfChangeLogEntry(
            id: UUID(),
            date: Date(),
            path: originalPath,
            renamedToPath: newPath,
            operation: .rename,
            previousContentSHA256: contentSHA256,
            newContentSHA256: contentSHA256,
            origin: origin,
            influencedBy: influencedBy,
            revertsEntryIdentifier: nil
        ))
    }

    // MARK: Reading

    /// Every recorded change, newest first, each marked when it was undone.
    func entries() -> [ElfChangeLogEntry] {
        var storedEntries = readStoredEntries()
        var undoEntryIdentifierByUndoneEntryIdentifier: [UUID: UUID] = [:]
        for storedEntry in storedEntries {
            if let revertsEntryIdentifier = storedEntry.revertsEntryIdentifier {
                undoEntryIdentifierByUndoneEntryIdentifier[revertsEntryIdentifier] = storedEntry.id
            }
        }
        for entryIndex in storedEntries.indices {
            storedEntries[entryIndex].revertedByEntryIdentifier = undoEntryIdentifierByUndoneEntryIdentifier[storedEntries[entryIndex].id]
        }
        return storedEntries.reversed()
    }

    // MARK: Undo

    /// Undoes a change — puts the file back the way it was before it — and
    /// records the undo. Refused when the file changed since, unless
    /// `force` is true.
    @discardableResult
    func undo(entryIdentifier: UUID, force: Bool) throws -> ElfChangeLogEntry {
        try requireElfFolder()
        guard let undoneEntry = entries().first(where: { $0.id == entryIdentifier }) else {
            throw ElfChangeLogError.unknownEntry
        }
        guard !undoneEntry.isUndone else { throw ElfChangeLogError.alreadyUndone }

        if let renamedToPath = undoneEntry.renamedToPath {
            // A rename (or the undo of one) is undone by moving it back.
            let currentFileURL = try home.resolvedURLInsideHome(renamedToPath)
            let originalFileURL = try home.resolvedURLInsideHome(undoneEntry.path)
            let currentContentSHA256 = (try? Data(contentsOf: currentFileURL)).map(Self.sha256)
            let fileIsStillWhereTheRenamePutIt = currentContentSHA256 != nil
                && !FileManager.default.fileExists(atPath: originalFileURL.path)
            guard fileIsStillWhereTheRenamePutIt else {
                throw ElfChangeLogError.fileChangedSinceThisChange(path: renamedToPath)
            }
            try FileManager.default.createDirectory(at: originalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: currentFileURL, to: originalFileURL)
            return try appendEntry(ElfChangeLogEntry(
                id: UUID(),
                date: Date(),
                path: renamedToPath,
                renamedToPath: undoneEntry.path,
                operation: .revert,
                previousContentSHA256: currentContentSHA256,
                newContentSHA256: currentContentSHA256,
                origin: .hub,
                influencedBy: [],
                revertsEntryIdentifier: undoneEntry.id
            ))
        }

        let fileURL = try home.resolvedURLInsideHome(undoneEntry.path)
        let currentContent = try? Data(contentsOf: fileURL)
        let currentContentSHA256 = currentContent.map(Self.sha256)
        if !force, currentContentSHA256 != undoneEntry.newContentSHA256 {
            throw ElfChangeLogError.fileChangedSinceThisChange(path: undoneEntry.path)
        }
        // A forced undo keeps what it overwrites, so it can be undone too.
        let overwrittenContentSHA256 = try currentContent.map(storeBackup)

        if let previousContentSHA256 = undoneEntry.previousContentSHA256 {
            guard let previousContent = try? Data(contentsOf: backupURL(forContentSHA256: previousContentSHA256)) else {
                throw ElfChangeLogError.missingBackup(path: undoneEntry.path)
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try previousContent.write(to: fileURL, options: .atomic)
        } else if currentContent != nil {
            try FileManager.default.removeItem(at: fileURL)
        }

        return try appendEntry(ElfChangeLogEntry(
            id: UUID(),
            date: Date(),
            path: undoneEntry.path,
            renamedToPath: nil,
            operation: .revert,
            previousContentSHA256: overwrittenContentSHA256,
            newContentSHA256: undoneEntry.previousContentSHA256,
            origin: .hub,
            influencedBy: [],
            revertsEntryIdentifier: undoneEntry.id
        ))
    }

    // MARK: Pruning

    /// Keeps the newest 500 changes from the last 30 days, then drops the
    /// oldest until the backups they need fit in 20 MB, and deletes
    /// backups no change needs any more.
    func prune(now: Date) throws {
        var keptEntries = readStoredEntries()
            .filter { now.timeIntervalSince($0.date) <= Self.maximumEntryAge }
        if keptEntries.count > Self.maximumEntryCount {
            keptEntries.removeFirst(keptEntries.count - Self.maximumEntryCount)
        }

        var backupByteCountBySHA256: [String: Int] = [:]
        for backupFileName in (try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)) ?? [] {
            let backupFileSize = (try? FileManager.default.attributesOfItem(
                atPath: backupsDirectory.appendingPathComponent(backupFileName).path
            )[.size] as? Int) ?? 0
            backupByteCountBySHA256[backupFileName] = backupFileSize
        }
        func neededBackupByteCount(_ entries: [ElfChangeLogEntry]) -> Int {
            let neededSHA256s = Set(entries.flatMap { [$0.previousContentSHA256, $0.newContentSHA256].compactMap { $0 } })
            return neededSHA256s.reduce(0) { byteCount, contentSHA256 in byteCount + (backupByteCountBySHA256[contentSHA256] ?? 0) }
        }
        while !keptEntries.isEmpty, neededBackupByteCount(keptEntries) > Self.maximumBackupsByteCount {
            keptEntries.removeFirst()
        }

        try writeStoredEntries(keptEntries)
        let neededSHA256s = Set(keptEntries.flatMap { [$0.previousContentSHA256, $0.newContentSHA256].compactMap { $0 } })
        for backupFileName in backupByteCountBySHA256.keys where !neededSHA256s.contains(backupFileName) {
            try? FileManager.default.removeItem(at: backupsDirectory.appendingPathComponent(backupFileName))
        }
    }

    /// The size of every kept backup, in bytes.
    func backupsByteCount() -> Int {
        let backupFileNames = (try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
        return backupFileNames.reduce(0) { byteCount, backupFileName in
            let backupFileSize = (try? FileManager.default.attributesOfItem(
                atPath: backupsDirectory.appendingPathComponent(backupFileName).path
            )[.size] as? Int) ?? 0
            return byteCount + backupFileSize
        }
    }

    // MARK: Storage

    /// A change never recreates an elf whose folder is gone — a worker still
    /// finishing after its elf was deleted, say.
    private func requireElfFolder() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ElfChangeLogError.elfFolderGone
        }
    }

    static func sha256(of content: Data) -> String {
        SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }

    private func backupURL(forContentSHA256 contentSHA256: String) -> URL {
        backupsDirectory.appendingPathComponent(contentSHA256)
    }

    /// Keeps a copy of `content` (once per content) and returns its hash.
    private func storeBackup(_ content: Data) throws -> String {
        let contentSHA256 = Self.sha256(of: content)
        let contentBackupURL = backupURL(forContentSHA256: contentSHA256)
        if !FileManager.default.fileExists(atPath: contentBackupURL.path) {
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            try content.write(to: contentBackupURL, options: .atomic)
        }
        return contentSHA256
    }

    private static let jsonEncoder: JSONEncoder = {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.sortedKeys]
        return jsonEncoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return jsonDecoder
    }()

    /// Oldest first, as stored. Lines that can't be read are skipped.
    private func readStoredEntries() -> [ElfChangeLogEntry] {
        guard let logText = try? String(contentsOf: logFileURL, encoding: .utf8) else { return [] }
        return logText
            .split(separator: "\n")
            .compactMap { logLine in try? Self.jsonDecoder.decode(ElfChangeLogEntry.self, from: Data(logLine.utf8)) }
    }

    private func writeStoredEntries(_ storedEntries: [ElfChangeLogEntry]) throws {
        try FileManager.default.createDirectory(at: home.appDataDirectory, withIntermediateDirectories: true)
        let logLines = try storedEntries.map { storedEntry -> String in
            var entryWithoutDerivedFields = storedEntry
            entryWithoutDerivedFields.revertedByEntryIdentifier = nil
            return String(decoding: try Self.jsonEncoder.encode(entryWithoutDerivedFields), as: UTF8.self)
        }
        try Data((logLines.joined(separator: "\n") + (logLines.isEmpty ? "" : "\n")).utf8).write(to: logFileURL, options: .atomic)
    }

    private func appendEntry(_ entry: ElfChangeLogEntry) throws -> ElfChangeLogEntry {
        try FileManager.default.createDirectory(at: home.appDataDirectory, withIntermediateDirectories: true)
        let logLine = String(decoding: try Self.jsonEncoder.encode(entry), as: UTF8.self) + "\n"
        if let logFileHandle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? logFileHandle.close() }
            try logFileHandle.seekToEnd()
            try logFileHandle.write(contentsOf: Data(logLine.utf8))
        } else {
            try Data(logLine.utf8).write(to: logFileURL, options: .atomic)
        }
        return entry
    }
}
