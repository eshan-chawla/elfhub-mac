//
//  ElfManager.swift
//  elfhub
//
//  Owns the roster of elfs: every folder in Elfs/ is an elf, and the
//  main elf ("main") always exists and comes first. Creates, renames and
//  deletes elfs (names checked with ElfNameRules), and builds the part of
//  every prompt that makes the model the main elf. Editing one elf's soul,
//  notes, skills and settings is ElfEditor's job.
//

import AppKit
import Combine
import Foundation
import os

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
            return "An Elf can have up to \(limit) other names."
        case .cannotDeleteMainElf:
            return "The main Elf can't be deleted. You can rename it instead."
        case let .unknownElf(elfIdentifier):
            return "There's no Elf called \(elfIdentifier)."
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
    @Published private(set) var elfs: [Elf] = []

    nonisolated static let mainElfIdentifier = "main"

    private let elfsDirectory: URL
    private let deletedFolderDisposal: ElfDeletedFolderDisposal
    /// Where renaming the main elf records that the "Name your elf" card is
    /// answered; tests pass their own so they never touch the app's.
    private let namingPromptUserDefaults: UserDefaults

    init(
        elfsDirectory: URL = ElfHome.defaultElfsDirectory,
        deletedFolderDisposal: ElfDeletedFolderDisposal = .moveToTrash,
        namingPromptUserDefaults: UserDefaults = .standard
    ) {
        self.elfsDirectory = elfsDirectory
        self.deletedFolderDisposal = deletedFolderDisposal
        self.namingPromptUserDefaults = namingPromptUserDefaults
        // 0.0.1 kept Elfs in Elves/; move that folder before the first read,
        // so the roster (and the main Elf's folder) is never made empty
        // beside it.
        // Only an Elfs/ folder has an Elves/ sibling to move — never a
        // temporary roster folder a test made somewhere else.
        if elfsDirectory.lastPathComponent == ElfsFolderMigration.currentFolderName {
            let elfsFolderMigrationOutcome = ElfsFolderMigration.moveLegacyElvesFolderIfNeeded(
                elfhubDataDirectory: elfsDirectory.deletingLastPathComponent()
            )
            if elfsFolderMigrationOutcome != .nothingToMove {
                companionLogger.info("Elves folder migration: \(String(describing: elfsFolderMigrationOutcome), privacy: .public)")
            }
        }
        reloadRoster()
    }

    /// The main elf. It's "main" — a fixed id, so every build of the app
    /// (release, Xcode, tests) finds the same elf, like it finds the same
    /// chats. `reloadRoster` recreates its folder if needed, so it's always
    /// in the roster.
    var mainElf: Elf {
        if let rosterMainElf = elfs.first(where: { $0.id == Self.mainElfIdentifier }) {
            return rosterMainElf
        }
        let mainElfHome = ElfHome(directory: elfsDirectory.appendingPathComponent(Self.mainElfIdentifier, isDirectory: true))
        return Elf(id: Self.mainElfIdentifier, home: mainElfHome, configuration: mainElfHome.readConfiguration())
    }

    func elf(withIdentifier elfIdentifier: String) -> Elf? {
        elfs.first { $0.id == elfIdentifier }
    }

    // MARK: Roster

    /// Re-reads which elfs exist. Only visible folders in Elfs/ are elfs,
    /// so a folder added in Finder shows up and stray files don't.
    func reloadRoster() {
        let fileManager = FileManager.default
        // The main elf always exists, even if its folder was removed while
        // the app was running.
        try? ElfHome(directory: elfsDirectory.appendingPathComponent(Self.mainElfIdentifier, isDirectory: true)).createIfNeeded()
        let elfsFolderItemNames = (try? fileManager.contentsOfDirectory(atPath: elfsDirectory.path)) ?? []
        var rosterElfs: [Elf] = []
        for elfIdentifier in elfsFolderItemNames where !elfIdentifier.hasPrefix(".") {
            let elfDirectory = elfsDirectory.appendingPathComponent(elfIdentifier, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: elfDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let elfHome = ElfHome(directory: elfDirectory)
            elfHome.moveLegacyUserNotesIfNeeded()
            rosterElfs.append(Elf(id: elfIdentifier, home: elfHome, configuration: elfHome.readConfiguration()))
        }
        elfs = rosterElfs.sorted { firstElf, secondElf in
            if firstElf.id == Self.mainElfIdentifier { return secondElf.id != Self.mainElfIdentifier }
            if secondElf.id == Self.mainElfIdentifier { return false }
            return firstElf.configuration.identity.name.localizedCaseInsensitiveCompare(secondElf.configuration.identity.name) == .orderedAscending
        }
    }

    /// Makes a new elf with its own home folder, named and identified from
    /// `identity`. Name warnings (a prefix of another elf's name) are allowed.
    @discardableResult
    func createElf(identity: ElfConfiguration.Identity) throws -> Elf {
        let otherElfNames = ElfNameRules.namesInUse(byElfs: elfs, excludingElfWithIdentifier: nil)
        try validateName(identity.name, otherElfNames: otherElfNames)
        let cleanedAliases = try validatedAliases(identity.aliases, elfName: identity.name, otherElfNames: otherElfNames)
        // Every item already in Elfs/ counts as taken — folders added in
        // Finder and stray files too — so a new elf never moves into them.
        let elfsFolderItemNames = (try? FileManager.default.contentsOfDirectory(atPath: elfsDirectory.path)) ?? []
        let identifiersInUse = Set(elfs.map(\.id)).union(elfsFolderItemNames)
        let elfIdentifier = ElfNameRules.uniqueIdentifier(forName: identity.name, existingIdentifiers: identifiersInUse)
        let elfHome = ElfHome(directory: elfsDirectory.appendingPathComponent(elfIdentifier, isDirectory: true))
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

    /// The starter elfs that can still be added: those whose name no elf
    /// uses yet (as a name or an alias).
    var availableStarterTemplates: [ElfStarterTemplate] {
        let otherElfNames = ElfNameRules.namesInUse(byElfs: elfs, excludingElfWithIdentifier: nil)
        return ElfStarterTemplate.allCases.filter { starterTemplate in
            ElfNameRules.problems(forName: starterTemplate.identity.name, otherElfNames: otherElfNames)
                .allSatisfy(\.isWarning)
        }
    }

    /// Renames an elf (the main elf too). Its id and folder stay the same.
    func renameElf(withIdentifier elfIdentifier: String, to newName: String) throws {
        guard let renamedElf = elf(withIdentifier: elfIdentifier) else { throw ElfManagerError.unknownElf(elfIdentifier) }
        let otherElfNames = ElfNameRules.namesInUse(byElfs: elfs, excludingElfWithIdentifier: elfIdentifier)
        try validateName(newName, otherElfNames: otherElfNames)
        var renamedConfiguration = renamedElf.home.readConfiguration()
        let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamedConfiguration.identity.name = trimmedNewName
        // An alias that is now the name itself isn't another name any more.
        let foldedNewName = ElfNameRules.foldedForComparison(trimmedNewName)
        renamedConfiguration.identity.aliases.removeAll { ElfNameRules.foldedForComparison($0) == foldedNewName }
        try renamedElf.home.writeConfiguration(renamedConfiguration)
        // Once the main elf has been named anywhere (its page, the card), the
        // one-time "Name your elf" card is answered for good — even if its
        // elf.json were ever read back as the starting name.
        if elfIdentifier == Self.mainElfIdentifier {
            ElfNamingPrompt.markOffered(userDefaults: namingPromptUserDefaults)
        }
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
    func promptContext(canWorkInBackground: (Elf) -> Bool = { _ in true }) async -> ElfPromptContext {
        let mainElfHome = mainElf.home
        let otherElfs = elfs.filter { $0.id != Self.mainElfIdentifier }
        let backgroundCapableElfIdentifiers = Set(otherElfs.filter(canWorkInBackground).map(\.id))
        return await Task.detached(priority: .userInitiated) {
            var mainElfPromptContext = ElfPromptContext.reading(home: mainElfHome)
            // The main elf is told about its elfs, so it can hand them work.
            mainElfPromptContext.roster = otherElfs.map { otherElf in
                ElfRosterEntry(
                    name: otherElf.configuration.identity.name,
                    emoji: otherElf.configuration.identity.emoji,
                    description: otherElf.configuration.identity.description,
                    topSkillNames: Array(otherElf.home.readSkills().prefix(3).map(\.name)),
                    canWorkInBackground: backgroundCapableElfIdentifiers.contains(otherElf.id)
                )
            }
            return mainElfPromptContext
        }.value
    }
}
