//
//  PrivateWebsiteList.swift
//  elfhub
//
//  Websites elfhub never looks at or acts on: banks and payment sites,
//  patient portals, password vaults. While the browser in front shows one,
//  that browser's windows are left out of every screenshot (like the apps
//  on ScreenCapturePrivacyBlocklist), its page isn't read through
//  Accessibility, and any action on it is the user's own step. A site
//  matches with all its subdomains; patient portals that live on their
//  hospital's domain (mychart.<hospital>.org) match by name. Editable in
//  Settings › Privacy; kept in UserDefaults.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PrivateWebsiteList: ObservableObject {
    static let shared = PrivateWebsiteList()

    nonisolated static let defaultPrivateWebsiteDomains: [String] = [
        // Banks and payments.
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com", "usbank.com",
        "pnc.com", "schwab.com", "fidelity.com", "vanguard.com", "americanexpress.com", "discover.com",
        "paypal.com", "venmo.com", "wise.com", "revolut.com", "coinbase.com", "robinhood.com",
        "rbcroyalbank.com", "td.com", "tdbank.com", "scotiabank.com", "bmo.com", "cibc.com", "tangerine.ca",
        "simplii.com", "desjardins.com", "hsbc.com", "barclays.co.uk", "monzo.com", "starlingbank.com",
        // Health.
        "mychart.com", "followmyhealth.com", "kp.org", "myhealth.va.gov", "patient.athenahealth.com",
        // Password vaults.
        "vault.bitwarden.com", "my.1password.com", "1password.com", "lastpass.com", "app.dashlane.com",
        "keepersecurity.com", "pass.proton.me",
    ]

    /// Host names (the first part) that mean a patient portal or online
    /// banking on an organization's own domain.
    nonisolated static let privateHostFirstLabels: Set<String> = ["mychart", "patientportal", "onlinebanking"]

    private static let privateWebsiteDomainsKey = "privateWebsiteDomains"

    @Published private(set) var privateWebsiteDomains: [String]

    private init() {
        privateWebsiteDomains = UserDefaults.standard.stringArray(forKey: Self.privateWebsiteDomainsKey)
            ?? Self.defaultPrivateWebsiteDomains
    }

    func isPrivate(host: String?) -> Bool {
        Self.isPrivate(host: host, domains: privateWebsiteDomains)
    }

    nonisolated static func isPrivate(host: String?, domains: [String]) -> Bool {
        guard let loweredHost = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !loweredHost.isEmpty else {
            return false
        }
        if let firstLabel = loweredHost.split(separator: ".").first, privateHostFirstLabels.contains(String(firstLabel)) {
            return true
        }
        return domains.contains { privateDomain in
            let loweredDomain = privateDomain.lowercased()
            return loweredHost == loweredDomain || loweredHost.hasSuffix("." + loweredDomain)
        }
    }

    /// Turns what the user typed ("https://www.mybank.com/login") into a
    /// domain ("mybank.com"), or nil when it isn't one.
    nonisolated static func domain(fromUserEntry userEntry: String) -> String? {
        var trimmedEntry = userEntry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedEntry.contains("://") {
            trimmedEntry = "https://" + trimmedEntry
        }
        guard var host = URL(string: trimmedEntry)?.host, host.contains("."), !host.contains(" ") else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    func addPrivateWebsite(_ userEntry: String) {
        guard let domain = Self.domain(fromUserEntry: userEntry), !privateWebsiteDomains.contains(domain) else { return }
        privateWebsiteDomains.append(domain)
        persist()
    }

    func removePrivateWebsite(_ domain: String) {
        privateWebsiteDomains.removeAll { $0 == domain }
        persist()
    }

    func resetToDefaults() {
        privateWebsiteDomains = Self.defaultPrivateWebsiteDomains
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(privateWebsiteDomains, forKey: Self.privateWebsiteDomainsKey)
    }

    /// Of these browser processes, the ones with a private website open in
    /// any window — all their windows are then left out of screenshots
    /// (in front or not: a bank beside Notes is still on the screen).
    static func browserProcessesShowingPrivateWebsites(_ browserProcessIdentifiers: Set<pid_t>) async -> Set<pid_t> {
        var privateBrowserProcessIdentifiers: Set<pid_t> = []
        for browserProcessIdentifier in browserProcessIdentifiers {
            let pageHosts = await AccessibilityElementLocator.pageHostsInWindows(processIdentifier: browserProcessIdentifier)
            if pageHosts.contains(where: { shared.isPrivate(host: $0) }) {
                privateBrowserProcessIdentifiers.insert(browserProcessIdentifier)
            }
        }
        return privateBrowserProcessIdentifiers
    }

    /// Whether the browser in front has a private website open (its page
    /// is then never read).
    static func isFrontmostBrowserShowingPrivateWebsite() async -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              AccessibilityElementLocator.isBrowser(bundleIdentifier: frontmostApplication.bundleIdentifier) else { return false }
        return await !browserProcessesShowingPrivateWebsites([frontmostApplication.processIdentifier]).isEmpty
    }
}

// MARK: - Settings UI

/// Settings › Privacy editor for private websites.
struct PrivateWebsiteListEditor: View {
    @ObservedObject var privateWebsiteList: PrivateWebsiteList
    @State private var newWebsiteEntry = ""
    @State private var isShowingAllWebsites = false

    private var websitesToShow: [String] {
        let userAddedWebsites = privateWebsiteList.privateWebsiteDomains.filter { !PrivateWebsiteList.defaultPrivateWebsiteDomains.contains($0) }
        guard !isShowingAllWebsites else { return privateWebsiteList.privateWebsiteDomains }
        return userAddedWebsites
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Private websites")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("While your browser shows one of these (banks, patient portals, password vaults — and any site you add), its windows are left out of screenshots, elfhub doesn't read the page, and it won't click or type there.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(websitesToShow, id: \.self) { privateDomain in
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)
                    Text(privateDomain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button(action: { privateWebsiteList.removePrivateWebsite(privateDomain) }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Let elfhub see this website")
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                TextField("Add a website, like mybank.com", text: $newWebsiteEntry)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(addEnteredWebsite)
                Button("Add", action: addEnteredWebsite)
                    .pointerCursor()
                    .disabled(PrivateWebsiteList.domain(fromUserEntry: newWebsiteEntry) == nil)
            }

            HStack(spacing: 12) {
                Button(action: { isShowingAllWebsites.toggle() }) {
                    Text(isShowingAllWebsites ? "Show only the ones I added" : "Show the built-in list (\(PrivateWebsiteList.defaultPrivateWebsiteDomains.count))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                Button(action: { privateWebsiteList.resetToDefaults() }) {
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

    private func addEnteredWebsite() {
        privateWebsiteList.addPrivateWebsite(newWebsiteEntry)
        newWebsiteEntry = ""
    }
}
