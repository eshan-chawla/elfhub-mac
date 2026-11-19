//
//  AppUpdateController.swift
//  elfhub
//
//  Keeps the published app up to date with Sparkle. Once a day Sparkle asks
//  GitHub for the latest release's appcast.xml (SUFeedURL in Info.plist);
//  when a newer version exists it shows the release notes with Install /
//  Remind me later / Skip. Every update must carry an EdDSA signature that
//  matches SUPublicEDKey and be signed by the same Developer ID as this app,
//  so nothing else can be installed.
//
//  Only the published app (com.elfhub.os) updates itself. Xcode and
//  contributor builds have other bundle ids, and a release would replace them
//  with a different app, so the updater never starts in those builds.
//

import Combine
import Foundation
import Sparkle

/// The rules for when this build updates itself and where it looks. Pure, so
/// they're unit-tested.
nonisolated enum AppUpdatePolicy {
    /// The bundle id of the app published on GitHub Releases.
    static let publishedAppBundleIdentifier = "com.elfhub.os"

    /// User-defaults key that points the updater at another feed, used to
    /// test an update end to end with a feed served from this Mac. Updates
    /// from that feed still need the EdDSA signature and the same Developer
    /// ID, so it can't bring in anything unsigned.
    static let feedURLOverrideDefaultsKey = "ElfhubUpdateFeedURL"

    static func isSelfUpdatingBuild(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == publishedAppBundleIdentifier
    }

    /// The test feed from user defaults, or nil to use SUFeedURL. Only
    /// http(s) URLs with a host count.
    static func feedURLOverride(from userDefaults: UserDefaults) -> String? {
        guard let overrideValue = userDefaults.string(forKey: feedURLOverrideDefaultsKey) else { return nil }
        let trimmedValue = overrideValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let overrideURL = URL(string: trimmedValue),
              let scheme = overrideURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = overrideURL.host, !host.isEmpty else {
            return nil
        }
        return trimmedValue
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    /// False in Xcode and contributor builds: no checks, no menu item.
    let isUpdatingAvailable: Bool
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private var standardUpdaterController: SPUStandardUpdaterController?
    private var updaterStateCancellables: Set<AnyCancellable> = []

    override init() {
        isUpdatingAvailable = AppUpdatePolicy.isSelfUpdatingBuild(bundleIdentifier: Bundle.main.bundleIdentifier)
        super.init()
        guard isUpdatingAvailable else { return }

        // Starting the updater schedules the daily check right away.
        // SUEnableAutomaticChecks is YES in Info.plist, so Sparkle never
        // asks whether it may check.
        let standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.standardUpdaterController = standardUpdaterController

        let updater = standardUpdaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
                self?.refreshUpdaterSettings()
            }
            .store(in: &updaterStateCancellables)
        refreshUpdaterSettings()
    }

    /// Re-reads the settings Sparkle keeps (the user can also change them in
    /// Sparkle's own update window).
    func refreshUpdaterSettings() {
        guard let updater = standardUpdaterController?.updater else { return }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        standardUpdaterController?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        standardUpdaterController?.updater.automaticallyChecksForUpdates = isEnabled
        refreshUpdaterSettings()
    }

    func setAutomaticallyDownloadsUpdates(_ isEnabled: Bool) {
        standardUpdaterController?.updater.automaticallyDownloadsUpdates = isEnabled
        refreshUpdaterSettings()
    }
}

extension AppUpdateController: SPUUpdaterDelegate {
    /// nil means "use SUFeedURL from Info.plist".
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdatePolicy.feedURLOverride(from: .standard)
    }
}
