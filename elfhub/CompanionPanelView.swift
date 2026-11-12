//
//  CompanionPanelView.swift
//  elfhub
//
//  The compact floating-panel experience hosted in the menu bar NSPanel.
//  Shows the companion voice status, push-to-talk shortcut, and quick
//  settings. Setup (models, shortcuts, permissions) happens in the main
//  window; until it's done the panel just points there. All row visuals live
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

                ProviderSettingsRow(companionManager: companionManager)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                VoiceOutputPicker(companionManager: companionManager)
                    .padding(.horizontal, 16)

                openChatRow
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                ScreenActionModeControls(
                    coordinator: companionManager.screenActionCoordinator,
                    isAccessibilityGranted: companionManager.hasAccessibilityPermission
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)

                ScreenActionConsentCard(coordinator: companionManager.screenActionCoordinator)
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

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("elfhub")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .dismissCompanionPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
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
                 : "Open chat below and ask me anything.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant them in the elfhub window to keep using it.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to elfhub.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Pick your speech, language and voice models, confirm the shortcut and grant permissions in the elfhub window.")
                    .font(.system(size: 11))
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
                .font(.system(size: 14, weight: .semibold))
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

    // MARK: - Open Chat Row

    private var openChatRow: some View {
        OpenTextChatButton(companionManager: companionManager)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit elfhub")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.showMainWindow()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11, weight: .medium))
                        Text("Open elfhub")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.hasCompletedOnboarding || !companionManager.hasPermissionsRequiredForActiveModes {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.hasPermissionsRequiredForActiveModes {
            return "Setup"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
