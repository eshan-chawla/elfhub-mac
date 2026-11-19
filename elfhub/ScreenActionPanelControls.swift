//
//  ScreenActionPanelControls.swift
//  elfhub
//
//  The menu bar panel's UI for real screen actions: the on/off toggle, the
//  Ask first / Auto / Allow all picker ("Allow all" only after a warning),
//  and the per-turn consent card (the same question as the approval popup,
//  ScreenActionApprovalPanel.swift). Split into its
//  own small views (each observing the coordinator directly) so CompanionPanelView
//  stays focused and these can evolve independently.
//

import SwiftUI

// MARK: - Action Mode Controls

/// The "Take actions" toggle plus, when enabled, the safety-mode picker.
/// Disabled entirely until Accessibility is granted, since nothing can fire
/// without it.
struct ScreenActionModeControls: View {
    @ObservedObject var coordinator: ScreenActionCoordinator
    let isAccessibilityGranted: Bool
    /// Settings has room to explain all three modes at once, so the choice is
    /// clear before picking; the compact menu bar panel explains only the
    /// chosen one.
    var explainsEveryMode: Bool = false

    /// "Allow all" is only switched on after this warning is accepted.
    @State private var isConfirmingAllowEverything = false

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        VStack(spacing: usesSettingsListStyle ? 0 : 8) {
            toggleRow

            if coordinator.isActionModeEnabled && isAccessibilityGranted {
                if usesSettingsListStyle {
                    SettingsRowDivider()
                }
                safetyModePicker
                if explainsEveryMode {
                    everySafetyModeExplanation
                        .padding(.bottom, usesSettingsListStyle ? 10 : 0)
                } else {
                    safetyModeExplanation
                }
            }
        }
        .alert("Dangerously allow everything?", isPresented: $isConfirmingAllowEverything) {
            Button("Allow everything", role: .destructive) {
                coordinator.setExecutionMode(.allowEverythingWithoutAsking)
            }
            Button("Keep asking", role: .cancel) {}
        } message: {
            Text("Your Elfs will click, type, send and delete without asking first. Only use this while you're watching the screen: press Esc, or touch the mouse or keyboard, to stop at once. Text on the screen or a web page could trick an Elf into doing something you didn't ask for. Passwords, private apps and private websites stay your step. This lasts until elfhub quits.")
        }
    }

    /// One line under the picker saying what the chosen mode does.
    private var safetyModeExplanation: some View {
        HStack(alignment: .top, spacing: 6) {
            if coordinator.executionMode == .allowEverythingWithoutAsking {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)
            }
            Text(Self.explanation(for: coordinator.executionMode))
                .font(DS.Typography.interface(size: 11, weight: .regular))
                .foregroundColor(coordinator.executionMode == .allowEverythingWithoutAsking ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Every mode with what it does; the chosen one stands out.
    private var everySafetyModeExplanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.safetyModeChoices, id: \.label) { safetyModeChoice in
                let isSelected = coordinator.executionMode == safetyModeChoice.mode
                let isDangerous = safetyModeChoice.mode == .allowEverythingWithoutAsking
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(safetyModeChoice.label)
                        .font(DS.Typography.interface(size: usesSettingsListStyle ? 12 : 11, weight: .semibold))
                        .foregroundColor(isSelected ? (isDangerous ? DS.Colors.destructiveText : DS.Colors.textPrimary) : DS.Colors.textTertiary)
                        .frame(width: usesSettingsListStyle ? 64 : 58, alignment: .leading)
                    Text(Self.explanation(for: safetyModeChoice.mode))
                        .font(DS.Typography.interface(size: usesSettingsListStyle ? 12 : 11, weight: .regular))
                        .foregroundColor(isSelected ? (isDangerous ? DS.Colors.destructiveText : DS.Colors.textSecondary) : DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The picker's segments, in order, with their short labels.
    private static let safetyModeChoices: [(label: String, mode: ScreenActionExecutionMode)] = [
        ("Ask first", .confirmEachAction),
        ("Auto", .autoFire),
        ("Allow all", .allowEverythingWithoutAsking),
    ]

    static func explanation(for executionMode: ScreenActionExecutionMode) -> String {
        switch executionMode {
        case .confirmEachAction:
            return "A popup asks before each new task and each new app. Press Return to go ahead."
        case .autoFire:
            return "Acts without asking, except before sending, deleting or anything else that can't be taken back."
        case .allowEverythingWithoutAsking:
            return "Nothing asks first. Watch the screen and press Esc to stop. Goes back to asking when elfhub quits."
        }
    }

    private var toggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                SettingsRowIcon(systemName: "hand.tap")

                VStack(alignment: .leading, spacing: usesSettingsListStyle ? 3 : 1) {
                    Text("Take actions")
                        .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: usesSettingsListStyle))
                        .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: usesSettingsListStyle))

                    if usesSettingsListStyle {
                        Text(isAccessibilityGranted
                             ? "Let your Elfs click, type and scroll for you, step by step."
                             : "Needs the Accessibility permission (Privacy & permissions).")
                            .font(SettingsRowMetrics.detailFont(usesSettingsListStyle: true))
                            .foregroundColor(SettingsRowMetrics.detailColor(usesSettingsListStyle: true))
                    } else {
                        Text(isAccessibilityGranted
                             ? "let your Elfs click, type and scroll for you"
                             : "needs accessibility permission")
                            .font(DS.Typography.interface(size: 10, weight: .regular))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { coordinator.isActionModeEnabled },
                set: { coordinator.setActionModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.controlTint)
            .scaleEffect(0.8)
            .disabled(!isAccessibilityGranted)
        }
        .padding(.vertical, SettingsRowMetrics.verticalPadding(usesSettingsListStyle: usesSettingsListStyle))
        .opacity(isAccessibilityGranted ? 1 : 0.5)
    }

    private var safetyModePicker: some View {
        HStack {
            Text("Before acting")
                .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: usesSettingsListStyle))
                .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: usesSettingsListStyle))

            Spacer()

            HStack(spacing: 0) {
                ForEach(Self.safetyModeChoices, id: \.label) { safetyModeChoice in
                    safetyModeButton(label: safetyModeChoice.label, mode: safetyModeChoice.mode)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.contrastTint.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.top, SettingsRowMetrics.verticalPadding(usesSettingsListStyle: usesSettingsListStyle))
        .padding(.bottom, usesSettingsListStyle ? 6 : 4)
    }

    private func safetyModeButton(label: String, mode: ScreenActionExecutionMode) -> some View {
        let isSelected = coordinator.executionMode == mode
        let isDangerous = mode == .allowEverythingWithoutAsking
        return Button(action: {
            if isDangerous && !isSelected {
                isConfirmingAllowEverything = true
            } else {
                coordinator.setExecutionMode(mode)
            }
        }) {
            Text(label)
                .font(DS.Typography.interface(size: 11, weight: .medium))
                .foregroundColor(isSelected ? (isDangerous ? DS.Colors.destructiveText : DS.Colors.textPrimary) : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? DS.Colors.contrastTint.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(Self.explanation(for: mode))
    }
}

// MARK: - Consent Card

/// The per-turn consent card. Appears while an action is waiting on the user's
/// go-ahead, showing exactly what elfhub will do plus Confirm / Cancel. The
/// hands-free path is saying "go"; this card is the on-screen equivalent.
struct ScreenActionConsentCard: View {
    @ObservedObject var coordinator: ScreenActionCoordinator
    /// The main elf's name: "Juniper wants to".
    let elfName: String

    var body: some View {
        if let pendingConsent = coordinator.pendingConsent {
            // An approval waiting on you (brand chapter 07): a card with an
            // amber left edge; going ahead is the primary button and
            // declining the quiet secondary one — never a red button here.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: pendingConsent.includesHighRiskAction
                          ? "exclamationmark.triangle"
                          : "hand.tap")
                        .font(DS.Typography.interface(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)

                    Text(pendingConsent.includesHighRiskAction ? "Confirm this action" : "\(elfName) wants to")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    DSStatusBadge(text: "Waiting on you", tone: .warning)
                }

                Text(pendingConsent.summary)
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Go ahead") { coordinator.confirmPendingActions() }
                        .dsPrimaryButtonStyle(isFullWidth: true, size: .small)
                    Button("Cancel") { coordinator.cancelPendingActions() }
                        .dsSecondaryButtonStyle(isFullWidth: true, size: .small)
                }

                Text("Or press Return in the popup, or just say \u{201C}go\u{201D}.")
                    .font(DS.Typography.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(12)
            .padding(.leading, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(DS.Colors.warning)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }
}
