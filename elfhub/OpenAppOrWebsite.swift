//
//  OpenAppOrWebsite.swift
//  elfhub
//
//  The direct route during a run: open an app by name or a web address
//  straight away (NSWorkspace) instead of hunting for it with Spotlight or
//  in the Dock — quicker, and it can't land on the wrong icon. It goes
//  through the same consent as every step (an app on the privacy list or a
//  private website is the user's step; a new app asks when the run is
//  scoped to others) and returns a fresh screenshot like any step.
//

import AppKit
import Foundation

extension GuidanceToolDefinitions {
    static let openAppOrWebsiteToolName = "open_app_or_website"

    /// Offered beside the screen steps (Claude's toolset or
    /// perform_screen_action) during a run.
    static let openAppOrWebsiteToolDefinition = LanguageModelToolDefinition(
        name: openAppOrWebsiteToolName,
        description: "Open an app by its name (\"Numbers\", \"Safari\") or a website address (\"https://example.com/pricing\") right away — quicker and surer than finding it on screen. Give one of the two. Returns a fresh screenshot.",
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "the app's name as it appears in Applications"],
                "website": ["type": "string", "description": "a full https address"],
            ],
        ]
    )
}

/// Finds an installed app by its name.
enum ApplicationLocator {
    /// Where apps live, in the order they're looked through.
    static var applicationFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    /// The app called `applicationName` (any case, with or without ".app"),
    /// in these folders or one level down (Utilities), or nil.
    static func applicationURL(named applicationName: String, in folders: [URL] = applicationFolders) -> URL? {
        var wantedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if wantedName.hasSuffix(".app") {
            wantedName.removeLast(4)
        }
        guard !wantedName.isEmpty else { return nil }
        let fileManager = FileManager.default
        for folder in folders {
            var foldersToSearch = [folder]
            if let subfolders = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
                foldersToSearch += subfolders.filter { $0.pathExtension.isEmpty }
            }
            for searchedFolder in foldersToSearch {
                guard let folderItems = try? fileManager.contentsOfDirectory(at: searchedFolder, includingPropertiesForKeys: nil) else { continue }
                if let matchingApplication = folderItems.first(where: { folderItem in
                    folderItem.pathExtension == "app" && folderItem.deletingPathExtension().lastPathComponent.lowercased() == wantedName
                }) {
                    return matchingApplication
                }
            }
        }
        return nil
    }

    /// The app's bundle identifier, or nil.
    static func bundleIdentifier(ofApplicationNamed applicationName: String) -> String? {
        applicationURL(named: applicationName).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// The browser a website opens in.
    static func defaultBrowserBundleIdentifier(for websiteURL: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: websiteURL).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Opens the app (or brings it to the front); false when it isn't installed or won't open.
    static func openApplication(named applicationName: String) async -> Bool {
        guard let applicationURL = applicationURL(named: applicationName) else { return false }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: openConfiguration)) != nil
    }

    /// Opens the address in the user's browser.
    static func openWebsite(_ websiteURL: URL) async -> Bool {
        guard ["http", "https"].contains(websiteURL.scheme?.lowercased()) else { return false }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        return (try? await NSWorkspace.shared.open(websiteURL, configuration: openConfiguration)) != nil
    }
}
