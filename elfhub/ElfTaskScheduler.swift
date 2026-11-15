//
//  ElfTaskScheduler.swift
//  elfhub
//
//  Runs background tasks. A task starts when there's room — one at a time
//  per elf, three in all — and runs the agent loop as that elf in its
//  background-worker role: its own notes, files and skills, plus the
//  worker's tools (report progress, ask the user, finish), and never the
//  screen (pointing, acting) or the main elf's task tools. Each run has 25
//  model rounds and 15 minutes, and a task 80,000 output tokens in all; out
//  of budget, it stops as failed with its notes kept. A task that asks the
//  user waits until answered. Esc never cancels background work — only the
//  user's "cancel" (by voice, through the main elf, or in the hub) does.
//  macOS is told work is under way so App Nap doesn't stall it.
//

import Combine
import Foundation

/// What a background task gets for one run on the user's screen, after the
/// user said yes to its request_screen: the step-by-step session, the
/// screen as it is now, how to offer the steps to its model, and the
/// clean-up for when the run ends (the pointer back, the pill, the screen
/// back to the main elf).
struct ElfWorkerScreenAccess {
    let session: ComputerUseSession
    let firstScreenshot: LanguageModelImage
    let usesAnthropicComputerToolset: Bool
    let extraToolDefinitions: [LanguageModelToolDefinition]
    let systemPromptAddition: String
    /// The window in front's controls, sent with the first screenshot.
    var firstInterfaceDescription: String? = nil
    let finish: @MainActor () -> Void
}

enum ElfWorkerScreenAccessOutcome {
    case granted(ElfWorkerScreenAccess)
    /// The screen can't be used now; the reason is told to the elf.
    case unavailable(reason: String)
}

@MainActor
final class ElfTaskScheduler: ObservableObject {
    static let maximumConcurrentTasks = 3
    static let maximumWorkerRounds = 25
    static let maximumOutputTokensPerTask = 80_000
    static let maximumDurationPerRunInSeconds: TimeInterval = 15 * 60

    /// Every elf's tasks, oldest first.
    @Published private(set) var tasks: [ElfTask] = []

    /// A task finished (done, failed or cancelled).
    var onTaskFinished: ((ElfTask) -> Void)?
    /// A task asked the user something and is waiting.
    var onTaskNeedsInput: ((ElfTask) -> Void)?

    private let elfManager: ElfManager
    private let languageModelProviderForWorker: (Elf) -> LanguageModelProvider?
    private let maximumOutputTokensPerTask: Int
    /// The web and the user's folders, for elves that may use them.
    private let outsideToolsForElf: (Elf) -> [ElfTool]
    private var runningTaskHandles: [UUID: Task<Void, Never>] = [:]
    private var taskIdentifiersBeingCancelled: Set<UUID> = []
    /// Tasks of a deleted elf: stopped, never saved or reported again.
    private var forgottenTaskIdentifiers: Set<UUID> = []
    /// Sets up a run on the user's screen for a task the user let use it.
    private let screenAccessForWorker: (Elf, ElfTask, LanguageModelProvider) async -> ElfWorkerScreenAccessOutcome

    /// What a task asks after the user stopped it on the screen.
    static let stoppedOnTheScreenQuestion = "you stopped me while i was using your screen. should i carry on another way, or leave it there?"

    /// `languageModelProviderForWorker` gives the model an elf works with in
    /// the background (one that can use tools), or nil when there's none.
    init(
        elfManager: ElfManager,
        languageModelProviderForWorker: @escaping (Elf) -> LanguageModelProvider?,
        maximumOutputTokensPerTask: Int = ElfTaskScheduler.maximumOutputTokensPerTask,
        outsideToolsForElf: @escaping (Elf) -> [ElfTool] = { _ in [] },
        screenAccessForWorker: @escaping (Elf, ElfTask, LanguageModelProvider) async -> ElfWorkerScreenAccessOutcome = { _, _, _ in
            .unavailable(reason: "the screen isn't available to background work here.")
        }
    ) {
        self.screenAccessForWorker = screenAccessForWorker
        self.outsideToolsForElf = outsideToolsForElf
        self.elfManager = elfManager
        self.languageModelProviderForWorker = languageModelProviderForWorker
        self.maximumOutputTokensPerTask = maximumOutputTokensPerTask
    }

