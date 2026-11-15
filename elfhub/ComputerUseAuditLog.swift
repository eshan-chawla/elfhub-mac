//
//  ComputerUseAuditLog.swift
//  elfhub
//
//  A local record of every screen action elfhub considered: what it was, the
//  real element it landed on, how consent was decided, who approved it and
//  what happened. It answers "what did elfhub do on my Mac, and why?" after
//  the fact — the receipt trail the industry practice calls for.
//
//  Privacy: the log stays in ~/Library/Application Support/elfhub and is
//  never sent anywhere. Typed text is never written (only its length), and
//  the file is trimmed so it can't grow without bound. It can be turned off,
//  revealed and deleted in Settings › Privacy.
//

import AppKit
import Combine
import Foundation

/// What finally happened to one action.
enum ComputerUseAuditOutcome: String, Codable {
    /// The events (or Accessibility action) were posted.
    case performed
    /// Tried, but it couldn't be done (unknown key, password field at type time…).
    case notPerformed
    /// The user pressed Esc or took over the mouse/keyboard first.
    case stoppedByUser
    /// The approved target was no longer under the pointer when it was time to fire.
    case screenChanged
    /// A re-check found it riskier than approved; the chain paused to ask again.
    case pausedForFreshApproval
    /// A password field, secure input or private app: handed back to the user.
    case handedToUser
    /// The user said no, the card timed out, or a new request replaced it.
    case declinedOrDropped
}

/// One line of the action log.
struct ComputerUseAuditEntry: Codable, Equatable {
    let date: Date
    /// "click", "type", "key", …
    let actionKind: String
    /// Human-readable action without any typed text, e.g. "click “Save”" or "type 12 characters".
    let actionSummary: String
    let targetRole: String?
    let targetTitle: String?
    let targetApplicationBundleIdentifier: String?
    let webPageHost: String?
    let frontmostApplicationBundleIdentifier: String?
    /// "proceed", "confirm: this would send something", "user's step: …".
    let consentDecision: String
    let approvalProvenance: ScreenActionApprovalProvenance?
    let outcome: ComputerUseAuditOutcome
}

extension ComputerUseAuditEntry {

    init(
        resolvedAction: ResolvedScreenAction,
        approvalProvenance: ScreenActionApprovalProvenance?,
        outcome: ComputerUseAuditOutcome,
        date: Date = Date()
    ) {
        self.init(
            date: date,
            actionKind: Self.actionKindName(of: resolvedAction.action),
            actionSummary: Self.summaryWithoutTypedText(of: resolvedAction),
            targetRole: resolvedAction.targetElementFacts?.role,
            targetTitle: resolvedAction.targetElementFacts?.title,
            targetApplicationBundleIdentifier: resolvedAction.targetElementFacts?.owningApplicationBundleIdentifier,
            webPageHost: resolvedAction.targetElementFacts?.webPageHost,
            frontmostApplicationBundleIdentifier: resolvedAction.frontmostApplicationBundleIdentifier,
            consentDecision: Self.describe(resolvedAction.consentDecision),
            approvalProvenance: approvalProvenance,
            outcome: outcome
        )
    }

    static func actionKindName(of action: CompanionScreenAction) -> String {
        switch action {
        case .click: return "click"
        case .doubleClick: return "double_click"
        case .scroll: return "scroll"
        case .type: return "type"
        case .key: return "key"
        case .rightClick: return "right_click"
        case .tripleClick: return "triple_click"
        case .drag: return "drag"
        case .moveMouse: return "move_mouse"
        case .openApplication: return "open_app"
        case .openWebsite: return "open_website"
        }
    }

    /// Typed text can be anything the user dictated (an address, a message),
    /// so the log keeps only how long it was.
    static func summaryWithoutTypedText(of resolvedAction: ResolvedScreenAction) -> String {
        if case let .type(text) = resolvedAction.action {
            return "type \(text.count) characters"
        }
        return resolvedAction.humanReadableDescription
    }

    static func describe(_ consentDecision: ScreenActionConsentDecision) -> String {
        switch consentDecision {
        case .proceedWithPreview: return "proceed"
        case let .requiresExplicitConfirmation(reason): return "confirm: \(reason)"
        case let .usersStep(reason): return "user's step: \(reason)"
        }
    }
}

@MainActor
final class ComputerUseAuditLog: ObservableObject {

    static let shared = ComputerUseAuditLog()

    /// On by default: it's local, and it's how the user can check what elfhub did.
    @Published private(set) var isLoggingEnabled: Bool
    /// Bumped on every write or delete so settings views refresh the size.
    @Published private(set) var logRevision = 0

    private static let loggingEnabledKey = "isComputerUseAuditLogEnabled"
    /// Past this size the oldest half of the log is dropped.
    static let maximumLogFileSizeInBytes = 2_000_000

    let logFileURL: URL

    init(logFileURL: URL = ComputerUseAuditLog.defaultLogFileURL, userDefaults: UserDefaults = .standard) {
        self.logFileURL = logFileURL
        self.isLoggingEnabled = userDefaults.object(forKey: Self.loggingEnabledKey) as? Bool ?? true
    }

    nonisolated static var defaultLogFileURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportDirectoryURL
            .appendingPathComponent("elfhub", isDirectory: true)
            .appendingPathComponent("ActionLog.jsonl")
    }

    func setLoggingEnabled(_ enabled: Bool) {
        isLoggingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.loggingEnabledKey)
    }

    /// Appends one entry as a line of JSON. Failures are only printed: the
    /// log must never get in the way of the action itself.
    func record(_ entry: ComputerUseAuditEntry) {
        guard isLoggingEnabled else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var lineData = try encoder.encode(entry)
            lineData.append(0x0A)

            try FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                defer { try? fileHandle.close() }
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: logFileURL, options: .atomic)
            }
            trimIfTooLarge()
            logRevision += 1
        } catch {
            print("⚠️ Action log: couldn't write an entry: \(error)")
        }
    }

    /// Every entry, oldest first. Lines that don't decode are skipped.
    func loadEntries() -> [ComputerUseAuditEntry] {
        guard let logData = try? Data(contentsOf: logFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return logData
            .split(separator: 0x0A)
            .compactMap { lineData in try? decoder.decode(ComputerUseAuditEntry.self, from: Data(lineData)) }
    }

    func logFileSizeInBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func deleteLog() {
        try? FileManager.default.removeItem(at: logFileURL)
        logRevision += 1
    }

    func revealLogInFinder() {
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
        } else {
            NSWorkspace.shared.open(logFileURL.deletingLastPathComponent())
        }
    }

    /// Keeps the newest half of the lines once the file passes the size cap.
    private func trimIfTooLarge() {
        guard logFileSizeInBytes() > Self.maximumLogFileSizeInBytes,
              let logData = try? Data(contentsOf: logFileURL) else { return }
        let lines = logData.split(separator: 0x0A)
        let newestHalfOfLines = lines.suffix(lines.count / 2)
        var trimmedLogData = Data()
        for line in newestHalfOfLines {
            trimmedLogData.append(contentsOf: line)
            trimmedLogData.append(0x0A)
        }
        try? trimmedLogData.write(to: logFileURL, options: .atomic)
    }
}
