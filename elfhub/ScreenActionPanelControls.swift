//
//  ScreenActionPanelControls.swift
//  elfhub
//
//  The menu bar panel's UI for real screen actions: the on/off toggle, the
//  confirm-vs-auto-fire picker, and the per-turn consent card. Split into its
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

    var body: some View {
        VStack(spacing: 8) {
            toggleRow

            if coordinator.isActionModeEnabled && isAccessibilityGranted {
                safetyModePicker
            }
        }
    }

    private var toggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Take actions")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isAccessibilityGranted
                         ? "let elfhub click, type, and scroll for you"
                         : "needs accessibility permission")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { coordinator.isActionModeEnabled },
                set: { coordinator.setActionModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
            .disabled(!isAccessibilityGranted)
        }
        .padding(.vertical, 4)
        .opacity(isAccessibilityGranted ? 1 : 0.5)
    }

    private var safetyModePicker: some View {
        HStack {
            Text("Before acting")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                safetyModeButton(label: "Ask first", mode: .confirmEachAction)
                safetyModeButton(label: "Auto", mode: .autoFire)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func safetyModeButton(label: String, mode: ScreenActionExecutionMode) -> some View {
        let isSelected = coordinator.executionMode == mode
        return Button(action: {
            coordinator.setExecutionMode(mode)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Consent Card

/// The per-turn consent card. Appears while an action is waiting on the user's
/// go-ahead, showing exactly what elfhub will do plus Confirm / Cancel. The
/// hands-free path is saying "go"; this card is the on-screen equivalent.
struct ScreenActionConsentCard: View {
    @ObservedObject var coordinator: ScreenActionCoordinator

    var body: some View {
        if let pendingConsent = coordinator.pendingConsent {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: pendingConsent.includesHighRiskAction
                          ? "exclamationmark.triangle.fill"
                          : "hand.tap.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(pendingConsent.includesHighRiskAction ? DS.Colors.warning : DS.Colors.accent)

                    Text(pendingConsent.includesHighRiskAction ? "Confirm this action" : "elfhub wants to")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Text(pendingConsent.summary)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: { coordinator.confirmPendingActions() }) {
                        Text("Do it")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: { coordinator.cancelPendingActions() }) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Text("or just say “go”")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }
}