    // MARK: Loading

    /// Reads every elf's tasks; tasks that were running when elfhub quit are
    /// queued again and started.
    func loadTasksAndResumeInterruptedOnes() {
        var loadedTasks: [ElfTask] = []
        var loadedTaskIdentifiers: Set<UUID> = []
        for elf in elfManager.elves {
            let elfTaskStore = ElfTaskStore(home: elf.home)
            _ = try? elfTaskStore.requeueInterruptedTasks()
            // Only the elf's own tasks, each once — a folder duplicated in
            // Finder carries copies of the original's task files.
            for storedTask in elfTaskStore.tasks()
            where storedTask.elfIdentifier == elf.id && !loadedTaskIdentifiers.contains(storedTask.id) {
                loadedTasks.append(storedTask)
                loadedTaskIdentifiers.insert(storedTask.id)
            }
        }
        // Old finished tasks go, so the list and the files don't grow forever.
        let forgottenFinishedTasks = Self.finishedTasksToForget(among: loadedTasks, now: Date())
        let forgottenTaskIdentifiers = Set(forgottenFinishedTasks.map(\.id))
        for forgottenTask in forgottenFinishedTasks {
            if let taskElf = elfManager.elf(withIdentifier: forgottenTask.elfIdentifier) {
                ElfTaskStore(home: taskElf.home).delete(taskIdentifier: forgottenTask.id)
            }
        }
        tasks = loadedTasks.filter { !forgottenTaskIdentifiers.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        startTasksThatHaveRoom()
    }

    // MARK: Assigning, answering, cancelling

    /// Queues a task for an elf ("main" for a background copy of the main
    /// elf) and starts it if there's room.
    @discardableResult
    func enqueue(
        elfIdentifier: String,
        instruction: String,
        contextFromMain: String = "",
        conversationExcerpt: [ElfTaskConversationTurn] = [],
        originConversationIdentifier: UUID? = nil
    ) throws -> ElfTask {
        guard elfManager.elf(withIdentifier: elfIdentifier) != nil else { throw ElfManagerError.unknownElf(elfIdentifier) }
        let newTask = ElfTask(
            elfIdentifier: elfIdentifier,
            instruction: instruction,
            contextFromMain: contextFromMain,
            conversationExcerpt: conversationExcerpt,
            originConversationIdentifier: originConversationIdentifier
        )
        store(newTask)
        startTasksThatHaveRoom()
        return task(withIdentifier: newTask.id) ?? newTask
    }

    /// How long a yes to "may i use your screen?" lasts: the screen isn't
    /// taken long after (or after a relaunch) when the user has moved on.
    static let screenGrantLifetimeInSeconds: TimeInterval = 5 * 60

    nonisolated static func isScreenGrantStillValid(grantedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(grantedAt) <= screenGrantLifetimeInSeconds
    }

    /// Finished tasks kept per elf; older ones beyond this are forgotten.
    static let finishedTasksKeptPerElf = 50
    /// Finished, reported tasks older than this are forgotten.
    static let finishedTaskLifetimeInSeconds: TimeInterval = 30 * 86_400

    /// Finished tasks to forget: reported ones older than 30 days, and any
    /// beyond an elf's newest 50 finished ones. Waiting or unreported tasks stay.
    nonisolated static func finishedTasksToForget(among elfTasks: [ElfTask], now: Date) -> [ElfTask] {
        var tasksToForget: [ElfTask] = []
        let finishedTasksByElf = Dictionary(grouping: elfTasks.filter { $0.status.isFinished }, by: \.elfIdentifier)
        for (_, finishedTasks) in finishedTasksByElf {
            let newestFirst = finishedTasks.sorted { $0.createdAt > $1.createdAt }
            for (position, finishedTask) in newestFirst.enumerated() {
                let isBeyondTheKeptNumber = position >= finishedTasksKeptPerElf
                let isOldAndReported = finishedTask.reportedToUser && now.timeIntervalSince(finishedTask.createdAt) > finishedTaskLifetimeInSeconds
                if isBeyondTheKeptNumber || isOldAndReported {
                    tasksToForget.append(finishedTask)
                }
            }
        }
        return tasksToForget.sorted { $0.createdAt < $1.createdAt }
    }

    /// The user's answer to a task's question: it goes back in the queue.
    /// `usersOwnWords` is what the user actually said when someone else
    /// (the main elf) passes the answer on — a screen request is granted
    /// only by those words, never by the passed-on answer.
    func answer(taskIdentifier: UUID, answer: String, usersOwnWords: String? = nil) throws {
        guard var answeredTask = task(withIdentifier: taskIdentifier) else { throw ElfTaskError.unknownTask }
        try answeredTask.move(to: .queued)
        if let pendingQuestion = answeredTask.pendingQuestion {
            answeredTask.answers.append("\(pendingQuestion) → \(answer)")
        } else {
            answeredTask.answers.append(answer)
        }
        // A yes to "may i use your screen?" lets the next run use it.
        if answeredTask.isWaitingForTheScreen {
            let userSaidYes = SpokenConfirmationParser.interpret(usersOwnWords ?? answer, requiredVerbKeywords: []) == .confirmed
            answeredTask.screenGrantedAt = userSaidYes ? Date() : nil
        }
        answeredTask.pendingQuestion = nil
        answeredTask.isWaitingForTheScreen = false
        store(answeredTask)
        startTasksThatHaveRoom()
    }

    func cancel(taskIdentifier: UUID) {
        guard var cancelledTask = task(withIdentifier: taskIdentifier), !cancelledTask.status.isFinished else { return }
        if cancelledTask.status == .running, let runningTaskHandle = runningTaskHandles[taskIdentifier] {
            // The run notices, stops, and records it as cancelled.
            taskIdentifiersBeingCancelled.insert(taskIdentifier)
            runningTaskHandle.cancel()
            return
        }
        try? cancelledTask.move(to: .cancelled)
        store(cancelledTask)
        onTaskFinished?(cancelledTask)
    }

    /// The user was told these results.
    func markReported(taskIdentifiers: [UUID]) {
        for taskIdentifier in taskIdentifiers {
            guard var reportedTask = task(withIdentifier: taskIdentifier), !reportedTask.reportedToUser else { continue }
            reportedTask.reportedToUser = true
            store(reportedTask)
        }
    }

    /// Before an elf is deleted: its tasks stop, and are forgotten — not
    /// saved, not reported. Waits for a running one to stop, so it can't
    /// write into the folder as it goes to the Trash.
    func cancelAndForgetTasks(forElfIdentifier elfIdentifier: String) async {
        let forgottenTasks = tasks.filter { $0.elfIdentifier == elfIdentifier }
        forgottenTaskIdentifiers.formUnion(forgottenTasks.map(\.id))
        tasks.removeAll { $0.elfIdentifier == elfIdentifier }
        for forgottenTask in forgottenTasks {
            guard let runningTaskHandle = runningTaskHandles[forgottenTask.id] else { continue }
            runningTaskHandle.cancel()
            await runningTaskHandle.value
        }
    }

    func task(withIdentifier taskIdentifier: UUID) -> ElfTask? {
        tasks.first { $0.id == taskIdentifier }
    }

    /// A task by the short id the main elf sees ("3f2a9c1e"), or its full id.
    func task(withShortIdentifier shortIdentifier: String) -> ElfTask? {
        let loweredIdentifier = shortIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !loweredIdentifier.isEmpty else { return nil }
        return tasks.last { $0.id.uuidString.lowercased().hasPrefix(loweredIdentifier) }
    }

    /// Waits until no task is running (for tests and quitting).
    func waitUntilIdle() async {
        while let runningTaskHandle = runningTaskHandles.values.first {
            await runningTaskHandle.value
        }
    }

    // MARK: Starting

    /// Which queued tasks may start now: oldest first, one per elf, and no
    /// more than `maximumConcurrentTasks` running in all.
    nonisolated static func tasksToStart(queuedTasks: [ElfTask], runningTasks: [ElfTask], maximumConcurrentTasks: Int) -> [ElfTask] {
        var busyElfIdentifiers = Set(runningTasks.map(\.elfIdentifier))
        var runningCount = runningTasks.count
        var startableTasks: [ElfTask] = []
        for queuedTask in queuedTasks.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard runningCount < maximumConcurrentTasks else { break }
            guard !busyElfIdentifiers.contains(queuedTask.elfIdentifier) else { continue }
            startableTasks.append(queuedTask)
            busyElfIdentifiers.insert(queuedTask.elfIdentifier)
            runningCount += 1
        }
        return startableTasks
    }

