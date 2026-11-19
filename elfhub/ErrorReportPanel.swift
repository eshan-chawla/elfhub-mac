//
//  ErrorReportPanel.swift
//  elfhub
//
//  When a turn or a background task fails with an error worth reporting
//  (ErrorReportEligibility), a window offers to file it as a GitHub issue.
//  ErrorReportPresenter gathers what's useful — where elfhub caught it, the
//  last few minutes of its own log, the model and versions — redacts it
//  (ErrorReportRedactor, with the user's stored keys by exact value), and
//  shows the whole issue for the user to read and edit.
//
//  Nothing leaves the Mac from here on its own. Return (or Open on GitHub)
//  opens GitHub's new-issue page in the browser with the edited text filled
//  in; the issue is only filed when the user presses Submit there. Each
//  error is offered once per launch, never in the unit-test host, and not
//  at all with Settings › General "Offer to report problems" off.
//

import AppKit
import OSLog
import SwiftUI

// MARK: - Presenter

@MainActor
final class ErrorReportPresenter {
    /// The current model and screen-action mode, read when an error is
    /// offered (CompanionManager sets it).
    var currentSetupDescription: () -> (modelDescription: String?, screenActionsDescription: String?) = { (nil, nil) }

    private var offeredErrorSignatures: Set<String> = []
    private var reportPanel: NSPanel?

    /// Pure, so the rule can be tested.
    nonisolated static func shouldOffer(
        error: Error,
        offersReports: Bool,
        alreadyOfferedSignatures: Set<String>,
        isShowingAReport: Bool
    ) -> Bool {
        offersReports
            && !isShowingAReport
            && ErrorReportEligibility.shouldOfferReport(for: error)
            && !alreadyOfferedSignatures.contains(ErrorReportEligibility.signature(for: error))
    }

    func offerReport(for error: Error, origin: ErrorReportContext.Origin) {
        // The test host never puts windows over the user's screen.
        guard !CompanionManager.isRunningUnitTests else { return }
        guard Self.shouldOffer(
            error: error,
            offersReports: ErrorReportSettings.offersReports(),
            alreadyOfferedSignatures: offeredErrorSignatures,
            isShowingAReport: reportPanel != nil
        ) else { return }
        offeredErrorSignatures.insert(ErrorReportEligibility.signature(for: error))

        // Taken now, while the stack still shows where it was caught.
        let callStackSymbols = Thread.callStackSymbols
        let setupDescription = currentSetupDescription()
        let errorDescription = error.localizedDescription
        let errorTypeName = ErrorReportComposer.errorTypeName(for: error)
        let logSubsystem = Bundle.main.bundleIdentifier ?? "elfhub"

        Task {
            // Reading the log and the Keychain can take a moment.
            let composedReport = await Task.detached(priority: .utility) { () -> ErrorReport in
                let context = ErrorReportContext(
                    errorDescription: errorDescription,
                    errorTypeName: errorTypeName,
                    origin: origin,
                    modelDescription: setupDescription.modelDescription,
                    screenActionsDescription: setupDescription.screenActionsDescription,
                    stackFrames: ErrorReportStackTrace.relevantFrames(fromCallStackSymbols: callStackSymbols),
                    recentLogLines: ErrorReportLogReader.recentLogLines(subsystem: logSubsystem),
                    supportDiagnostics: .current
                )
                return ErrorReportComposer.compose(
                    context,
                    knownSecrets: KeychainSecretStore.allStoredSecrets().flatMap(ErrorReportRedactor.secretValues(fromStoredSecret:)),
                    personalStrings: ErrorReportPersonalStrings.current()
                )
            }.value
            showReportPanel(composedReport)
        }
    }

