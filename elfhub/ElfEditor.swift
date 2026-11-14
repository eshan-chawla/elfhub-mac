//
//  ElfEditor.swift
//  elfhub
//
//  Edits one elf — any elf, not only the main one: its identity, how it
//  answers, its soul, its notes about the user, its skills, and exporting
//  it. Each elf page in the Elves hub owns one. Every edit first checks the
//  elf's folder is still there, so an elf removed in Finder is never
//  brought back by a save; the roster (ElfManager) is told about every
//  change that shows in the sidebar.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ElfEditor: ObservableObject {
    @Published private(set) var elf: Elf
    @Published private(set) var soulText: String
    @Published private(set) var profileText: String
    @Published private(set) var skills: [ElfSkill]
    @Published private(set) var elfFileCount: Int

    private let elfManager: ElfManager

    convenience init(elfIdentifier: String, elfManager: ElfManager) throws {
        guard let openedElf = elfManager.elf(withIdentifier: elfIdentifier) else {
            throw ElfManagerError.unknownElf(elfIdentifier)
        }
        self.init(openedElf: openedElf, elfManager: elfManager)
    }

    /// The main elf is always in the roster, so opening it can't fail.
    convenience init(editingMainElfOf elfManager: ElfManager) {
        self.init(openedElf: elfManager.mainElf, elfManager: elfManager)
    }

    private init(openedElf: Elf, elfManager: ElfManager) {
        self.elfManager = elfManager
        self.elf = openedElf
        self.soulText = openedElf.home.readSoul()
        self.profileText = openedElf.home.readProfile()
        self.skills = openedElf.home.readSkills()
        self.elfFileCount = openedElf.home.fileCount()
    }

    var home: ElfHome { elf.home }
    var isMainElf: Bool { elf.id == ElfManager.mainElfIdentifier }

    /// Re-reads everything from disk, e.g. after the user edited soul.md in
    /// another app. An elf whose folder is gone keeps showing what it had.
    func reload() {
        guard elfFolderExists else { return }
        elf.configuration = home.readConfiguration()
        soulText = home.readSoul()
        profileText = home.readProfile()
        skills = home.readSkills()
        elfFileCount = home.fileCount()
    }

    // MARK: Identity and behaviour

    /// Renames the elf through the name rules (ElfManager checks them
    /// against every other elf's names and aliases).
    func rename(to newName: String) throws {
        try requireElfFolder()
        try elfManager.renameElf(withIdentifier: elf.id, to: newName)
        elf.configuration = home.readConfiguration()
    }

    /// Other names the elf answers to, cleaned and checked with the name
    /// rules against every other elf's names and aliases.
    func updateAliases(_ proposedAliases: [String]) throws {
        try requireElfFolder()
        let otherElfNames = ElfNameRules.namesInUse(byElves: elfManager.elves, excludingElfWithIdentifier: elf.id)
        let cleanedAliases = try elfManager.validatedAliases(
            proposedAliases,
            elfName: home.readConfiguration().identity.name,
            otherElfNames: otherElfNames
        )
        try updateConfiguration { configuration in configuration.identity.aliases = cleanedAliases }
    }

    /// Keeps only the first emoji of whatever was typed or pasted.
    func updateEmoji(_ proposedEmoji: String) throws {
        let normalizedEmoji = ElfNameRules.normalizedEmoji(proposedEmoji)
        try updateConfiguration { configuration in configuration.identity.emoji = normalizedEmoji }
    }

    func updateDescription(_ newDescription: String) throws {
        let trimmedDescription = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        try updateConfiguration { configuration in configuration.identity.description = trimmedDescription }
    }

    func updateBehaviour(_ updateBehaviour: (inout ElfConfiguration.Behaviour) -> Void) throws {
        try updateConfiguration { configuration in updateBehaviour(&configuration.behaviour) }
    }

    /// Writes elf.json when something changed. The name is never changed
    /// here: names change only through `rename(to:)`.
    private func updateConfiguration(_ updateConfiguration: (inout ElfConfiguration) -> Void) throws {
        try requireElfFolder()
        var updatedConfiguration = home.readConfiguration()
        let savedName = updatedConfiguration.identity.name
        updateConfiguration(&updatedConfiguration)
        updatedConfiguration.identity.name = savedName
        guard updatedConfiguration != home.readConfiguration() else {
            elf.configuration = updatedConfiguration
            return
        }
        try home.writeConfiguration(updatedConfiguration)
        elf.configuration = updatedConfiguration
        elfManager.reloadRoster()
    }

    // MARK: Soul and profile

    func saveSoul(_ newSoulText: String) throws {
        try requireElfFolder()
        try home.writeSoul(newSoulText)
        soulText = newSoulText
    }

    func resetSoulToStarter() throws {
        try saveSoul(ElfHome.starterSoul)
    }

    func saveProfile(_ newProfileText: String) throws {
        try requireElfFolder()
        try home.writeProfile(newProfileText)
        profileText = newProfileText
    }

    func clearProfile() throws {
        try saveProfile(ElfHome.starterProfile)
    }

    // MARK: Skills

    /// Saves a skill. An edited skill stays in its own folder whatever its
    /// name becomes — the folder is the skill's identity (as agentskills.io
    /// treats it) and may hold references/, scripts/ or assets/ too. A new
    /// skill gets a folder named after it, and never takes over a folder
    /// another skill uses (compared ignoring case, as the Mac's disk does).
    func saveSkill(_ skill: ElfSkill, isNewSkill: Bool) throws {
        try requireElfFolder()
        if isNewSkill {
            let newSkillSlug = ElfSkill.slug(forName: skill.name)
            let skillFolderNamesInUse = (try? FileManager.default.contentsOfDirectory(atPath: home.skillsDirectory.path)) ?? []
            if skillFolderNamesInUse.contains(where: { $0.lowercased() == newSkillSlug.lowercased() }) {
                throw ElfManagerError.skillAlreadyExists(name: skill.name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try home.writeSkill(ElfSkill(
                slug: newSkillSlug,
                name: skill.name,
                description: skill.description,
                body: skill.body,
                unrecognizedFrontmatterLines: skill.unrecognizedFrontmatterLines
            ))
        } else {
            try home.writeSkill(skill)
        }
        skills = home.readSkills()
    }

    func deleteSkill(_ skill: ElfSkill) throws {
        try requireElfFolder()
        try home.deleteSkill(slug: skill.slug)
        skills = home.readSkills()
    }

    // MARK: Export and Finder

    /// Writes a `.elf` file. `preferredModels` is the current setup (no
    /// keys), stored in the export's elf.json so an imported elf can
    /// suggest it.
    func export(
        to destinationURL: URL,
        options: ElfExporter.Options,
        preferredModels: ElfConfiguration.PreferredModels
    ) throws {
        try requireElfFolder()
        var exportedConfiguration = home.readConfiguration()
        exportedConfiguration.preferredModels = preferredModels
        try ElfExporter.export(home: home, configuration: exportedConfiguration, options: options, to: destinationURL)
    }

    func revealHomeInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([home.directory])
    }

    func revealFilesInFinder() {
        guard elfFolderExists else { return }
        try? FileManager.default.createDirectory(at: home.filesDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(home.filesDirectory)
    }

    // MARK: Folder check

    private var elfFolderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home.directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Refuses an edit once the elf's folder is gone (deleted, or removed
    /// in Finder), so saving never recreates it, and tells the roster.
    private func requireElfFolder() throws {
        guard elfFolderExists else {
            elfManager.reloadRoster()
            throw ElfManagerError.unknownElf(elf.id)
        }
    }
}
