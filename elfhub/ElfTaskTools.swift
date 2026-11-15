//
//  ElfTaskTools.swift
//  elfhub
//
//  The main elf's tools as manager: assigning work to an elf by name (or to
//  a background copy of itself), listing, checking, cancelling and
//  answering tasks, and searching the chats saved on this Mac. Only the
//  main elf, answering the user, has them — side elves and workers never
//  assign work (no elf-to-elf chains).
//

import Foundation

enum ElfTaskTools {
    static func tools(
        elfManager: ElfManager,
        scheduler: ElfTaskScheduler,
        savedConversationsProvider: @escaping () -> [ChatConversation]
    ) -> [ElfTool] {
        [
            AssignTaskTool(elfManager: elfManager, scheduler: scheduler),
            ListTasksTool(elfManager: elfManager, scheduler: scheduler),
            CheckTaskTool(elfManager: elfManager, scheduler: scheduler),
            CancelTaskTool(elfManager: elfManager, scheduler: scheduler),
            AnswerTaskTool(elfManager: elfManager, scheduler: scheduler),
            SearchChatsTool(savedConversationsProvider: savedConversationsProvider),
        ]
    }

    /// Words that mean "a background copy of you".
    static let selfReferenceWords: Set<String> = ["main", "me", "myself", "yourself", "you", "self"]

    /// The elf a name (or alias) stands for; "yourself" or the main elf's
    /// own name mean a background copy of the main elf.
    static func elf(named requestedName: String, in elfManager: ElfManager) -> Elf? {
        let foldedRequestedName = ElfNameRules.foldedForComparison(requestedName)
        if selfReferenceWords.contains(foldedRequestedName) { return elfManager.mainElf }
        return elfManager.elves.first { elf in
            ([elf.configuration.identity.name] + elf.configuration.identity.aliases)
                .contains { ElfNameRules.foldedForComparison($0) == foldedRequestedName }
        }
    }

    static func elfName(forIdentifier elfIdentifier: String, in elfManager: ElfManager) -> String {
        elfManager.elf(withIdentifier: elfIdentifier)?.configuration.identity.name ?? elfIdentifier
    }

    /// One line about a task, for list_tasks and check_task.
    static func summaryLine(for elfTask: ElfTask, elfManager: ElfManager) -> String {
        let elfName = elfIdentifierDisplayName(elfTask.elfIdentifier, elfManager: elfManager)
        var summaryLine = "- task \(ElfStatusBlock.shortTaskIdentifier(elfTask.id)) · \(elfName) · \(elfTask.status.rawValue) · \"\(elfTask.instruction)\""
        if let pendingQuestion = elfTask.pendingQuestion { summaryLine += " · asks: " + pendingQuestion }
        if let resultSummary = elfTask.result?.summary { summaryLine += " · result: " + resultSummary }
        if let failureReason = elfTask.failureReason { summaryLine += " · couldn't finish: " + failureReason }
        return summaryLine
    }

    private static func elfIdentifierDisplayName(_ elfIdentifier: String, elfManager: ElfManager) -> String {
        elfIdentifier == ElfManager.mainElfIdentifier ? "you (in the background)" : elfName(forIdentifier: elfIdentifier, in: elfManager)
    }
}

private protocol MainElfOnlyTool: ElfTool {}
extension MainElfOnlyTool {
    func isAvailable(for role: ElfPromptRole, configuration: ElfConfiguration) -> Bool {
        role == .mainForeground
    }
}

