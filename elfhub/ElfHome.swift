//
//  ElfHome.swift
//  elfhub
//
//  An elf's home folder, and the only code that reads or writes it:
//
//    ~/Library/Application Support/elfhub/Elfs/<elf id>/
//      elf.json  soul.md  user.md  skills/<slug>/SKILL.md  files/  access.json
//      .elfhub/      the app's own data about this elf (per-Mac settings,
//                    and later its change history and tasks) — never the
//                    elf's to touch and never exported
//
//  Every path the elf names is checked with `resolvedURLInsideHome(_:)`, so
//  nothing it asks for can reach outside its home (no "..", no absolute
//  paths, no symlinks pointing out). Text is size-capped so the files stay
//  small enough to go into every prompt.
//

import Foundation

nonisolated enum ElfHomeError: LocalizedError, Equatable {
    case pathOutsideHome(String)
    case textTooLong(fileDescription: String, characterLimit: Int)
    case notTextFile(String)
    case reservedPath(String)
    /// elf.json is there but can't be read (a hand edit that broke the
    /// JSON, say). Nothing is written over it, so the Elf's name and settings
    /// aren't replaced with defaults.
    case configurationUnreadable

    var errorDescription: String? {
        switch self {
        case let .pathOutsideHome(path):
            return "\(path) is outside the Elf's home folder."
        case let .textTooLong(fileDescription, characterLimit):
            return "\(fileDescription) is longer than \(characterLimit) characters. Shorten it and try again."
        case let .notTextFile(path):
            return "\(path) isn't a text file."
        case let .reservedPath(path):
            return "\(path) belongs to elfhub, not the Elf."
        case .configurationUnreadable:
            return "This Elf's elf.json couldn't be read, so nothing was saved over it. Fix the file (Show in Finder) or move it away, then try again."
        }
    }
}

/// Whether an elf tool wants to read a path or change it.
nonisolated enum ElfToolPathAccess: Sendable {
    case read
    case write
}

