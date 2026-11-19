//
//  ElfFileTools.swift
//  elfhub
//
//  The tools an elf uses on its own folder. It may read anything there
//  except the app's own files (.elfhub/, elf.json, access.json), and write
//  only its notes about the user (user.md, when it takes notes) and its
//  own files (files/…). Skills are written only through save_skill, and
//  only when the user asked; soul.md only ever by the user. Every write
//  goes through the change log, so the user sees it and can undo it.
//

import Foundation

enum ElfFileTools {
    static let readPageCharacterCount = 20_000
    static let listedFileLimit = 200

    static var allTools: [ElfTool] {
        [ListFilesTool(), ReadFileTool(), WriteFileTool(), DeleteFileTool(), RenameFileTool(), LoadSkillTool(), SaveSkillTool()]
    }

    /// The path from the home an elf may write to, or why not: only
    /// user.md (when it takes notes) and files under files/.
    static func writablePath(_ proposedPath: String, context: ElfToolContext) -> Result<String, ElfToolPathRefusal> {
        let homeRelativePath: String
        do {
            homeRelativePath = try context.elf.home.homeRelativePathForElfTool(proposedPath, access: .write)
        } catch {
            return .failure(ElfToolPathRefusal(reason: "you can't change \(proposedPath): it's outside your notes and files, or it belongs to the app or the user."))
        }
        if homeRelativePath == "user.md" {
            guard context.elf.configuration.behaviour.takesNotes else {
                return .failure(ElfToolPathRefusal(reason: "taking notes about the user is switched off in your settings, so user.md can't be changed."))
            }
            return .success(homeRelativePath)
        }
        let pathComponents = homeRelativePath.split(separator: "/")
        guard pathComponents.count >= 2, pathComponents.first == "files" else {
            if pathComponents.first == "skills" {
                return .failure(ElfToolPathRefusal(reason: "skills are saved with save_skill, and only when the user asks for one."))
            }
            return .failure(ElfToolPathRefusal(reason: "you can only write user.md and files inside files/ (for example files/notes.md)."))
        }
        return .success(homeRelativePath)
    }

    /// True when this turn (or the try before a fallback restart) already
    /// wrote exactly this text there and it's still there — so writing it
    /// again would only repeat the change.
    static func alreadyWroteThisTurn(path homeRelativePath: String, contentSHA256: String, context: ElfToolContext) -> Bool {
        guard context.turnEffectLedger.hasWritten(path: homeRelativePath, contentSHA256: contentSHA256),
              let fileURL = try? context.elf.home.resolvedURLInsideHome(homeRelativePath),
              let currentContent = try? Data(contentsOf: fileURL) else { return false }
        return ElfChangeLog.sha256(of: currentContent) == contentSHA256
    }

    /// One line per changed file, for the chat.
    static func chatNote(for fileChange: ElfChangeLogEntry) -> String {
        switch fileChange.operation {
        case .create, .modify: return "saved \(fileChange.path)"
        case .delete: return "deleted \(fileChange.path)"
        case .rename: return "moved \(fileChange.path) to \(fileChange.renamedToPath ?? "")"
        case .revert: return "undid a change to \(fileChange.path)"
        }
    }
}

struct ElfToolPathRefusal: Error {
    let reason: String
}

/// Tools on the elf's own folder are for every role.
private protocol OwnFolderTool: ElfTool {}
extension OwnFolderTool {
    func isAvailable(for role: ElfPromptRole, configuration: ElfConfiguration) -> Bool { true }
}

// MARK: - Reading