    private func startTasksThatHaveRoom() {
        let startableTasks = Self.tasksToStart(
            queuedTasks: tasks.filter { $0.status == .queued },
            runningTasks: tasks.filter { $0.status == .running },
            maximumConcurrentTasks: Self.maximumConcurrentTasks
        )
        for var startingTask in startableTasks {
            try? startingTask.move(to: .running)
            if startingTask.budgetUsage.startedAt == nil {
                startingTask.budgetUsage.startedAt = Date()
            }
            store(startingTask)
            let startingTaskIdentifier = startingTask.id
            runningTaskHandles[startingTaskIdentifier] = Task { [weak self] in
                await self?.run(taskIdentifier: startingTaskIdentifier)
                self?.runningTaskHandles[startingTaskIdentifier] = nil
                self?.startTasksThatHaveRoom()
            }
        }
    }

    // MARK: Running

    /// The model a worker uses: its own when it can use tools, otherwise
    /// the main model when that can, otherwise none.
    nonisolated static func workerConfiguration(
        elfPreferredConfiguration: ProviderConfiguration?,
        mainConfiguration: ProviderConfiguration?
    ) -> ProviderConfiguration? {
        if let elfPreferredConfiguration, elfPreferredConfiguration.supportsToolCalling { return elfPreferredConfiguration }
        if let mainConfiguration, mainConfiguration.supportsToolCalling { return mainConfiguration }
        return nil
    }

