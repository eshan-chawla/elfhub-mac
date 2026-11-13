//
//  LanguageModelFallbackTests.swift
//  elfhubTests
//
//  Which model answers the next turn when the ChatGPT plan is the active
//  model: the plan while it works, the user's fallback for an hour after
//  the plan hit its limit (then the plan is tried again), the fallback while
//  the plan can't be used at all, and never a fallback that isn't ready.
//  Also the ChatGPT plan configuration itself.
//

import Combine
import Foundation
import Testing
@testable import elfhub

struct LanguageModelFallbackTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)
    private let chatGPTPlanConfiguration = ProviderConfiguration.chatGPTPlan(model: "gpt-test")
    private let claudeConfiguration = ProviderConfiguration.directAnthropic()

    private func route(
        active: ProviderConfiguration?,
        fallback: ProviderConfiguration?,
        isFallbackReady: Bool = true,
        canUseChatGPTPlan: Bool = true,
        unavailableSince: Date? = nil,
        now: Date? = nil
    ) -> ProviderConfiguration? {
        LanguageModelTurnRouting.configurationForNextTurn(
            activeConfiguration: active,
            fallbackConfiguration: fallback,
            isFallbackReady: isFallbackReady,
            canUseChatGPTPlan: canUseChatGPTPlan,
            chatGPTPlanUnavailableSince: unavailableSince,
            now: now ?? referenceDate
        )
    }

    @Test func nonPlanModelsAlwaysAnswerThemselves() {
        #expect(route(active: claudeConfiguration, fallback: chatGPTPlanConfiguration, unavailableSince: referenceDate) == claudeConfiguration)
        #expect(route(active: nil, fallback: claudeConfiguration) == nil)
    }

    @Test func workingPlanAnswers() {
        #expect(route(active: chatGPTPlanConfiguration, fallback: claudeConfiguration) == chatGPTPlanConfiguration)
    }

    @Test func fallbackAnswersForAnHourAfterTheLimitThenThePlanIsTriedAgain() {
        let limitHitDate = referenceDate
        #expect(route(active: chatGPTPlanConfiguration, fallback: claudeConfiguration, unavailableSince: limitHitDate,
                      now: limitHitDate.addingTimeInterval(60)) == claudeConfiguration)
        #expect(route(active: chatGPTPlanConfiguration, fallback: claudeConfiguration, unavailableSince: limitHitDate,
                      now: limitHitDate.addingTimeInterval(3599)) == claudeConfiguration)
        #expect(route(active: chatGPTPlanConfiguration, fallback: claudeConfiguration, unavailableSince: limitHitDate,
                      now: limitHitDate.addingTimeInterval(3600)) == chatGPTPlanConfiguration)
    }

    @Test func fallbackAnswersWhileThePlanCannotBeUsed() {
        #expect(route(active: chatGPTPlanConfiguration, fallback: claudeConfiguration, canUseChatGPTPlan: false) == claudeConfiguration)
    }

    @Test func aFallbackThatIsNotReadyOrMissingIsNeverUsed() {
        #expect(route(active: chatGPTPlanConfiguration, fallback: claudeConfiguration, isFallbackReady: false,
                      unavailableSince: referenceDate) == chatGPTPlanConfiguration)
        #expect(route(active: chatGPTPlanConfiguration, fallback: nil, unavailableSince: referenceDate) == chatGPTPlanConfiguration)
        #expect(route(active: chatGPTPlanConfiguration, fallback: ProviderConfiguration.chatGPTPlan(model: "other"),
                      unavailableSince: referenceDate)?.model == "gpt-test")
    }

    // MARK: - The ChatGPT plan configuration

    @Test func chatGPTPlanConfigurationUsesTheResponsesRouteWithoutAKey() {
        #expect(chatGPTPlanConfiguration.kind == .chatGPTPlan)
        #expect(!chatGPTPlanConfiguration.requiresAPIKey)
        #expect(!chatGPTPlanConfiguration.runsLocally)
        #expect(chatGPTPlanConfiguration.supportsToolCalling)
        #expect(chatGPTPlanConfiguration.supportsVision)
        #expect(chatGPTPlanConfiguration.coordinateConvention == .imagePixels)
        #expect(chatGPTPlanConfiguration.baseURL == "https://api.openai.com/v1")
    }

    @Test func chatGPTPlanConfigurationRoundTrips() throws {
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(chatGPTPlanConfiguration))
        #expect(decoded == chatGPTPlanConfiguration)
    }

    @Test @MainActor func chatGPTPlanBuildsTheResponsesProvider() throws {
        let provider = try ProviderConfigurationStore.makeProvider(for: chatGPTPlanConfiguration, apiKey: nil)
        #expect(provider is OpenAIResponsesLanguageModelProvider)
        #expect(provider.capabilities.supportsToolCalling)
    }
}

struct LanguageModelFallbackSwitchTests {

    private let chatGPTPlanConfiguration = ProviderConfiguration.chatGPTPlan(model: "gpt-test")
    private let claudeConfiguration = ProviderConfiguration.directAnthropic()

    @Test func planLimitSwitchesToAReadyFallback() {
        let fallback = CompanionTurnPipeline.fallbackConfiguration(
            afterFailure: ChatGPTPlanUsageError.usageLimitReached,
            of: chatGPTPlanConfiguration,
            fallbackConfiguration: claudeConfiguration,
            isFallbackReady: true
        )
        #expect(fallback == claudeConfiguration)
    }

