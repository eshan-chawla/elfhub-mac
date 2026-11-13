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

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Input mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(inputModeSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
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
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .togglePointerCursor(isSelected: isSelected)
    }
}

// MARK: - Model Layers Summary Row

/// Compact summary of the three model layers (hearing, thinking, speaking)
/// with a "Manage" action that opens the Models section of the main window.
struct ProviderSettingsRow: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Models")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(activeLanguageModelSummary)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(companionManager.isLanguageModelReady ? DS.Colors.textTertiary : DS.Colors.warning)
                        .lineLimit(1)
                    Text("\(companionManager.transcriptionProviderChoice.displayLabel) · \(companionManager.speechOutputMode.displayLabel) voice")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: { companionManager.openProviderSettings() }) {
                Text(companionManager.isLanguageModelReady ? "Manage" : "Set up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    private var activeLanguageModelSummary: String {
        guard let activeConfiguration = companionManager.providerConfigurationStore.activeConfiguration else {
            return "No language model yet — add one to get started"
        }
        if !companionManager.isLanguageModelReady {
            return "\(activeConfiguration.displayName) — needs a key or model"
        }
        return "\(activeConfiguration.displayName) · \(activeConfiguration.model)"
    }
}

// MARK: - Voice Output Picker

/// Compact picker for how elfhub replies sound (used in the menu bar panel;
/// the Models section has the full voice setup).
struct VoiceOutputPicker: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                Text("Voice output")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { companionManager.speechOutputMode },
                set: { companionManager.setSpeechOutputMode($0) }
            )) {
                ForEach(SpeechOutputMode.allCases) { speechOutputMode in
                    Text(speechOutputMode.displayLabel).tag(speechOutputMode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .pointerCursor()
        }
        .padding(.vertical, 4)
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

    var body: some View {
        HStack(alignment: .center) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.vertical, 4)
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

// MARK: - Open Text Chat Button

/// Row-style button that opens the text chat surface (embedded pane in the
/// main window, standalone window from the panel).
struct OpenTextChatButton: View {
    @ObservedObject var companionManager: CompanionManager
    var openAction: (() -> Void)? = nil

    var body: some View {
        Button(action: { performOpen() }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12, weight: .medium))
                Text("Chat with elfhub")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func performOpen() {
        if let openAction {
            openAction()
        } else {
            companionManager.openTextChat()
        }
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

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let subtitle, !isGranted {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    grantButtons
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var grantButtons: some View {
        if let onGrantAccessibility {
            // Accessibility special case: system prompt on first attempt, plus a
            // "Find App" helper for unsigned dev builds that don't appear in the
            // Accessibility list automatically.
            Button(action: onGrantAccessibility) {
                Text("Grant")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                WindowPositionManager.revealAppInFinder()
                WindowPositionManager.openAccessibilitySettings()
            }) {
                Text("Find App")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        } else if let onGrantSystemSettings {
            Button(action: onGrantSystemSettings) {
                Text("Grant")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }
}

/// The full four-permission checklist (Microphone, Screen Recording,
/// Screen Content, Accessibility). Shared by onboarding, the revoked-permission
/// state, and the Settings pane.
struct PermissionGroupView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            PermissionRow(
                iconName: "mic",
                title: "Microphone",
                subtitle: nil,
                isGranted: companionManager.hasMicrophonePermission,
                onGrantSystemSettings: { requestMicrophonePermission() }
            )

            PermissionRow(
                iconName: "hand.raised",
                title: "Accessibility",
                subtitle: nil,
                isGranted: companionManager.hasAccessibilityPermission,
                onGrantAccessibility: { WindowPositionManager.requestAccessibilityPermission() }
            )

            PermissionRow(
                iconName: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                subtitle: companionManager.hasScreenRecordingPermission ? nil : "Quit and reopen after granting",
                isGranted: companionManager.hasScreenRecordingPermission,
                onGrantSystemSettings: { WindowPositionManager.requestScreenRecordingPermission() }
            )

            // Screen content only makes sense after screen recording is
            // granted — the picker can't capture anything without it.
            if companionManager.hasScreenRecordingPermission {
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