    /// A worker's tools: its own folder and skills, plus progress, asking
    /// and finishing. No screen tools and no task tools.
    static func workerToolRegistry(session: ElfWorkerSession, outsideTools: [ElfTool] = [], mayRequestScreen: Bool = true) -> ElfToolRegistry {
        ElfToolRegistry(tools: ElfFileTools.allTools + ElfWorkerTools.tools(session: session, mayRequestScreen: mayRequestScreen) + outsideTools)
    }

    /// Said to a worker that answered with words only.
    static let finishNudge = "you haven't finished the task yet. keep working with your tools, call ask_user if you need the user, or call finish_task with a short summary when you're done."

    static let workerInstructions = """
    how to work on this task: nobody is watching while you work. use your tools — read your notes and skills, and write longer findings to a file under files/ so the user can open it later. call report_progress now and then with a short note. if you need something only the user can tell you, call ask_user with one clear question and stop. if part of the task can only be done in the user's apps on their screen, call request_screen saying what for, and stop. when you're done, call finish_task with a summary of two or three sentences, written to be spoken to the user, and the files you wrote. don't ask for permission to start; just do the task.
    """

    private func run(taskIdentifier: UUID) async {
        guard var runningTask = task(withIdentifier: taskIdentifier) else { return }
        guard let workingElf = elfManager.elf(withIdentifier: runningTask.elfIdentifier) else {
            taskIdentifiersBeingCancelled.remove(taskIdentifier)
            finish(&runningTask, as: .failed, failureReason: "the elf for this task is gone")
            return
        }
        guard let languageModelProvider = languageModelProviderForWorker(workingElf) else {
            taskIdentifiersBeingCancelled.remove(taskIdentifier)
            finish(&runningTask, as: .failed, failureReason: "background work needs a language model that can use tools. pick one in Settings › Models.")
            return
        }

        // Keeps macOS from napping the app while the elf works.
        // App Nap is held off; a closed or idle Mac may still sleep.
        let backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "An elf is working on a task"
        )
        defer { ProcessInfo.processInfo.endActivity(backgroundActivity) }

