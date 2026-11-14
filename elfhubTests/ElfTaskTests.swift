//
//  ElfTaskTests.swift
//  elfhubTests
//
//  Background tasks: the statuses a task may move between, where tasks are
//  kept (in the elf's app-owned folder, never exported), and a task that
//  was running when elfhub quit being queued again with its notes.
//

import Foundation
import Testing
@testable import elfhub

struct ElfTaskTests {

    private func makeTemporaryHome() throws -> (home: ElfHome, cleanUp: () -> Void) {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()
        return (home, { try? FileManager.default.removeItem(at: homeDirectory) })
    }

    private func makeTask(status: ElfTaskStatus = .queued, elfIdentifier: String = "juniper") -> ElfTask {
        var elfTask = ElfTask(elfIdentifier: elfIdentifier, instruction: "find flights to Lisbon", contextFromMain: "in May")
        elfTask.status = status
        return elfTask
    }

    @Test func onlyAllowedStatusMovesHappen() {
        #expect(ElfTaskStatusMachine.canMove(from: .queued, to: .running))
        #expect(ElfTaskStatusMachine.canMove(from: .running, to: .needsInput))
        #expect(ElfTaskStatusMachine.canMove(from: .running, to: .done))
        #expect(ElfTaskStatusMachine.canMove(from: .running, to: .failed))
        #expect(ElfTaskStatusMachine.canMove(from: .running, to: .cancelled))
        #expect(ElfTaskStatusMachine.canMove(from: .needsInput, to: .queued))
        #expect(ElfTaskStatusMachine.canMove(from: .needsInput, to: .cancelled))
        #expect(ElfTaskStatusMachine.canMove(from: .queued, to: .cancelled))
        #expect(!ElfTaskStatusMachine.canMove(from: .done, to: .running))
        #expect(!ElfTaskStatusMachine.canMove(from: .queued, to: .done))
        #expect(!ElfTaskStatusMachine.canMove(from: .cancelled, to: .queued))
        #expect(!ElfTaskStatusMachine.canMove(from: .failed, to: .running))
    }

    @Test func movingATaskRefusesMovesThatAreNotAllowed() throws {
        var elfTask = makeTask()
        try elfTask.move(to: .running)
        #expect(elfTask.status == .running)
        #expect(throws: ElfTaskError.self) { try elfTask.move(to: .queued) }
        #expect(elfTask.status == .running)
    }

    @Test func tasksAreSavedInTheElfsAppFolderAndRoundTrip() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let elfTaskStore = ElfTaskStore(home: home)
        var elfTask = makeTask()
        elfTask.progressNotes = ["found three airlines"]
        try elfTaskStore.save(elfTask)
        #expect(elfTaskStore.tasks() == [elfTask])
        #expect(FileManager.default.fileExists(atPath: home.appDataDirectory.appendingPathComponent("tasks/\(elfTask.id.uuidString).json").path))
        #expect(throws: ElfHomeError.self) { try home.resolvedURLForElfTool(".elfhub/tasks", access: .read) }
    }

    @Test func aTaskRunningAtQuitIsQueuedAgainWithItsNotes() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        let elfTaskStore = ElfTaskStore(home: home)
        var runningTask = makeTask(status: .running)
        runningTask.progressNotes = ["checked TAP"]
        try elfTaskStore.save(runningTask)
        try elfTaskStore.save(makeTask(status: .done))
        let requeuedTasks = try elfTaskStore.requeueInterruptedTasks()
        #expect(requeuedTasks.map(\.id) == [runningTask.id])
        let storedRunningTask = elfTaskStore.tasks().first { $0.id == runningTask.id }
        #expect(storedRunningTask?.status == .queued)
        #expect(storedRunningTask?.progressNotes == ["checked TAP"])
        #expect(elfTaskStore.tasks().count == 2)
    }

    @Test func tasksAreNeverExported() throws {
        let (home, cleanUp) = try makeTemporaryHome()
        defer { cleanUp() }
        try ElfTaskStore(home: home).save(makeTask())
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).elf")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try ElfExporter.export(home: home, configuration: home.readConfiguration(), options: ElfExporter.Options(includesProfile: true, includesFiles: true), to: exportURL)
        let exportedText = String(decoding: try Data(contentsOf: exportURL), as: UTF8.self)
        #expect(!exportedText.contains("tasks/"))
        #expect(!exportedText.contains(".elfhub"))
    }

    @Test func aTaskFromAnOlderBuildStillLoads() throws {
        let olderTaskJSON = #"{"id":"6B1C5A3E-0000-4000-8000-000000000009","elfIdentifier":"juniper","instruction":"x","status":"queued"}"#
        let decodedTask = try JSONDecoder().decode(ElfTask.self, from: Data(olderTaskJSON.utf8))
        #expect(decodedTask.progressNotes.isEmpty)
        #expect(decodedTask.reportedToUser == false)
    }
}