nonisolated struct ElfHome: Equatable, Sendable {
    let directory: URL

    static let soulCharacterLimit = 8_000
    /// user.md holds what the Elf knows about the user and a memory of past
    /// conversations (MainElfMemoryKeeper), so it's larger than the soul.
    static let userNotesCharacterLimit = 12_000
    static let skillCharacterLimit = 16_000
    static let fileByteLimit = 256_000
    /// The file inside each skill folder, as agentskills.io names it.
    static let skillFileName = "SKILL.md"

    var configurationURL: URL { directory.appendingPathComponent("elf.json") }
    var soulURL: URL { directory.appendingPathComponent("soul.md") }
    /// What the Elf knows about the user: notes, and (for the main Elf) a
    /// memory of past conversations. Called profile.md before 0.0.2.
    var userNotesURL: URL { directory.appendingPathComponent(Self.userNotesFileName) }
    static let userNotesFileName = "user.md"
    static let legacyUserNotesFileName = "profile.md"
    var skillsDirectory: URL { directory.appendingPathComponent("skills", isDirectory: true) }
    var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }
    /// This Mac's grants to the user's folders. Never exported.
    var accessURL: URL { directory.appendingPathComponent("access.json") }
    /// The app's own data about this elf. Elf tools can't reach it and
    /// exports leave it out.
    var appDataDirectory: URL { directory.appendingPathComponent(Self.appDataFolderName, isDirectory: true) }
    /// Which of this Mac's models and voices the elf uses.
    var localSettingsURL: URL { appDataDirectory.appendingPathComponent("local-settings.json") }
    /// The picture the user chose for the elf's avatar: a square PNG made by
    /// `ElfAvatarPicture`. In the app's own data, so elf tools can't swap it
    /// and it stays on this Mac like the rest of `.elfhub/`.
    var avatarPictureURL: URL { appDataDirectory.appendingPathComponent("avatar.png") }

    static let appDataFolderName = ".elfhub"
    /// Top-level items in the home that elf tools may never read or write.
    static let pathsReservedForTheApp: Set<String> = [appDataFolderName, "elf.json", "access.json"]
    /// Top-level items elf tools may read but never write: the soul is the
    /// user's, so text the elf read somewhere can't rewrite its standing
    /// instructions.
    static let pathsElfToolsMayOnlyRead: Set<String> = ["soul.md"]

    /// ~/Library/Application Support/elfhub
    static var defaultElfhubDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elfhub", isDirectory: true)
    }

    /// ~/Library/Application Support/elfhub/Elfs
    static var defaultElfsDirectory: URL {
        defaultElfhubDataDirectory.appendingPathComponent(ElfsFolderMigration.currentFolderName, isDirectory: true)
    }

    // MARK: Creating

    /// Makes the folders and starter files that don't exist yet; never
    /// overwrites what's there.
    func createIfNeeded(configuration: ElfConfiguration = ElfConfiguration()) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appDataDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: configurationURL.path) {
            try writeConfiguration(configuration)
        }
        if !fileManager.fileExists(atPath: soulURL.path) {
            try writeSoul(Self.starterSoul)
        }
        moveLegacyUserNotesIfNeeded()
        if !fileManager.fileExists(atPath: userNotesURL.path) {
            try writeUserNotes(Self.starterUserNotes)
        }
        migrateLegacySkillFilesOnce()
    }

    /// 0.0.1 called the user notes profile.md: rename it once, keeping what
    /// the Elf noted. If both exist, user.md wins and profile.md is left.
    /// Also run for every Elf when the roster is read, so side Elfs from
    /// 0.0.1 (never passed through `createIfNeeded`) keep their notes.
    func moveLegacyUserNotesIfNeeded() {
        let fileManager = FileManager.default
        let legacyUserNotesURL = directory.appendingPathComponent(Self.legacyUserNotesFileName)
        guard fileManager.fileExists(atPath: legacyUserNotesURL.path),
              !fileManager.fileExists(atPath: userNotesURL.path) else { return }
        try? fileManager.moveItem(at: legacyUserNotesURL, to: userNotesURL)
    }

    /// Marks that phase-1 skill files were moved once, so a markdown file
    /// dropped into skills/ later (a README, say) isn't turned into a skill.
    var legacySkillsMigratedMarkerURL: URL { appDataDirectory.appendingPathComponent("legacy-skills-migrated") }

    private func migrateLegacySkillFilesOnce() {
        guard !FileManager.default.fileExists(atPath: legacySkillsMigratedMarkerURL.path) else { return }
        migrateLegacySkillFilesIfNeeded()
        try? Data().write(to: legacySkillsMigratedMarkerURL)
    }

    // MARK: elf.json

    func readConfiguration() -> ElfConfiguration {
        guard let configurationData = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(ElfConfiguration.self, from: configurationData) else {
            return ElfConfiguration()
        }
        return configuration
    }

    /// True when elf.json exists but doesn't decode. `readConfiguration()`
    /// then returns defaults for display, and `writeConfiguration` refuses.
    var isConfigurationUnreadable: Bool {
        guard let configurationData = try? Data(contentsOf: configurationURL) else { return false }
        return (try? JSONDecoder().decode(ElfConfiguration.self, from: configurationData)) == nil
    }

    func writeConfiguration(_ configuration: ElfConfiguration) throws {
        // Never replace an elf.json we couldn't read: the edit was made on
        // top of defaults, and saving it would lose the real name, aliases
        // and settings.
        if isConfigurationUnreadable {
            throw ElfHomeError.configurationUnreadable
        }
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try jsonEncoder.encode(configuration).write(to: configurationURL, options: .atomic)
    }

    // MARK: .elfhub/local-settings.json

    /// Empty settings (use the main elf's model and voice) when the file is
    /// missing or unreadable.
    func readLocalSettings() -> ElfLocalSettings {
        guard let localSettingsData = try? Data(contentsOf: localSettingsURL),
              let localSettings = try? JSONDecoder().decode(ElfLocalSettings.self, from: localSettingsData) else {
            return ElfLocalSettings()
        }
        return localSettings
    }

    func writeLocalSettings(_ localSettings: ElfLocalSettings) throws {
        try FileManager.default.createDirectory(at: appDataDirectory, withIntermediateDirectories: true)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try jsonEncoder.encode(localSettings).write(to: localSettingsURL, options: .atomic)
    }

    // MARK: .elfhub/avatar.png

    func writeAvatarPicture(pngData: Data) throws {
        try FileManager.default.createDirectory(at: appDataDirectory, withIntermediateDirectories: true)
        try pngData.write(to: avatarPictureURL, options: .atomic)
    }

    func removeAvatarPicture() throws {
        guard FileManager.default.fileExists(atPath: avatarPictureURL.path) else { return }
        try FileManager.default.removeItem(at: avatarPictureURL)
    }

    // MARK: soul.md and user.md

    func readSoul() -> String {
        (try? String(contentsOf: soulURL, encoding: .utf8)) ?? Self.starterSoul
    }

    func writeSoul(_ soulText: String) throws {
        try writeText(soulText, to: soulURL, characterLimit: Self.soulCharacterLimit, fileDescription: "soul.md")
    }

    func readUserNotes() -> String {
        (try? String(contentsOf: userNotesURL, encoding: .utf8)) ?? ""
    }

    func writeUserNotes(_ profileText: String) throws {
        try writeText(profileText, to: userNotesURL, characterLimit: Self.userNotesCharacterLimit, fileDescription: Self.userNotesFileName)
    }

    // MARK: Skills

    /// Every skill, sorted by name. A skill is a folder in skills/ holding a
    /// SKILL.md; folders without one (or hidden ones) are skipped.
    func readSkills() -> [ElfSkill] {
        let skillFolderNames = (try? FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)) ?? []
        return skillFolderNames
            .filter { !$0.hasPrefix(".") }
            .compactMap { skillFolderName -> ElfSkill? in
                let skillFileURL = skillsDirectory
                    .appendingPathComponent(skillFolderName, isDirectory: true)
                    .appendingPathComponent(Self.skillFileName)
                guard let skillMarkdown = try? String(contentsOf: skillFileURL, encoding: .utf8) else { return nil }
                return ElfSkill.parse(slug: skillFolderName, skillMarkdown: skillMarkdown)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func writeSkill(_ skill: ElfSkill) throws {
        let skillFileURL = try resolvedURLInsideHome("skills/\(skill.slug)/\(Self.skillFileName)")
        try FileManager.default.createDirectory(at: skillFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeText(skill.skillMarkdown, to: skillFileURL, characterLimit: Self.skillCharacterLimit, fileDescription: "The skill \"\(skill.name)\"")
    }

    /// Removes the skill's whole folder, with anything else it carried.
    func deleteSkill(slug: String) throws {
        let skillFolderURL = try resolvedURLInsideHome("skills/\(slug)")
        try FileManager.default.removeItem(at: skillFolderURL)
    }

    /// Moves skills saved as single skills/<name>.md files (before skills
    /// were SKILL.md folders) into skills/<slug>/SKILL.md. A file whose
    /// folder already exists is left where it is rather than overwrite.
    func migrateLegacySkillFilesIfNeeded() {
        let fileManager = FileManager.default
        let skillsFolderItemNames = (try? fileManager.contentsOfDirectory(atPath: skillsDirectory.path)) ?? []
        for legacySkillFileName in skillsFolderItemNames where legacySkillFileName.hasSuffix(".md") && !legacySkillFileName.hasPrefix(".") {
            let legacySkillFileURL = skillsDirectory.appendingPathComponent(legacySkillFileName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: legacySkillFileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let legacyMarkdown = try? String(contentsOf: legacySkillFileURL, encoding: .utf8) else { continue }
            let migratedSkill = ElfLegacySkillMigration.skill(
                fromLegacyFileName: String(legacySkillFileName.dropLast(".md".count)),
                markdown: legacyMarkdown
            )
            let migratedSkillFolderURL = skillsDirectory.appendingPathComponent(migratedSkill.slug, isDirectory: true)
            guard !fileManager.fileExists(atPath: migratedSkillFolderURL.path) else { continue }
            do {
                try writeSkill(migratedSkill)
                try fileManager.removeItem(at: legacySkillFileURL)
            } catch {
                print("⚠️ elfhub: Couldn't move the skill \(legacySkillFileName) into a SKILL.md folder: \(error)")
            }
        }
    }

    // MARK: files/

    /// Every file in the Elf's folder a person may audit — user.md, soul.md,
    /// skills/ and files/ — with its size and when it last changed, sorted
    /// by path. The app's own data (.elfhub/, elf.json, access.json) and
    /// hidden files are left out, and nothing outside the folder is
    /// followed (links pointing out are skipped).
    func fileEntries(limit: Int = 2_000) -> [ElfFileEntry] {
        let fileManager = FileManager.default
        let resolvedHomePath = directory.resolvingSymlinksInPath().path
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let fileEnumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var fileEntries: [ElfFileEntry] = []
        for case let fileURL as URL in fileEnumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            // Links are never listed or followed: one could point anywhere.
            // (skipDescendants is only for real folders — on anything else
            // it would skip the last folder the enumerator entered.)
            if resourceValues?.isSymbolicLink == true { continue }
            let isRealDirectory = resourceValues?.isDirectory == true
            let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
            guard resolvedFilePath.hasPrefix(resolvedHomePath + "/") else {
                if isRealDirectory { fileEnumerator.skipDescendants() }
                continue
            }
            let homeRelativePath = String(resolvedFilePath.dropFirst(resolvedHomePath.count + 1))
            let firstPathComponent = homeRelativePath.split(separator: "/").first.map(String.init) ?? ""
            if Self.pathsReservedForTheApp.contains(firstPathComponent) {
                if isRealDirectory { fileEnumerator.skipDescendants() }
                continue
            }
            guard resourceValues?.isRegularFile == true else { continue }
            fileEntries.append(ElfFileEntry(
                path: homeRelativePath,
                byteCount: Int64(resourceValues?.fileSize ?? 0),
                modifiedAt: resourceValues?.contentModificationDate ?? .distantPast
            ))
            if fileEntries.count >= limit { break }
        }
        return fileEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// How many files the elf keeps in files/ (folders not counted).
    func fileCount() -> Int {
        guard let fileEnumerator = FileManager.default.enumerator(
            at: filesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var regularFileCount = 0
        for case let fileURL as URL in fileEnumerator
        where (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            regularFileCount += 1
        }
        return regularFileCount
    }

    /// Every file in files/, as paths from the home ("files/trip.md"),
    /// newest first. Hidden files are left out.
    func ownNotePaths() -> [String] {
        guard let fileEnumerator = FileManager.default.enumerator(
            at: filesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let resolvedFilesFolderPath = filesDirectory.resolvingSymlinksInPath().path
        var notePathsWithDates: [(notePath: String, modificationDate: Date)] = []
        for case let fileURL as URL in fileEnumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
            guard resolvedFilePath.hasPrefix(resolvedFilesFolderPath + "/") else { continue }
            let pathInsideFilesFolder = String(resolvedFilePath.dropFirst(resolvedFilesFolderPath.count + 1))
            notePathsWithDates.append((
                notePath: "files/" + pathInsideFilesFolder,
                modificationDate: resourceValues?.contentModificationDate ?? .distantPast
            ))
        }
        return notePathsWithDates
            .sorted { firstNote, secondNote in
                if firstNote.modificationDate != secondNote.modificationDate {
                    return firstNote.modificationDate > secondNote.modificationDate
                }
                return firstNote.notePath < secondNote.notePath
            }
            .map(\.notePath)
    }

    // MARK: The user's folders (access.json)

    /// The folders the user let this elf use, on this Mac only (never
    /// exported; unreachable for elf tools).
    func readFolderGrants() -> [ElfFolderGrant] {
        guard let grantsData = try? Data(contentsOf: accessURL) else { return [] }
        return (try? JSONDecoder().decode([ElfFolderGrant].self, from: grantsData)) ?? []
    }

    func writeFolderGrants(_ folderGrants: [ElfFolderGrant]) throws {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try jsonEncoder.encode(folderGrants).write(to: accessURL, options: .atomic)
    }

    // MARK: Paths

    /// A path inside the home, from a relative path the elf (or the app)
    /// names. Rejects absolute paths, "..", and anything that resolves —
    /// symlinks included — outside the home folder. Returns the resolved
    /// path (links followed), so what was checked is what gets read or
    /// written: a link swapped in after the check can't redirect a write.
    func resolvedURLInsideHome(_ relativePath: String) throws -> URL {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponents = trimmedPath.split(separator: "/").map(String.init)
        guard !trimmedPath.isEmpty,
              !trimmedPath.hasPrefix("/"),
              !trimmedPath.hasPrefix("~"),
              !pathComponents.contains(".."),
              !pathComponents.isEmpty else {
            throw ElfHomeError.pathOutsideHome(relativePath)
        }
        let candidateURL = directory.appendingPathComponent(trimmedPath)
        let resolvedHomePath = Self.resolvedPath(of: directory)
        let resolvedCandidatePath = Self.resolvedPath(of: candidateURL)
        guard resolvedCandidatePath.hasPrefix(resolvedHomePath + "/") else {
            throw ElfHomeError.pathOutsideHome(relativePath)
        }
        return URL(fileURLWithPath: resolvedCandidatePath, isDirectory: candidateURL.hasDirectoryPath)
    }

    /// A path an elf's own tools name (reading or writing its notes, for
    /// example). Same checks as `resolvedURLInsideHome`, and the app's own
    /// files are off limits: .elfhub/, elf.json and access.json can't be
    /// read or written, and soul.md can only be read. Compared ignoring
    /// case, as the Mac's disk does.
    func resolvedURLForElfTool(_ relativePath: String, access: ElfToolPathAccess) throws -> URL {
        let resolvedURL = try resolvedURLInsideHome(relativePath)
        // Judged by where the path really lands, not how it's written: "./"
        // and symlinks inside the home (files/x → ../.elfhub) can't sneak
        // past the reserved names.
        let resolvedHomePath = Self.resolvedPath(of: directory)
        let resolvedTargetPath = Self.resolvedPath(of: resolvedURL)
        let pathRelativeToHome = String(resolvedTargetPath.dropFirst(resolvedHomePath.count + 1))
        // Folded as the Mac's disk compares names, so lookalikes
        // ("ACCESS.json", "acceſs.json") count as the reserved file.
        let firstPathComponent = pathRelativeToHome
            .split(separator: "/")
            .first
            .map { String($0).precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil) } ?? ""
        let isReservedForTheApp = Self.pathsReservedForTheApp.contains(firstPathComponent)
        let isReadOnlyForElfTools = access == .write && Self.pathsElfToolsMayOnlyRead.contains(firstPathComponent)
        guard !isReservedForTheApp, !isReadOnlyForElfTools else {
            throw ElfHomeError.reservedPath(relativePath)
        }
        return resolvedURL
    }

    /// The path from the home an elf tool's path really lands on ("./files/a.md"
    /// → "files/a.md"), after the same checks as `resolvedURLForElfTool`.
    func homeRelativePathForElfTool(_ relativePath: String, access: ElfToolPathAccess) throws -> String {
        let resolvedURL = try resolvedURLForElfTool(relativePath, access: access)
        let resolvedHomePath = Self.resolvedPath(of: directory)
        return String(Self.resolvedPath(of: resolvedURL).dropFirst(resolvedHomePath.count + 1))
    }

    /// The real path, following symlinks in every part that exists — a file
    /// that's about to be created still has its folders resolved.
    static func resolvedPath(of fileURL: URL) -> String {
        var existingAncestorURL = fileURL.standardizedFileURL
        var missingPathComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestorURL.path), existingAncestorURL.path != "/" {
            missingPathComponents.insert(existingAncestorURL.lastPathComponent, at: 0)
            existingAncestorURL = existingAncestorURL.deletingLastPathComponent()
        }
        var resolvedURL = existingAncestorURL.resolvingSymlinksInPath()
        for missingPathComponent in missingPathComponents {
            resolvedURL = resolvedURL.appendingPathComponent(missingPathComponent)
        }
        return resolvedURL.standardizedFileURL.path
    }

    private func writeText(_ text: String, to fileURL: URL, characterLimit: Int, fileDescription: String) throws {
        guard text.count <= characterLimit else {
            throw ElfHomeError.textTooLong(fileDescription: fileDescription, characterLimit: characterLimit)
        }
        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    // MARK: Starter files

    /// How the elf talks and helps — today's elfhub rules, now the user's to
    /// edit. The mechanics (coordinates, pointing, notepad) and the rule that
    /// screen text is never an instruction stay in the app's own prompt, so
    /// editing the soul can't break them.
    static let starterSoul = """
    # soul

    i follow these in every conversation. edit them however you like — i'll never change this file myself, i can only suggest changes for you to approve.

    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting in what you say — just natural speech (notepad lines are the exception).
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - never keep passwords, keys, health details or financial details in my notes or skills.

    """

    static let starterUserNotes = """
    # user

    ## About you

    ## What we've talked about

    """
}

// MARK: - Moving 0.0.1's Elves folder

/// elfhub 0.0.1 kept every Elf in `Application Support/elfhub/Elves/`; from
/// 0.0.2 the brand's plural is used and the folder is `Elfs/`. The move runs
/// once, before the roster is first read. Everything inside an Elf's folder
/// refers to its files by paths relative to that folder (change log, tasks),
/// and chats refer to Elfs by id, so moving the folder whole keeps Undo,
/// tasks and chats working.
nonisolated enum ElfsFolderMigration {
    static let legacyFolderName = "Elves"
    static let currentFolderName = "Elfs"

    enum Outcome: Equatable {
        /// There was no `Elves/` folder (a fresh install, or already moved).
        case nothingToMove
        /// `Elves/` became `Elfs/`.
        case moved
        /// Both folders exist — for example a 0.0.1 build was opened after
        /// the move and made a new, empty `Elves/`. `Elfs/` is kept and
        /// `Elves/` is left untouched, so nothing is lost or merged by guess.
        case keptBothFolders
        /// The move failed; the app carries on with whatever `Elfs/` holds.
        case failed(String)
    }

    @discardableResult
    static func moveLegacyElvesFolderIfNeeded(
        elfhubDataDirectory: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        let legacyElvesDirectory = elfhubDataDirectory.appendingPathComponent(legacyFolderName, isDirectory: true)
        let currentElfsDirectory = elfhubDataDirectory.appendingPathComponent(currentFolderName, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyElvesDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .nothingToMove
        }
        if fileManager.fileExists(atPath: currentElfsDirectory.path) {
            return .keptBothFolders
        }
        do {
            try fileManager.moveItem(at: legacyElvesDirectory, to: currentElfsDirectory)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Files for the audit view

/// One file in an Elf's folder, as the Work tab lists it.
nonisolated struct ElfFileEntry: Identifiable, Equatable, Sendable {
    /// From the Elf's folder, e.g. "files/trips/rome.md".
    let path: String
    let byteCount: Int64
    let modifiedAt: Date

    var id: String { path }

    /// The folder it's in ("files/trips"), or "" for the Elf's folder itself.
    var folderPath: String {
        guard let lastSlashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[..<lastSlashIndex])
    }

    var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Files grouped by folder: the Elf's own top-level files first, then
    /// each folder by name; newest first within a folder.
    static func groupedByFolder(_ fileEntries: [ElfFileEntry]) -> [(folderPath: String, fileEntries: [ElfFileEntry])] {
        let entriesByFolder = Dictionary(grouping: fileEntries, by: \.folderPath)
        return entriesByFolder.keys
            .sorted { firstFolder, secondFolder in
                if firstFolder.isEmpty != secondFolder.isEmpty { return firstFolder.isEmpty }
                return firstFolder.localizedStandardCompare(secondFolder) == .orderedAscending
            }
            .map { folderPath in
                (folderPath, (entriesByFolder[folderPath] ?? []).sorted { $0.modifiedAt > $1.modifiedAt })
            }
    }
}