private struct ListFilesTool: OwnFolderTool {
    let group = ElfToolGroup.files
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "list_files",
        description: "List the files in your own folder: your notes and files (files/), user.md, soul.md and your skills. Give a folder like \"files/trips\" to list just that, or \".\" for everything.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "folder to list, from your folder; default \"files\""],
            ],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        let requestedFolder = arguments.string("folder")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let home = context.elf.home
        let listedFolderURL: URL
        if requestedFolder.isEmpty || requestedFolder == "." || requestedFolder == "/" {
            listedFolderURL = home.directory
        } else if requestedFolder.lowercased() == "files" || requestedFolder.lowercased() == "files/" {
            listedFolderURL = home.filesDirectory
        } else {
            do {
                listedFolderURL = try home.resolvedURLForElfTool(requestedFolder, access: .read)
            } catch {
                return .failure("you can't list \(requestedFolder).")
            }
        }
        let fileManager = FileManager.default
        let resolvedHomePath = home.directory.resolvingSymlinksInPath().path
        guard let fileEnumerator = fileManager.enumerator(
            at: listedFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return .failure("there's no folder called \(requestedFolder).") }

        var listedFileLines: [String] = []
        var unlistedFileCount = 0
        for case let fileURL as URL in fileEnumerator {
            let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
            guard resolvedFilePath.hasPrefix(resolvedHomePath + "/") else { continue }
            let homeRelativePath = String(resolvedFilePath.dropFirst(resolvedHomePath.count + 1))
            let firstPathComponent = homeRelativePath.split(separator: "/").first.map { $0.lowercased() } ?? ""
            if ElfHome.pathsReservedForTheApp.contains(firstPathComponent) {
                fileEnumerator.skipDescendants()
                continue
            }
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if listedFileLines.count >= ElfFileTools.listedFileLimit {
                unlistedFileCount += 1
                continue
            }
            let fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(resourceValues?.fileSize ?? 0), countStyle: .file)
            listedFileLines.append("- \(homeRelativePath) (\(fileSizeText))")
        }
        guard !listedFileLines.isEmpty else { return ElfToolOutcome(resultText: "no files there yet.") }
        var resultText = listedFileLines.sorted().joined(separator: "\n")
        if unlistedFileCount > 0 { resultText += "\n(\(unlistedFileCount) more)" }
        return ElfToolOutcome(resultText: resultText)
    }
}

private struct ReadFileTool: OwnFolderTool {
    let group = ElfToolGroup.files
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "read_file",
        description: "Read a text file in your own folder, such as files/trip.md, user.md or soul.md. Long files come in pages of 20,000 characters.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "the file's path from your folder, e.g. files/trip.md"],
                "page": ["type": "integer", "description": "which page of a long file, starting at 1"],
            ],
            "required": ["path"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let requestedPath = arguments.string("path") else { return .failure("give the file's path.") }
        let fileURL: URL
        do {
            fileURL = try context.elf.home.resolvedURLForElfTool(requestedPath, access: .read)
        } catch {
            return .failure("you can't read \(requestedPath).")
        }
        guard let fileText = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .failure("there's no text file at \(requestedPath).")
        }
        // What the elf reads may steer what it writes next.
        context.influencedBy.insert(.file)
        let pageCount = max(1, Int((Double(fileText.count) / Double(ElfFileTools.readPageCharacterCount)).rounded(.up)))
        let requestedPage = min(max(arguments.integer("page") ?? 1, 1), pageCount)
        let pageText = String(fileText.dropFirst((requestedPage - 1) * ElfFileTools.readPageCharacterCount).prefix(ElfFileTools.readPageCharacterCount))
        let header = pageCount > 1 ? "\(requestedPath) (page \(requestedPage) of \(pageCount)):" : "\(requestedPath):"
        return ElfToolOutcome(resultText: header + "\n" + pageText)
    }
}

// MARK: - Writing

private struct WriteFileTool: OwnFolderTool {
    let group = ElfToolGroup.files
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "write_file",
        description: "Create or replace a text file: your notes about the user in user.md, or your own notes and files under files/ (e.g. files/trips/lisbon.md). The user sees every change and can undo it. Never store passwords, keys, health or financial details.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "user.md, or a path under files/"],
                "content": ["type": "string", "description": "the whole new text of the file (markdown)"],
            ],
            "required": ["path", "content"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let requestedPath = arguments.string("path"), let newText = arguments.string("content") else {
            return .failure("give the file's path and its content.")
        }
        let homeRelativePath: String
        switch ElfFileTools.writablePath(requestedPath, context: context) {
        case let .success(writablePath): homeRelativePath = writablePath
        case let .failure(refusal): return .failure(refusal.reason)
        }
        let characterLimit = homeRelativePath == "user.md" ? ElfHome.userNotesCharacterLimit : ElfHome.fileByteLimit
        guard newText.utf8.count <= characterLimit else {
            let limitDescription = homeRelativePath == "user.md" ? "\(characterLimit) bytes" : "\(characterLimit / 1_000) KB"
            return .failure("that's too long for \(homeRelativePath) (the limit is \(limitDescription); accented letters and emoji take more than one byte). shorten it or split it into several files.")
        }
        let newContentSHA256 = ElfChangeLog.sha256(of: Data(newText.utf8))
        if ElfFileTools.alreadyWroteThisTurn(path: homeRelativePath, contentSHA256: newContentSHA256, context: context) {
            return ElfToolOutcome(resultText: "saved \(homeRelativePath).")
        }
        try Task.checkCancellation()
        do {
            let fileChange = try context.changeLog.recordWrite(
                path: homeRelativePath,
                newText: newText,
                origin: context.origin,
                influencedBy: context.influencedBy
            )
            context.turnEffectLedger.recordWrite(path: homeRelativePath, contentSHA256: newContentSHA256)
            context.turnEffectLedger.recordFileChange(fileChange)
            return ElfToolOutcome(
                resultText: "saved \(homeRelativePath).",
                fileChanges: [fileChange],
                chatNotes: [ElfFileTools.chatNote(for: fileChange)]
            )
        } catch {
            return .failure("couldn't save \(homeRelativePath): \(error.localizedDescription)")
        }
    }
}

