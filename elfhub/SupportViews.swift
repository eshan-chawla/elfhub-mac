//
//  SupportViews.swift
//  elfhub
//
//  Where to get help, opened from the Support button at the bottom of the
//  sidebar: first the elfhub Discord (the preferred way in, for quick
//  questions and basic support); then on GitHub, a bug report, a feature
//  request or a question (each its own issue template); then an email to
//  the developers or a report on the website (to hear about fixes). Each one opens in the user's own
//  browser or mail app — elfhub sends nothing itself. A link that isn't set
//  up yet is left out of the sheet rather than shown broken.
//
//  The only details filled in for the user are the app and macOS versions,
//  so a report can be matched to a build. Nothing about the user, their
//  chats or their Elfs is added.
//

import AppKit
import SwiftUI

// MARK: - Links

/// What the user is getting in touch about. Each becomes a GitHub issue
/// with its own title prefix, label and template.
nonisolated enum SupportRequestKind: String, CaseIterable, Sendable {
    case bugReport
    case featureRequest
    case question

    /// Put in front of the issue title so the kind shows in the list.
    var issueTitlePrefix: String {
        switch self {
        case .bugReport: return "Bug: "
        case .featureRequest: return "Feature request: "
        case .question: return "Question: "
        }
    }

    /// One of the repository's labels. GitHub applies it only for people
    /// who can triage; for everyone else the title prefix says it.
    var issueLabel: String {
        switch self {
        case .bugReport: return "bug"
        case .featureRequest: return "enhancement"
        case .question: return "question"
        }
    }

    var emailSubject: String {
        switch self {
        case .bugReport: return "elfhub bug report"
        case .featureRequest: return "elfhub feature request"
        case .question: return "elfhub question"
        }
    }

    /// What a new issue or email starts with, before the versions.
    var templatePrompts: [String] {
        switch self {
        case .bugReport:
            return ["What happened:", "What you expected:", "Steps to make it happen again:"]
        case .featureRequest:
            return ["What you'd like elfhub to do:", "Why it would help you:", "How you'd expect it to work:"]
        case .question:
            return ["Your question:", "What you've tried so far:"]
        }
    }
}

