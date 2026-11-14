//
//  ElfToolRegistry.swift
//  elfhub
//
//  The tools an elf can call, and which of them each role gets. A tool
//  runs with an `ElfToolContext` (the elf, its change log, who asked, what
//  the elf has read so far this turn) and returns an `ElfToolOutcome`: the
//  text the model reads back, the file changes it made, and whether it
//  failed. Mistakes come back as readable results, so the model can try
//  again or tell the user; only cancellation is thrown.
//

import Foundation

nonisolated enum ElfToolGroup: String, Codable, CaseIterable, Sendable {
    /// Its own files (files/, profile.md; reading soul.md and skills too).
    case files
    /// Loading skills, and saving one when the user asked.
    case skills
    /// The main elf assigning and checking background tasks.
    case tasks
    /// The main elf searching saved chats.
    case memory
    /// A background worker reporting progress, asking, finishing.
    case worker
    case web
    case userFolders
}

@MainActor
protocol ElfTool {
    var definition: LanguageModelToolDefinition { get }
    var group: ElfToolGroup { get }
    /// True when the model needs the result to go on (reading, listing);
    /// false for actions it can mention without seeing a result (saving).
    var resultFeedsBackToModel: Bool { get }
    func isAvailable(for role: ElfPromptRole, configuration: ElfConfiguration) -> Bool
    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome
}

/// Everything a tool needs for one turn or task. A class, because what the
/// elf has read grows as the turn goes on.
@MainActor
final class ElfToolContext {
    let elf: Elf
    let changeLog: ElfChangeLog
    let origin: ElfChangeLogEntry.Origin
    /// What the user said this turn (for a task: the instruction). Decides
    /// whether saving a skill was asked for.
    let userUtterance: String
    /// Content the elf has read this turn that could steer what it writes.
    var influencedBy: Set<ElfChangeLogEntry.Influence>
    let turnEffectLedger: ElfTurnEffectLedger

    init(
        elf: Elf,
        changeLog: ElfChangeLog,
        origin: ElfChangeLogEntry.Origin,
        userUtterance: String,
        influencedBy: Set<ElfChangeLogEntry.Influence> = [],
        turnEffectLedger: ElfTurnEffectLedger
    ) {
        self.elf = elf
        self.changeLog = changeLog
        self.origin = origin
        self.userUtterance = userUtterance
        self.influencedBy = influencedBy
        self.turnEffectLedger = turnEffectLedger
    }
}

struct ElfToolOutcome {
    /// What the model reads back.
    var resultText: String
    var fileChanges: [ElfChangeLogEntry] = []
    /// Short lines for the chat ("saved files/trip.md").
    var chatNotes: [String] = []
    /// Tasks this call created (phase 5).
    var createdTaskIdentifiers: [UUID] = []
    /// The call didn't do what was asked; the model gets the reason back.
    var isFailure = false

    static func failure(_ reason: String) -> ElfToolOutcome {
        ElfToolOutcome(resultText: reason, isFailure: true)
    }
}

/// What a turn already did, kept across the ChatGPT-plan fallback restart
/// of that turn so its effects don't happen twice: writing the same text to
/// the same file again is a no-op, and a repeated task assignment returns
/// the task already made.
@MainActor
final class ElfTurnEffectLedger {
    private var writtenContentSHA256ByPath: [String: String] = [:]
    private var assignedTaskIdentifierByKey: [String: UUID] = [:]

    func hasWritten(path: String, contentSHA256: String) -> Bool {
        writtenContentSHA256ByPath[path] == contentSHA256
    }

    func recordWrite(path: String, contentSHA256: String) {
        writtenContentSHA256ByPath[path] = contentSHA256
    }

    func assignedTaskIdentifier(forKey assignmentKey: String) -> UUID? {
        assignedTaskIdentifierByKey[assignmentKey]
    }

    func recordAssignedTask(_ taskIdentifier: UUID, forKey assignmentKey: String) {
        assignedTaskIdentifierByKey[assignmentKey] = taskIdentifier
    }
}

@MainActor
final class ElfToolRegistry {
    private let tools: [ElfTool]

    init(tools: [ElfTool]) {
        self.tools = tools
    }

    /// The tools every elf has on its own folder and skills.
    static func standard() -> ElfToolRegistry {
        ElfToolRegistry(tools: ElfFileTools.allTools)
    }

    func availableTools(for role: ElfPromptRole, configuration: ElfConfiguration) -> [ElfTool] {
        tools.filter { $0.isAvailable(for: role, configuration: configuration) }
    }

    func toolDefinitions(for role: ElfPromptRole, configuration: ElfConfiguration) -> [LanguageModelToolDefinition] {
        availableTools(for: role, configuration: configuration).map(\.definition)
    }

    func tool(named toolName: String) -> ElfTool? {
        tools.first { $0.definition.name == toolName }
    }
}

/// A tool call's JSON arguments.
nonisolated struct ElfToolArguments {
    private let argumentValues: [String: Any]

    init(argumentsJSON: String) {
        let parsedArguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        argumentValues = parsedArguments ?? [:]
    }

    func string(_ argumentName: String) -> String? {
        guard let stringValue = argumentValues[argumentName] as? String else { return nil }
        return stringValue
    }

    func integer(_ argumentName: String) -> Int? {
        if let integerValue = argumentValues[argumentName] as? Int { return integerValue }
        if let doubleValue = argumentValues[argumentName] as? Double { return Int(doubleValue) }
        if let stringValue = argumentValues[argumentName] as? String { return Int(stringValue) }
        return nil
    }
}

/// Did the user ask for a skill to be saved? Skills are saved only when the
/// user's own words ask for it ("save that as a skill", "make a skill for
/// deploying", "update the deploy skill") — never because the elf decided
/// to, and never from text it read.
enum SkillSaveRequest {
    static let savingVerbs: Set<String> = [
        "save", "make", "create", "add", "write", "remember", "learn", "keep", "store", "update", "record", "turn", "edit", "change",
    ]

    static func userAskedToSaveSkill(userUtterance: String) -> Bool {
        let clauses = userUtterance
            .replacingOccurrences(of: #"\bbut\b"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: CharacterSet(charactersIn: ",.;:!?\n"))
        for clause in clauses {
            let clauseWords = UtteranceWords.words(in: clause)
            guard clauseWords.contains(where: { $0 == "skill" || $0 == "skills" }) else { continue }
            for (wordIndex, clauseWord) in clauseWords.enumerated() where savingVerbs.contains(clauseWord) {
                let negationWindowStart = max(0, wordIndex - ConsentPolicy.negationReachInWords)
                let isNegated = clauseWords[negationWindowStart..<wordIndex].contains { ConsentPolicy.negationWords.contains($0) }
                if !isNegated { return true }
            }
        }
        return false
    }
}
