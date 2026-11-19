//
//  SupportLinksTests.swift
//  elfhubTests
//
//  The Support sheet's links: a bug report, a feature request and a
//  question each open their own GitHub issue, the email goes to the
//  developers, every one carries the app and macOS versions and nothing
//  else, and a link that isn't set up gives no row.
//

import Foundation
import Testing
@testable import elfhub

struct SupportLinksTests {

    private let supportDiagnostics = SupportDiagnostics(appVersion: "0.0.2", appBuildNumber: "14", macOSVersion: "26.1.0")

    private func queryValue(_ queryItemName: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == queryItemName })?
            .value
    }

    @Test func eachKindOfRequestOpensItsOwnGitHubIssue() throws {
        for supportRequestKind in SupportRequestKind.allCases {
            let issueURL = try #require(SupportLinks.published.gitHubNewIssueURL(for: supportRequestKind, supportDiagnostics: supportDiagnostics))
            let urlComponents = try #require(URLComponents(url: issueURL, resolvingAgainstBaseURL: false))
            #expect(urlComponents.host == "github.com")
            #expect(urlComponents.path == "/eshan-chawla/elfhub-mac/issues/new")
            #expect(queryValue("title", in: issueURL) == supportRequestKind.issueTitlePrefix)
            #expect(queryValue("labels", in: issueURL) == supportRequestKind.issueLabel)
            let issueBody = try #require(queryValue("body", in: issueURL))
            #expect(issueBody.contains(supportRequestKind.templatePrompts[0]))
            #expect(issueBody.hasSuffix("---\nelfhub 0.0.2 (14) · macOS 26.1.0"))
        }
        let featureRequestURL = try #require(SupportLinks.published.gitHubNewIssueURL(for: .featureRequest, supportDiagnostics: supportDiagnostics))
        #expect(queryValue("labels", in: featureRequestURL) == "enhancement")
    }

    @Test func theEmailGoesToTheDevelopersWithASubjectAndTheVersions() throws {
        let emailURL = try #require(SupportLinks.published.supportEmailURL(for: .featureRequest, supportDiagnostics: supportDiagnostics))
        let urlComponents = try #require(URLComponents(url: emailURL, resolvingAgainstBaseURL: false))
        #expect(urlComponents.scheme == "mailto")
        #expect(urlComponents.path == SupportLinks.published.supportEmailAddress)
        #expect(queryValue("subject", in: emailURL) == "elfhub feature request")
        #expect(queryValue("body", in: emailURL)?.contains("macOS 26.1.0") == true)
    }

    @Test func theDiscordInviteShipsAsThePreferredWayIn() {
        #expect(SupportLinks.published.discordInviteURL?.absoluteString == "https://discord.gg/ZGVzhv4ggS")
    }

    @Test func linksThatArentSetUpGiveNoRow() {
        let supportLinks = SupportLinks(gitHubNewIssueURL: nil, websiteReportURL: nil, discordInviteURL: nil, supportEmailAddress: "  ")
        #expect(supportLinks.gitHubNewIssueURL(for: .bugReport, supportDiagnostics: supportDiagnostics) == nil)
        #expect(supportLinks.supportEmailURL(supportDiagnostics: supportDiagnostics) == nil)
    }
}