nonisolated struct SupportLinks: Equatable, Sendable {
    /// GitHub's new-issue page for the app's repository.
    var gitHubNewIssueURL: URL?
    /// The website's report form, for people without a GitHub account who
    /// want to hear back when it's fixed.
    var websiteReportURL: URL?
    /// An invite to the elfhub Discord — the preferred way to get help,
    /// shown first and marked Recommended.
    var discordInviteURL: URL?
    /// Where "Email the developers" writes to.
    var supportEmailAddress: String?

    /// The links the app ships with. The website's form is added here once
    /// it exists; until then its row doesn't show.
    static let published = SupportLinks(
        gitHubNewIssueURL: URL(string: "https://github.com/eshan-chawla/elfhub-mac/issues/new"),
        websiteReportURL: nil,
        discordInviteURL: URL(string: "https://discord.gg/ZGVzhv4ggS"),
        supportEmailAddress: "support@elfhub.ai"
    )

    /// The new-issue page for one kind of request: title prefix, label and
    /// template, with the versions at the end.
    func gitHubNewIssueURL(for supportRequestKind: SupportRequestKind, supportDiagnostics: SupportDiagnostics) -> URL? {
        guard let gitHubNewIssueURL,
              var urlComponents = URLComponents(url: gitHubNewIssueURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        urlComponents.queryItems = (urlComponents.queryItems ?? []) + [
            URLQueryItem(name: "title", value: supportRequestKind.issueTitlePrefix),
            URLQueryItem(name: "labels", value: supportRequestKind.issueLabel),
            URLQueryItem(name: "body", value: supportDiagnostics.template(for: supportRequestKind))
        ]
        return urlComponents.url
    }

    /// A `mailto:` link to the developers with a subject and the versions
    /// in the body.
    func supportEmailURL(for supportRequestKind: SupportRequestKind = .bugReport, supportDiagnostics: SupportDiagnostics) -> URL? {
        guard let supportEmailAddress,
              !supportEmailAddress.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        var urlComponents = URLComponents()
        urlComponents.scheme = "mailto"
        urlComponents.path = supportEmailAddress.trimmingCharacters(in: .whitespaces)
        urlComponents.queryItems = [
            URLQueryItem(name: "subject", value: supportRequestKind.emailSubject),
            URLQueryItem(name: "body", value: supportDiagnostics.template(for: supportRequestKind))
        ]
        return urlComponents.url
    }
}

/// The app and macOS versions, put into reports so they can be matched to
/// a build. Nothing personal.
nonisolated struct SupportDiagnostics: Equatable, Sendable {
    let appVersion: String
    let appBuildNumber: String
    let macOSVersion: String

    static var current: SupportDiagnostics {
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        return SupportDiagnostics(
            appVersion: bundleInfo["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuildNumber: bundleInfo["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion).\(operatingSystemVersion.patchVersion)"
        )
    }

    /// "elfhub 0.0.2 (14) · macOS 26.1.0"
    var versionLine: String {
        "elfhub \(appVersion) (\(appBuildNumber)) · macOS \(macOSVersion)"
    }

    /// What a new issue or email starts with: the kind's prompts with room
    /// to answer, then the versions.
    func template(for supportRequestKind: SupportRequestKind) -> String {
        let promptsWithRoomToAnswer = supportRequestKind.templatePrompts
            .map { "\($0)\n\n" }
            .joined(separator: "\n")
        return promptsWithRoomToAnswer + "\n---\n" + versionLine
    }
}

// MARK: - Sheet

struct SupportSheet: View {
    var supportLinks: SupportLinks = .published
    var supportDiagnostics: SupportDiagnostics = .current

    @Environment(\.dismiss) private var dismiss

    private var hasOtherWaysToReachUs: Bool {
        supportLinks.supportEmailURL(supportDiagnostics: supportDiagnostics) != nil
            || supportLinks.websiteReportURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Support")
                        .font(DS.Typography.headingMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Stuck, found a bug or have an idea? The Discord is the quickest way to an answer.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .dsPrimaryButtonStyle(size: .small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                // Discord is the preferred way in: most questions are
                // answered there fastest, by us or other people.
                if let discordInviteURL = supportLinks.discordInviteURL {
                    SupportSectionLabel(title: "Fastest help")
                    SupportOptionRow(
                        iconName: "bubble.left.and.bubble.right",
                        title: "Join the elfhub Discord",
                        detail: "The best place for quick questions, setup help and bug reports. Ask us and other people who use elfhub, and hear about updates first.",
                        destination: discordInviteURL,
                        isRecommended: true
                    )
                    SupportSectionLabel(title: "On GitHub")
                        .padding(.top, 8)
                } else {
                    SupportSectionLabel(title: "On GitHub")
                }
                if let bugReportURL = supportLinks.gitHubNewIssueURL(for: .bugReport, supportDiagnostics: supportDiagnostics) {
                    SupportOptionRow(
                        iconName: "ladybug",
                        title: "Report a bug",
                        detail: "Opens a new issue with your app and macOS versions filled in. Everyone can follow it.",
                        destination: bugReportURL
                    )
                }
                if let featureRequestURL = supportLinks.gitHubNewIssueURL(for: .featureRequest, supportDiagnostics: supportDiagnostics) {
                    SupportOptionRow(
                        iconName: "lightbulb",
                        title: "Request a feature",
                        detail: "Tell us what you'd like elfhub or your Elfs to do next.",
                        destination: featureRequestURL
                    )
                }
                if let questionURL = supportLinks.gitHubNewIssueURL(for: .question, supportDiagnostics: supportDiagnostics) {
                    SupportOptionRow(
                        iconName: "questionmark.bubble",
                        title: "Ask a question",
                        detail: "Stuck on setup or not sure how something works? Ask in the open.",
                        destination: questionURL
                    )
                }

                if hasOtherWaysToReachUs {
                    SupportSectionLabel(title: "Other ways")
                        .padding(.top, 8)
                }
                if let supportEmailURL = supportLinks.supportEmailURL(supportDiagnostics: supportDiagnostics),
                   let supportEmailAddress = supportLinks.supportEmailAddress {
                    SupportOptionRow(
                        iconName: "envelope",
                        title: "Email the developers",
                        detail: "Write to \(supportEmailAddress) from your mail app — for anything you'd rather not post publicly.",
                        destination: supportEmailURL
                    )
                }
                if let websiteReportURL = supportLinks.websiteReportURL {
                    SupportOptionRow(
                        iconName: "globe",
                        title: "Send a report on our website",
                        detail: "No GitHub account needed. Leave your email to hear when it's fixed.",
                        destination: websiteReportURL
                    )
                }
            }
            .padding(24)

            Spacer(minLength: 0)

            Text(supportDiagnostics.versionLine)
                .font(DS.Typography.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .frame(width: 520)
        .frame(minHeight: 420)
        .background(DS.Colors.background)
        .tint(DS.Colors.controlTint)
    }
}

/// A small mono heading over a group of options.
private struct SupportSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DS.Typography.label)
            .dsLabelStyle()
            .foregroundColor(DS.Colors.textTertiary)
    }
}

/// One way to get help: a card that opens its link in the user's browser
/// or mail app.
private struct SupportOptionRow: View {
    let iconName: String
    let title: String
    let detail: String
    let destination: URL
    /// The preferred way to get help: a Recommended badge and a blue edge.
    var isRecommended: Bool = false

    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(destination)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: iconName)
                    .font(DS.Typography.interface(size: 15, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accentSubtle)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(DS.Typography.bodyMedium)
                            .foregroundColor(DS.Colors.textPrimary)
                        if isRecommended {
                            DSStatusBadge(text: "Recommended", tone: .info)
                        }
                    }
                    Text(detail)
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(DS.Typography.interface(size: 11, weight: .semibold))
                    .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(
                        isHovered || isRecommended ? DS.Colors.accent.opacity(isHovered ? 0.8 : 0.45) : DS.Colors.borderSubtle,
                        lineWidth: isRecommended ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(destination.scheme == "mailto" ? "Opens your mail app" : "Opens in your browser")
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}