        let workerSession = ElfWorkerSession(progressNotes: runningTask.progressNotes)
        workerSession.onProgressNoted = { [weak self] progressNotes in
            guard var progressingTask = self?.task(withIdentifier: taskIdentifier) else { return }
            progressingTask.progressNotes = progressNotes
            self?.store(progressingTask)
        }
        let taskInstruction = runningTask.instruction
        let workingElfHome = workingElf.home
        let elfPromptContext = await Task.detached(priority: .utility) {
            ElfPromptContext.reading(home: workingElfHome, role: .backgroundWorker(taskInstruction: taskInstruction))
        }.value
        // The user said yes to this task using their screen: this run gets it.
        var screenAccess: ElfWorkerScreenAccess?
        var screenUnavailableReason: String?
        if let screenGrantedAt = runningTask.screenGrantedAt {
            runningTask.screenGrantedAt = nil
            store(runningTask)
            if Self.isScreenGrantStillValid(grantedAt: screenGrantedAt, now: Date()) {
                switch await screenAccessForWorker(workingElf, runningTask, languageModelProvider) {
                case let .granted(grantedScreenAccess):
                    screenAccess = grantedScreenAccess
                case let .unavailable(reason):
                    screenUnavailableReason = reason
                }
            } else {
                screenUnavailableReason = "the user's okay ran out (it lasts \(Int(Self.screenGrantLifetimeInSeconds / 60)) minutes). ask for the screen again if you still need it."
            }
        }
        defer { screenAccess?.finish() }

        var systemPromptSections = elfPromptContext.promptSections + [Self.workerInstructions]
        if let screenAccess {
            systemPromptSections.append(screenAccess.systemPromptAddition)
        }
        let systemPrompt = systemPromptSections.joined(separator: "\n\n")
        let workerToolRegistry = Self.workerToolRegistry(
            session: workerSession,
            outsideTools: outsideToolsForElf(workingElf),
            mayRequestScreen: screenAccess == nil
        )
        let turnEffectLedger = ElfTurnEffectLedger()
        let toolContext = ElfToolContext(
            elf: workingElf,
            changeLog: ElfChangeLog(home: workingElf.home),
            origin: .task(taskIdentifier: taskIdentifier),
            userUtterance: runningTask.instruction,
            // What earlier runs of this task read and used still counts.
            influencedBy: runningTask.influencedBy,
            turnEffectLedger: turnEffectLedger
        )
        toolContext.usedResources = runningTask.usedResources
        // What it saw on the screen can steer what it writes afterwards.
        if screenAccess != nil {
            toolContext.influencedBy.insert(.screen)
        }
        // Whatever happens, the next run (and the hub) know what this one used.
        defer {
            if var endedTask = task(withIdentifier: taskIdentifier) {
                endedTask.usedResources.formUnion(toolContext.usedResources)
                endedTask.influencedBy.formUnion(toolContext.influencedBy)
                store(endedTask)
            }
            if !turnEffectLedger.recordedFileChanges.isEmpty {
                try? ElfChangeLog(home: workingElf.home).prune(now: Date())
            }
        }
        var workerUserText = Self.workerUserText(for: runningTask)
        if let screenAccess {
            workerUserText += "\n\n" + Self.screenGrantedNote
            if let firstInterfaceDescription = screenAccess.firstInterfaceDescription {
                workerUserText += "\n\n" + firstInterfaceDescription
            }
        } else if let screenUnavailableReason {
            workerUserText += "\n\nthe user said you may use their screen, but it can't be used right now: \(screenUnavailableReason) carry on another way, or finish and say what's left."
        }
        var initialRequest = LanguageModelRequest(
            systemPrompt: systemPrompt,
            history: runningTask.conversationExcerpt.map { LanguageModelHistoryTurn(userText: $0.userText, assistantText: $0.assistantText) },
            userText: workerUserText,
            images: screenAccess.map { [$0.firstScreenshot] } ?? [],
            tools: workerToolRegistry.toolDefinitions(
                for: .backgroundWorker(taskInstruction: taskInstruction),
                configuration: workingElf.configuration
            ) + (screenAccess?.extraToolDefinitions ?? [])
        )
        initialRequest.usesAnthropicComputerToolset = screenAccess?.usesAnthropicComputerToolset ?? false
        let remainingOutputTokens = max(0, maximumOutputTokensPerTask - runningTask.budgetUsage.outputTokens)

