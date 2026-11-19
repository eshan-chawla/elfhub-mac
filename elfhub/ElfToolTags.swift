//
//  ElfToolTags.swift
//  elfhub
//
//  How models without tool calling change their files: silent tags in the
//  reply, run through the same tools as tool calls.
//
//    [FILE:files/trip.md]the whole new text[/FILE]   save a file
//    [DELETE_FILE:files/old.md]                      delete one
//    [SKILL:name]the skill in markdown[/SKILL]       save a skill (only
//                                                     when the user asked)
//
//  Blocks are never spoken (SpokenSentenceSegmenter holds speech back while
//  one is open). Tags written inside notepad lines are examples, not
//  actions. Such models see their newest notes in the prompt instead of
//  reading them (ElfPromptBudget).
//

import Foundation

nonisolated enum ElfTagInvocation: Equatable, Sendable {
    case writeFile(path: String, content: String)
    case deleteFile(path: String)
    case saveSkill(name: String, body: String)
    case assignTask(elfName: String, instruction: String)
    case cancelTask(taskIdentifier: String)

    /// The tool call this tag stands for.
    var toolNameAndArguments: (toolName: String, arguments: [String: String]) {
        switch self {
        case let .writeFile(path, content): return ("write_file", ["path": path, "content": content])
        case let .deleteFile(path): return ("delete_file", ["path": path])
        case let .saveSkill(name, body): return ("save_skill", ["name": name, "body": body])
        case let .assignTask(elfName, instruction): return ("assign_task", ["elf": elfName, "instruction": instruction])
        case let .cancelTask(taskIdentifier): return ("cancel_task", ["id": taskIdentifier])
        }
    }
}

