//
//  ElfManager.swift
//  elfhub
//
//  Owns the roster of elves: every folder in Elves/ is an elf, and the
//  main elf ("main") always exists and comes first. Creates, renames and
//  deletes elves (names checked with ElfNameRules), and builds the part of
//  every prompt that makes the model the main elf. Editing one elf's soul,
//  notes, skills and settings is ElfEditor's job.
//

import AppKit
import Combine
import Foundation

nonisolated enum ElfManagerError: LocalizedError, Equatable {
    /// Only the problems that block the name; warnings are allowed.
    case invalidName([ElfNameProblem])
    /// Only the problems that block the alias; warnings are allowed.
    case invalidAlias(alias: String, problems: [ElfNameProblem])
    case tooManyAliases(limit: Int)
    case cannotDeleteMainElf
    case unknownElf(String)
    /// A new skill would land in a folder another skill already uses.
    case skillAlreadyExists(name: String)

    var errorDescription: String? {
        switch self {
        case let .invalidName(nameProblems):
            return nameProblems.first?.message ?? "That name can't be used."
        case let .invalidAlias(alias, aliasProblems):
            return "\"\(alias)\": " + (aliasProblems.first?.message ?? "That name can't be used.")
        case let .tooManyAliases(limit):
            return "An elf can have up to \(limit) other names."
        case .cannotDeleteMainElf:
            return "The main elf can't be deleted. You can rename it instead."
        case let .unknownElf(elfIdentifier):
            return "There's no elf called \(elfIdentifier)."
        case let .skillAlreadyExists(skillName):
            return "There's already a skill called \(skillName). Pick another name."
        }
    }
}

/// What happens to a deleted elf's folder. The app moves it to the Trash so
/// it can be recovered; tests remove it so they never fill the user's Trash.
nonisolated enum ElfDeletedFolderDisposal: Sendable {
    case moveToTrash
    case removePermanently
}

@MainActor
final class ElfManager: ObservableObject {
    /// Every elf on this Mac: main first, then the rest by name.
    @Published private(set) var elves: [Elf] = []

    nonisolated static let mainElfIdentifier = "main"

    private let elvesDirectory: URL
    private let deletedFolderDisposal: ElfDeletedFolderDisposal

    init(elvesDirectory: URL = ElfHome.defaultElvesDirectory, deletedFolderDisposal: ElfDeletedFolderDisposal = .moveToTrash) {
        self.elvesDirectory = elvesDirectory
        self.deletedFolderDisposal = deletedFolderDisposal
        reloadRoster()
    }

    /// The main elf. It's "main" — a fixed id, so every build of the app
    /// (release, Xcode, tests) finds the same elf, like it finds the same
    /// chats. `reloadRoster` recreates its folder if needed, so it's always
    /// in the roster.
    var mainElf: Elf {
        if let rosterMainElf = elves.first(where: { $0.id == Self.mainElfIdentifier }) {
            return rosterMainElf
        }
        let mainElfHome = ElfHome(directory: elvesDirectory.appendingPathComponent(Self.mainElfIdentifier, isDirectory: true))
        return Elf(id: Self.mainElfIdentifier, home: mainElfHome, configuration: mainElfHome.readConfiguration())
    }

    func elf(withIdentifier elfIdentifier: String) -> Elf? {
        elves.first { $0.id == elfIdentifier }
    }

    // MARK: Roster