        do {
            let loopResult = try await ElfAgentLoop.run(
                initialRequest: initialRequest,
                languageModelProvider: languageModelProvider,
                toolRegistry: workerToolRegistry,
                toolContext: toolContext,
                guidanceToolNames: [],
                maximumRounds: Self.maximumWorkerRounds,
                budget: ElfAgentLoopBudget(
                    maximumOutputTokens: remainingOutputTokens,
                    deadline: Date(timeIntervalSinceNow: Self.maximumDurationPerRunInSeconds)
                ),
                textOnlyRoundNudge: Self.finishNudge,
                computerUseExecutor: screenAccess?.session,
                onReplyTextDelta: { _ in },
                onModelRoundEnded: {}
            )
            runningTask = task(withIdentifier: taskIdentifier) ?? runningTask
            runningTask.progressNotes = workerSession.progressNotes
            runningTask.budgetUsage.rounds += loopResult.roundsUsed
            runningTask.budgetUsage.outputTokens += loopResult.outputTokensUsed
            // Stop pressed while the last round's tools ran: it's stopped.
            if taskIdentifiersBeingCancelled.remove(taskIdentifier) != nil {
                finish(&runningTask, as: .cancelled, failureReason: nil)
                return
            }
            if let pendingQuestion = workerSession.pendingQuestion {
                parkForAnswer(&runningTask, question: pendingQuestion, isAskingForTheScreen: false)
                return
            }
            if let screenRequestReason = workerSession.pendingScreenRequestReason {
                let elfName = workingElf.configuration.identity.name
                parkForAnswer(
                    &runningTask,
                    question: "\(elfName) needs your screen for a moment, to \(screenRequestReason). okay to go ahead?",
                    isAskingForTheScreen: true
                )
                return
            }
            // The user stopped it (or it reached their step) on the screen:
            // it asks how to go on rather than failing.
            if workerSession.result == nil, case let .stopNow(spokenReason) = screenAccess?.session.ending {
                let question = spokenReason.map { $0 + " should i carry on another way, or leave it there?" } ?? Self.stoppedOnTheScreenQuestion
                parkForAnswer(&runningTask, question: question, isAskingForTheScreen: false)
                return
            }
            // Only finish_task finishes a task; talking about it doesn't.
            guard var finishedResult = workerSession.result else {
                finish(&runningTask, as: .failed, failureReason: "it stopped without finishing")
                return
            }
            finishedResult.filePaths = Self.filePathsTheElfReallyHas(
                finishedResult.filePaths,
                writtenFilePaths: Set(turnEffectLedger.recordedFileChanges.map(\.path)),
                home: workingElf.home
            )
            runningTask.result = finishedResult
            finish(&runningTask, as: .done, failureReason: nil)
        } catch {
            runningTask = task(withIdentifier: taskIdentifier) ?? runningTask
            runningTask.progressNotes = workerSession.progressNotes
            if taskIdentifiersBeingCancelled.remove(taskIdentifier) != nil {
                finish(&runningTask, as: .cancelled, failureReason: nil)
            } else {
                finish(&runningTask, as: .failed, failureReason: error.localizedDescription)
            }
        }
    }

    /// What a worker is told when the user let it use the screen.
    static let screenGrantedNote = "the user said yes: you may use their screen now. here it is. work on it step by step with the screen tools, then call finish_task. you only have it for this run."

    private func parkForAnswer(_ parkedTask: inout ElfTask, question: String, isAskingForTheScreen: Bool) {
        try? parkedTask.move(to: .needsInput)
        parkedTask.pendingQuestion = question
        parkedTask.isWaitingForTheScreen = isAskingForTheScreen
        store(parkedTask)
        onTaskNeedsInput?(parkedTask)
    }

    /// The files a finished task lists, kept only when they're real files in
    /// the elf's own folder (written this run, or already there).
    static func filePathsTheElfReallyHas(_ claimedFilePaths: [String], writtenFilePaths: Set<String>, home: ElfHome) -> [String] {
        var keptFilePaths: [String] = []
        for claimedFilePath in claimedFilePaths {
            guard let homeRelativePath = try? home.homeRelativePathForElfTool(claimedFilePath, access: .read) else { continue }
            let isRealFile = writtenFilePaths.contains(homeRelativePath)
                || ((try? home.resolvedURLInsideHome(homeRelativePath)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            if isRealFile, !keptFilePaths.contains(homeRelativePath) {
                keptFilePaths.append(homeRelativePath)
            }
        }
        return keptFilePaths
    }

    /// What the worker is told when its run starts (or resumes).
    static func workerUserText(for elfTask: ElfTask) -> String {
        // The task itself is in the system prompt (the worker's identity).
        var userTextParts = ["work on your task now."]
        let trimmedContext = elfTask.contextFromMain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            userTextParts.append("what the main elf passed along: " + trimmedContext)
        }
        if !elfTask.progressNotes.isEmpty {
            userTextParts.append("your notes so far (you're picking this up again):\n" + elfTask.progressNotes.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !elfTask.answers.isEmpty {
            userTextParts.append("the user's answers to your questions:\n" + elfTask.answers.map { "- " + $0 }.joined(separator: "\n"))
        }
        return userTextParts.joined(separator: "\n\n")
    }

    private func finish(_ finishedTask: inout ElfTask, as finalStatus: ElfTaskStatus, failureReason: String?) {
        // A deleted elf's task is just dropped.
        guard !forgottenTaskIdentifiers.contains(finishedTask.id) else { return }
        // A queued task that can't start (its elf or model is gone) runs
        // for no time; anything else must be allowed to end this way.
        if finishedTask.status == .queued {
            try? finishedTask.move(to: .running)
        }
        guard (try? finishedTask.move(to: finalStatus)) != nil else { return }
        finishedTask.failureReason = failureReason
        store(finishedTask)
        onTaskFinished?(finishedTask)
    }

    // MARK: Storage

    /// Saves the task in its elf's folder and updates the published list.
    private func store(_ storedTask: ElfTask) {
        guard !forgottenTaskIdentifiers.contains(storedTask.id) else { return }
        if let index = tasks.firstIndex(where: { $0.id == storedTask.id }) {
            tasks[index] = storedTask
        } else {
            tasks.append(storedTask)
        }
        guard let taskElf = elfManager.elf(withIdentifier: storedTask.elfIdentifier) else { return }
        try? ElfTaskStore(home: taskElf.home).save(storedTask)
    }
}

// MARK: - Worker tools

/// What a worker's own tools record during a run.
@MainActor
final class ElfWorkerSession {
    var progressNotes: [String]
    var pendingQuestion: String?
    /// Why it asked to use the screen (request_screen).
    var pendingScreenRequestReason: String?
    var result: ElfTaskResult?
    var onProgressNoted: (([String]) -> Void)?

    init(progressNotes: [String] = []) {
        self.progressNotes = progressNotes
    }
}

enum ElfWorkerTools {
    static func tools(session: ElfWorkerSession, mayRequestScreen: Bool = true) -> [ElfTool] {
        var workerTools: [ElfTool] = [ReportProgressTool(session: session), AskUserTool(session: session), FinishTaskTool(session: session)]
        if mayRequestScreen {
            workerTools.append(RequestScreenTool(session: session))
        }
        return workerTools
    }
}

private protocol WorkerOnlyTool: ElfTool {}
extension WorkerOnlyTool {
    func isAvailable(for role: ElfPromptRole, configuration: ElfConfiguration) -> Bool {
        if case .backgroundWorker = role { return true }
        return false
    }
}

private struct ReportProgressTool: WorkerOnlyTool {
    let session: ElfWorkerSession
    let group = ElfToolGroup.worker
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "report_progress",
        description: "Note how the task is going, in one short line. The user sees it in the task's notes.",
        inputSchema: ["type": "object", "properties": ["note": ["type": "string"]], "required": ["note"]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        guard let note = ElfToolArguments(argumentsJSON: argumentsJSON).string("note")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else { return .failure("give a short note.") }
        session.progressNotes.append(note)
        session.onProgressNoted?(session.progressNotes)
        return ElfToolOutcome(resultText: "noted.")
    }
}

private struct AskUserTool: WorkerOnlyTool {
    let session: ElfWorkerSession
    let group = ElfToolGroup.worker
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "ask_user",
        description: "Ask the user one clear question you can't answer yourself. The task waits for the answer, so stop after asking.",
        inputSchema: ["type": "object", "properties": ["question": ["type": "string"]], "required": ["question"]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        guard let question = ElfToolArguments(argumentsJSON: argumentsJSON).string("question")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return .failure("give the question.") }
        session.pendingQuestion = question
        return ElfToolOutcome(resultText: "the user will be asked. stop now; you'll pick this up with their answer.", endsTheRun: true)
    }
}

/// Asks the user to let the elf use their screen for a while (click, type,
/// scroll in their apps). The task waits for the answer; a yes gives the
/// next run the screen, step by step, with the user watching.
private struct RequestScreenTool: WorkerOnlyTool {
    let session: ElfWorkerSession
    let group = ElfToolGroup.worker
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "request_screen",
        description: "Ask to use the user's screen (click, type and scroll in their apps) for part of the task that can only be done there. Say what for, in a few words (\"export the sheet from Numbers\"). The task waits for the user's answer, so stop after asking.",
        inputSchema: ["type": "object", "properties": ["reason": ["type": "string"]], "required": ["reason"]]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        guard let reason = ElfToolArguments(argumentsJSON: argumentsJSON).string("reason")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return .failure("say what you need the screen for.") }
        session.pendingScreenRequestReason = reason
        return ElfToolOutcome(resultText: "the user will be asked. stop now; you'll pick this up with their answer.", endsTheRun: true)
    }
}