    @Test func otherFailuresNeverSwitch() {
        for failure in [
            ChatGPTPlanUsageError.unsupportedCapability(parameter: "x") as Error,
            LanguageModelProviderError.streamFailed("overloaded"),
            CancellationError(),
        ] {
            #expect(CompanionTurnPipeline.fallbackConfiguration(
                afterFailure: failure, of: chatGPTPlanConfiguration,
                fallbackConfiguration: claudeConfiguration, isFallbackReady: true
            ) == nil)
        }
    }

    @Test func noSwitchWithoutAReadyFallbackOrFromANonPlanModel() {
        #expect(CompanionTurnPipeline.fallbackConfiguration(
            afterFailure: ChatGPTPlanUsageError.usageLimitReached, of: chatGPTPlanConfiguration,
            fallbackConfiguration: claudeConfiguration, isFallbackReady: false
        ) == nil)
        #expect(CompanionTurnPipeline.fallbackConfiguration(
            afterFailure: ChatGPTPlanUsageError.usageLimitReached, of: chatGPTPlanConfiguration,
            fallbackConfiguration: nil, isFallbackReady: true
        ) == nil)
        #expect(CompanionTurnPipeline.fallbackConfiguration(
            afterFailure: ChatGPTPlanUsageError.usageLimitReached, of: claudeConfiguration,
            fallbackConfiguration: chatGPTPlanConfiguration, isFallbackReady: true
        ) == nil)
    }

    @Test func onlyTheLimitAndEligibilityPauseThePlanForAnHour() {
        #expect(CompanionTurnPipeline.chatGPTPlanPauseReason(afterFailure: ChatGPTPlanUsageError.usageLimitReached) == .usageLimitReached)
        #expect(CompanionTurnPipeline.chatGPTPlanPauseReason(afterFailure: ChatGPTPlanUsageError.notEligible) == .notEligible)
        for passingFailure in [ChatGPTPlanUsageError.usageTemporarilyUnavailable, .credentialRejected, .planUsageNotEnabled] {
            #expect(CompanionTurnPipeline.chatGPTPlanPauseReason(afterFailure: passingFailure) == nil)
        }
        #expect(CompanionTurnPipeline.chatGPTPlanPauseReason(afterFailure: CancellationError()) == nil)
    }

    @Test func spokenErrorForTheUsageLimitPointsToChatGPTSettings() {
        let utterance = CompanionManager.spokenErrorUtterance(for: ChatGPTPlanUsageError.usageLimitReached)
        #expect(utterance.localizedCaseInsensitiveContains("usage limit"))
        #expect(utterance.localizedCaseInsensitiveContains("ChatGPT"))
        #expect(CompanionManager.spokenErrorUtterance(for: LanguageModelProviderError.streamFailed("x")).contains("Check your connection"))
    }

    @Test @MainActor func aNewSignInEndsThePauseAndKeepsTheReasonUntilThen() {
        let providerConfigurationStore = ProviderConfigurationStore()
        providerConfigurationStore.recordChatGPTPlanUnavailable(reason: .notEligible)
        #expect(providerConfigurationStore.chatGPTPlanUnavailableReason == .notEligible)
        #expect(providerConfigurationStore.chatGPTPlanUnavailableSince != nil)
        ChatGPTPlanAccount.shared.signInCompletedPublisher.send()
        #expect(providerConfigurationStore.chatGPTPlanUnavailableSince == nil)
        #expect(providerConfigurationStore.chatGPTPlanUnavailableReason == nil)
    }

    @Test func noticesNameTheModelAndTheReason() {
        let limitNotice = LanguageModelSwitchNotice.switchedToFallback(fallbackModelName: "Claude", reason: .usageLimitReached)
        #expect(limitNotice.message.contains("Claude"))
        #expect(limitNotice.message.localizedCaseInsensitiveContains("limit"))
        #expect(LanguageModelSwitchNotice.returnedToChatGPTPlan.message.contains("ChatGPT plan"))
    }

    @Test func onlyTheUsageLimitNoticeOffersManageUsage() {
        #expect(LanguageModelSwitchNotice.switchedToFallback(fallbackModelName: "Claude", reason: .usageLimitReached).offersManageUsage)
        #expect(!LanguageModelSwitchNotice.switchedToFallback(fallbackModelName: "Claude", reason: .usageTemporarilyUnavailable).offersManageUsage)
        #expect(!LanguageModelSwitchNotice.returnedToChatGPTPlan.offersManageUsage)
    }

    @Test func switchNoticeShowsOnlyInTheChatWhereTheTurnHappened() {
        let conversationIdentifier = UUID()
        let chatNotice = LanguageModelSwitchChatNotice(
            switchNotice: .returnedToChatGPTPlan,
            conversationIdentifier: conversationIdentifier
        )
        #expect(chatNotice.isShown(inConversationWithIdentifier: conversationIdentifier))
        #expect(!chatNotice.isShown(inConversationWithIdentifier: UUID()))
    }

    @Test func switchHintIsNotShownAgainOverRunningActions() {
        #expect(CompanionManager.shouldShowLanguageModelSwitchHintAfterTurn(isRunningScreenActions: false))
        #expect(!CompanionManager.shouldShowLanguageModelSwitchHintAfterTurn(isRunningScreenActions: true))
    }

    @Test func smallerScreenshotsFitALargerModelButNotTheOtherWay() {
        let genericProfile = ModelVisionProfile.genericVisionModel(coordinateConvention: .imagePixels)
        #expect(ScreenshotGeometry.imageFits(widthInPixels: 1280, heightInPixels: 800, profile: .claudeHighResolution))
        #expect(ScreenshotGeometry.imageFits(widthInPixels: 1280, heightInPixels: 800, profile: genericProfile))
        #expect(!ScreenshotGeometry.imageFits(widthInPixels: 1920, heightInPixels: 1200, profile: genericProfile))
    }
}
