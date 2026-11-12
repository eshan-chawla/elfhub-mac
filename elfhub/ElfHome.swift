//
//  ElfHome.swift
//  elfhub
//
//  An elf's home folder, and the only code that reads or writes it:
//
//    ~/Library/Application Support/elfhub/Elves/<elf id>/
//      elf.json  soul.md  profile.md  skills/  files/  access.json
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

    var errorDescription: String? {
        switch self {
        case let .pathOutsideHome(path):
            return "\(path) is outside the elf's home folder."
        case let .textTooLong(fileDescription, characterLimit):
            return "\(fileDescription) is longer than \(characterLimit) characters. Shorten it and try again."
        case let .notTextFile(path):
            return "\(path) isn't a text file."
        }
    }
}

nonisolated struct ElfHome: Equatable, Sendable {
    let directory: URL

    static let soulCharacterLimit = 8_000
    static let profileCharacterLimit = 8_000
    static let skillCharacterLimit = 16_000
    static let fileByteLimit = 256_000

    var configurationURL: URL { directory.appendingPathComponent("elf.json") }
    var soulURL: URL { directory.appendingPathComponent("soul.md") }
    var profileURL: URL { directory.appendingPathComponent("profile.md") }
    var skillsDirectory: URL { directory.appendingPathComponent("skills", isDirectory: true) }
    var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }
    /// This Mac's grants to the user's folders. Never exported.
    var accessURL: URL { directory.appendingPathComponent("access.json") }

    /// ~/Library/Application Support/elfhub/Elves
    static var defaultElvesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elfhub", isDirectory: true)
            .appendingPathComponent("Elves", isDirectory: true)
    }

    // MARK: Creating

    /// Makes the folders and starter files that don't exist yet; never
    /// overwrites what's there.
    func createIfNeeded(configuration: ElfConfiguration = ElfConfiguration()) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: configurationURL.path) {
            try writeConfiguration(configuration)
        }
        if !fileManager.fileExists(atPath: soulURL.path) {
            try writeSoul(Self.starterSoul)
        }
        if !fileManager.fileExists(atPath: profileURL.path) {
            try writeProfile(Self.starterProfile)
        }
    }

    // MARK: elf.json

    func readConfiguration() -> ElfConfiguration {
        guard let configurationData = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(ElfConfiguration.self, from: configurationData) else {
            return ElfConfiguration()
        }
        return configuration
    }

    func writeConfiguration(_ configuration: ElfConfiguration) throws {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try jsonEncoder.encode(configuration).write(to: configurationURL, options: .atomic)
    }

    // MARK: soul.md and profile.md

    func readSoul() -> String {
        (try? String(contentsOf: soulURL, encoding: .utf8)) ?? Self.starterSoul
    }

    func writeSoul(_ soulText: String) throws {
        try writeText(soulText, to: soulURL, characterLimit: Self.soulCharacterLimit, fileDescription: "soul.md")
    }

    func readProfile() -> String {
        (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
    }

    func writeProfile(_ profileText: String) throws {
        try writeText(profileText, to: profileURL, characterLimit: Self.profileCharacterLimit, fileDescription: "profile.md")
    }

    // MARK: Skills

    /// Every skill, sorted by title.
    func readSkills() -> [ElfSkill] {
        let skillFileNames = (try? FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)) ?? []
        return skillFileNames
            .filter { $0.hasSuffix(".md") }
            .compactMap { skillFileName -> ElfSkill? in
                let skillURL = skillsDirectory.appendingPathComponent(skillFileName)
                guard let skillMarkdown = try? String(contentsOf: skillURL, encoding: .utf8) else { return nil }
                return ElfSkill.parse(fileName: String(skillFileName.dropLast(".md".count)), markdown: skillMarkdown)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func writeSkill(_ skill: ElfSkill) throws {
        try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        let skillURL = try resolvedURLInsideHome("skills/\(skill.fileName).md")
        try writeText(skill.markdown, to: skillURL, characterLimit: Self.skillCharacterLimit, fileDescription: "The skill \"\(skill.title)\"")
    }

    func deleteSkill(fileName: String) throws {
        let skillURL = try resolvedURLInsideHome("skills/\(fileName).md")
        try FileManager.default.removeItem(at: skillURL)
    }

    // MARK: files/

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

    // MARK: Paths

    /// A path inside the home, from a relative path the elf (or the app)
    /// names. Rejects absolute paths, "..", and anything that resolves —
    /// symlinks included — outside the home folder.
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
        return candidateURL
    }

    /// The real path, following symlinks in every part that exists — a file
    /// that's about to be created still has its folders resolved.
    private static func resolvedPath(of fileURL: URL) -> String {
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

    static let starterProfile = """
    # profile

    """
}
