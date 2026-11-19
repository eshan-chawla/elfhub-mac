//
//  LanguageModelFallbackPolicy.swift
//  elfhub
//
//  When the ChatGPT plan is the active model, which model answers the next
//  turn. The user picks a fallback model in Settings › Models; elfhub uses it
//  while the plan can't be used (signed out, plan use not allowed) and for an
//  hour after the plan hits its usage limit, then quietly tries the plan
//  again. OpenAI asks apps not to guess when a limit resets, so the hour is
//  only how often elfhub checks — it never tells the user a reset time.
//  The active model never changes: the fallback is a per-turn override.
//

import Foundation

enum LanguageModelTurnRouting {

    /// How long elfhub stays on the fallback after the plan was unavailable
    /// before trying the plan again on a new turn.
    static let chatGPTPlanRetryIntervalInSeconds: TimeInterval = 3600

    /// The model an elf answers with: its own choice (from this Mac's
    /// models) when it has one and it's ready, otherwise the main model.
    /// The ChatGPT-plan fallback then applies to whichever it is.
    static func activeConfiguration(
        mainActiveConfiguration: ProviderConfiguration?,
        elfPreferredConfiguration: ProviderConfiguration?,
        isElfPreferredConfigurationReady: Bool,
        hasReadyFallbackForChatGPTPlan: Bool = false
    ) -> ProviderConfiguration? {
        guard let elfPreferredConfiguration else { return mainActiveConfiguration }
        // An elf on the ChatGPT plan stays on it even when it can't be used
        // right now, when there's a fallback for it: the user's chosen
        // fallback answers then, not the main elf's model.
        if elfPreferredConfiguration.kind == .chatGPTPlan, hasReadyFallbackForChatGPTPlan { return elfPreferredConfiguration }
        guard isElfPreferredConfigurationReady else { return mainActiveConfiguration }
        return elfPreferredConfiguration
    }

    static func configurationForNextTurn(
        activeConfiguration: ProviderConfiguration?,
        fallbackConfiguration: ProviderConfiguration?,
        isFallbackReady: Bool,
        canUseChatGPTPlan: Bool,
        chatGPTPlanUnavailableSince: Date?,
        now: Date
    ) -> ProviderConfiguration? {
        guard let activeConfiguration else { return nil }
        guard activeConfiguration.kind == .chatGPTPlan else { return activeConfiguration }
        guard let fallbackConfiguration, isFallbackReady, fallbackConfiguration.kind != .chatGPTPlan else {
            // No usable fallback: the plan answers (or fails with a clear message).
            return activeConfiguration
        }
        guard canUseChatGPTPlan else { return fallbackConfiguration }
        if let chatGPTPlanUnavailableSince,
           now.timeIntervalSince(chatGPTPlanUnavailableSince) < chatGPTPlanRetryIntervalInSeconds {
            return fallbackConfiguration
        }
        return activeConfiguration
    }
}

/// Why the ChatGPT plan is paused for an hour. Only problems that won't
/// clear in a moment pause it; a brief outage or a sign-in problem moves
/// just that one turn to the fallback.
enum ChatGPTPlanUnavailableReason: String, Codable {
    case usageLimitReached
    case notEligible
}

/// What elfhub tells the user when a turn moves between the ChatGPT plan
/// and the fallback model (status pill and a notice in chat).
enum LanguageModelSwitchNotice: Equatable {
    case switchedToFallback(fallbackModelName: String, reason: ChatGPTPlanUsageError)
    case returnedToChatGPTPlan

    var message: String {
        switch self {
        case let .switchedToFallback(fallbackModelName, reason):
            let cause: String
            switch reason {
            case .usageLimitReached:
                cause = "Your ChatGPT plan's usage limit is reached"
            case .notEligible:
                cause = "Your ChatGPT plan can't be used here"
            case .usageTemporarilyUnavailable:
                cause = "Your ChatGPT plan isn't available right now"
            case .planUsageNotEnabled, .credentialRejected:
                cause = "Your ChatGPT sign-in needs attention in Settings"
            case .unsupportedCapability, .requestNotAuthorized:
                cause = "Your ChatGPT plan couldn't answer"
            }
            return "\(cause) — answering with \(fallbackModelName). elfhub will try ChatGPT again in about an hour."
        case .returnedToChatGPTPlan:
            return "Back on your ChatGPT plan."
        }
    }

    /// Only the usage limit is something the user can change in ChatGPT's
    /// usage settings, so only that notice links there.
    var offersManageUsage: Bool {
        if case .switchedToFallback(_, .usageLimitReached) = self { return true }
        return false
    }
}

/// A switch notice tied to the chat whose turn switched, so it shows only
/// there and not in whichever chat happens to be open.
struct LanguageModelSwitchChatNotice: Equatable {
    let switchNotice: LanguageModelSwitchNotice
    let conversationIdentifier: UUID

    func isShown(inConversationWithIdentifier activeConversationIdentifier: UUID) -> Bool {
        activeConversationIdentifier == conversationIdentifier
    }
}
