//
//  ElfTask.swift
//  elfhub
//
//  A piece of work the main elf handed to an elf (or a background copy of
//  itself) to do in the background: what to do, what the main elf passed
//  along, the elf's progress notes, a question waiting for the user, and
//  the result. Tasks are kept in the elf's app-owned folder
//  (.elfhub/tasks/<id>.json, never exported); one running when elfhub quit
//  is queued again on the next launch, with its notes.
//
//    queued → running → done | failed | cancelled
//               ⇅
//           needsInput (waiting for the user's answer) → queued
//

import Foundation

nonisolated enum ElfTaskStatus: String, Codable, Sendable {
    case queued
    case running
    case needsInput
    case done
    case failed
    case cancelled

    var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
}

nonisolated enum ElfTaskStatusMachine {
    private static let allowedMoves: [ElfTaskStatus: Set<ElfTaskStatus>] = [
        .queued: [.running, .cancelled],
        .running: [.needsInput, .done, .failed, .cancelled],
        .needsInput: [.queued, .cancelled],
    ]

    static func canMove(from currentStatus: ElfTaskStatus, to newStatus: ElfTaskStatus) -> Bool {
        allowedMoves[currentStatus]?.contains(newStatus) ?? false
    }
}

nonisolated enum ElfTaskError: LocalizedError, Equatable {
    case statusMoveNotAllowed(from: ElfTaskStatus, to: ElfTaskStatus)
    case unknownTask

    var errorDescription: String? {
        switch self {
        case let .statusMoveNotAllowed(currentStatus, newStatus):
            return "A task that's \(currentStatus.rawValue) can't become \(newStatus.rawValue)."
        case .unknownTask:
            return "That task isn't there any more."
        }
    }
}

nonisolated struct ElfTaskResult: Codable, Equatable, Sendable {
    var summary: String
    /// Files the elf wrote for the user, as paths in its folder.
    var filePaths: [String]
}

nonisolated struct ElfTaskBudgetUsage: Codable, Equatable, Sendable {
    var rounds = 0
    var outputTokens = 0
    var startedAt: Date?
}

nonisolated struct ElfTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// The elf doing the work ("main" for a background copy of the main elf).
    let elfIdentifier: String
    let instruction: String
    /// What the main elf passed along with the instruction.
    var contextFromMain: String
    /// The chat the task came from, as plain exchanges.
    var conversationExcerpt: [ElfTaskConversationTurn]
    var originConversationIdentifier: UUID?
    var status: ElfTaskStatus
    var progressNotes: [String]
    /// A question the elf asked; the task waits for the answer.
    var pendingQuestion: String?
    /// True when the question is the elf asking for the screen.
    var isWaitingForTheScreen: Bool
    /// The user's answers to its questions, in order.
    var answers: [String]
    var result: ElfTaskResult?
    /// Why it failed, when it did.
    var failureReason: String?
    var budgetUsage: ElfTaskBudgetUsage
    /// True once the user has been told the result.
    var reportedToUser: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        elfIdentifier: String,
        instruction: String,
        contextFromMain: String = "",
        conversationExcerpt: [ElfTaskConversationTurn] = [],
        originConversationIdentifier: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.elfIdentifier = elfIdentifier
        self.instruction = instruction
        self.contextFromMain = contextFromMain
        self.conversationExcerpt = conversationExcerpt
        self.originConversationIdentifier = originConversationIdentifier
        self.status = .queued
        self.progressNotes = []
        self.pendingQuestion = nil
        self.isWaitingForTheScreen = false
        self.answers = []
        self.result = nil
        self.failureReason = nil
        self.budgetUsage = ElfTaskBudgetUsage()
        self.reportedToUser = false
        self.createdAt = createdAt
    }

    /// Moves the task to a new status, or throws when that move isn't allowed.
    mutating func move(to newStatus: ElfTaskStatus) throws {
        guard ElfTaskStatusMachine.canMove(from: status, to: newStatus) else {
            throw ElfTaskError.statusMoveNotAllowed(from: status, to: newStatus)
        }
        status = newStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id, elfIdentifier, instruction, contextFromMain, conversationExcerpt, originConversationIdentifier, status
        case progressNotes, pendingQuestion, isWaitingForTheScreen, answers, result, failureReason, budgetUsage
        case reportedToUser, createdAt
    }

    /// Fields missing from older files get their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        elfIdentifier = try container.decode(String.self, forKey: .elfIdentifier)
        instruction = try container.decode(String.self, forKey: .instruction)
        contextFromMain = try container.decodeIfPresent(String.self, forKey: .contextFromMain) ?? ""
        conversationExcerpt = try container.decodeIfPresent([ElfTaskConversationTurn].self, forKey: .conversationExcerpt) ?? []
        originConversationIdentifier = try container.decodeIfPresent(UUID.self, forKey: .originConversationIdentifier)
        status = (try? container.decodeIfPresent(ElfTaskStatus.self, forKey: .status)) ?? .failed
        progressNotes = try container.decodeIfPresent([String].self, forKey: .progressNotes) ?? []
        pendingQuestion = try container.decodeIfPresent(String.self, forKey: .pendingQuestion)
        isWaitingForTheScreen = try container.decodeIfPresent(Bool.self, forKey: .isWaitingForTheScreen) ?? false
        answers = try container.decodeIfPresent([String].self, forKey: .answers) ?? []
        result = try container.decodeIfPresent(ElfTaskResult.self, forKey: .result)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        budgetUsage = try container.decodeIfPresent(ElfTaskBudgetUsage.self, forKey: .budgetUsage) ?? ElfTaskBudgetUsage()
        reportedToUser = try container.decodeIfPresent(Bool.self, forKey: .reportedToUser) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// One exchange from the chat a task came from.
