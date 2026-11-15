//
//  elfhubApp.swift
//  elfhub
//
//  elfhub companion app. Shows a main window GUI on launch, plus a menu bar
//  status item for the floating companion panel.
//
//  The main window is an AppKit window owned by MainWindowPresenter, not a
//  SwiftUI WindowGroup: SwiftUI only recreates a closed WindowGroup window
//  when the app has no visible windows, and elfhub's click-through overlay
//  always counts as one — so a closed main window could never come back.
//

import AppKit
import ServiceManagement
import SwiftUI

@main
struct elfhubApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The main window and the menu bar panel are both managed from the
        // AppDelegate (see MainWindowPresenter); this empty Settings scene
        // satisfies SwiftUI's requirement for at least one scene.
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
        MainWindowPresenter.showMainWindow()
    }

    /// Clicking the Dock icon (or opening the app again from Finder) always
    /// brings the main window back. AppKit's own reopen handling does
    /// nothing while any window is visible, and the overlay always is.
    /// A .elf double-clicked in Finder (or dropped on the Dock icon): its
    /// preview opens in the main window — after setup, or over onboarding.
    func application(_ application: NSApplication, open urls: [URL]) {
        for packageURL in urls where packageURL.pathExtension.lowercased() == "elf" {
            companionManager.requestElfImport(from: packageURL)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }
}

/// Owns the main window — chat first, with every chat in the sidebar and
/// Settings behind its bottom menu (see MainAppView); onboarding takes over
/// its detail pane until setup is complete. Every surface (launch, the Dock
/// icon, the menu bar panel, onboarding, the tutorial) opens it through
/// here. Closing it only hides it, so it comes back exactly as it was.
@MainActor
enum MainWindowPresenter {
    static let mainWindowTitle = "elfhub"
    private static let defaultMainWindowSize = NSSize(width: 1000, height: 700)
    private static let mainWindowFrameAutosaveName = "elfhub main window"

    private static var mainWindow: NSWindow?

    static func showMainWindow() {
        let mainWindow = mainWindow ?? makeMainWindow()
        self.mainWindow = mainWindow
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeMainWindow() -> NSWindow {
        let hostingView = NSHostingView(rootView: MainAppView(companionManager: CompanionManager.shared))
        // Only the view's minimum size constrains the window: if it followed
        // each page's ideal size it would jump when onboarding or the
        // tutorial opened. The user alone resizes it.
        hostingView.sizingOptions = [.minSize]

        let newMainWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultMainWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newMainWindow.title = mainWindowTitle
        newMainWindow.contentView = hostingView
        newMainWindow.isReleasedWhenClosed = false
        newMainWindow.tabbingMode = .disallowed
        newMainWindow.center()
        // Comes back where the user last left it (only moves it if a frame
        // was saved before).
        newMainWindow.setFrameAutosaveName(mainWindowFrameAutosaveName)
        return newMainWindow
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