    private func showReportPanel(_ report: ErrorReport) {
        guard reportPanel == nil else { return }
        let reportView = ErrorReportView(
            initialReport: report,
            onOpenOnGitHub: { [weak self] editedReport in
                self?.openOnGitHub(editedReport)
            },
            onDismiss: { [weak self] in
                self?.closeReportPanel()
            }
        )
        let hostingView = ErrorReportFirstClickHostingView(rootView: reportView)
        let panelSize = CGSize(width: ErrorReportView.width, height: ErrorReportView.height)
        let targetScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visibleScreenFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelOrigin = CGPoint(
            x: visibleScreenFrame.midX - panelSize.width / 2,
            y: visibleScreenFrame.midY - panelSize.height / 2
        )
        let reportPanel = ErrorReportNSPanel(
            contentRect: NSRect(origin: panelOrigin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        reportPanel.isFloatingPanel = true
        reportPanel.level = .floating
        reportPanel.isOpaque = false
        reportPanel.backgroundColor = .clear
        reportPanel.hasShadow = false
        reportPanel.hidesOnDeactivate = false
        reportPanel.isMovableByWindowBackground = true
        reportPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        reportPanel.contentView = hostingView
        reportPanel.orderFrontRegardless()
        // Takes the keyboard only while the user is in elfhub, so a report
        // appearing during a voice turn never swallows typing in their app;
        // there, one click on it does.
        if NSApp.isActive {
            reportPanel.makeKey()
        }
        self.reportPanel = reportPanel
    }

    private func openOnGitHub(_ editedReport: ErrorReport) {
        guard let newIssuePageURL = SupportLinks.published.gitHubNewIssueURL,
              let (issueURL, isShortened) = ErrorReportComposer.newIssueURL(for: editedReport, newIssuePageURL: newIssuePageURL) else {
            return
        }
        if isShortened {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(editedReport.body, forType: .string)
        }
        NSWorkspace.shared.open(issueURL)
        closeReportPanel()
    }

    private func closeReportPanel() {
        reportPanel?.orderOut(nil)
        reportPanel = nil
    }
}

/// Borderless panels can't become key by default; this one must, so the
/// user can edit the text and Return opens it.
private final class ErrorReportNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The first click on the panel (while another app is active) goes to what
/// it lands on instead of only making the panel key.
private final class ErrorReportFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - What goes into the report from this Mac

/// The last few minutes of elfhub's own log (the turn timings, screen steps
/// and so on). Values logged as private come back as "<private>".
nonisolated enum ErrorReportLogReader {
    static func recentLogLines(subsystem: String, sinceSecondsAgo: TimeInterval = 300) -> [String] {
        guard let logStore = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let startPosition = logStore.position(date: Date().addingTimeInterval(-sinceSecondsAgo))
        let subsystemPredicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let logEntries = try? logStore.getEntries(at: startPosition, matching: subsystemPredicate) else { return [] }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SSS"
        var logLines: [String] = []
        for logEntry in logEntries {
            guard let logEntryLog = logEntry as? OSLogEntryLog else { continue }
            logLines.append("\(timeFormatter.string(from: logEntryLog.date)) [\(logEntryLog.category)] \(logEntryLog.composedMessage)")
        }
        return Array(logLines.suffix(ErrorReportComposer.maximumRecentLogLineCount))
    }
}

/// The names that identify the user on this Mac: their account name, full
/// name (and each part of it) and the computer's name.
nonisolated enum ErrorReportPersonalStrings {
    static func current() -> [String] {
        let fullUserName = NSFullUserName()
        var personalStrings = [NSUserName(), fullUserName]
        personalStrings += fullUserName.split(separator: " ").map(String.init)
        if let computerName = Host.current().localizedName {
            personalStrings.append(computerName)
        }
        let hostName = ProcessInfo.processInfo.hostName
        personalStrings.append(hostName)
        if hostName.hasSuffix(".local") {
            personalStrings.append(String(hostName.dropLast(".local".count)))
        }
        return personalStrings.filter { $0.count >= 3 }
    }
}

// MARK: - Window content

struct ErrorReportView: View {
    static let width: CGFloat = 660
    static let height: CGFloat = 620

    let initialReport: ErrorReport
    let onOpenOnGitHub: (ErrorReport) -> Void
    let onDismiss: () -> Void

    @State private var titleText: String
    @State private var bodyText: String
    /// Return and clicks only count after a moment, so a key already on its
    /// way somewhere else can't open the report unseen.
    @State private var acceptsAnswers = false
    nonisolated static let answerArmingDelaySeconds: Double = 0.6

    init(initialReport: ErrorReport, onOpenOnGitHub: @escaping (ErrorReport) -> Void, onDismiss: @escaping () -> Void) {
        self.initialReport = initialReport
        self.onOpenOnGitHub = onOpenOnGitHub
        self.onDismiss = onDismiss
        _titleText = State(initialValue: initialReport.title)
        _bodyText = State(initialValue: initialReport.body)
    }

    private var editedReport: ErrorReport {
        ErrorReport(title: titleText, body: bodyText)
    }

    private var isTooLongForALink: Bool {
        guard let newIssuePageURL = SupportLinks.published.gitHubNewIssueURL else { return false }
        return ErrorReportComposer.newIssueURL(for: editedReport, newIssuePageURL: newIssuePageURL)?.isShortened ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.bubble")
                    .font(DS.Typography.interface(size: 18, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Something went wrong")
                        .font(DS.Typography.headingMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Help fix it by opening a GitHub issue. Read and edit it first — nothing is sent until you press Submit on GitHub.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(DS.Typography.smallMedium)
                    .foregroundColor(DS.Colors.textSecondary)
                TextField("Title", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.body)
                    .onSubmit(openOnGitHubIfReady)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Issue")
                    .font(DS.Typography.smallMedium)
                    .foregroundColor(DS.Colors.textSecondary)
                // The system monospaced font: no ligatures, so "<!--" and
                // "-->" look exactly as they'll be posted.
                TextEditor(text: $bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(DS.Typography.interface(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(privacyNote)
                    .font(DS.Typography.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(titleText + "\n\n" + bodyText, forType: .string)
                }
                .dsSecondaryButtonStyle(size: .small)
                .pointerCursor()

                Spacer()

                Button(action: onDismiss) {
                    HStack(spacing: 6) {
                        Text("Not now")
                        Text("esc")
                            .font(DS.Typography.interface(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .dsSecondaryButtonStyle(size: .small)
                .keyboardShortcut(.cancelAction)
                .pointerCursor()

                Button(action: openOnGitHubIfReady) {
                    HStack(spacing: 6) {
                        Text("Open on GitHub")
                        Image(systemName: "return")
                            .font(DS.Typography.interface(size: 11, weight: .semibold))
                    }
                }
                .dsPrimaryButtonStyle(size: .small)
                .keyboardShortcut(.defaultAction)
                .disabled(!acceptsAnswers || titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor(isEnabled: acceptsAnswers)
            }
            // ⌘Return also opens it while the cursor is in the issue text,
            // where Return starts a new line.
            .background(
                Button("", action: openOnGitHubIfReady)
                    .keyboardShortcut(.return, modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            )
        }
        .padding(20)
        .frame(width: Self.width - 24, height: Self.height - 24)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .dsShadow(.large)
        .padding(12)
        .tint(DS.Colors.controlTint)
        .task {
            try? await Task.sleep(for: .seconds(Self.answerArmingDelaySeconds))
            acceptsAnswers = true
        }
    }

    private var privacyNote: String {
        var privacyNote = "Keys, tokens, emails, names, addresses and personal numbers we found were replaced with [REDACTED …]. The issue will be public, so check nothing personal is left. Return opens it on GitHub (⌘Return while editing the text)."
        if isTooLongForALink {
            privacyNote += " It's too long for a link, so the full text will be copied for you to paste."
        }
        return privacyNote
    }

    private func openOnGitHubIfReady() {
        guard acceptsAnswers, !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onOpenOnGitHub(editedReport)
    }
}
