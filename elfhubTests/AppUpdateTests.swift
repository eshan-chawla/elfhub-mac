//
//  AppUpdateTests.swift
//  elfhubTests
//
//  Which builds update themselves, the test-feed override, and the Sparkle
//  settings the published app ships with.
//

import Foundation
import Testing
@testable import elfhub

struct AppUpdateTests {

    @Test func onlyThePublishedAppUpdatesItself() {
        #expect(AppUpdatePolicy.isSelfUpdatingBuild(bundleIdentifier: "com.elfhub.os"))
        #expect(!AppUpdatePolicy.isSelfUpdatingBuild(bundleIdentifier: "com.elfhub.os.dev"))
        #expect(!AppUpdatePolicy.isSelfUpdatingBuild(bundleIdentifier: "com.elfhub.os.tests"))
        #expect(!AppUpdatePolicy.isSelfUpdatingBuild(bundleIdentifier: "com.yourname.elfhub"))
        #expect(!AppUpdatePolicy.isSelfUpdatingBuild(bundleIdentifier: nil))
    }

    @Test func theTestFeedOverrideOnlyTakesWebURLs() throws {
        let suiteName = "elfhub-update-tests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let overrideKey = AppUpdatePolicy.feedURLOverrideDefaultsKey

        #expect(AppUpdatePolicy.feedURLOverride(from: userDefaults) == nil)

        userDefaults.set(" http://127.0.0.1:8000/appcast.xml ", forKey: overrideKey)
        #expect(AppUpdatePolicy.feedURLOverride(from: userDefaults) == "http://127.0.0.1:8000/appcast.xml")

        userDefaults.set("https://example.com/appcast.xml", forKey: overrideKey)
        #expect(AppUpdatePolicy.feedURLOverride(from: userDefaults) == "https://example.com/appcast.xml")

        for rejectedValue in ["", "   ", "file:///tmp/appcast.xml", "not a url", "ftp://example.com/appcast.xml", "https://"] {
            userDefaults.set(rejectedValue, forKey: overrideKey)
            #expect(AppUpdatePolicy.feedURLOverride(from: userDefaults) == nil, "\(rejectedValue) should be refused")
        }
    }

    /// The tests run inside the app, so its Info.plist is the one that ships.
    @Test func theAppShipsWithDailyChecksOnAndInstallingOff() throws {
        let infoDictionary = try #require(Bundle.main.infoDictionary)

        let feedURLString = try #require(infoDictionary["SUFeedURL"] as? String)
        #expect(feedURLString.hasPrefix("https://"))
        #expect(feedURLString.hasSuffix("/releases/latest/download/appcast.xml"))

        let publicKey = try #require(infoDictionary["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: publicKey)?.count == 32)

        #expect(infoDictionary["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(infoDictionary["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(infoDictionary["SUScheduledCheckInterval"] as? Int == 86_400)
        #expect(infoDictionary["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }
}