nonisolated enum ElfToolTags {
    /// Block tags whose content is never spoken.
    static let silentBlockTagNames = ["FILE", "SKILL"]

    private static let completeBlockPattern = try? NSRegularExpression(
        pattern: #"\[(FILE|SKILL):([^\]]*)\]([\s\S]*?)\[/\1\]"#
    )
    private static let deleteFileTagPattern = try? NSRegularExpression(pattern: #"\[DELETE_FILE:([^\]]*)\]"#)
    private static let assignTaskTagPattern = try? NSRegularExpression(pattern: #"\[ASSIGN_TASK:([^\]:]*):([^\]]*)\]"#)
    private static let cancelTaskTagPattern = try? NSRegularExpression(pattern: #"\[CANCEL_TASK:([^\]]*)\]"#)
    private static let unclosedBlockOpenerPattern = try? NSRegularExpression(pattern: #"\[(FILE|SKILL):[^\]]*\]"#)

    /// The tags in a complete reply, in order. `[SKILL]` blocks count only
    /// when the user's words asked for a skill.
    static func invocations(fromResponseText responseText: String, userAskedToSaveSkill: Bool) -> [ElfTagInvocation] {
        let textWithoutNotepad = NotepadTagParser.removingNotepadTags(from: responseText)
        var positionedInvocations: [(position: Int, invocation: ElfTagInvocation)] = []
        let fullRange = NSRange(textWithoutNotepad.startIndex..., in: textWithoutNotepad)

        completeBlockPattern?.enumerateMatches(in: textWithoutNotepad, range: fullRange) { match, _, _ in
            guard let match,
                  let tagNameRange = Range(match.range(at: 1), in: textWithoutNotepad),
                  let argumentRange = Range(match.range(at: 2), in: textWithoutNotepad),
                  let contentRange = Range(match.range(at: 3), in: textWithoutNotepad) else { return }
            let tagArgument = textWithoutNotepad[argumentRange].trimmingCharacters(in: .whitespaces)
            let blockContent = String(textWithoutNotepad[contentRange])
            switch textWithoutNotepad[tagNameRange] {
            case "FILE":
                positionedInvocations.append((match.range.location, .writeFile(path: tagArgument, content: blockContent)))
            case "SKILL" where userAskedToSaveSkill:
                positionedInvocations.append((match.range.location, .saveSkill(name: tagArgument, body: blockContent)))
            default:
                break
            }
        }
        // A delete tag written inside a saved file's text is text, not an
        // action.
        let completeBlockRanges = completeBlockPattern?.matches(in: textWithoutNotepad, range: fullRange).map(\.range) ?? []
        deleteFileTagPattern?.enumerateMatches(in: textWithoutNotepad, range: fullRange) { match, _, _ in
            guard let match, let pathRange = Range(match.range(at: 1), in: textWithoutNotepad) else { return }
            guard !completeBlockRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            let deletedPath = textWithoutNotepad[pathRange].trimmingCharacters(in: .whitespaces)
            positionedInvocations.append((match.range.location, .deleteFile(path: deletedPath)))
        }
        assignTaskTagPattern?.enumerateMatches(in: textWithoutNotepad, range: fullRange) { match, _, _ in
            guard let match,
                  !completeBlockRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let elfNameRange = Range(match.range(at: 1), in: textWithoutNotepad),
                  let instructionRange = Range(match.range(at: 2), in: textWithoutNotepad) else { return }
            positionedInvocations.append((match.range.location, .assignTask(
                elfName: textWithoutNotepad[elfNameRange].trimmingCharacters(in: .whitespaces),
                instruction: textWithoutNotepad[instructionRange].trimmingCharacters(in: .whitespaces)
            )))
        }
        cancelTaskTagPattern?.enumerateMatches(in: textWithoutNotepad, range: fullRange) { match, _, _ in
            guard let match,
                  !completeBlockRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let taskIdentifierRange = Range(match.range(at: 1), in: textWithoutNotepad) else { return }
            positionedInvocations.append((match.range.location, .cancelTask(
                taskIdentifier: textWithoutNotepad[taskIdentifierRange].trimmingCharacters(in: .whitespaces)
            )))
        }
        return positionedInvocations.sorted { $0.position < $1.position }.map(\.invocation)
    }

    /// The reply without its elf tags: complete blocks and delete tags
    /// removed, and an unclosed block cut off with everything after it.
    static func textWithoutElfTags(_ responseText: String) -> String {
        var remainingText = responseText
        if let completeBlockPattern {
            remainingText = completeBlockPattern.stringByReplacingMatches(
                in: remainingText, range: NSRange(remainingText.startIndex..., in: remainingText), withTemplate: ""
            )
        }
        for singleTagPattern in [deleteFileTagPattern, assignTaskTagPattern, cancelTaskTagPattern].compactMap({ $0 }) {
            remainingText = singleTagPattern.stringByReplacingMatches(
                in: remainingText, range: NSRange(remainingText.startIndex..., in: remainingText), withTemplate: ""
            )
        }
        if let unclosedBlockOpenerMatch = unclosedBlockOpenerPattern?.firstMatch(
            in: remainingText, range: NSRange(remainingText.startIndex..., in: remainingText)
        ), let openerRange = Range(unclosedBlockOpenerMatch.range, in: remainingText) {
            remainingText = String(remainingText[..<openerRange.lowerBound])
        }
        return remainingText
    }

    /// What the main elf, on a model without tool calling, is told about
    /// assigning work.
    static let taskTagInstructions = """
    your elfs can work in the background — also silent tags:
    - hand longer work to an elf: [ASSIGN_TASK:elf name:what to do] (use "yourself" for a background copy of you), and tell the user in a few words who's on it.
    - stop a task: [CANCEL_TASK:task id]
    """

    /// What models without tool calling are told about the tags.
    static let promptInstructions = """
    your notes and files — you have no tools, so use these silent tags (never spoken, the user sees each change in chat and can undo it):
    - save a file: [FILE:files/name.md]the whole new text of the file[/FILE]. your notes about the user live in [FILE:user.md]…[/FILE] (only if you take notes).
    - delete one of your files: [DELETE_FILE:files/name.md]
    - save a skill, only when the user asks you to: [SKILL:skill name]the skill in markdown[/SKILL]
    your newest notes are shown above; never store passwords, keys, health or financial details.
    """
}

/// What models without tool calling see of their notes, since they can't
/// open them: the newest files' text, up to a budget.
nonisolated struct ElfPreloadedNote: Equatable, Sendable {
    let path: String
    let text: String
}

nonisolated enum ElfPromptBudget {
    static let preloadedNotesCharacterLimit = 6_000

    /// The newest of the elf's own files, whole, while they fit the budget.
    static func preloadedNotes(home: ElfHome) -> [ElfPreloadedNote] {
        var remainingCharacterBudget = preloadedNotesCharacterLimit
        var preloadedNotes: [ElfPreloadedNote] = []
        for notePath in home.ownNotePaths() {
            guard let noteURL = try? home.resolvedURLForElfTool(notePath, access: .read),
                  let noteText = try? String(contentsOf: noteURL, encoding: .utf8) else { continue }
            guard noteText.count <= remainingCharacterBudget else { continue }
            preloadedNotes.append(ElfPreloadedNote(path: notePath, text: noteText))
            remainingCharacterBudget -= noteText.count
        }
        return preloadedNotes
    }
}
