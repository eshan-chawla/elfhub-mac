//
//  ChatGPTPlanViews.swift
//  elfhub
//
//  "Use your ChatGPT plan": the card at the top of the language-model layer
//  (onboarding step 1 and Settings › Models) that signs in with ChatGPT,
//  picks the model, shows that requests use the plan with a Manage usage
//  link, and sets the fallback model for when the plan can't answer. Also
//  the one-time "You're using your ChatGPT plan" confirmation.
//
//  Wording follows OpenAI's Sign in with ChatGPT UI guidelines: the button
//  says "Continue with ChatGPT", and "Manage usage" opens ChatGPT's usage
//  settings.
//

import AppKit
import SwiftUI

struct ChatGPTPlanCard: View {
    @ObservedObject var chatGPTPlanAccount: ChatGPTPlanAccount
    @ObservedObject var providerConfigurationStore: ProviderConfigurationStore

    @State private var availableModels: [ChatGPTPlanModel] = []
    @State private var modelListProblemMessage: String?
    @State private var isLoadingModels = false
    @State private var isSigningOut = false

    /// The one ChatGPT plan configuration, once a model has been picked.
    private var chatGPTPlanConfiguration: ProviderConfiguration? {
        providerConfigurationStore.configurations.first(where: { $0.kind == .chatGPTPlan })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Use your ChatGPT plan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            switch chatGPTPlanAccount.signInStatus {
            case .signedOut:
                signedOutContent(signInExpired: false)
            case .needsSignInAgain:
                signedOutContent(signInExpired: true)
            case .signingIn:
                signingInContent
            case let .signedIn(email, canUsePlan):
                if canUsePlan {
                    signedInContent(email: email)
                } else {
                    planUseNotAllowedContent(email: email)
                }
            }

            if let lastProblemMessage = chatGPTPlanAccount.lastProblemMessage {
                problemText(lastProblemMessage)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .sheet(isPresented: Binding(
            get: { chatGPTPlanAccount.shouldShowPlanWelcome },
            set: { isPresented in if !isPresented { chatGPTPlanAccount.dismissPlanWelcome() } }
        )) {
            ChatGPTPlanWelcomeSheet(onDismiss: chatGPTPlanAccount.dismissPlanWelcome)
        }
        .task(id: chatGPTPlanAccount.canUsePlan) {
            if chatGPTPlanAccount.canUsePlan {
                await loadModels()
            } else {
                availableModels = []
            }
        }
    }

    // MARK: - States

    private func signedOutContent(signInExpired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(signInExpired
                 ? "Your ChatGPT sign-in has expired. Continue with ChatGPT to keep using your plan."
                 : "Answer with OpenAI models included in your ChatGPT plan, instead of an API key. Speech-to-text and the voice stay as you set them below.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ContinueWithChatGPTButton { chatGPTPlanAccount.startSignIn() }
                if chatGPTPlanAccount.hasSavedRegistration {
                    linkButton("Use a different ChatGPT account", help: "Signs in with another ChatGPT account or workspace") {
                        chatGPTPlanAccount.startSignIn(asDifferentAccount: true)
                    }
                }
            }
        }
    }

