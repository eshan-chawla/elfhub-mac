//
//  PrivateWebsiteTests.swift
//  elfhubTests
//
//  Private websites (banks, patient portals, password vaults): a site and
//  its subdomains match, look-alikes don't, patient-portal hosts like
//  mychart.<hospital>.org match by name, and acting on one is always the
//  user's own step.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct PrivateWebsiteTests {

    private let domains = PrivateWebsiteList.defaultPrivateWebsiteDomains

    @Test func aPrivateSiteAndItsSubdomainsMatchButLookAlikesDont() {
        #expect(PrivateWebsiteList.isPrivate(host: "chase.com", domains: domains))
        #expect(PrivateWebsiteList.isPrivate(host: "secure.Chase.com", domains: domains))
        #expect(!PrivateWebsiteList.isPrivate(host: "notchase.com", domains: domains))
        #expect(!PrivateWebsiteList.isPrivate(host: "chase.com.example.net", domains: domains))
        #expect(!PrivateWebsiteList.isPrivate(host: "bankrate.com", domains: domains))
        #expect(!PrivateWebsiteList.isPrivate(host: nil, domains: domains))
        #expect(PrivateWebsiteList.isPrivate(host: "my.clinic-example.org", domains: domains + ["clinic-example.org"]))
    }

    @Test func patientPortalsMatchByTheirName() {
        #expect(PrivateWebsiteList.isPrivate(host: "mychart.clevelandclinic.org", domains: domains))
        #expect(PrivateWebsiteList.isPrivate(host: "patientportal.example-hospital.com", domains: domains))
        #expect(!PrivateWebsiteList.isPrivate(host: "mychartblog.com", domains: domains))
    }

    @Test func theGuardIsOnByDefaultAndSwitchingItOffStopsEveryCheck() {
        let userDefaultsSuiteName = "private-websites-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        let privateWebsiteList = PrivateWebsiteList(userDefaults: userDefaults)
        #expect(privateWebsiteList.isGuardEnabled)
        #expect(privateWebsiteList.isPrivate(host: "chase.com"))

        privateWebsiteList.setGuardEnabled(false)
        #expect(!privateWebsiteList.isPrivate(host: "chase.com"))
        #expect(!PrivateWebsiteList(userDefaults: userDefaults).isGuardEnabled)

        privateWebsiteList.setGuardEnabled(true)
        #expect(privateWebsiteList.isPrivate(host: "chase.com"))
    }

    @Test func actingOnAPrivateWebsiteIsTheUsersStep() {
        let decision = ConsentPolicy.evaluate(ScreenActionConsentContext(
            action: .click(screenshotPixel: CGPoint(x: 1, y: 1), label: "transfer", screenNumber: nil),
            targetElementFacts: nil,
            frontmostApplicationBundleIdentifier: "com.google.Chrome",
            isTargetApplicationPrivacyBlocked: false,
            userUtterance: "click transfer",
            isTargetWebsitePrivate: true
        ))
        guard case .usersStep = decision else {
            Issue.record("acting on a private website should be the user's step, got \(decision)")
            return
        }
    }
}