private struct FinishTaskTool: WorkerOnlyTool {
    static let maximumSummaryLength = 500
    let session: ElfWorkerSession
    let group = ElfToolGroup.worker
    let resultFeedsBackToModel = true
    let definition = LanguageModelToolDefinition(
        name: "finish_task",
        description: "Finish the task: a summary of two or three sentences, to be spoken to the user, and the files you wrote for them.",
        inputSchema: [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "files": ["type": "array", "items": ["type": "string"], "description": "paths under files/ you wrote, if any"],
            ],
            "required": ["summary"],
        ]
    )

    func run(argumentsJSON: String, context: ElfToolContext) async throws -> ElfToolOutcome {
        let argumentsData = Data(argumentsJSON.utf8)
        let parsedArguments = (try? JSONSerialization.jsonObject(with: argumentsData)) as? [String: Any] ?? [:]
        guard let summary = (parsedArguments["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return .failure("give a short summary.")
        }
        let filePaths = (parsedArguments["files"] as? [String] ?? []).filter { !$0.isEmpty }
        // It's spoken: a few sentences at most.
        let spokenSummary = summary.count > Self.maximumSummaryLength
            ? String(summary.prefix(Self.maximumSummaryLength)).trimmingCharacters(in: .whitespaces) + "…"
            : summary
        session.result = ElfTaskResult(summary: spokenSummary, filePaths: filePaths)
        return ElfToolOutcome(resultText: "finished.", endsTheRun: true)
    }
}
