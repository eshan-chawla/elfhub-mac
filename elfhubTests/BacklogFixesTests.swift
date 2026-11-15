//
//  BacklogFixesTests.swift
//  elfhubTests
//
//  Small fixes from earlier reviews:
//   - renaming an elf to one of its aliases drops that alias;
//   - only a real emoji counts as an elf's emoji;
//   - a worker's task isn't repeated and isn't always "from the main elf";
//   - old finished tasks are forgotten;
//   - option-click and option-drag ask first;
//   - more personal-number formats are hidden;
//   - a task stopped on a private site asks how to go on;
//   - using the screen marks what the task writes afterwards.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct BacklogFixesTests {

    // MARK: - Elves

    @Test func renamingAnElfToOneOfItsAliasesDropsThatAlias() throws {
        let elvesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elves-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elvesDirectory) }
        let elfManager = ElfManager(elvesDirectory: elvesDirectory, deletedFolderDisposal: .removePermanently)
        try elfManager.createElf(identity: .init(name: "Juniper", aliases: ["June", "Junie"]))
        try elfManager.renameElf(withIdentifier: "juniper", to: "June")
        let renamedElf = try #require(elfManager.elf(withIdentifier: "juniper"))
        #expect(renamedElf.configuration.identity.name == "June")
        #expect(renamedElf.configuration.identity.aliases == ["Junie"])
    }

    @Test func onlyARealEmojiCountsAsAnElfsEmoji() {
        #expect(ElfNameRules.normalizedEmoji("A\u{FE0F}") == "")
        #expect(ElfNameRules.normalizedEmoji("☺\u{FE0F}") == "☺\u{FE0F}")
        #expect(ElfNameRules.normalizedEmoji("🎄 tree") == "🎄")
    }

    // MARK: - Background tasks

    @Test func aWorkersTaskIsntRepeatedOrAlwaysFromTheMainElf() {
        let elfTask = ElfTask(elfIdentifier: "juniper", instruction: "find flights to Lisbon")
        #expect(!ElfTaskScheduler.workerUserText(for: elfTask).contains("find flights to Lisbon"))
        var elfPromptContext = ElfPromptContext.starter
        elfPromptContext.elfName = "Juniper"
        let workerPrompt = ElfPromptAssembler.elfSections(
            role: .backgroundWorker(taskInstruction: "find flights to Lisbon"),
            context: elfPromptContext,
            ownNotePaths: [],
            roster: []
        ).joined(separator: "\n")
        #expect(!workerPrompt.contains("main elf gave you"))
        #expect(workerPrompt.contains("find flights to Lisbon"))
    }

    @Test func oldFinishedTasksAreForgotten() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        func finishedTask(daysAgo: Double, reported: Bool = true, status: ElfTaskStatus = .done) -> ElfTask {
            var elfTask = ElfTask(elfIdentifier: "juniper", instruction: "x", createdAt: now.addingTimeInterval(-daysAgo * 86_400))
            elfTask.status = status
            elfTask.reportedToUser = reported
            return elfTask
        }
        let recentTask = finishedTask(daysAgo: 2)
        let oldTask = finishedTask(daysAgo: 40)
        let oldUnreportedTask = finishedTask(daysAgo: 40, reported: false)
        let oldWaitingTask = finishedTask(daysAgo: 40, status: .needsInput)
        let forgotten = ElfTaskScheduler.finishedTasksToForget(among: [recentTask, oldTask, oldUnreportedTask, oldWaitingTask], now: now)
        #expect(forgotten.map(\.id) == [oldTask.id])

        // Beyond the newest 50 finished tasks of an elf, the oldest go too.
        let manyRecentTasks = (0..<55).map { finishedTask(daysAgo: Double($0) / 10) }
        #expect(ElfTaskScheduler.finishedTasksToForget(among: manyRecentTasks, now: now).count == 5)
    }

    // MARK: - Consent

    @Test func optionClickAndOptionDragAskFirst() {
        func decision(for action: CompanionScreenAction) -> ScreenActionConsentDecision {
            ConsentPolicy.evaluate(ScreenActionConsentContext(
                action: action,
                targetElementFacts: nil,
                frontmostApplicationBundleIdentifier: "com.apple.finder",
                isTargetApplicationPrivacyBlocked: false,
                userUtterance: "move the report"
            ))
        }
        let click = CompanionScreenAction.click(screenshotPixel: .zero, label: nil, screenNumber: nil)
        let drag = CompanionScreenAction.drag(fromScreenshotPixel: .zero, toScreenshotPixel: CGPoint(x: 9, y: 9), screenNumber: nil)
        for optionAction in [CompanionScreenAction.withModifierKeys(["opt"], click), .withModifierKeys(["opt", "cmd"], drag)] {
            guard case .requiresExplicitConfirmation = decision(for: optionAction) else {
                Issue.record("\(optionAction) should ask first")
                continue
            }
        }
        #expect(decision(for: .withModifierKeys(["cmd"], click)) == .proceedWithPreview)
    }

    // MARK: - Personal numbers

    @Test func morePersonalNumberFormatsAreHidden() {
        func hiddenParts(_ text: String) -> [String] {
            SensitiveIdentifierDetector.sensitiveRanges(in: text).map { String(text[$0]) }
        }
        #expect(hiddenParts("SSN 078 05 1120") == ["078 05 1120"])
        #expect(hiddenParts("Social insurance number: 046454286") == ["046454286"])
        #expect(hiddenParts("patient id a12-4471") == ["a12-4471"])
        #expect(hiddenParts("DOB: Jan 5, 1980") == ["Jan 5, 1980"])
        #expect(hiddenParts("Health card 1234-567-890") == ["1234-567-890"])
        // Still left alone.
        #expect(hiddenParts("Call 416-555-0199 about order 123456789").isEmpty)
    }
}
