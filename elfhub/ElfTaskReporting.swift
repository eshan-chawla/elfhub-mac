//
//  ElfTaskReporting.swift
//  elfhub
//
//  How finished background work reaches the user. A soft earcon and a pill
//  line always; the main elf speaks a short summary right away when the
//  user is idle (not talking, not waiting on a reply, nothing acting), and
//  otherwise mentions it at the start of its next reply. What the main elf
//  should know about tasks reaches it as an `[elfhub status]` block put in
//  front of the user's newest message — not in the system prompt, so
//  Claude's prompt cache keeps working.
//

import Foundation

nonisolated enum ElfTaskReportDelivery: Equatable, Sendable {
    /// Earcon, pill, and the main elf says it now.
    case speakNow
    /// Earcon and pill now; the main elf mentions it at the start of its
    /// next reply.
    case mentionNextTurn
    /// Spoken reports are switched off: earcon and pill, then mentioned in
    /// the next reply.
    case showOnlyAndMentionNextTurn
}

/// What the user is told about a task, spoken and in chat.
nonisolated enum ElfTaskReportText {
    static func report(for elfTask: ElfTask, elfName: String) -> String {
        let quotedInstruction = "“\(elfTask.instruction)”"
        switch elfTask.status {
        case .done:
            return "\(elfName) finished \(quotedInstruction): \(elfTask.result?.summary ?? "done.")"
        case .failed:
            let failureReason = (elfTask.failureReason ?? "it stopped").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "\(elfName) couldn't finish \(quotedInstruction): \(failureReason)."
        case .needsInput:
            return "\(elfName) asks about \(quotedInstruction): \(elfTask.pendingQuestion ?? "")"
        case .cancelled:
            return "\(elfName) stopped \(quotedInstruction)."
        case .queued, .running:
            return "\(elfName) is working on \(quotedInstruction)."
        }
    }
}

nonisolated enum ElfTaskReportPlanner {
    static func plan(
        isVoiceIdle: Bool,
        isRecording: Bool,
        isReplyStreaming: Bool,
        areActionsRunning: Bool,
        speaksReports: Bool
    ) -> ElfTaskReportDelivery {
        guard speaksReports else { return .showOnlyAndMentionNextTurn }
        let userIsIdle = isVoiceIdle && !isRecording && !isReplyStreaming && !areActionsRunning
        return userIsIdle ? .speakNow : .mentionNextTurn
    }
}

/// A status block for the main elf's next turn and the finished tasks it
/// reports (marked reported once the turn succeeds).
struct ElfMainStatusUpdate {
    let text: String
    let reportedTaskIdentifiers: [UUID]
}

nonisolated enum ElfStatusBlock {
    /// The task ids the model sees: short and easy to repeat back.
    static func shortTaskIdentifier(_ taskIdentifier: UUID) -> String {
        String(taskIdentifier.uuidString.prefix(8)).lowercased()
    }

    /// What the main elf is told about background work before the user's
    /// newest message, or nil when there's nothing to tell.
    static func text(
        unreportedFinishedTasks: [ElfTask],
        runningTasks: [ElfTask],
        tasksWaitingForAnswers: [ElfTask],
        elfNameForIdentifier: (String) -> String
    ) -> String? {
        var statusLines: [String] = []
        for finishedTask in unreportedFinishedTasks {
            let elfName = elfNameForIdentifier(finishedTask.elfIdentifier)
            switch finishedTask.status {
            case .done:
                var finishedLine = "- \(elfName) finished \"\(finishedTask.instruction)\": \(finishedTask.result?.summary ?? "done.")"
                if let filePaths = finishedTask.result?.filePaths, !filePaths.isEmpty {
                    finishedLine += " (files: " + filePaths.joined(separator: ", ") + ")"
                }
                statusLines.append(finishedLine)
            case .failed:
                statusLines.append("- \(elfName) couldn't finish \"\(finishedTask.instruction)\": \(finishedTask.failureReason ?? "it stopped.")")
            default:
                continue
            }
        }
        for runningTask in runningTasks {
            statusLines.append("- \(elfNameForIdentifier(runningTask.elfIdentifier)) is working on \"\(runningTask.instruction)\" (task \(shortTaskIdentifier(runningTask.id))).")
        }
        for askingTask in tasksWaitingForAnswers {
            guard let pendingQuestion = askingTask.pendingQuestion else { continue }
            statusLines.append("- \(elfNameForIdentifier(askingTask.elfIdentifier)) asks (task \(shortTaskIdentifier(askingTask.id))): \(pendingQuestion)")
        }
        guard !statusLines.isEmpty else { return nil }
        return "[elfhub status] background work since your last reply — tell the user about finished work briefly, first:\n"
            + statusLines.joined(separator: "\n")
    }
}