    private var signingInContent: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Finish signing in in your browser…")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Button("Cancel") { chatGPTPlanAccount.cancelSignIn() }
                .pointerCursor()
        }
    }

    private func planUseNotAllowedContent(email: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signed in\(email.map { " as \($0)" } ?? ""), but elfhub wasn't allowed to use your ChatGPT plan. Continue with ChatGPT again and allow it, or use another model below.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ContinueWithChatGPTButton { chatGPTPlanAccount.startSignIn(requestingPlanConsent: true) }
                signOutButton
            }
            linkButton("Use a different ChatGPT account", help: "Signs in with another ChatGPT account or workspace") {
                chatGPTPlanAccount.startSignIn(asDifferentAccount: true)
            }
        }
    }

    private func signedInContent(email: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(email.map { "Signed in as \($0)" } ?? "Signed in")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                signOutButton
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(DS.Colors.success)
                Text("Using ChatGPT plan")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                linkButton("Manage usage", help: "Opens ChatGPT's usage settings in your browser") {
                    NSWorkspace.shared.open(ChatGPTPlanOAuthConstants.manageUsageURL)
                }
            }

            if let unavailableSince = providerConfigurationStore.chatGPTPlanUnavailableSince,
               Date().timeIntervalSince(unavailableSince) < LanguageModelTurnRouting.chatGPTPlanRetryIntervalInSeconds {
                usageLimitNotice
            }

            modelPicker

            if let chatGPTPlanConfiguration {
                Toggle(isOn: Binding(
                    get: { chatGPTPlanConfiguration.supportsVision },
                    set: { supportsVision in
                        var updatedConfiguration = chatGPTPlanConfiguration
                        updatedConfiguration.supportsVision = supportsVision
                        providerConfigurationStore.upsert(updatedConfiguration, apiKey: nil)
                    }
                )) {
                    Text("Sees your screen")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .tint(DS.Colors.accent)
                .pointerCursor()

                fallbackPicker

                if providerConfigurationStore.activeConfigurationID != chatGPTPlanConfiguration.id {
                    Button(action: { providerConfigurationStore.setActiveConfiguration(id: chatGPTPlanConfiguration.id) }) {
                        Text("Use ChatGPT plan")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Makes the ChatGPT plan the model elfhub answers with")
                    .pointerCursor()
                }
            }
        }
    }

    // MARK: - Pieces

    private var usageLimitNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(providerConfigurationStore.chatGPTPlanUnavailableReason == .notEligible
                     ? "Your ChatGPT plan can't be used here"
                     : "Usage limit reached")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(DS.Colors.warning)
            Text(providerConfigurationStore.fallbackConfiguration.map {
                "elfhub is answering with \($0.displayName) for now and will try your ChatGPT plan again in about an hour."
            } ?? "Pick a fallback model below to keep answering meanwhile.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.Colors.warning.opacity(0.1)))
    }

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODEL")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            if isLoadingModels && availableModels.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading your models…")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            } else if availableModels.isEmpty {
                HStack(spacing: 8) {
                    Text(modelListProblemMessage ?? "No models listed for this account.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await loadModels() } }
                        .pointerCursor()
                }
            } else {
                Picker("", selection: Binding(
                    get: { chatGPTPlanConfiguration?.model ?? "" },
                    set: { selectedModelSlug in useModel(slug: selectedModelSlug) }
                )) {
                    if chatGPTPlanConfiguration == nil {
                        Text("Pick a model").tag("")
                    }
                    ForEach(availableModels) { availableModel in
                        Text(availableModel.displayName).tag(availableModel.slug)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .pointerCursor()
            }
        }
    }

    private var fallbackPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WHEN THE CHATGPT PLAN CAN'T ANSWER, USE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Picker("", selection: Binding(
                get: { providerConfigurationStore.fallbackConfigurationID },
                set: { providerConfigurationStore.setFallbackConfiguration(id: $0) }
            )) {
                Text("No fallback — just tell me").tag(UUID?.none)
                ForEach(providerConfigurationStore.fallbackCandidates) { candidateConfiguration in
                    Text("\(candidateConfiguration.displayName) · \(candidateConfiguration.model)")
                        .tag(Optional(candidateConfiguration.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .pointerCursor()
            Text(providerConfigurationStore.fallbackCandidates.isEmpty
                 ? "Add another model below (with its key, or one on this Mac) to have a fallback for when your plan's limit is reached."
                 : "Used when your plan's usage limit is reached; elfhub tells you when it switches and tries ChatGPT again after about an hour.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signOutButton: some View {
        Button(isSigningOut ? "Signing out…" : "Sign out") {
            isSigningOut = true
            Task {
                await chatGPTPlanAccount.signOut()
                isSigningOut = false
            }
        }
        .disabled(isSigningOut)
        .pointerCursor(isEnabled: !isSigningOut)
    }

    private func linkButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DS.Colors.accentText)
        }
        .buttonStyle(.plain)
        .help(help)
        .pointerCursor()
    }

    private func problemText(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundColor(DS.Colors.warning)
    }

    // MARK: - Actions

    private func loadModels() async {
        isLoadingModels = true
        modelListProblemMessage = nil
        do {
            availableModels = try await chatGPTPlanAccount.listModels()
            // Right after a sign-in (only then), pick the account's first model
            // and make the plan the active model, so onboarding can go straight
            // on. Opening Settings later never re-creates a removed ChatGPT
            // model or changes which model is active.
            if chatGPTPlanAccount.consumeNewlyCompletedSignIn(),
               chatGPTPlanConfiguration == nil,
               let firstModel = availableModels.first {
                useModel(slug: firstModel.slug)
            }
        } catch {
            modelListProblemMessage = "Couldn't list your models: \(error.localizedDescription.prefix(120))"
        }
        isLoadingModels = false
    }

    private func useModel(slug selectedModelSlug: String) {
        guard !selectedModelSlug.isEmpty else { return }
        if var existingConfiguration = chatGPTPlanConfiguration {
            existingConfiguration.model = selectedModelSlug
            providerConfigurationStore.upsert(existingConfiguration, apiKey: nil)
        } else {
            let newConfiguration = ProviderConfiguration.chatGPTPlan(model: selectedModelSlug)
            providerConfigurationStore.upsert(newConfiguration, apiKey: nil)
            providerConfigurationStore.setActiveConfiguration(id: newConfiguration.id)
        }
    }
}

// MARK: - Continue with ChatGPT

/// OpenAI's sign-in button: black, "Continue with ChatGPT", with the ChatGPT
/// logo when the approved artwork is in the asset catalog (`ChatGPTLogo`).
struct ContinueWithChatGPTButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let chatGPTLogo = NSImage(named: "ChatGPTLogo") {
                    Image(nsImage: chatGPTLogo)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 16, height: 16)
                }
                Text("Continue with ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.8 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Opens ChatGPT's sign-in in your browser")
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

// MARK: - First sign-in confirmation

struct ChatGPTPlanWelcomeSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundColor(DS.Colors.success)
            Text("You're using your ChatGPT plan")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("elfhub's answers now use your ChatGPT plan instead of an API key. You can review and limit what elfhub uses in ChatGPT's settings, under Usage.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Manage usage") { NSWorkspace.shared.open(ChatGPTPlanOAuthConstants.manageUsageURL) }
                    .pointerCursor()
                Button("Got it", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(DS.Colors.background)
    }
}
