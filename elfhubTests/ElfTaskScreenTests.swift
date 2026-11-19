//
//  ElfTaskScreenTests.swift
//  elfhubTests
//
//  A background task that needs the user's screen asks for it
//  (request_screen) and waits; a yes lets its next run work on the screen
//  step by step (the same ComputerUseSession as the foreground), a no lets
//  it carry on without; the user stopping it on the screen parks it with a
//  question instead of failing it; and when the screen can't be used the
//  task is told why.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfTaskScreenTests {

    @MainActor
    private final class ScreenAccessRecorder {
        var requestCount = 0
        var finishCount = 0
        var screen = FakeComputerUseScreen()
        var unavailableReason: String?
    }

    private func makeScheduler(
        scriptedResponses: [LanguageModelResponse],
        recorder: ScreenAccessRecorder
    ) throws -> (scheduler: ElfTaskScheduler, provider: ScriptedLanguageModelProvider, cleanUp: () -> Void) {
        let elfsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elfs-\(UUID().uuidString)", isDirectory: true)
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Juniper"))
        let provider = ScriptedLanguageModelProvider(scriptedResponses: scriptedResponses)
        let scheduler = ElfTaskScheduler(
            elfManager: elfManager,
            languageModelProviderForWorker: { _ in provider },
            screenAccessForWorker: { _, _, _ in
                recorder.requestCount += 1
                if let unavailableReason = recorder.unavailableReason {
                    return .unavailable(reason: unavailableReason)
                }
                let firstCapture = FakeComputerUseScreen.capture(imageData: FakeComputerUseScreen.jpegData(withBoxAt: nil))
                return .granted(ElfWorkerScreenAccess(
                    session: ComputerUseSession(screen: recorder.screen, firstCapture: firstCapture, coordinateConvention: .imagePixels),
                    firstScreenshot: LanguageModelImage(data: firstCapture.imageData, label: "the user's screen"),
                    usesAnthropicComputerToolset: true,
                    extraToolDefinitions: [],
                    systemPromptAddition: "act step by step",
                    finish: { recorder.finishCount += 1 }
                ))
            }
        )
        return (scheduler, provider, { try? FileManager.default.removeItem(at: elfsDirectory) })
    }

    private func requestScreenCall() -> LanguageModelToolCall {
        ScriptedLanguageModelProvider.toolCall("request_screen", ["reason": "export the sheet from Numbers"])
    }

    private func clickCall() -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: "toolu_click", toolName: "left_click", argumentsJSON: #"{"coordinate":[100,200]}"#, toolsetName: "computer")
    }

    private func finishCall(_ summary: String) -> LanguageModelToolCall {
        ScriptedLanguageModelProvider.toolCall("finish_task", ["summary": summary])
    }

    @Test func askingForTheScreenParksTheTaskWithAQuestion() async throws {
        let recorder = ScreenAccessRecorder()
        let (scheduler, _, cleanUp) = try makeScheduler(scriptedResponses: [ScriptedLanguageModelProvider.toolCalls([requestScreenCall()])], recorder: recorder)
        defer { cleanUp() }
        var tasksNeedingInput: [ElfTask] = []
        scheduler.onTaskNeedsInput = { tasksNeedingInput.append($0) }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "export my budget")
        await scheduler.waitUntilIdle()
        let waitingTask = try #require(scheduler.task(withIdentifier: elfTask.id))
        #expect(waitingTask.status == .needsInput)
        #expect(waitingTask.isWaitingForTheScreen)
        #expect(waitingTask.pendingQuestion?.contains("export the sheet from Numbers") == true)
        #expect(tasksNeedingInput.map(\.id) == [elfTask.id])
        #expect(recorder.requestCount == 0)
    }

    @Test func aYesLetsTheNextRunWorkOnTheScreenStepByStep() async throws {
        let recorder = ScreenAccessRecorder()
        let (scheduler, provider, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([requestScreenCall()]),
            ScriptedLanguageModelProvider.toolCalls([clickCall()]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("Exported it to your Desktop.")]),
        ], recorder: recorder)
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "export my budget")
        await scheduler.waitUntilIdle()
        try scheduler.answer(taskIdentifier: elfTask.id, answer: "yes go ahead")
        await scheduler.waitUntilIdle()

        let finishedTask = try #require(scheduler.task(withIdentifier: elfTask.id))
        #expect(finishedTask.status == .done)
        #expect(!finishedTask.screenGrantedForNextRun)
        #expect(recorder.requestCount == 1)
        #expect(recorder.finishCount == 1)
        #expect(recorder.screen.performedActions.count == 1)
        let screenRunRequest = provider.receivedRequests[1]
        #expect(screenRunRequest.usesAnthropicComputerToolset)
        #expect(screenRunRequest.systemPrompt.contains("act step by step"))
        let hasScreenshot = screenRunRequest.messages.last?.content.contains { if case .image = $0 { return true }; return false } ?? false
        #expect(hasScreenshot)
        // It doesn't ask for the screen it already has.
        let screenRunToolNames = Set(screenRunRequest.tools.map(\.name))
        #expect(!screenRunToolNames.contains("request_screen"))
    }

    @Test func aNoLetsItCarryOnWithoutTheScreen() async throws {
        let recorder = ScreenAccessRecorder()
        let (scheduler, provider, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([requestScreenCall()]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("I couldn't export it without your screen.")]),
        ], recorder: recorder)
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "export my budget")
        await scheduler.waitUntilIdle()
        try scheduler.answer(taskIdentifier: elfTask.id, answer: "no, not now")
        await scheduler.waitUntilIdle()
        #expect(recorder.requestCount == 0)
        #expect(!provider.receivedRequests[1].usesAnthropicComputerToolset)
        #expect(scheduler.task(withIdentifier: elfTask.id)?.status == .done)
    }

    @Test func theUserStoppingItOnTheScreenParksTheTaskInsteadOfFailingIt() async throws {
        let recorder = ScreenAccessRecorder()
        recorder.screen.scriptedOutcomes = [.stoppedByUser]
        let (scheduler, _, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([requestScreenCall()]),
            ScriptedLanguageModelProvider.toolCalls([clickCall()]),
        ], recorder: recorder)
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "export my budget")
        await scheduler.waitUntilIdle()
        try scheduler.answer(taskIdentifier: elfTask.id, answer: "yes")
        await scheduler.waitUntilIdle()
        let parkedTask = try #require(scheduler.task(withIdentifier: elfTask.id))
        #expect(parkedTask.status == .needsInput)
        #expect(parkedTask.pendingQuestion == ElfTaskScheduler.stoppedOnTheScreenQuestion)
        #expect(!parkedTask.isWaitingForTheScreen)
        #expect(recorder.finishCount == 1)
    }

    @Test func whenTheScreenCantBeUsedTheTaskIsToldWhy() async throws {
        let recorder = ScreenAccessRecorder()
        recorder.unavailableReason = "acting on the screen is switched off"
        let (scheduler, provider, cleanUp) = try makeScheduler(scriptedResponses: [
            ScriptedLanguageModelProvider.toolCalls([requestScreenCall()]),
            ScriptedLanguageModelProvider.toolCalls([finishCall("Couldn't use the screen.")]),
        ], recorder: recorder)
        defer { cleanUp() }
        let elfTask = try scheduler.enqueue(elfIdentifier: "juniper", instruction: "export my budget")
        await scheduler.waitUntilIdle()
        try scheduler.answer(taskIdentifier: elfTask.id, answer: "yes")
        await scheduler.waitUntilIdle()
        let secondRunText = provider.receivedRequests[1].messages.last?.content.compactMap { if case let .text(text) = $0 { return text }; return nil }.joined() ?? ""
        #expect(secondRunText.contains("acting on the screen is switched off"))
        #expect(scheduler.task(withIdentifier: elfTask.id)?.status == .done)
    }
}