    /// Re-reads which elves exist. Only visible folders in Elves/ are elves,
    /// so a folder added in Finder shows up and stray files don't.
    func reloadRoster() {
        let fileManager = FileManager.default
        // The main elf always exists, even if its folder was removed while
        // the app was running.
        try? ElfHome(directory: elvesDirectory.appendingPathComponent(Self.mainElfIdentifier, isDirectory: true)).createIfNeeded()
        let elvesFolderItemNames = (try? fileManager.contentsOfDirectory(atPath: elvesDirectory.path)) ?? []
        var rosterElves: [Elf] = []
        for elfIdentifier in elvesFolderItemNames where !elfIdentifier.hasPrefix(".") {
            let elfDirectory = elvesDirectory.appendingPathComponent(elfIdentifier, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: elfDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let elfHome = ElfHome(directory: elfDirectory)
            rosterElves.append(Elf(id: elfIdentifier, home: elfHome, configuration: elfHome.readConfiguration()))
        }
        elves = rosterElves.sorted { firstElf, secondElf in
            if firstElf.id == Self.mainElfIdentifier { return secondElf.id != Self.mainElfIdentifier }
            if secondElf.id == Self.mainElfIdentifier { return false }
            return firstElf.configuration.identity.name.localizedCaseInsensitiveCompare(secondElf.configuration.identity.name) == .orderedAscending
        }
    }

    /// Makes a new elf with its own home folder, named and identified from
    /// `identity`. Name warnings (a prefix of another elf's name) are allowed.
    @discardableResult
    func createElf(identity: ElfConfiguration.Identity) throws -> Elf {
        let otherElfNames = ElfNameRules.namesInUse(byElves: elves, excludingElfWithIdentifier: nil)
        try validateName(identity.name, otherElfNames: otherElfNames)
        let cleanedAliases = try validatedAliases(identity.aliases, elfName: identity.name, otherElfNames: otherElfNames)
        // Every item already in Elves/ counts as taken — folders added in
        // Finder and stray files too — so a new elf never moves into them.
        let elvesFolderItemNames = (try? FileManager.default.contentsOfDirectory(atPath: elvesDirectory.path)) ?? []
        let identifiersInUse = Set(elves.map(\.id)).union(elvesFolderItemNames)
        let elfIdentifier = ElfNameRules.uniqueIdentifier(forName: identity.name, existingIdentifiers: identifiersInUse)
        let elfHome = ElfHome(directory: elvesDirectory.appendingPathComponent(elfIdentifier, isDirectory: true))
        var trimmedIdentity = identity
        trimmedIdentity.name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmedIdentity.aliases = cleanedAliases
        try elfHome.createIfNeeded(configuration: ElfConfiguration(identity: trimmedIdentity))
        reloadRoster()
        return elf(withIdentifier: elfIdentifier) ?? Elf(id: elfIdentifier, home: elfHome, configuration: elfHome.readConfiguration())
    }

    /// Adds a ready-made elf (Researcher, Writer) with its soul. Fails like
    /// `createElf` when an elf already goes by that name.
    @discardableResult
    func createElf(fromStarterTemplate starterTemplate: ElfStarterTemplate) throws -> Elf {
        let createdElf = try createElf(identity: starterTemplate.identity)
        try createdElf.home.writeSoul(starterTemplate.soulText)
        return createdElf
    }

    /// The starter elves that can still be added: those whose name no elf
    /// uses yet (as a name or an alias).
    var availableStarterTemplates: [ElfStarterTemplate] {
        let otherElfNames = ElfNameRules.namesInUse(byElves: elves, excludingElfWithIdentifier: nil)
        return ElfStarterTemplate.allCases.filter { starterTemplate in
            ElfNameRules.problems(forName: starterTemplate.identity.name, otherElfNames: otherElfNames)
                .allSatisfy(\.isWarning)
        }
    }

    /// Renames an elf (the main elf too). Its id and folder stay the same.
    func renameElf(withIdentifier elfIdentifier: String, to newName: String) throws {
        guard let renamedElf = elf(withIdentifier: elfIdentifier) else { throw ElfManagerError.unknownElf(elfIdentifier) }
        let otherElfNames = ElfNameRules.namesInUse(byElves: elves, excludingElfWithIdentifier: elfIdentifier)
        try validateName(newName, otherElfNames: otherElfNames)
        var renamedConfiguration = renamedElf.home.readConfiguration()
        renamedConfiguration.identity.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try renamedElf.home.writeConfiguration(renamedConfiguration)
        reloadRoster()
    }

    /// Deletes an elf and its folder (to the Trash in the app). The main elf
    /// can't be deleted.
    func deleteElf(withIdentifier elfIdentifier: String) throws {
        guard elfIdentifier != Self.mainElfIdentifier else { throw ElfManagerError.cannotDeleteMainElf }
        guard let deletedElf = elf(withIdentifier: elfIdentifier) else { throw ElfManagerError.unknownElf(elfIdentifier) }
        switch deletedFolderDisposal {
        case .moveToTrash:
            try FileManager.default.trashItem(at: deletedElf.home.directory, resultingItemURL: nil)
        case .removePermanently:
            try FileManager.default.removeItem(at: deletedElf.home.directory)
        }
        reloadRoster()
    }

    /// Cleans aliases and checks each with the name rules against
    /// `otherElfNames` and the elf's other aliases. Throws on the first
    /// alias with a blocking problem.
    func validatedAliases(_ proposedAliases: [String], elfName: String, otherElfNames: [String]) throws -> [String] {
        let cleanedAliases = ElfNameRules.cleanedAliases(proposedAliases, elfName: elfName)
        guard cleanedAliases.count <= ElfNameRules.maximumAliasCount else {
            throw ElfManagerError.tooManyAliases(limit: ElfNameRules.maximumAliasCount)
        }
        for (aliasIndex, alias) in cleanedAliases.enumerated() {
            var otherAliasesOfThisElf = cleanedAliases
            otherAliasesOfThisElf.remove(at: aliasIndex)
            let blockingAliasProblems = ElfNameRules.problems(forName: alias, otherElfNames: otherElfNames + otherAliasesOfThisElf)
                .filter { !$0.isWarning }
            if !blockingAliasProblems.isEmpty {
                throw ElfManagerError.invalidAlias(alias: alias, problems: blockingAliasProblems)
            }
        }
        return cleanedAliases
    }

    private func validateName(_ proposedName: String, otherElfNames: [String]) throws {
        let blockingNameProblems = ElfNameRules.problems(forName: proposedName, otherElfNames: otherElfNames)
            .filter { !$0.isWarning }
        guard blockingNameProblems.isEmpty else { throw ElfManagerError.invalidName(blockingNameProblems) }
    }

    // MARK: Prompt

    /// The main elf's part of the next prompt, read fresh from disk so edits
    /// made outside the app count straight away. Read off the main actor so
    /// a slow disk or many skills never hold up the interface.
    func promptContext() async -> ElfPromptContext {
        let mainElfHome = mainElf.home
        let otherElves = elves.filter { $0.id != Self.mainElfIdentifier }
        return await Task.detached(priority: .userInitiated) {
            var mainElfPromptContext = ElfPromptContext.reading(home: mainElfHome)
            // The main elf is told about its elves, so it can hand them work.
            mainElfPromptContext.roster = otherElves.map { otherElf in
                ElfRosterEntry(
                    name: otherElf.configuration.identity.name,
                    emoji: otherElf.configuration.identity.emoji,
                    description: otherElf.configuration.identity.description,
                    topSkillNames: Array(otherElf.home.readSkills().prefix(3).map(\.name)),
                    canWorkInBackground: true
                )
            }
            return mainElfPromptContext
        }.value
    }
}
