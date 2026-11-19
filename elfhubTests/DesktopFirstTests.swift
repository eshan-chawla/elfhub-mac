//
//  DesktopFirstTests.swift
//  elfhubTests
//
//  On-device chat storage, the provider catalog, the Ollama download
//  progress/listing parsers, the push-to-talk shortcut setting and the
//  guided tutorial's step selection.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct DesktopFirstTests {

    // MARK: - Chat storage

    private func makeTemporaryConversationDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("elfhub-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savedConversationsReloadFromDiskNewestFirst() throws {
        let storageDirectoryURL = makeTemporaryConversationDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }

        let firstStore = ChatConversationStore(storageDirectoryURL: storageDirectoryURL)
        guard firstStore.isSavingChatsEnabled else { return } // the user turned saving off on this Mac

        var olderConversation = ChatConversation(title: "older")
        olderConversation.messages = [StoredChatMessage(role: .user, text: "hello")]
        firstStore.save(olderConversation)

        var newerConversation = ChatConversation(title: "newer")
        newerConversation.messages = [StoredChatMessage(role: .user, text: "hi again")]
        firstStore.save(newerConversation)

        let reloadedStore = ChatConversationStore(storageDirectoryURL: storageDirectoryURL)
        #expect(reloadedStore.conversations.map(\.title) == ["newer", "older"])
        #expect(reloadedStore.conversations.first?.messages.first?.text == "hi again")

        reloadedStore.deleteConversation(withIdentifier: newerConversation.id)
        #expect(ChatConversationStore(storageDirectoryURL: storageDirectoryURL).conversations.map(\.title) == ["older"])

        reloadedStore.deleteAllConversations()
        #expect(ChatConversationStore(storageDirectoryURL: storageDirectoryURL).conversations.isEmpty)
    }

    @Test func savedConversationTimesKeepFractionsOfASecond() throws {
        let storageDirectoryURL = makeTemporaryConversationDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }

        let firstStore = ChatConversationStore(storageDirectoryURL: storageDirectoryURL)
        guard firstStore.isSavingChatsEnabled else { return } // the user turned saving off on this Mac

        var conversation = ChatConversation(title: "timed")
        conversation.messages = [StoredChatMessage(role: .user, text: "hello")]
        firstStore.save(conversation)
        let savedUpdatedAt = try #require(firstStore.conversations.first?.updatedAt)

        // Two chats saved within the same second must still reload in order.
        let reloadedUpdatedAt = try #require(ChatConversationStore(storageDirectoryURL: storageDirectoryURL).conversations.first?.updatedAt)
        #expect(abs(reloadedUpdatedAt.timeIntervalSince(savedUpdatedAt)) < 0.01)
    }

    @Test func emptyConversationsAreNotSaved() {
        let storageDirectoryURL = makeTemporaryConversationDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }

        let chatConversationStore = ChatConversationStore(storageDirectoryURL: storageDirectoryURL)
        chatConversationStore.save(ChatConversation())
        #expect(chatConversationStore.conversations.isEmpty)
    }

    @Test func historyTurnsSkipErrorsAndUnansweredMessages() {
        let conversation = ChatConversation(messages: [
            StoredChatMessage(role: .user, text: "first question"),
            StoredChatMessage(role: .assistant, text: "first answer"),
            StoredChatMessage(role: .user, text: "second question"),
            StoredChatMessage(role: .assistant, text: "⚠️ network down", isError: true),
            StoredChatMessage(role: .user, text: "third question"),
            StoredChatMessage(role: .assistant, text: "third answer"),
            StoredChatMessage(role: .user, text: "still waiting"),
        ])
        let historyTurns = conversation.historyTurns(maximumTurnCount: 10)
        #expect(historyTurns.map(\.userText) == ["first question", "third question"])
        #expect(historyTurns.map(\.assistantText) == ["first answer", "third answer"])
        #expect(conversation.historyTurns(maximumTurnCount: 1).map(\.userText) == ["third question"])
    }

    @Test func conversationTitleComesFromFirstMessage() {
        #expect(ChatConversation.title(forFirstUserMessage: "  what's on\nmy screen? ") == "what's on my screen?")
        let longTitle = ChatConversation.title(forFirstUserMessage: String(repeating: "a", count: 100))
        #expect(longTitle.count == 49)
        #expect(longTitle.hasSuffix("…"))
        #expect(ChatConversation.title(forFirstUserMessage: "   ") == ChatConversation.untitledConversationTitle)
    }

    // MARK: - Provider catalog

    @Test func catalogPresetsBuildUsableConfigurations() {
        let presetIdentifiers = LanguageModelProviderCatalog.allPresets.map(\.id)
        #expect(Set(presetIdentifiers).count == presetIdentifiers.count)

        for preset in LanguageModelProviderCatalog.allPresets {
            let configuration = preset.makeConfiguration()
            #expect(configuration.presetIdentifier == preset.id)
            #expect(URL(string: configuration.baseURL)?.host != nil)
            // Cloud presets need a key; on-this-Mac presets never do.
            #expect(configuration.requiresAPIKey == (preset.category == .cloudAPI))
            #expect(configuration.runsLocally == (preset.category == .onThisMac))
        }
        #expect(ProviderConfiguration.directAnthropic().model == "claude-opus-5-5")
    }

    @Test func geminiModelListKeepsChatModelsWithoutPrefix() {
        let geminiModelsResponse = """
        {"models":[
          {"name":"models/gemini-pro-vision","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/text-embedding","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-flash","supportedGenerationMethods":["generateContent"]}
        ]}
        """
        #expect(LocalModelServerDiscovery.parseGeminiModelIdentifiers(fromModelsResponse: Data(geminiModelsResponse.utf8))
                == ["gemini-flash", "gemini-pro-vision"])
    }

    // MARK: - Ollama

    @Test func pullProgressSumsLayersAndDetectsSuccess() {
        var pullProgressAccumulator = OllamaPullProgressAccumulator()
        pullProgressAccumulator.apply(pullResponseLine: #"{"status":"pulling manifest"}"#)
        #expect(pullProgressAccumulator.progress.statusText == "Preparing…")
        #expect(pullProgressAccumulator.progress.fractionCompleted == nil)

        pullProgressAccumulator.apply(pullResponseLine: #"{"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":500}"#)
        pullProgressAccumulator.apply(pullResponseLine: #"{"status":"pulling bbb","digest":"sha256:bbb","total":1000,"completed":0}"#)
        pullProgressAccumulator.apply(pullResponseLine: #"{"status":"pulling bbb","digest":"sha256:bbb","total":1000,"completed":500}"#)
        #expect(pullProgressAccumulator.progress.completedBytes == 1000)
        #expect(pullProgressAccumulator.progress.totalBytes == 2000)
        #expect(pullProgressAccumulator.progress.fractionCompleted == 0.5)
        #expect(pullProgressAccumulator.progress.statusText == "Downloading…")
        #expect(!pullProgressAccumulator.didSucceed)

        pullProgressAccumulator.apply(pullResponseLine: "not json")
        pullProgressAccumulator.apply(pullResponseLine: #"{"status":"success"}"#)
        #expect(pullProgressAccumulator.didSucceed)
    }

    @Test func pullErrorsAreReported() {
        var pullProgressAccumulator = OllamaPullProgressAccumulator()
        pullProgressAccumulator.apply(pullResponseLine: #"{"error":"pull model manifest: file does not exist"}"#)
        #expect(pullProgressAccumulator.errorMessage == "pull model manifest: file does not exist")
    }

    @Test func installedModelsAndCapabilitiesParse() {
        let tagsResponse = """
        {"models":[
          {"name":"qwen3-vl:8b","size":6100000000,"details":{"parameter_size":"8.8B"}},
          {"name":"gemma3:4b","size":3338801804,"details":{"parameter_size":"4.3B"}}
        ]}
        """
        let installedModels = OllamaWireFormat.parseInstalledModels(fromTagsResponse: Data(tagsResponse.utf8))
        #expect(installedModels.map(\.name) == ["gemma3:4b", "qwen3-vl:8b"])
        #expect(installedModels.first?.parameterSize == "4.3B")

        let showResponse = #"{"capabilities":["completion","vision","tools"]}"#
        #expect(OllamaWireFormat.parseCapabilities(fromShowResponse: Data(showResponse.utf8)) == ["completion", "vision", "tools"])
    }

    @Test func untaggedOllamaNamesMatchLatest() {
        #expect(OllamaWireFormat.modelNamesMatch("llava", "llava:latest"))
        #expect(OllamaWireFormat.modelNamesMatch("gemma3:4b", "gemma3:4b"))
        #expect(!OllamaWireFormat.modelNamesMatch("gemma3:4b", "gemma3:12b"))
    }

    @Test func recommendedModelsHaveUniqueTags() {
        let recommendedModelTags = OnDeviceModelCatalog.recommendedLanguageModels.map(\.id)
        #expect(Set(recommendedModelTags).count == recommendedModelTags.count)
        #expect(OnDeviceModelCatalog.recommendedLanguageModels.contains { $0.seesScreen })
        #expect(OnDeviceModelCatalog.recommendedLanguageModels.contains { !$0.seesScreen })
    }

    // MARK: - Push-to-talk shortcut

    @Test func shortcutChoiceIsPersistedAndRestored() {
        let originalShortcutOption = BuddyPushToTalkShortcut.currentShortcutOption
        defer { BuddyPushToTalkShortcut.setCurrentShortcutOption(originalShortcutOption) }

        BuddyPushToTalkShortcut.setCurrentShortcutOption(.shiftControl)
        #expect(BuddyPushToTalkShortcut.currentShortcutOption == .shiftControl)
        #expect(BuddyPushToTalkShortcut.pushToTalkDisplayText == "shift + control")
        #expect(UserDefaults.standard.string(forKey: "pushToTalkShortcutOption") == "shiftControl")
    }

    // MARK: - Guided tutorial

    @Test func tutorialLeavesOutStepsTheSetupCantDo() {
        let guidedTutorialController = GuidedTutorialController(companionEventBus: CompanionEventBus())

        guidedTutorialController.start(includesVoiceStep: false, includesPointingSteps: false)
        #expect(guidedTutorialController.steps == [.textChat, .screenActions])

        guidedTutorialController.start(includesVoiceStep: true, includesPointingSteps: true)
        #expect(guidedTutorialController.steps == GuidedTutorialStep.allCases)
        #expect(guidedTutorialController.currentStep == .pushToTalk)

        guidedTutorialController.noteVoiceTranscriptReceived()
        #expect(guidedTutorialController.isCurrentStepComplete)
        guidedTutorialController.goToNextStep()
        #expect(guidedTutorialController.currentStep == .pointing)

        guidedTutorialController.endTutorial()
        #expect(!guidedTutorialController.isActive)
        #expect(guidedTutorialController.currentStep == nil)
    }

    @Test func escapeOnlyCountsAfterSomethingWasPointedAt() {
        let companionEventBus = CompanionEventBus()
        let guidedTutorialController = GuidedTutorialController(companionEventBus: companionEventBus)
        guidedTutorialController.start(includesVoiceStep: false, includesPointingSteps: true)

        companionEventBus.emit(.allGuidanceDismissed)
        #expect(!guidedTutorialController.completedSteps.contains(.dismissWithEscape))
    }
}
