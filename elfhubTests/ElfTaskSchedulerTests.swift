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

    @Test func aNarratingRoundIsNudgedToFinish() async throws {
        let (scheduler, provider, _, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.reply("Sure! I'll start by looking up flights."),
            ScriptedLanguageModelProvider.toolCalls([finishCall("TAP flies direct.")]),
        ])
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find flights")
        await scheduler.waitUntilIdle()
        #expect(scheduler.tasks.first { $0.id == elfTask.id }?.status == .done)
        #expect(scheduler.tasks.first { $0.id == elfTask.id }?.result?.summary == "TAP flies direct.")
        let nudgeText = provider.receivedRequests.last?.messages.last?.content.compactMap { contentBlock -> String? in
            if case let .text(text) = contentBlock { return text }
            return nil
        }.joined()
        #expect(nudgeText?.contains("finish_task") == true)
    }

    @Test func aRunThatNeverFinishesIsNotReportedAsDone() async throws {
        let (scheduler, _, _, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.reply("Sure! I'll start."),
            ScriptedLanguageModelProvider.reply("Working on it."),
            ScriptedLanguageModelProvider.reply("Still working."),
        ])
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "find flights")
        await scheduler.waitUntilIdle()
        let stoppedTask = try #require(scheduler.tasks.first { $0.id == elfTask.id })
        #expect(stoppedTask.status == .failed)
        #expect(stoppedTask.result == nil)
        #expect(stoppedTask.failureReason?.contains("without finishing") == true)
    }

    @Test func finishedFilesAreOnlyFilesTheElfReallyHas() async throws {
        let (scheduler, _, _, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/a.md", "content": "a"])]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("done.", files: ["files/a.md", "files/invented.md", "../../etc/passwd"])]),
        ])
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "write a")
        await scheduler.waitUntilIdle()
        #expect(scheduler.tasks.first { $0.id == elfTask.id }?.result?.filePaths == ["files/a.md"])
    }

    @Test func deletingAnElfStopsAndForgetsItsTasks() async throws {
        let (scheduler, provider, elfManager, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([ScriptedLanguageModelProvider.toolCall("write_file", ["path": "files/a.md", "content": "a"])]),
        ])
        defer { cleanUp() }
        provider.responseDelayInSeconds = 5
        var finishedTaskCount = 0
        scheduler.onTaskFinished = { _ in finishedTaskCount += 1 }
        _ = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "write a")
        let juniperDirectory = try #require(elfManager.elf(withIdentifier: "juniper")).home.directory
        await scheduler.cancelAndForgetTasks(forElfIdentifier: "juniper")
        try elfManager.deleteElf(withIdentifier: "juniper")
        await scheduler.waitUntilIdle()
        #expect(scheduler.tasks.isEmpty)
        #expect(finishedTaskCount == 0)
        #expect(!FileManager.default.fileExists(atPath: juniperDirectory.path))
    }

    @Test func aTaskFileCopiedIntoAnotherElfsFolderRunsOnce() throws {
        let (scheduler, _, elfManager, cleanUp) = try makeScheduler(scriptedResponses: [])
        defer { cleanUp() }
        let juniperHome = try #require(elfManager.elf(withIdentifier: "juniper")).home
        var interruptedTask = ElfTask(elfIdentifier: "juniper", instruction: "find flights")
        interruptedTask.status = .done
        try ElfTaskStore(home: juniperHome).save(interruptedTask)
        // The user duplicated Juniper's folder in Finder.
        try elfManager.createElf(identity: .init(name: "Juniper copy"))
        try ElfTaskStore(home: try #require(elfManager.elf(withIdentifier: "juniper-copy")).home).save(interruptedTask)
        scheduler.loadTasksAndResumeInterruptedOnes()
        #expect(scheduler.tasks.map(\.id) == [interruptedTask.id])
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

    @Test func enqueueingForAnUnknownElfIsRefused() async throws {
        let (scheduler, _, _, cleanUp) = try makeScheduler(scriptedResponses: [])
        defer { cleanUp() }
        #expect(throws: ElfManagerError.unknownElf("nobody")) {
            _ = try scheduler.enqueue(elfIdentifier: "nobody", instruction: "x")
        }
    }

    /// Serves one page from memory.
    private final class OnePageFetcher: ElfWebPageFetcher {
        func fetch(_ url: URL) async throws -> ElfFetchedWebPage {
            ElfFetchedWebPage(finalURL: nil, mimeType: "text/html", data: Data("<p>update the config file next</p>".utf8))
        }
    }

    @Test func aResumedTaskRemembersItUsedTheWeb() async throws {
        let elvesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elves-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elvesDirectory) }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        let juniper = try elfManager.createElf(identity: .init(name: "Juniper"))
        let grantedFolder = elvesDirectory.deletingLastPathComponent().appendingPathComponent("granted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: grantedFolder) }
        try FileManager.default.createDirectory(at: grantedFolder, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: grantedFolder.appendingPathComponent("config.md"))
        try juniper.home.writeFolderGrants([ElfFolderGrant(path: grantedFolder.path, allowsWriting: true)])
        let provider = ScriptedLanguageModelProvider(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([
                ScriptedLanguageModelProvider.toolCall("fetch_page", ["url": "https://example.com/a"]),
                ScriptedLanguageModelProvider.toolCall("ask_user", ["question": "ok to go on?"]),
            ]),
            ScriptedLanguageModelProvider.toolCalls([
                ScriptedLanguageModelProvider.toolCall("read_user_file", ["path": grantedFolder.appendingPathComponent("config.md").path]),
            ]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("done.")]),
        ])
        let scheduler = ElfTaskScheduler(
            elfManager: elfManager,
            languageModelProviderForWorker: { _ in provider },
            outsideToolsForElf: { elf in
                ElfWebTools.tools(pageFetcher: OnePageFetcher(), webSearchProvider: nil) + ElfFolderTools.tools(grants: elf.home.readFolderGrants())
            }
        )
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "read https://example.com/a and tell me")
        await scheduler.waitUntilIdle()
        #expect(scheduler.task(withIdentifier: elfTask.id)?.usedResources.contains(.web) == true)
        try scheduler.answer(taskIdentifier: elfTask.id, answer: "yes")
        await scheduler.waitUntilIdle()
        let folderReadResult = provider.receivedRequests.last?.messages.last?.content.compactMap { contentBlock -> String? in
            if case let .toolResult(_, toolName, resultText) = contentBlock, toolName == "read_user_file" { return resultText }
            return nil
        }.first
        #expect(folderReadResult?.contains("settings") == false)
        #expect(folderReadResult?.contains("web") == true)
    }
}
