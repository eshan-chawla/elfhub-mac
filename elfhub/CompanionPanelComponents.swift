//
//  CompanionPanelComponents.swift
//  elfhub
//
//  Shared SwiftUI building blocks used by BOTH the compact menu-bar panel
//  (CompanionPanelView) and the native main window (MainAppView). Each component
//  is a small, self-contained row/section so the two hosts stay visually in sync
//  without one having to mirror the other's layout.
//

import AVFoundation
import AppKit
import SwiftUI

// MARK: - Input Mode Picker

/// Segmented control for choosing how the user interacts with elfhub —
/// voice (push-to-talk), text only, or both. Shown wherever mode switching
/// matters (Settings › Controls, onboarding and the compact panel).
struct InputModePicker: View {
    @ObservedObject var companionManager: CompanionManager

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                SettingsRowIcon(systemName: "arrow.left.arrow.right")

                VStack(alignment: .leading, spacing: usesSettingsListStyle ? 3 : 1) {
                    Text("Input mode")
                        .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: usesSettingsListStyle))
                        .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: usesSettingsListStyle))
                    Text(inputModeSubtitle)
                        .font(usesSettingsListStyle
                              ? SettingsRowMetrics.detailFont(usesSettingsListStyle: true)
                              : DS.Typography.interface(size: 10))
                        .foregroundColor(SettingsRowMetrics.detailColor(usesSettingsListStyle: usesSettingsListStyle))
                }
            }

            Spacer()

            HStack(spacing: 0) {
                ForEach(CompanionManager.InteractionInputMode.allCases) { mode in
                    inputModeButton(mode: mode)
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
        .padding(.vertical, SettingsRowMetrics.verticalPadding(usesSettingsListStyle: usesSettingsListStyle))
    }

    private var inputModeSubtitle: String {
        switch companionManager.interactionInputMode {
        case .voice: return "Push-to-talk active"
        case .textOnly: return "Chat only — mic off"
        case .both: return "Push-to-talk + chat"
        }
    }

    private func inputModeButton(mode: CompanionManager.InteractionInputMode) -> some View {
        let isSelected = companionManager.interactionInputMode == mode
        return Button(action: { companionManager.setInteractionInputMode(mode) }) {
            Text(mode.displayLabel)
                .font(DS.Typography.interface(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? DS.Colors.contrastTint.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .togglePointerCursor(isSelected: isSelected)
    }
}

// MARK: - Sound Cues Toggle

/// Short system sounds for "got it", "needs your yes" and "something failed".
struct SoundCuesToggleRow: View {
    @State private var areSoundCuesEnabled = CompanionEarcon.areSoundCuesEnabled

    var body: some View {
        SettingsToggleRow(
            iconName: "bell",
            title: "Sound cues",
            detail: "A soft sound when elfhub hears you, needs a yes, or hits an error.",
            isOn: Binding(
                get: { areSoundCuesEnabled },
                set: { requestedValue in
                    CompanionEarcon.setSoundCuesEnabled(requestedValue)
                    areSoundCuesEnabled = requestedValue
                }
            )
        )
    }
}

// MARK: - Settings Toggle Row

/// Icon + title (+ optional detail) + switch. Shared by the General settings
/// rows so they match the other settings rows visually.
struct SettingsToggleRow: View {
    let iconName: String
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        HStack(alignment: .center) {
            HStack(alignment: .top, spacing: 8) {
                SettingsRowIcon(systemName: iconName)

                VStack(alignment: .leading, spacing: usesSettingsListStyle ? 3 : 2) {
                    Text(title)
                        .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: usesSettingsListStyle))
                        .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: usesSettingsListStyle))
                    if let detail {
                        Text(detail)
                            .font(SettingsRowMetrics.detailFont(usesSettingsListStyle: usesSettingsListStyle))
                            .foregroundColor(SettingsRowMetrics.detailColor(usesSettingsListStyle: usesSettingsListStyle))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 16)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.controlTint)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.vertical, SettingsRowMetrics.verticalPadding(usesSettingsListStyle: usesSettingsListStyle))
    }
}

// MARK: - Launch At Login Toggle

/// Opt-in launch at login. elfhub never registers itself as a login item
/// without the user asking.
struct LaunchAtLoginToggleRow: View {
    @State private var isLaunchAtLoginEnabled = LaunchAtLoginSetting.isEnabled

    var body: some View {
        SettingsToggleRow(
            iconName: "power.circle",
            title: "Open elfhub at login",
            detail: nil,
            isOn: Binding(
                get: { isLaunchAtLoginEnabled },
                set: { requestedValue in
                    LaunchAtLoginSetting.setEnabled(requestedValue)
                    // Re-read the real status: registration can fail or need
                    // approval in System Settings.
                    isLaunchAtLoginEnabled = LaunchAtLoginSetting.isEnabled
                }
            )
        )
    }
}

// MARK: - Permission Rows

