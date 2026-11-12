//
//  elfhubApp.swift
//  elfhub
//
//  elfhub companion app. Shows a main window GUI on launch, plus a menu bar
//  status item for the floating companion panel.
//

import AppKit
import ServiceManagement
import SwiftUI

@main
struct elfhubApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    // Shared manager: created once, referenced by both the main window and
    // the app-delegate-driven companion pipeline.
    private var companionManager = CompanionManager.shared

    var body: some Scene {
        // Main window with the full native app experience — chat first, with
        // every chat in the sidebar and Settings behind its bottom menu
        // (see MainAppView).
        // Onboarding takes over the detail pane until setup is complete.
        WindowGroup("elfhub") {
            MainAppView(companionManager: companionManager)
        }
        .windowToolbarStyle(.unified)
        // A fixed starting size, and only the user resizes it: without these
        // the window followed each page's ideal size and jumped when
        // onboarding or the tutorial opened.
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)

        // The menu bar panel is still managed by the AppDelegate; this empty
        // Settings scene satisfies SwiftUI's requirement for at least one scene.
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var companionManager = CompanionManager.shared
    private var menuBarPanelManager: MenuBarPanelManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 elfhub: Starting...")
        print("🎯 elfhub: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }
}

/// Brings the SwiftUI main window forward from AppKit code (the menu bar
/// panel, onboarding, the tutorial). If the user closed it, asking macOS to
/// "reopen" the running app makes SwiftUI create a fresh one.
enum MainWindowPresenter {
    static let mainWindowTitle = "elfhub"

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existingMainWindow = NSApp.windows.first(where: { $0.title == mainWindowTitle && $0.canBecomeMain }) {
            existingMainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let reopenConfiguration = NSWorkspace.OpenConfiguration()
        reopenConfiguration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: reopenConfiguration)
    }
}

/// Opt-in launch at login via SMAppService (shows in System Settings >
/// General > Login Items). Toggled from Settings > General; never enabled
/// automatically.
enum LaunchAtLoginSetting {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        let loginItemService = SMAppService.mainApp
        do {
            if enabled {
                try loginItemService.register()
            } else {
                try loginItemService.unregister()
            }
        } catch {
            print("⚠️ elfhub: Failed to update login item: \(error)")
        }
    }
}
