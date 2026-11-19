//
//  ElfEditor.swift
//  elfhub
//
//  Edits one elf — any elf, not only the main one: its identity, how it
//  answers, its soul, its notes about the user, its skills, and exporting
//  it. Each elf page in the Elfs hub owns one. Every edit first checks the
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
    /// Which of this Mac's models and voices the elf uses.
    @Published private(set) var localSettings: ElfLocalSettings
    /// The user's folders this elf may use (this Mac only).
    @Published private(set) var folderGrants: [ElfFolderGrant]

    private let elfManager: ElfManager
    private var savedChangesObserver: NSObjectProtocol?

    /// Posted after an editor saves anything about an elf (object: the elf's
    /// id). The page and the settings sheet each have their own editor, so
    /// the other one reloads and a rename or a new note shows at once.
    static let didSaveElfChangesNotification = Notification.Name("ElfEditorDidSaveElfChanges")

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
        self.profileText = openedElf.home.readUserNotes()
        self.skills = openedElf.home.readSkills()
        self.elfFileCount = openedElf.home.fileCount()
        self.localSettings = openedElf.home.readLocalSettings()
        self.folderGrants = openedElf.home.readFolderGrants()
        savedChangesObserver = NotificationCenter.default.addObserver(
            forName: Self.didSaveElfChangesNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let savingEditor = notification.userInfo?["editor"] as AnyObject?,
                      savingEditor !== self,
                      notification.object as? String == self.elf.id else { return }
                self.reload()
            }
        }
    }

    deinit {
        if let savedChangesObserver {
            NotificationCenter.default.removeObserver(savedChangesObserver)
        }
    }

    /// Tells this elf's other open editors to reload what was just saved.
    private func announceSavedChanges() {
        NotificationCenter.default.post(name: Self.didSaveElfChangesNotification, object: elf.id, userInfo: ["editor": self])
    }

    var home: ElfHome { elf.home }
    var isMainElf: Bool { elf.id == ElfManager.mainElfIdentifier }

    /// Re-reads everything from disk, e.g. after the user edited soul.md in
    /// another app. An elf whose folder is gone keeps showing what it had.
    func reload() {
        guard elfFolderExists else { return }
        elf.configuration = home.readConfiguration()
        soulText = home.readSoul()
        profileText = home.readUserNotes()
        skills = home.readSkills()
        elfFileCount = home.fileCount()
        localSettings = home.readLocalSettings()
        folderGrants = home.readFolderGrants()
    }

    // MARK: Identity and behaviour

    /// Renames the elf through the name rules (ElfManager checks them
    /// against every other elf's names and aliases).
    func rename(to newName: String) throws {
        try requireElfFolder()
        try elfManager.renameElf(withIdentifier: elf.id, to: newName)
        elf.configuration = home.readConfiguration()
        announceSavedChanges()
    }

    /// A warning about the elf's current name that doesn't block it (it's the
    /// start of another elf's name, or the other way round), or nil.
    var nameWarningMessage: String? {
        let otherElfNames = ElfNameRules.namesInUse(byElfs: elfManager.elfs, excludingElfWithIdentifier: elf.id)
        return ElfNameRules.problems(forName: elf.configuration.identity.name, otherElfNames: otherElfNames)
            .first(where: \.isWarning)?
            .message
    }

    /// Other names the elf answers to, cleaned and checked with the name
    /// rules against every other elf's names and aliases.
    func updateAliases(_ proposedAliases: [String]) throws {
        try requireElfFolder()
        let otherElfNames = ElfNameRules.namesInUse(byElfs: elfManager.elfs, excludingElfWithIdentifier: elf.id)
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

    /// Picks one of the six brand avatar fills; out-of-range values wrap.
    func updateAvatarColorIndex(_ proposedAvatarColorIndex: Int) throws {
        let avatarColorIndex = ElfAvatarAppearance.normalizedFillIndex(proposedAvatarColorIndex)
        try updateConfiguration { configuration in configuration.identity.avatarColorIndex = avatarColorIndex }
    }

    /// Makes the picture at `sourceURL` the elf's avatar: turned upright,
    /// cut to its middle square and scaled down off the main thread, then
    /// saved in the elf's folder.
    func updateAvatarPicture(fromImageAt sourceURL: URL) async throws {
        try requireElfFolder()
        let squarePNGData = try await Task.detached(priority: .userInitiated) {
            try ElfAvatarPicture.squarePNGData(fromImageAt: sourceURL)
        }.value
        try requireElfFolder()
        try home.writeAvatarPicture(pngData: squarePNGData)
        ElfAvatarPictureStore.shared.pictureDidChange(for: home)
    }

    /// Back to initials on the elf's color.
    func removeAvatarPicture() throws {
        try requireElfFolder()
        try home.removeAvatarPicture()
        ElfAvatarPictureStore.shared.pictureDidChange(for: home)
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
        announceSavedChanges()
    }

    /// What the elf may reach beyond its own folder (the web; the web and
    /// the user's folders in one task).
    func updateCapabilities(_ updateCapabilities: (inout ElfConfiguration.Capabilities) -> Void) throws {
        try updateConfiguration { configuration in updateCapabilities(&configuration.capabilities) }
    }

    /// Changes which of the user's folders the elf may use, and how.
    func updateFolderGrants(_ updateFolderGrants: (inout [ElfFolderGrant]) -> Void) throws {
        try requireElfFolder()
        var updatedFolderGrants = home.readFolderGrants()
        updateFolderGrants(&updatedFolderGrants)
        try home.writeFolderGrants(updatedFolderGrants)
        folderGrants = updatedFolderGrants
        announceSavedChanges()
    }

    /// Changes which of this Mac's models and voices the elf uses.
    func updateLocalSettings(_ updateLocalSettings: (inout ElfLocalSettings) -> Void) throws {
        try requireElfFolder()
        var updatedLocalSettings = home.readLocalSettings()
        updateLocalSettings(&updatedLocalSettings)
        try home.writeLocalSettings(updatedLocalSettings)
        localSettings = updatedLocalSettings
        announceSavedChanges()
    }

    // MARK: Soul and profile

    func saveSoul(_ newSoulText: String) throws {
        try requireElfFolder()
        try home.writeSoul(newSoulText)
        soulText = newSoulText
        announceSavedChanges()
    }

    func resetSoulToStarter() throws {
        try saveSoul(ElfHome.starterSoul)
    }

    func saveProfile(_ newProfileText: String) throws {
        try requireElfFolder()
        try home.writeUserNotes(newProfileText)
        profileText = newProfileText
        announceSavedChanges()
    }

    func clearProfile() throws {
        try saveProfile(ElfHome.starterUserNotes)
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
        announceSavedChanges()
    }

    func deleteSkill(_ skill: ElfSkill) throws {
        try requireElfFolder()
        try home.deleteSkill(slug: skill.slug)
        skills = home.readSkills()
        announceSavedChanges()
    }

    // MARK: Export and Finder

    /// Writes a `.elf` file. `preferredModels` is the current setup (no
    /// keys), stored in the export's elf.json so an imported elf can
    /// suggest it.
    func export(
        to destinationURL: URL,
        options: ElfExporter.Options,
        preferredModels: ElfConfiguration.PreferredModels,
        chats: [ChatConversation]
    ) throws {
        try requireElfFolder()
        var exportedConfiguration = home.readConfiguration()
        exportedConfiguration.preferredModels = preferredModels
        try ElfExporter.export(
            home: home,
            configuration: exportedConfiguration,
            options: options,
            chats: chats,
            exportedElfIdentifier: elf.id,
            to: destinationURL
        )
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