private struct AssignTaskTool: MainElfOnlyTool {
    let elfManager: ElfManager
    let scheduler: ElfTaskScheduler
    let group = ElfToolGroup.tasks
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "assign_task",
        description: "Hand longer work (research, writing, several steps) to one of your elves to do in the background, or to \"yourself\" for a background copy of you. They report back when done; tell the user in a few words who's on it.",
        inputSchema: [
            "type": "object",
            "properties": [
                "elf": ["type": "string", "description": "the elf's name, or \"yourself\""],
                "instruction": ["type": "string", "description": "what to do, as you'd tell them"],
                "context": ["type": "string", "description": "anything from the conversation they need to know"],
            ],
            "required": ["elf", "instruction"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let requestedElfName = arguments.string("elf"),
              let instruction = arguments.string("instruction")?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else {
            return .failure("give the elf's name and the instruction.")
        }
        guard let assignedElf = ElfTaskTools.elf(named: requestedElfName, in: elfManager) else {
            let otherElfNames = elfManager.elves.filter { $0.id != ElfManager.mainElfIdentifier }.map(\.configuration.identity.name)
            let knownNamesText = otherElfNames.isEmpty ? "you have no other elves yet; use \"yourself\"." : "your elves are " + otherElfNames.joined(separator: ", ") + ", or \"yourself\"."
            return .failure("there's no elf called \(requestedElfName). " + knownNamesText)
        }
        // After reading a file, a page or an elf's report, only the user's
        // own words can start work: text the elf read can't assign it.
        if !context.influencedBy.isEmpty, !TaskRequest.userAskedForBackgroundWork(userUtterance: context.userUtterance) {
            return .failure("only the user can ask for that — they didn't ask for background work. if it would help, offer it.")
        }
        // A turn restarted on the fallback model returns the task it made.
        let assignmentKey = assignedElf.id + "|" + instruction.lowercased()
        if let alreadyAssignedTaskIdentifier = context.turnEffectLedger.assignedTaskIdentifier(forKey: assignmentKey) {
            return ElfToolOutcome(resultText: "already assigned.", createdTaskIdentifiers: [alreadyAssignedTaskIdentifier])
        }
        try Task.checkCancellation()
        do {
            var originConversationIdentifier: UUID?
            if case let .turn(conversationIdentifier) = context.origin {
                originConversationIdentifier = conversationIdentifier
            }
            let assignedTask = try scheduler.enqueue(
                elfIdentifier: assignedElf.id,
                instruction: instruction,
                contextFromMain: arguments.string("context") ?? "",
                originConversationIdentifier: originConversationIdentifier
            )
            context.turnEffectLedger.recordAssignedTask(assignedTask.id, forKey: assignmentKey)
            let assigneeName = assignedElf.id == ElfManager.mainElfIdentifier ? "a background copy of you" : assignedElf.configuration.identity.name
            return ElfToolOutcome(
                resultText: "assigned task \(ElfStatusBlock.shortTaskIdentifier(assignedTask.id)) to \(assigneeName).",
                chatNotes: ["assigned \"\(instruction)\" to \(assigneeName)"],
                createdTaskIdentifiers: [assignedTask.id]
            )
        } catch {
            return .failure("couldn't assign it: \(error.localizedDescription)")
        }
    }
}

private struct ListTasksTool: MainElfOnlyTool {
    let elfManager: ElfManager
    let scheduler: ElfTaskScheduler
    let group = ElfToolGroup.tasks
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "list_tasks",
        description: "List your elves' background tasks: running, waiting for an answer, and recently finished.",
        inputSchema: ["type": "object", "properties": [:]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let listedTasks = scheduler.tasks.filter { !$0.status.isFinished } + scheduler.tasks.filter(\.status.isFinished).suffix(10)
        guard !listedTasks.isEmpty else { return ElfToolOutcome(resultText: "no tasks.") }
        return ElfToolOutcome(resultText: listedTasks.map { ElfTaskTools.summaryLine(for: $0, elfManager: elfManager) }.joined(separator: "\n"))
    }
}

private struct CheckTaskTool: MainElfOnlyTool {
    let elfManager: ElfManager
    let scheduler: ElfTaskScheduler
    let group = ElfToolGroup.tasks
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "check_task",
        description: "See one task in full: its status, notes, question and result.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string", "description": "the task id"]], "required": ["id"]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        guard let shortIdentifier = ElfToolArguments(argumentsJSON: argumentsJSON).string("id"),
              let checkedTask = scheduler.task(withShortIdentifier: shortIdentifier) else {
            return .failure("there's no task with that id. use list_tasks.")
        }
        var detailLines = [ElfTaskTools.summaryLine(for: checkedTask, elfManager: elfManager)]
        if !checkedTask.progressNotes.isEmpty {
            detailLines.append("notes:\n" + checkedTask.progressNotes.map { "  - " + $0 }.joined(separator: "\n"))
        }
        if let filePaths = checkedTask.result?.filePaths, !filePaths.isEmpty {
            detailLines.append("files: " + filePaths.joined(separator: ", "))
        }
        return ElfToolOutcome(resultText: detailLines.joined(separator: "\n"))
    }
}

