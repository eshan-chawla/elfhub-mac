//
//  CompanionPanelView.swift
//  elfhub
//
//  The compact floating-panel experience hosted in the menu bar NSPanel.
//  Shows the companion voice status, push-to-talk shortcut, the input mode,
//  open chat and screen actions. Models, voices and every other setting live
//  in the main window's Settings; quitting is the Dock's or ⌘Q's job. Until
//  setup is done the panel just points to the main window. All row visuals live
//  in CompanionPanelComponents.swift so the main window (MainAppView) and
//  this panel stay consistent.
//
//  Designed to feel like Loom's recording panel — dark, rounded, minimal.
//

import AppKit
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if isSetupComplete {
                Spacer()
                    .frame(height: 12)

                InputModePicker(companionManager: companionManager)
                    .padding(.horizontal, 16)

                ScreenActionModeControls(
                    coordinator: companionManager.screenActionCoordinator,
                    isAccessibilityGranted: companionManager.hasAccessibilityPermission
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)

                ScreenActionConsentCard(
                coordinator: companionManager.screenActionCoordinator,
                elfName: companionManager.elfManager.mainElf.configuration.identity.name
            )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            if !isSetupComplete {
                Spacer()
                    .frame(height: 16)

                finishSetupButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            // The footer opens the main window (Chat, Settings); before
            // onboarding the window only shows setup, which the Finish setup
            // button already opens, so there's no footer.
            if companionManager.hasCompletedOnboarding {
                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 16)

                footerSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    /// Onboarded and holding the permissions the active input modes need.
    private var isSetupComplete: Bool {
        companionManager.hasCompletedOnboarding && companionManager.hasPermissionsRequiredForActiveModes
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            // No status label: the on-screen pill already shows listening,
            // thinking and acting, so the header stays just the wordmark.
            BrandWordmark(height: 14)

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .dismissCompanionPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(DS.Colors.contrastTint.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if isSetupComplete {
            Text(companionManager.interactionInputMode.isVoiceInputEnabled
                 ? "Hold \(companionManager.pushToTalkShortcutOption.displayText) to talk."
                 : "Click Chat below and ask your Elf anything.")
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(DS.Typography.interface(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant them in the elfhub window to keep using it.")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to elfhub.")
                    .font(DS.Typography.interface(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Pick your speech, language and voice models, confirm the shortcut and grant permissions in the elfhub window.")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Finish Setup Button

    private var finishSetupButton: some View {
        Button(action: { companionManager.showMainWindow() }) {
            Text(companionManager.hasCompletedOnboarding ? "Open elfhub" : "Finish setup")
                .font(DS.Typography.interface(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    /// Chat opens the main window on its home page (the chat); Settings opens
    /// it on Settings › General, like ⌘, does.
    private var footerSection: some View {
        HStack {
            PanelFooterButton(iconName: "bubble.left.and.text.bubble.right", title: "Chat") {
                companionManager.showMainWindow(section: .chat)
            }

            Spacer()

            PanelFooterButton(iconName: "gearshape", title: "Settings") {
                companionManager.showMainWindow(section: .settings(.general))
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .dsShadow(.extraLarge)
    }
}

/// A quiet text button for the panel's footer: grey, darkening on hover so
/// it reads as clickable, with the pointer cursor.
private struct PanelFooterButton: View {
    let iconName: String
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(DS.Typography.interface(size: 11, weight: .medium))
                Text(title)
                    .font(DS.Typography.interface(size: 12, weight: .medium))
            }
            .foregroundColor(isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            isHovered = isHovering
        }
    }
}
