//
//  CompanionTurnLatencyTimeline.swift
//  elfhub
//
//  Measures where a turn's time goes — release of push-to-talk → transcript
//  → first reply text → first spoken audio → first screen action — so speed
//  work can be judged by numbers instead of feel.
//
//  Local only: each milestone is written to the macOS unified log (visible in
//  Console.app, filter "elfhub") and as a signpost for Instruments. Nothing
//  is stored or sent anywhere.
//

import Foundation
import OSLog

/// elfhub's unified-log channel. Use `privacy: .private` for anything the
/// user said or typed, so it never shows up in plain text in shared logs.
let companionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "elfhub", category: "companion")

@MainActor
final class CompanionTurnLatencyTimeline {

    enum Milestone: String, CaseIterable {
        case transcriptReady = "transcript ready"
        case firstReplyText = "first reply text"
        case firstSpeech = "first speech"
        case firstScreenAction = "first screen action"
    }

    enum TurnTrigger: String {
        case pushToTalkReleased = "push-to-talk released"
        case chatMessageSent = "chat message sent"
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "elfhub",
        category: "turn-latency"
    )

    private let currentInstant: () -> ContinuousClock.Instant
    private var turnStartInstant: ContinuousClock.Instant?
    private(set) var recordedMilestoneOffsets: [Milestone: Duration] = [:]

    init(currentInstant: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.currentInstant = currentInstant
    }

    /// Starts timing a new turn; earlier milestones are forgotten.
    func startTurn(trigger: TurnTrigger) {
        turnStartInstant = currentInstant()
        recordedMilestoneOffsets = [:]
        Self.signposter.emitEvent("turn started")
        companionLogger.info("⏱ turn started (\(trigger.rawValue, privacy: .public))")
    }

    /// Records a milestone the first time it happens in the current turn.
    /// Later repeats (every reply chunk is a "reply text") are ignored, as is
    /// anything that happens when no turn is being timed.
    func mark(_ milestone: Milestone) {
        guard let turnStartInstant, recordedMilestoneOffsets[milestone] == nil else { return }
        let offsetSinceTurnStart = currentInstant() - turnStartInstant
        recordedMilestoneOffsets[milestone] = offsetSinceTurnStart
        Self.signposter.emitEvent("turn milestone")
        companionLogger.info("⏱ +\(Self.milliseconds(of: offsetSinceTurnStart), privacy: .public) ms \(milestone.rawValue, privacy: .public)")
    }

    static func milliseconds(of duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
