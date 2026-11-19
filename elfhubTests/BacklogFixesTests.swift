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

    // MARK: - Elfs

    @Test func renamingAnElfToOneOfItsAliasesDropsThatAlias() throws {
        let elfsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elfs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elfsDirectory) }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
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

        // Beyond the newest 50 finished tasks of an elf, the oldest go too —
        // only once the user has been told about them.
        let manyRecentTasks = (0..<55).map { finishedTask(daysAgo: Double($0) / 10) }
        #expect(ElfTaskScheduler.finishedTasksToForget(among: manyRecentTasks, now: now).count == 5)
        let manyUnreportedTasks = (0..<55).map { finishedTask(daysAgo: Double($0) / 10, reported: false) }
        #expect(ElfTaskScheduler.finishedTasksToForget(among: manyUnreportedTasks, now: now).isEmpty)
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
        #expect(hiddenParts("Health card 1234-567-897") == ["1234-567-897"])
        // Still left alone: phone numbers here and in Australia, "sin" in
        // Spanish and in maths.
        #expect(hiddenParts("Call 416-555-0199 about order 123456789").isEmpty)
        #expect(hiddenParts("Call 0412 345 678 or 1800 123 456").isEmpty)
        #expect(hiddenParts("café sin 300 gramos de azúcar, sin 30 = 0.5").isEmpty)
    }
}

@MainActor
struct BacklogFixesSecondBatchTests {

    @Test func aSideElfOnAChatGPTPlanThatCantBeUsedGetsTheFallbackNotMainsModel() throws {
        let chatGPTPlanConfiguration = ProviderConfiguration.chatGPTPlan(model: "gpt-test")
        let mainConfiguration = ProviderConfiguration(kind: .anthropic, displayName: "Main", baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", supportsVision: true)
        let elfActiveConfiguration = LanguageModelTurnRouting.activeConfiguration(
            mainActiveConfiguration: mainConfiguration,
            elfPreferredConfiguration: chatGPTPlanConfiguration,
            isElfPreferredConfigurationReady: false,
            hasReadyFallbackForChatGPTPlan: true
        )
        // The plan stays the elf's model, so the plan's fallback rules apply.
        #expect(elfActiveConfiguration?.id == chatGPTPlanConfiguration.id)
        // With no fallback to go to, the main elf's model answers instead of failing.
        let withoutFallback = LanguageModelTurnRouting.activeConfiguration(
            mainActiveConfiguration: mainConfiguration,
            elfPreferredConfiguration: chatGPTPlanConfiguration,
            isElfPreferredConfigurationReady: false,
            hasReadyFallbackForChatGPTPlan: false
        )
        #expect(withoutFallback?.id == mainConfiguration.id)
    }

    @Test func aVoiceRemovedFromTheMacFallsBackToMainsVoice() {
        var localSettings = ElfLocalSettings()
        localSettings.voice = ElfVoiceSelection(speechOutputModeRawValue: SpeechOutputMode.system.rawValue, voiceIdentifier: "com.apple.voice.premium.en-US.Zoe")
        #expect(ElfSpeechChoice.choice(for: localSettings, isMainElf: false, isSystemVoiceInstalled: { _ in false }) == .sameAsMain)
        #expect(ElfSpeechChoice.choice(for: localSettings, isMainElf: false, isSystemVoiceInstalled: { _ in true })
            == .system(voiceIdentifier: "com.apple.voice.premium.en-US.Zoe"))
    }

    @Test func aFailedTaskSaysWhyInPlainWords() {
        #expect(ElfTaskScheduler.spokenFailureReason(for: LanguageModelProviderError.httpError(statusCode: 529, body: #"{"type":"error","error":{"type":"overloaded_error"}}"#))
            == "the model's service is busy right now")
        #expect(ElfTaskScheduler.spokenFailureReason(for: LanguageModelProviderError.httpError(statusCode: 401, body: "{}"))
            == "the model's service didn't accept the key")
        #expect(ElfTaskScheduler.spokenFailureReason(for: URLError(.notConnectedToInternet)) == "the internet connection dropped")
        #expect(ElfTaskScheduler.spokenFailureReason(for: ElfAgentLoopError.budgetExceeded) == ElfAgentLoopError.budgetExceeded.localizedDescription)
    }
}