nonisolated struct ElfTaskConversationTurn: Codable, Equatable, Sendable {
    var userText: String
    var assistantText: String
}

/// An elf's tasks on disk, in .elfhub/tasks/ — which elf tools can't reach
/// and exports never include.
nonisolated struct ElfTaskStore {
    let home: ElfHome

    init(home: ElfHome) {
        self.home = home
    }

    var tasksDirectory: URL { home.appDataDirectory.appendingPathComponent("tasks", isDirectory: true) }

    private static let jsonEncoder: JSONEncoder = {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return jsonEncoder
    }()

    private static let jsonDecoder = JSONDecoder()

    func save(_ elfTask: ElfTask) throws {
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
        try Self.jsonEncoder.encode(elfTask).write(
            to: tasksDirectory.appendingPathComponent("\(elfTask.id.uuidString).json"),
            options: .atomic
        )
    }

    /// Every task, oldest first. Files that can't be read are skipped.
    func tasks() -> [ElfTask] {
        let taskFileNames = (try? FileManager.default.contentsOfDirectory(atPath: tasksDirectory.path)) ?? []
        return taskFileNames
            .filter { $0.hasSuffix(".json") }
            .compactMap { taskFileName in
                guard let taskData = try? Data(contentsOf: tasksDirectory.appendingPathComponent(taskFileName)) else { return nil }
                return try? Self.jsonDecoder.decode(ElfTask.self, from: taskData)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func delete(taskIdentifier: UUID) {
        try? FileManager.default.removeItem(at: tasksDirectory.appendingPathComponent("\(taskIdentifier.uuidString).json"))
    }

    /// Tasks that were running when elfhub quit go back in the queue, notes
    /// kept, so they pick up where they were.
    func requeueInterruptedTasks() throws -> [ElfTask] {
        var requeuedTasks: [ElfTask] = []
        for var interruptedTask in tasks() where interruptedTask.status == .running {
            // Not a normal move (running → queued): the run it was in is gone.
            interruptedTask.status = .queued
            try save(interruptedTask)
            requeuedTasks.append(interruptedTask)
        }
        return requeuedTasks
    }
}
