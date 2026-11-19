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
        // satisfies SwiftUI's requirement for at least one scene, and carries
        // the app menu's "Check for Updates…".
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(appUpdateController: CompanionManager.shared.appUpdateController)
            }
            // The empty Settings scene above would otherwise own "Settings…"
            // and ⌘, and open a blank window. elfhub's Settings live in the
            // main window, so the menu item opens them there.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsMenuItem()
            }
        }
    }
}

/// "Settings…" (⌘,) in the app menu: opens the main window on Settings.
/// Before setup is complete the main window only shows onboarding, so it
/// brings that forward instead of queueing a Settings page for later.
private struct OpenSettingsMenuItem: View {
    var body: some View {
        Button("Settings…") {
            let companionManager = CompanionManager.shared
            if companionManager.hasCompletedOnboarding {
                companionManager.showMainWindow(section: .settings(.general))
            } else {
                companionManager.showMainWindow()
            }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// "Check for Updates…" in the app menu, under "About elfhub". Only the
/// published app has it; Xcode and contributor builds never update.
private struct CheckForUpdatesMenuItem: View {
    @ObservedObject var appUpdateController: AppUpdateController

    var body: some View {
        if appUpdateController.isUpdatingAvailable {
            Button("Check for Updates…") {
                appUpdateController.checkForUpdates()
            }
            .disabled(!appUpdateController.canCheckForUpdates)
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

    /// A .elf double-clicked in Finder (or dropped on the Dock icon): its
    /// preview opens in the main window — after setup, or over onboarding.
    func application(_ application: NSApplication, open urls: [URL]) {
        for packageURL in urls where packageURL.pathExtension.lowercased() == "elf" {
            companionManager.requestElfImport(from: packageURL)
        }
    }

    /// Clicking the Dock icon (or opening the app again from Finder) always
    /// brings the main window back. AppKit's own reopen handling does
    /// nothing while any window is visible, and the overlay always is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        // Usage is saved a moment after each request; quitting right after
        // one would otherwise lose its counts.
        LanguageModelUsageLedger.shared.saveNow()
    }
}

/// Owns the main window — chat first, with every chat in the sidebar and
/// Settings at the bottom of it and on ⌘, (see MainAppView); onboarding takes over
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

    /// The title bar as part of the content (MainWindowChrome): not drawn,
    /// no separator, and — through an empty unified toolbar — as tall as
    /// `MainWindowChrome.titleBarHeight` with the window buttons centered in
    /// it. The window needs `.fullSizeContentView`.
    static func applyContentTitleBar(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let titleBarToolbar = NSToolbar(identifier: "elfhub main window title bar")
        titleBarToolbar.showsBaselineSeparator = false
        window.toolbar = titleBarToolbar
        window.toolbarStyle = .unified
    }

    private static func makeMainWindow() -> NSWindow {
        let hostingView = NSHostingView(rootView: MainAppView(companionManager: CompanionManager.shared))
        // Only the view's minimum size constrains the window: if it followed
        // each page's ideal size it would jump when onboarding or the
        // tutorial opened. The user alone resizes it.
        hostingView.sizingOptions = [.minSize]
        // The title bar is drawn by the content itself (MainWindowChrome), so
        // SwiftUI isn't told about it as a safe area — otherwise backgrounds
        // near the top (a banner's tint) stretch up into the title bar band.
        hostingView.safeAreaRegions = []

        let newMainWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultMainWindowSize),
            // The title bar is part of the content (MainWindowChrome): the
            // sidebar runs up behind the window buttons, no grey strip.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Still the window's name in the Window menu and Mission Control,
        // just not drawn.
        newMainWindow.title = mainWindowTitle
        applyContentTitleBar(to: newMainWindow)
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
