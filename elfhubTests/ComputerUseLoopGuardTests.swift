//
//  ComputerUseLoopGuardTests.swift
//  elfhubTests
//
//  A multi-step run stops on its own: at the step and time budgets, after
//  three failed steps in a row, or when it keeps doing the same thing; it
//  is nudged first when it repeats itself or the screen stops changing.
//  The screenshot fingerprint tells "the screen changed" from "nothing
//  happened" without being fooled by a blinking text cursor.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import elfhub

struct ComputerUseLoopGuardTests {

    private let runStart = Date(timeIntervalSince1970: 1_000)

    private func click(_ x: Int, _ y: Int) -> CompanionScreenAction {
        .click(screenshotPixel: CGPoint(x: x, y: y), label: nil, screenNumber: nil)
    }

    @Test func stopsAtTheStepBudget() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        var verdicts: [ComputerUseGuardVerdict] = []
        for stepNumber in 1...loopGuard.limits.maximumSteps {
            verdicts.append(loopGuard.recordStep(actions: [click(stepNumber * 40, 10)], anyStepFailed: false, screenChanged: true, now: runStart))
        }
        #expect(verdicts.dropLast().allSatisfy { if case .keepGoing = $0 { return true }; return false })
        guard case .stopAndSummarize = verdicts.last else {
            Issue.record("expected the last step to end the run, got \(String(describing: verdicts.last))")
            return
        }
    }

    @Test func stopsWhenTimeRunsOut() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        let lateVerdict = loopGuard.recordStep(
            actions: [click(1, 1)], anyStepFailed: false, screenChanged: true,
            now: runStart.addingTimeInterval(loopGuard.limits.maximumActiveDurationInSeconds + 1)
        )
        guard case .stopAndSummarize = lateVerdict else {
            Issue.record("expected a time-out, got \(lateVerdict)")
            return
        }
    }

    // MARK: - Limits from Settings

    @Test func theLimitIsFifteenStepsUnlessAnotherChoiceIsSaved() throws {
        let userDefaultsSuiteName = "ComputerUseLoopGuardTests-\(UUID().uuidString)"
        let isolatedUserDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { isolatedUserDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        #expect(ComputerUseRunLimits.current(userDefaults: isolatedUserDefaults).maximumSteps == 15)
        isolatedUserDefaults.set(100, forKey: ComputerUseRunLimits.maximumStepsKey)
        #expect(ComputerUseRunLimits.current(userDefaults: isolatedUserDefaults).maximumSteps == 100)
        isolatedUserDefaults.set(7, forKey: ComputerUseRunLimits.maximumStepsKey)
        #expect(ComputerUseRunLimits.current(userDefaults: isolatedUserDefaults).maximumSteps == 15, "only the offered choices")
        #expect(ComputerUseRunLimits.stepChoices.first == 15)
        #expect(ComputerUseRunLimits.stepChoices == ComputerUseRunLimits.stepChoices.sorted())
    }

    @Test func timeAndModelRoundsScaleWithTheSteps() {
        #expect(ComputerUseRunLimits.standard.maximumActiveDurationInSeconds == 180, "15 steps keep the old 3 minutes")
        #expect(ComputerUseRunLimits(maximumSteps: 100).maximumActiveDurationInSeconds == 1_200)
        #expect(ComputerUseRunLimits(maximumSteps: 100).activeDurationDescription == "20 minutes")
        let limits = ComputerUseRunLimits(maximumSteps: 50)
        #expect(limits.maximumModelRounds == 50 + ComputerUseRunLimits.maximumWaitOnlyRounds + 1)
        #expect(limits.maximumWholeRunDurationInSeconds == limits.maximumActiveDurationInSeconds + ComputerUseRunLimits.maximumTotalWaitInSeconds)
    }

    @Test func aLongerLimitIsntStoppedAtFifteen() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart, limits: ComputerUseRunLimits(maximumSteps: 30))
        for stepNumber in 1...20 {
            let verdict = loopGuard.recordStep(actions: [click(stepNumber * 40, 10)], anyStepFailed: false, screenChanged: true, now: runStart)
            guard case .keepGoing = verdict else {
                Issue.record("step \(stepNumber) of 30 stopped the run: \(verdict)")
                return
            }
        }
    }

    // MARK: - Waiting

    @Test func waitingUsesNoStepsAndNoActiveTime() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        // Ten four-minute waits: far past 3 minutes of clock time…
        for waitNumber in 1...10 {
            loopGuard.recordWait(seconds: 240)
            let verdict = loopGuard.recordStep(
                actions: [], anyStepFailed: false, screenChanged: true, onlyWaited: true,
                now: runStart.addingTimeInterval(Double(waitNumber) * 245)
            )
            #expect(verdict == .keepGoing(note: nil), "wait \(waitNumber)")
        }
        // …but only 50 seconds of active time and no steps.
        #expect(loopGuard.stepsTaken == 0)
        #expect(loopGuard.activeSeconds(now: runStart.addingTimeInterval(2_450)) == 50)
        #expect(!loopGuard.hasRunOutOfActiveTime(now: runStart.addingTimeInterval(2_450)))
    }

    @Test func tooManyWaitsInARowStillEndTheRun() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        var lastVerdict = ComputerUseGuardVerdict.keepGoing(note: nil)
        for _ in 1...ComputerUseRunLimits.maximumWaitOnlyRounds {
            loopGuard.recordWait(seconds: 1)
            lastVerdict = loopGuard.recordStep(actions: [], anyStepFailed: false, screenChanged: nil, onlyWaited: true, now: runStart)
        }
        guard case .stopAndSummarize = lastVerdict else {
            Issue.record("expected polling with tiny waits to run out, got \(lastVerdict)")
            return
        }
    }

    @Test func waitsAreRefusedPastFiveMinutesOrPastTheRunsHalfHour() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        #expect(loopGuard.refusalForWait(seconds: 300) == nil)
        #expect(loopGuard.refusalForWait(seconds: 301) != nil)
        #expect(loopGuard.refusalForWait(seconds: 0) != nil)
        loopGuard.recordWait(seconds: ComputerUseRunLimits.maximumTotalWaitInSeconds - 60)
        #expect(loopGuard.refusalForWait(seconds: 60) == nil)
        #expect(loopGuard.refusalForWait(seconds: 61)?.contains("1 minutes of waiting left") == true)
    }

    @Test func stopsAfterThreeFailedStepsInARow() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        #expect(loopGuard.recordStep(actions: [click(1, 1)], anyStepFailed: true, screenChanged: false, now: runStart) == .keepGoing(note: nil))
        _ = loopGuard.recordStep(actions: [click(50, 1)], anyStepFailed: false, screenChanged: true, now: runStart)
        _ = loopGuard.recordStep(actions: [click(100, 1)], anyStepFailed: true, screenChanged: false, now: runStart)
        _ = loopGuard.recordStep(actions: [click(150, 1)], anyStepFailed: true, screenChanged: false, now: runStart)
        let thirdFailureVerdict = loopGuard.recordStep(actions: [click(200, 1)], anyStepFailed: true, screenChanged: false, now: runStart)
        guard case .stopAndSummarize = thirdFailureVerdict else {
            Issue.record("expected a stop after three failures in a row, got \(thirdFailureVerdict)")
            return
        }
    }

    @Test func repeatingTheSameClickIsNudgedThenStopped() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        // A few pixels apart is still the same click.
        let verdicts = (0..<ComputerUseLoopGuard.repeatedActionStopCount).map { attemptNumber in
            loopGuard.recordStep(actions: [click(300 + attemptNumber, 200)], anyStepFailed: false, screenChanged: true, now: runStart)
        }
        #expect(verdicts[0] == .keepGoing(note: nil))
        guard case let .keepGoing(nudgeNote) = verdicts[ComputerUseLoopGuard.repeatedActionNudgeCount - 1], nudgeNote != nil else {
            Issue.record("expected a nudge on the third identical click")
            return
        }
        guard case .stopAndSummarize = verdicts.last else {
            Issue.record("expected a stop on the fifth identical click")
            return
        }
    }

    @Test func aScreenThatStopsChangingIsNudged() {
        var loopGuard = ComputerUseLoopGuard(startedAt: runStart)
        _ = loopGuard.recordStep(actions: [click(10, 10)], anyStepFailed: false, screenChanged: false, now: runStart)
        _ = loopGuard.recordStep(actions: [click(60, 10)], anyStepFailed: false, screenChanged: false, now: runStart)
        let thirdUnchangedVerdict = loopGuard.recordStep(actions: [click(110, 10)], anyStepFailed: false, screenChanged: false, now: runStart)
        guard case let .keepGoing(nudgeNote) = thirdUnchangedVerdict, nudgeNote != nil else {
            Issue.record("expected a nudge after three steps with no change, got \(thirdUnchangedVerdict)")
            return
        }
        // Looking (a screenshot, zoom or wait) isn't a step that should change anything.
        var lookingGuard = ComputerUseLoopGuard(startedAt: runStart)
        for _ in 0..<4 {
            #expect(lookingGuard.recordStep(actions: [], anyStepFailed: false, screenChanged: false, now: runStart) == .keepGoing(note: nil))
        }
    }

    // MARK: - Fingerprint

    private func jpegData(drawing draw: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        draw(context)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    @Test func aPopUpOverTheTargetCountsAsChangedButThePointerDoesnt() throws {
        let before = jpegData { _ in }
        let pointerMoved = jpegData { $0.fill(CGRect(x: 640, y: 380, width: 14, height: 22)) }
        let dialogOpened = jpegData { $0.fill(CGRect(x: 450, y: 250, width: 380, height: 280)) }
        let target = CGPoint(x: 640, y: 400)
        let pointerChange = try #require(ScreenshotRegionComparison.changedFraction(beforeJPEG: before, afterJPEG: pointerMoved, aroundScreenshotPixel: target))
        let dialogChange = try #require(ScreenshotRegionComparison.changedFraction(beforeJPEG: before, afterJPEG: dialogOpened, aroundScreenshotPixel: target))
        #expect(pointerChange < ScreenshotRegionComparison.changedFractionThatMeansStale)
        #expect(dialogChange >= ScreenshotRegionComparison.changedFractionThatMeansStale)
        // Something changing elsewhere on screen doesn't matter.
        let elsewhere = jpegData { $0.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) }
        let elsewhereChange = try #require(ScreenshotRegionComparison.changedFraction(beforeJPEG: before, afterJPEG: elsewhere, aroundScreenshotPixel: target))
        #expect(elsewhereChange == 0)
    }

    @Test func theFingerprintSeesACheckboxButNotABlinkingCursor() throws {
        let blankScreen = try #require(ScreenshotFingerprint(jpegData: jpegData { _ in }))
        let sameBlankScreen = try #require(ScreenshotFingerprint(jpegData: jpegData { _ in }))
        let tickedCheckbox = try #require(ScreenshotFingerprint(jpegData: jpegData { $0.fill(CGRect(x: 600, y: 400, width: 16, height: 16)) }))
        let textCursor = try #require(ScreenshotFingerprint(jpegData: jpegData { $0.fill(CGRect(x: 600, y: 400, width: 1, height: 16)) }))
        #expect(!blankScreen.differs(from: sameBlankScreen))
        #expect(blankScreen.differs(from: tickedCheckbox))
        #expect(!blankScreen.differs(from: textCursor))
        #expect(ScreenshotFingerprint(jpegData: Data([1, 2, 3])) == nil)
    }
}
