//
//  ElfTaskSchedulerTests.swift
//  elfhubTests
//
//  Background work: tasks start when there's room (one per elf, three in
//  all), run with the elf's own tools plus the worker's (progress, ask the
//  user, finish) — never the screen or task tools — finish with a summary,
//  wait for an answer when they ask, and stop as failed, notes kept, when
//  they run out of budget.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfTaskSchedulerTests {

    private func makeScheduler(
        scriptedResponses: [LanguageModelResponse],
        maximumOutputTokens: Int = ElfTaskScheduler.maximumOutputTokensPerTask
    ) throws -> (scheduler: ElfTaskScheduler, provider: ScriptedLanguageModelProvider, elfManager: ElfManager, cleanUp: () -> Void) {
        let elvesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elves-\(UUID().uuidString)", isDirectory: true)
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Juniper"))
        let provider = ScriptedLanguageModelProvider(scriptedResponses: scriptedResponses)
        let scheduler = ElfTaskScheduler(
            elfManager: elfManager,
            languageModelProviderForWorker: { _ in provider },
            maximumOutputTokensPerTask: maximumOutputTokens
        )
        return (scheduler, provider, elfManager, { try? FileManager.default.removeItem(at: elvesDirectory) })
    }

    private func finishCall(_ summary: String, files: [String] = []) -> LanguageModelToolCall {
        ScriptedLanguageModelProvider.toolCall("finish_task", ["summary": summary, "files": files])
    }

    @Test func atMostOnePerElfAndThreeOverall() {
        func task(_ elfIdentifier: String) -> ElfTask { ElfTask(elfIdentifier: elfIdentifier, instruction: "x") }
        let juniperFirst = task("juniper")
        let juniperSecond = task("juniper")
        let writerTask = task("writer")
        let mainTask = task("main")
        let atlasTask = task("atlas")
        let startable = ElfTaskScheduler.tasksToStart(
            queuedTasks: [juniperFirst, juniperSecond, writerTask, mainTask, atlasTask],
            runningTasks: [],
            maximumConcurrentTasks: 3
        )
        #expect(startable.map(\.id) == [juniperFirst.id, writerTask.id, mainTask.id])
        let startableWhileJuniperRuns = ElfTaskScheduler.tasksToStart(queuedTasks: [juniperSecond, writerTask], runningTasks: [juniperFirst], maximumConcurrentTasks: 3)
        #expect(startableWhileJuniperRuns.map(\.id) == [writerTask.id])
    }

    @Test func aTaskRunsToTheEndWithItsSummaryAndFiles() async throws {
        let (scheduler, _, elfManager, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([
                ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/flights.md", "content": "TAP direct on the 3rd"]),
                ScriptedLanguageModelProvider.toolCall("report_progress", ["note": "found TAP"]),
            ]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("TAP flies direct on the 3rd.", files: ["files/flights.md"])]),
        ])
        defer { cleanUp() }
        var finishedTasks: [ElfTask] = []
        scheduler.onTaskFinished = { finishedTasks.append($0) }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find flights to Lisbon")
        await scheduler.waitUntilIdle()
        let finishedTask = try #require(scheduler.tasks.first { $0.id == elfTask.id })
        #expect(finishedTask.status == .done)
        #expect(finishedTask.result?.summary == "TAP flies direct on the 3rd.")
        #expect(finishedTask.result?.filePaths == ["files/flights.md"])
        #expect(finishedTask.progressNotes == ["found TAP"])
        #expect(finishedTasks.map(\.id) == [elfTask.id])
        let juniperHome = try #require(elfManager.elf(withIdentifier: "juniper")).home
        #expect(ElfChangeLog(home: juniperHome).entries().first?.origin == .task(taskIdentifier: elfTask.id))
        #expect(ElfTaskStore(home: juniperHome).tasks().first?.status == .done)
    }

    @Test func aRunThatEndsWithoutFinishingUsesItsReplyAsTheSummary() async throws {
        let (scheduler, _, _, cleanUp) = try makeScheduler(scriptedResponses: [ScriptedLanguageModelProvider.reply("All done: three options.")])
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find options")
        await scheduler.waitUntilIdle()
        #expect(scheduler.tasks.first { $0.id == elfTask.id }?.result?.summary == "All done: three options.")
    }

    @Test func askUserParksTheTaskUntilAnswered() async throws {
        let (scheduler, provider, _, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("ask_user", ["question": "which month?"])]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("May works.")]),
        ])
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find flights")
        await scheduler.waitUntilIdle()
        let waitingTask = try #require(scheduler.tasks.first { $0.id == elfTask.id })
        #expect(waitingTask.status == .needsInput)
        #expect(waitingTask.pendingQuestion == "which month?")
        try scheduler.answer(taskIdentifier: elfTask.id, answer: "May")
        await scheduler.waitUntilIdle()
        #expect(scheduler.tasks.first { $0.id == elfTask.id }?.status == .done)
        let resumedUserText = provider.receivedRequests.last?.messages.last?.content.compactMap { contentBlock -> String? in
            if case let .text(text) = contentBlock { return text }
            return nil
        }.joined()
        #expect(resumedUserText?.contains("May") == true)
    }

    @Test func budgetsStopATaskAsFailedWithItsNotes() async throws {
        var expensiveResponse = ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("report_progress", ["note": "checked TAP"])])
        expensiveResponse.usage = LanguageModelUsage(outputTokens: 600)
        let (scheduler, _, _, cleanUp) = try makeScheduler(
            scriptedResponses: [expensiveResponse, expensiveResponse, expensiveResponse],
            maximumOutputTokens: 1_000
        )
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find flights")
        await scheduler.waitUntilIdle()
        let failedTask = try #require(scheduler.tasks.first { $0.id == elfTask.id })
        #expect(failedTask.status == .failed)
        #expect(failedTask.progressNotes.contains("checked TAP"))
        #expect(failedTask.failureReason != nil)
    }

    @Test func cancellingAWaitingTaskStopsIt() async throws {
        let (scheduler, _, _, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("ask_user", ["question": "which month?"])]),
        ])
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find flights")
        await scheduler.waitUntilIdle()
        scheduler.cancel(taskIdentifier: elfTask.id)
        #expect(scheduler.tasks.first { $0.id == elfTask.id }?.status == .cancelled)
    }

    @Test func workersNeverGetGuidanceOrTaskTools() {
        let workerToolNames = Set(ElfTaskScheduler.workerToolRegistry(session: ElfWorkerSession())
            .toolDefinitions(for: .backgroundWorker(taskInstruction: "x"), configuration: ElfConfiguration())
            .map(\.name))
        #expect(workerToolNames.isDisjoint(with: GuidanceToolDefinitions.toolNames))
        #expect(!workerToolNames.contains("assign_task"))
        #expect(workerToolNames.isSuperset(of: ["finish_task", "ask_user", "report_progress", "write_file", "read_file"]))
    }

    @Test func aNonToolElfRunsOnMainsModel() {
        var textOnlyConfiguration = ProviderConfiguration.localServer(.ollama)
        textOnlyConfiguration.supportsToolCalling = false
        let claudeConfiguration = ProviderConfiguration.directAnthropic()
        #expect(ElfTaskScheduler.workerConfiguration(elfPreferredConfiguration: textOnlyConfiguration, mainConfiguration: claudeConfiguration) == claudeConfiguration)
        #expect(ElfTaskScheduler.workerConfiguration(elfPreferredConfiguration: nil, mainConfiguration: claudeConfiguration) == claudeConfiguration)
        #expect(ElfTaskScheduler.workerConfiguration(elfPreferredConfiguration: nil, mainConfiguration: textOnlyConfiguration) == nil)
    }

    @Test func aTaskForAnElfThatIsGoneFails() async throws {
        let (scheduler, _, _, cleanUp) = try makeScheduler(scriptedResponses: [])
        defer { cleanUp() }
        #expect(throws: ElfManagerError.unknownElf("nobody")) {
            _ = try scheduler.enqueue(elfIdentifier: "nobody", instruction: "x")
        }
    }
}