/// One granting row inside the permissions group. Handles the two grant
/// mechanics the app uses: a custom async request (screen content) or opening
/// system settings / a system prompt (everything else).
struct PermissionRow: View {
    let iconName: String
    let title: String
    let subtitle: String?
    let isGranted: Bool
    var onGrantAccessibility: (() -> Void)? = nil
    var onGrantSystemSettings: (() -> Void)? = nil
    /// Shown beside Grant for permissions macOS only applies after a
    /// relaunch (Screen Recording): elfhub has no Quit item of its own there.
    var onQuitAndReopen: (() -> Void)? = nil

    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                SettingsRowIcon(systemName: iconName, color: isGranted ? DS.Colors.textTertiary : DS.Colors.warning)

                VStack(alignment: .leading, spacing: usesSettingsListStyle ? 3 : 1) {
                    Text(title)
                        .font(SettingsRowMetrics.titleFont(usesSettingsListStyle: usesSettingsListStyle))
                        .foregroundColor(SettingsRowMetrics.titleColor(usesSettingsListStyle: usesSettingsListStyle))
                    if let subtitle, !isGranted {
                        Text(subtitle)
                            .font(usesSettingsListStyle
                                  ? SettingsRowMetrics.detailFont(usesSettingsListStyle: true)
                                  : DS.Typography.interface(size: 10))
                            .foregroundColor(SettingsRowMetrics.detailColor(usesSettingsListStyle: usesSettingsListStyle))
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(DS.Typography.interface(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    grantButtons
                }
            }
        }
        .padding(.vertical, usesSettingsListStyle ? SettingsRowMetrics.verticalPadding(usesSettingsListStyle: true) : 6)
    }

    @ViewBuilder
    private var grantButtons: some View {
        if let onGrantAccessibility {
            // Accessibility special case: system prompt on first attempt, plus a
            // "Find App" helper for unsigned dev builds that don't appear in the
            // Accessibility list automatically.
            Button(action: onGrantAccessibility) {
                PermissionPillLabel(title: "Grant")
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                WindowPositionManager.revealAppInFinder()
                WindowPositionManager.openAccessibilitySettings()
            }) {
                PermissionPillLabel(title: "Find app")
            }
            .buttonStyle(.plain)
            .pointerCursor()
        } else if let onGrantSystemSettings {
            Button(action: onGrantSystemSettings) {
                PermissionPillLabel(title: "Grant")
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        if let onQuitAndReopen {
            Button(action: onQuitAndReopen) {
                PermissionPillLabel(title: "Quit & reopen")
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("macOS applies Screen Recording after elfhub restarts. Setup picks up where you left it.")
        }
    }
}

/// The small outlined pill on a permission row (Grant, Find app, Quit &
/// reopen). Secondary on purpose: the step's own Continue stays the one
/// primary action, however many permissions are missing. Darkens on hover.
private struct PermissionPillLabel: View {
    let title: String
    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(DS.Typography.interface(size: 11, weight: .semibold))
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(isHovered ? DS.Colors.contrastTint.opacity(0.06) : Color.clear))
            .overlay(Capsule().stroke(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 0.8))
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// The full four-permission checklist (Microphone, Screen Recording,
/// Screen Content, Accessibility). Shared by onboarding, the revoked-permission
/// state, and the Settings pane.
struct PermissionGroupView: View {
    @ObservedObject var companionManager: CompanionManager

    /// On a Settings page the section heading names the list and hairlines
    /// separate the rows; elsewhere it carries its own small label.
    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    var body: some View {
        VStack(spacing: usesSettingsListStyle ? 0 : 2) {
            if !usesSettingsListStyle {
                Text("Permissions")
                    .dsLabelStyle()
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }

            PermissionRow(
                iconName: "mic",
                title: "Microphone",
                subtitle: nil,
                isGranted: companionManager.hasMicrophonePermission,
                onGrantSystemSettings: { requestMicrophonePermission() }
            )

            rowDivider

            PermissionRow(
                iconName: "hand.raised",
                title: "Accessibility",
                subtitle: nil,
                isGranted: companionManager.hasAccessibilityPermission,
                onGrantAccessibility: { WindowPositionManager.requestAccessibilityPermission() }
            )

            rowDivider

            PermissionRow(
                iconName: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                subtitle: companionManager.hasScreenRecordingPermission ? nil : "After granting, quit and reopen elfhub",
                isGranted: companionManager.hasScreenRecordingPermission,
                onGrantSystemSettings: { WindowPositionManager.requestScreenRecordingPermission() },
                onQuitAndReopen: { WindowPositionManager.quitAndReopenApp() }
            )

            // Screen content only makes sense after screen recording is
            // granted — the picker can't capture anything without it.
            if companionManager.hasScreenRecordingPermission {
                rowDivider
                PermissionRow(
                    iconName: "eye",
                    title: "Screen Content",
                    subtitle: nil,
                    isGranted: companionManager.hasScreenContentPermission,
                    onGrantSystemSettings: { companionManager.requestScreenContentPermission() }
                )
            }
        }
    }

    @ViewBuilder
    private var rowDivider: some View {
        if usesSettingsListStyle {
            SettingsRowDivider()
        }
    }

    /// Triggers the native macOS microphone permission dialog on first attempt.
    /// If already denied, opens System Settings.
    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Small Helpers

extension View {
    /// Buttons inside a segmented control: the selected one already reads as
    /// active, so make sure the pointer cursor only communicates clickability
    /// on the unselected options too (still a pointer — it's a button).
    func togglePointerCursor(isSelected: Bool) -> some View {
        pointerCursor()
    }
}