private struct DeleteFileTool: OwnFolderTool {
    let group = ElfToolGroup.files
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "delete_file",
        description: "Delete one of your own files under files/. The user can undo it.",
        inputSchema: [
            "type": "object",
            "properties": ["path": ["type": "string", "description": "a path under files/"]],
            "required": ["path"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let requestedPath = arguments.string("path") else { return .failure("give the file's path.") }
        let homeRelativePath: String
        switch ElfFileTools.writablePath(requestedPath, context: context) {
        case let .success(writablePath): homeRelativePath = writablePath
        case let .failure(refusal): return .failure(refusal.reason)
        }
        guard homeRelativePath != "user.md" else {
            return .failure("user.md can't be deleted. write it again without the notes you want gone.")
        }
        try Task.checkCancellation()
        do {
            let fileChange = try context.changeLog.recordDelete(path: homeRelativePath, origin: context.origin, influencedBy: context.influencedBy)
            context.turnEffectLedger.recordFileChange(fileChange)
            return ElfToolOutcome(resultText: "deleted \(homeRelativePath).", fileChanges: [fileChange], chatNotes: [ElfFileTools.chatNote(for: fileChange)])
        } catch {
            return .failure("there's no file at \(homeRelativePath) to delete.")
        }
    }
}

private struct RenameFileTool: OwnFolderTool {
    let group = ElfToolGroup.files
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "rename_file",
        description: "Rename or move one of your own files within files/. The user can undo it.",
        inputSchema: [
            "type": "object",
            "properties": [
                "from": ["type": "string", "description": "the file's current path under files/"],
                "to": ["type": "string", "description": "its new path under files/"],
            ],
            "required": ["from", "to"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let originalPath = arguments.string("from"), let newPath = arguments.string("to") else {
            return .failure("give the file's current path and its new path.")
        }
        let writableOriginalPath: String
        let writableNewPath: String
        switch (ElfFileTools.writablePath(originalPath, context: context), ElfFileTools.writablePath(newPath, context: context)) {
        case let (.success(originalWritablePath), .success(newWritablePath)):
            writableOriginalPath = originalWritablePath
            writableNewPath = newWritablePath
        case let (.failure(refusal), _), let (_, .failure(refusal)):
            return .failure(refusal.reason)
        }
        guard writableOriginalPath != "user.md", writableNewPath != "user.md" else {
            return .failure("user.md stays where it is.")
        }
        guard !FileManager.default.fileExists(atPath: try context.elf.home.resolvedURLInsideHome(writableNewPath).path) else {
            return .failure("there's already a file at \(writableNewPath).")
        }
        try Task.checkCancellation()
        do {
            let fileChange = try context.changeLog.recordRename(
                from: writableOriginalPath,
                to: writableNewPath,
                origin: context.origin,
                influencedBy: context.influencedBy
            )
            context.turnEffectLedger.recordFileChange(fileChange)
            return ElfToolOutcome(resultText: "moved \(writableOriginalPath) to \(writableNewPath).", fileChanges: [fileChange], chatNotes: [ElfFileTools.chatNote(for: fileChange)])
        } catch {
            return .failure("there's no file at \(writableOriginalPath) to move.")
        }
    }
}

// MARK: - Skills

private struct LoadSkillTool: OwnFolderTool {
    let group = ElfToolGroup.skills
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "load_skill",
        description: "Read one of your skills in full, by its name from your skills list.",
        inputSchema: [
            "type": "object",
            "properties": ["name": ["type": "string", "description": "the skill's name"]],
            "required": ["name"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let requestedName = arguments.string("name") else { return .failure("give the skill's name.") }
        let foldedRequestedName = ElfNameRules.foldedForComparison(requestedName)
        guard let skill = context.elf.home.readSkills().first(where: {
            ElfNameRules.foldedForComparison($0.name) == foldedRequestedName || $0.slug.lowercased() == requestedName.lowercased()
        }) else {
            return .failure("there's no skill called \(requestedName).")
        }
        // A skill may be a dropped-in third-party file; what it says may
        // steer what the elf writes next.
        context.influencedBy.insert(.file)
        let descriptionLine = skill.description.isEmpty ? "" : "\n" + skill.description
        return ElfToolOutcome(resultText: "# \(skill.name)" + descriptionLine + "\n\n" + skill.body)
    }
}

private struct SaveSkillTool: OwnFolderTool {
    let group = ElfToolGroup.skills
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "save_skill",
        description: "Save working knowledge (how something is done: steps, tools, conventions) as a skill — only when the user asked you to save or update a skill. A skill with the same name is updated.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "short name, e.g. \"Deploying the web app\""],
                "description": ["type": "string", "description": "one line on what it covers"],
                "body": ["type": "string", "description": "the skill itself, in markdown"],
            ],
            "required": ["name", "body"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let skillName = arguments.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !skillName.isEmpty,
              let skillBody = arguments.string("body") else {
            return .failure("give the skill's name and body.")
        }
        guard SkillSaveRequest.userAskedToSaveSkill(userUtterance: context.userUtterance) else {
            return .failure("skills are saved only when the user asks for one. don't save it; you can offer to.")
        }
        guard context.elf.configuration.behaviour.learnsSkills else {
            return .failure("saving skills is switched off in your settings.")
        }
        let home = context.elf.home
        let foldedSkillName = ElfNameRules.foldedForComparison(skillName)
        let existingSkill = home.readSkills().first { ElfNameRules.foldedForComparison($0.name) == foldedSkillName }
        let savedSkill = ElfSkill(
            slug: existingSkill?.slug ?? ElfSkill.slug(forName: skillName),
            name: skillName,
            description: arguments.string("description") ?? existingSkill?.description ?? "",
            body: skillBody,
            unrecognizedFrontmatterLines: existingSkill?.unrecognizedFrontmatterLines ?? []
        )
        let skillMarkdown = savedSkill.skillMarkdown
        guard skillMarkdown.count <= ElfHome.skillCharacterLimit else {
            return .failure("that skill is too long (the limit is \(ElfHome.skillCharacterLimit) characters).")
        }
        // Judged by where the path really lands: a skill folder that's a
        // link elsewhere (into the app's own folder, say) is refused.
        guard let skillPath = try? home.homeRelativePathForElfTool(
            "skills/\(savedSkill.slug)/\(ElfHome.skillFileName)",
            access: .write
        ), skillPath.hasPrefix("skills/") else {
            return .failure("the skill folder for \(skillName) isn't a plain folder in your skills, so it can't be saved there.")
        }
        if existingSkill == nil, FileManager.default.fileExists(atPath: home.skillsDirectory.appendingPathComponent(savedSkill.slug).path) {
            return .failure("a skill folder called \(savedSkill.slug) already exists. pick another name.")
        }
        let newContentSHA256 = ElfChangeLog.sha256(of: Data(skillMarkdown.utf8))
        if ElfFileTools.alreadyWroteThisTurn(path: skillPath, contentSHA256: newContentSHA256, context: context) {
            return ElfToolOutcome(resultText: "saved the skill \(skillName).")
        }
        try Task.checkCancellation()
        do {
            let fileChange = try context.changeLog.recordWrite(path: skillPath, newText: skillMarkdown, origin: context.origin, influencedBy: context.influencedBy)
            context.turnEffectLedger.recordWrite(path: skillPath, contentSHA256: newContentSHA256)
            context.turnEffectLedger.recordFileChange(fileChange)
            return ElfToolOutcome(resultText: "saved the skill \(skillName).", fileChanges: [fileChange], chatNotes: ["saved the skill \(skillName)"])
        } catch {
            return .failure("couldn't save the skill: \(error.localizedDescription)")
        }
    }
}