private struct CancelTaskTool: MainElfOnlyTool {
    let elfManager: ElfManager
    let scheduler: ElfTaskScheduler
    let group = ElfToolGroup.tasks
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "cancel_task",
        description: "Stop a task the user no longer wants.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        guard let shortIdentifier = ElfToolArguments(argumentsJSON: argumentsJSON).string("id"),
              let cancelledTask = scheduler.task(withShortIdentifier: shortIdentifier) else {
            return .failure("there's no task with that id. use list_tasks.")
        }
        scheduler.cancel(taskIdentifier: cancelledTask.id)
        return ElfToolOutcome(resultText: "cancelled task \(ElfStatusBlock.shortTaskIdentifier(cancelledTask.id)).")
    }
}

private struct AnswerTaskTool: MainElfOnlyTool {
    let elfManager: ElfManager
    let scheduler: ElfTaskScheduler
    let group = ElfToolGroup.tasks
    let resultFeedsBackToModel = false
    let definition = LanguageModelToolDefinition(
        name: "answer_task",
        description: "Pass the user's answer to a task that asked a question; it carries on.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "string"], "answer": ["type": "string", "description": "the user's answer, in their words"]],
            "required": ["id", "answer"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let arguments = ElfToolArguments(argumentsJSON: argumentsJSON)
        guard let shortIdentifier = arguments.string("id"), let answer = arguments.string("answer"),
              let answeredTask = scheduler.task(withShortIdentifier: shortIdentifier) else {
            return .failure("give the task id and the answer.")
        }
        // An answer is the user's, never one the elf made up.
        guard TaskRequest.answerComesFromTheUser(answer: answer, userUtterance: context.userUtterance) else {
            return .failure("that isn't what the user said. ask them, and pass on their words.")
        }
        do {
            try scheduler.answer(taskIdentifier: answeredTask.id, answer: answer)
            return ElfToolOutcome(resultText: "passed on; the task carries on.")
        } catch {
            return .failure("that task isn't waiting for an answer.")
        }
    }
}

private struct SearchChatsTool: MainElfOnlyTool {
    let savedConversationsProvider: () -> [ChatConversation]
    let group = ElfToolGroup.memory
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "search_chats",
        description: "Search the user's earlier chats saved on this Mac, newest first, when they refer to something you talked about before.",
        inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "a few words to look for"]], "required": ["query"]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        guard let query = ElfToolArguments(argumentsJSON: argumentsJSON).string("query") else { return .failure("give a few words to look for.") }
        let searchResults = ChatConversationSearch.search(query: query, in: savedConversationsProvider())
        guard !searchResults.isEmpty else { return ElfToolOutcome(resultText: "nothing found for \"\(query)\".") }
        let resultLines = searchResults.map { searchResult in
            "- \"\(searchResult.conversationTitle)\" (\(searchResult.updatedAt.formatted(date: .abbreviated, time: .omitted))): \(searchResult.snippet)"
        }
        // What the elf reads from old chats may steer what it writes next.
        context.influencedBy.insert(.file)
        return ElfToolOutcome(resultText: resultLines.joined(separator: "\n"))
    }
}

// MARK: - The user's words

/// Checks that background work and answers to tasks come from what the user
/// said, not from text an elf read.
enum TaskRequest {
    static let backgroundWorkWords: Set<String> = [
        "assign", "ask", "have", "get", "tell", "let", "delegate", "hand", "background", "task", "tasks",
        "research", "look", "find", "dig", "draft", "write", "work", "check", "compile", "gather", "summarise", "summarize",
    ]

    static let wordsThatCarryNoAnswer: Set<String> = [
        "the", "a", "an", "it", "is", "to", "and", "or", "of", "in", "on", "for", "please", "that", "this", "with",
    ]

    /// The user asked for work to be done or handed off.
    static func userAskedForBackgroundWork(userUtterance: String) -> Bool {
        UtteranceWords.words(in: userUtterance).contains { backgroundWorkWords.contains($0) }
    }

    /// The answer passed to a task is in the user's words: one of its
    /// meaningful words is something the user said.
    static func answerComesFromTheUser(answer: String, userUtterance: String) -> Bool {
        let userWords = Set(UtteranceWords.words(in: userUtterance))
        let answerWords = UtteranceWords.words(in: answer).filter { !wordsThatCarryNoAnswer.contains($0) }
        guard !answerWords.isEmpty else { return false }
        return answerWords.contains { userWords.contains($0) }
    }
}
