//
//  ComputerUseAuditLogTests.swift
//  elfhubTests
//
//  The local action log: entries round-trip, typed text is never written,
//  turning it off writes nothing, and deleting removes it. Also the turn
//  latency timeline, which only counts each milestone once.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct ComputerUseAuditLogTests {

    private func makeTemporaryAuditLog() -> ComputerUseAuditLog {
        let logFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elfhub-tests-\(UUID().uuidString)")
            .appendingPathComponent("ActionLog.jsonl")
        let isolatedUserDefaults = UserDefaults(suiteName: "elfhub-tests-\(UUID().uuidString)")!
        return ComputerUseAuditLog(logFileURL: logFileURL, userDefaults: isolatedUserDefaults)
    }

    private func resolvedAction(_ action: CompanionScreenAction, title: String? = "Save") -> ResolvedScreenAction {
        ResolvedScreenAction(
            action: action,
            coreGraphicsTargetPoint: nil,
            appKitTargetPoint: nil,
            displayFrame: nil,
            targetElementFacts: AccessibilityElementFacts(
                frameInCoreGraphicsGlobalCoordinates: nil,
                role: "AXButton",
                subrole: nil,
                title: title,
                isSecureTextField: false,
                isDefaultButton: false,
                owningApplicationBundleIdentifier: "com.apple.TextEdit"
            ),
            frontmostApplicationBundleIdentifier: "com.apple.TextEdit",
            consentDecision: .requiresExplicitConfirmation(reason: "this would send something"),
            consequentialEffect: .send
        )
    }

    @Test func entriesRoundTripWithDecisionProvenanceAndOutcome() {
        let auditLog = makeTemporaryAuditLog()
        defer { auditLog.deleteLog() }

        auditLog.record(ComputerUseAuditEntry(
            resolvedAction: resolvedAction(.click(screenshotPixel: .zero, label: "save", screenNumber: nil)),
            approvalProvenance: .userSaidYes,
            outcome: .performed
        ))

        let loadedEntries = auditLog.loadEntries()
        #expect(loadedEntries.count == 1)
        #expect(loadedEntries.first?.actionKind == "click")
        #expect(loadedEntries.first?.actionSummary == "click “Save”")
        #expect(loadedEntries.first?.consentDecision == "confirm: this would send something")
        #expect(loadedEntries.first?.approvalProvenance == .userSaidYes)
        #expect(loadedEntries.first?.outcome == .performed)
        #expect(loadedEntries.first?.targetApplicationBundleIdentifier == "com.apple.TextEdit")
    }

    @Test func typedTextIsNeverWritten() throws {
        let auditLog = makeTemporaryAuditLog()
        defer { auditLog.deleteLog() }

        auditLog.record(ComputerUseAuditEntry(
            resolvedAction: resolvedAction(.type(text: "my home address is 12 Elm St")),
            approvalProvenance: .autoFireMode,
            outcome: .performed
        ))

        let rawLogText = try String(contentsOf: auditLog.logFileURL, encoding: .utf8)
        #expect(!rawLogText.contains("Elm"))
        #expect(auditLog.loadEntries().first?.actionSummary == "type 28 characters")
    }

    @Test func turningLoggingOffWritesNothing() {
        let auditLog = makeTemporaryAuditLog()
        defer { auditLog.setLoggingEnabled(true) }
        auditLog.setLoggingEnabled(false)

        auditLog.record(ComputerUseAuditEntry(
            resolvedAction: resolvedAction(.key(comboString: "cmd+s")),
            approvalProvenance: .userClickedConfirm,
            outcome: .performed
        ))

        #expect(auditLog.loadEntries().isEmpty)
        #expect(auditLog.logFileSizeInBytes() == 0)
    }

    @Test func deletingRemovesTheLog() {
        let auditLog = makeTemporaryAuditLog()
        auditLog.record(ComputerUseAuditEntry(
            resolvedAction: resolvedAction(.key(comboString: "cmd+s")),
            approvalProvenance: nil,
            outcome: .declinedOrDropped
        ))
        #expect(auditLog.logFileSizeInBytes() > 0)
        auditLog.deleteLog()
        #expect(auditLog.loadEntries().isEmpty)
    }

    // MARK: - Turn latency timeline

    @Test func latencyTimelineCountsEachMilestoneOnceAndOnlyDuringATurn() {
        var fakeNow = ContinuousClock.now
        let latencyTimeline = CompanionTurnLatencyTimeline(currentInstant: { fakeNow })

        // Before any turn starts, milestones are ignored.
        latencyTimeline.mark(.firstReplyText)
        #expect(latencyTimeline.recordedMilestoneOffsets.isEmpty)

        latencyTimeline.startTurn(trigger: .pushToTalkReleased)
        fakeNow = fakeNow.advanced(by: .milliseconds(250))
        latencyTimeline.mark(.transcriptReady)
        fakeNow = fakeNow.advanced(by: .milliseconds(650))
        latencyTimeline.mark(.firstReplyText)
        fakeNow = fakeNow.advanced(by: .milliseconds(400))
        latencyTimeline.mark(.firstReplyText)

        #expect(latencyTimeline.recordedMilestoneOffsets[.transcriptReady].map(CompanionTurnLatencyTimeline.milliseconds(of:)) == 250)
        #expect(latencyTimeline.recordedMilestoneOffsets[.firstReplyText].map(CompanionTurnLatencyTimeline.milliseconds(of:)) == 900)

        latencyTimeline.startTurn(trigger: .chatMessageSent)
        #expect(latencyTimeline.recordedMilestoneOffsets.isEmpty)
    }
}
