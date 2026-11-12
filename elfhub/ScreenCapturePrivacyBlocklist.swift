//
//  ScreenCapturePrivacyBlocklist.swift
//  elfhub
//
//  Apps whose windows are never included in screenshots sent to the AI.
//  Enforced at capture time in CompanionScreenCaptureUtility by excluding the
//  windows from the ScreenCaptureKit filter, so the model never receives their
//  pixels at all (rather than receiving them and being told to ignore them).
//
//  Defaults cover password managers and macOS credential stores. The user can
//  add or remove apps in Settings > Privacy; the list persists in UserDefaults.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenCapturePrivacyBlocklist: ObservableObject {
    static let shared = ScreenCapturePrivacyBlocklist()

    /// Password managers and credential stores. Not System Settings — helping
    /// the user find a setting is a core use case.
    static let defaultBlockedBundleIdentifiers: [String] = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc",
        "com.nordpass.macos.NordPass",
        "me.proton.pass.electron"
    ]

    private static let blockedBundleIdentifiersKey = "screenCaptureBlockedBundleIdentifiers"

    @Published private(set) var blockedBundleIdentifiers: [String]

    private init() {
        if let savedBundleIdentifiers = UserDefaults.standard.stringArray(forKey: Self.blockedBundleIdentifiersKey) {
            blockedBundleIdentifiers = savedBundleIdentifiers
        } else {
            blockedBundleIdentifiers = Self.defaultBlockedBundleIdentifiers
        }
    }

    func isBlocked(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return blockedBundleIdentifiers.contains { blockedBundleIdentifier in
            blockedBundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    func addBlockedApp(bundleIdentifier: String) {
        guard !isBlocked(bundleIdentifier: bundleIdentifier) else { return }
        blockedBundleIdentifiers.append(bundleIdentifier)
        persist()
    }

    func removeBlockedApp(bundleIdentifier: String) {
        blockedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        persist()
    }

    func resetToDefaults() {
        blockedBundleIdentifiers = Self.defaultBlockedBundleIdentifiers
        persist()
    }

    /// Human-readable app name for a bundle id, falling back to the id itself
    /// when the app isn't installed.
    static func displayName(forBundleIdentifier bundleIdentifier: String) -> String {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: applicationURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func persist() {
        UserDefaults.standard.set(blockedBundleIdentifiers, forKey: Self.blockedBundleIdentifiersKey)
    }
}

// MARK: - Settings UI

/// Settings > Privacy editor for the capture blocklist. Shows installed
/// blocked apps (uninstalled defaults are hidden to keep the list short),
/// lets the user remove any, add an app via an open panel, or reset.
struct ScreenCaptureBlocklistEditor: View {
    @ObservedObject var screenCapturePrivacyBlocklist: ScreenCapturePrivacyBlocklist

    private var installedOrUserAddedBundleIdentifiers: [String] {
        screenCapturePrivacyBlocklist.blockedBundleIdentifiers.filter { blockedBundleIdentifier in
            let isUserAdded = !ScreenCapturePrivacyBlocklist.defaultBlockedBundleIdentifiers.contains(blockedBundleIdentifier)
            let isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: blockedBundleIdentifier) != nil
            return isUserAdded || isInstalled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows from these apps are never included in screenshots elfhub sends to the AI.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(installedOrUserAddedBundleIdentifiers, id: \.self) { blockedBundleIdentifier in
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text(ScreenCapturePrivacyBlocklist.displayName(forBundleIdentifier: blockedBundleIdentifier))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    Button(action: {
                        screenCapturePrivacyBlocklist.removeBlockedApp(bundleIdentifier: blockedBundleIdentifier)
                    }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Allow this app in screenshots")
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 12) {
                Button(action: presentAddAppPanel) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Hide an app…")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: { screenCapturePrivacyBlocklist.resetToDefaults() }) {
                    Text("Reset to defaults")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.top, 4)
        }
    }

    /// Lets the user pick any .app; its bundle id is added to the blocklist.
    private func presentAddAppPanel() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Hide an app from elfhub screenshots"
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.allowedContentTypes = [.applicationBundle]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        guard openPanel.runModal() == .OK,
              let selectedApplicationURL = openPanel.url,
              let selectedBundleIdentifier = Bundle(url: selectedApplicationURL)?.bundleIdentifier else {
            return
        }
        screenCapturePrivacyBlocklist.addBlockedApp(bundleIdentifier: selectedBundleIdentifier)
    }
}
