//
//  ComputerUseLoopGuard.swift
//  elfhub
//
//  Keeps a multi-step run on the user's screen from going on forever or
//  going in circles. Pure, so every rule is unit-tested:
//   - budgets: at most 15 steps and 3 minutes per run;
//   - three failed steps in a row end the run;
//   - the same action again and again is nudged at 3 and ends the run at 5;
//   - three acting steps in a row that changed nothing on screen get a
//     nudge to try something else or stop and tell the user.
//  A nudge goes back to the model with that step's result; a stop makes
//  the model sum up what it did, honestly, with no more steps.
//
//  ScreenshotFingerprint tells "the screen changed" from "nothing
//  happened", from a 16×16 grid of average brightness: a ticked checkbox
//  moves its cell, a blinking text cursor doesn't.
//

import CoreGraphics
import Foundation
import ImageIO

enum ComputerUseGuardVerdict: Equatable {
    /// Carry on; the note (when there is one) goes back to the model.
    case keepGoing(note: String?)
    /// No more steps: the model answers with what it did and didn't do.
    case stopAndSummarize(reason: String)
}

struct ComputerUseLoopGuard {
    static let maximumSteps = 15
    static let maximumRunDurationInSeconds: TimeInterval = 180
    static let maximumConsecutiveFailures = 3
    static let repeatedActionNudgeCount = 3
    static let repeatedActionStopCount = 5
    static let unchangedScreenNudgeCount = 3
    /// Clicks this close together count as the same click.
    static let samePlaceGridInPixels: CGFloat = 10

    let startedAt: Date
    private(set) var stepsTaken = 0
    private var consecutiveFailureCount = 0
    private var consecutiveUnchangedActingStepCount = 0
    private var occurrenceCountByActionSignature: [String: Int] = [:]

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Records one step (one model round's batch) and says whether to go on.
    /// `actions` are what it did on screen (empty when it only looked);
    /// `screenChanged` is nil when that wasn't measured.
    mutating func recordStep(
        actions: [CompanionScreenAction],
        anyStepFailed: Bool,
        screenChanged: Bool?,
        now: Date
    ) -> ComputerUseGuardVerdict {
        stepsTaken += 1
        consecutiveFailureCount = anyStepFailed ? consecutiveFailureCount + 1 : 0

        var highestRepeatCount = 0
        for action in actions {
            guard let actionSignature = Self.repetitionSignature(of: action) else { continue }
            occurrenceCountByActionSignature[actionSignature, default: 0] += 1
            highestRepeatCount = max(highestRepeatCount, occurrenceCountByActionSignature[actionSignature] ?? 0)
        }

        if !actions.isEmpty, let screenChanged {
            consecutiveUnchangedActingStepCount = screenChanged ? 0 : consecutiveUnchangedActingStepCount + 1
        }

        if consecutiveFailureCount >= Self.maximumConsecutiveFailures {
            return .stopAndSummarize(reason: "the last \(Self.maximumConsecutiveFailures) steps failed")
        }
        if highestRepeatCount >= Self.repeatedActionStopCount {
            return .stopAndSummarize(reason: "it kept repeating the same action without getting anywhere")
        }
        if stepsTaken >= Self.maximumSteps {
            return .stopAndSummarize(reason: "it used all \(Self.maximumSteps) steps")
        }
        if now.timeIntervalSince(startedAt) >= Self.maximumRunDurationInSeconds {
            return .stopAndSummarize(reason: "it ran out of time (\(Int(Self.maximumRunDurationInSeconds / 60)) minutes)")
        }
        if highestRepeatCount >= Self.repeatedActionNudgeCount {
            return .keepGoing(note: "you've done this same action \(highestRepeatCount) times. if it isn't working, try a different way (a keyboard shortcut, a menu), or stop and tell the user what's in the way.")
        }
        if consecutiveUnchangedActingStepCount >= Self.unchangedScreenNudgeCount {
            consecutiveUnchangedActingStepCount = 0
            return .keepGoing(note: "the screen hasn't changed for the last \(Self.unchangedScreenNudgeCount) steps. try a different approach, or stop and tell the user what's in the way.")
        }
        if stepsTaken == Self.maximumSteps * 3 / 4 {
            return .keepGoing(note: "you have \(Self.maximumSteps - stepsTaken) steps left. wrap up, or stop and tell the user where things stand.")
        }
        return .keepGoing(note: nil)
    }

    /// Which actions count as "the same again". Scrolling and key presses
    /// are often legitimately repeated, so only pointer actions and typing
    /// count; positions are compared on a 10-pixel grid.
    static func repetitionSignature(of action: CompanionScreenAction) -> String? {
        func gridCell(_ point: CGPoint) -> String {
            "\(Int((point.x / samePlaceGridInPixels).rounded(.down))),\(Int((point.y / samePlaceGridInPixels).rounded(.down)))"
        }
        switch action {
        case let .click(screenshotPixel, _, _): return "click@" + gridCell(screenshotPixel)
        case let .doubleClick(screenshotPixel, _, _): return "double@" + gridCell(screenshotPixel)
        case let .rightClick(screenshotPixel, _, _): return "right@" + gridCell(screenshotPixel)
        case let .tripleClick(screenshotPixel, _, _): return "triple@" + gridCell(screenshotPixel)
        case let .drag(startPixel, endPixel, _): return "drag@" + gridCell(startPixel) + ">" + gridCell(endPixel)
        case let .type(text): return "type:" + text
        case let .openApplication(name): return "open:" + name.lowercased()
        case let .openWebsite(url): return "open:" + url.absoluteString
        case let .withModifierKeys(modifierNames, innerAction):
            return repetitionSignature(of: innerAction).map { modifierNames.joined(separator: "+") + "+" + $0 }
        case .scroll, .key, .moveMouse: return nil
        }
    }
}

/// A screenshot reduced to a 16×16 grid of average brightness, to tell
/// whether the screen changed between two captures.
struct ScreenshotFingerprint: Equatable {
    static let gridSize = 16
    /// How far (0–255) one cell's average must move to count as a change.
    static let changedCellBrightnessThreshold = 4

    let cellBrightnessValues: [UInt8]

    init?(jpegData: Data) {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        self.init(image: image)
    }

    init?(image: CGImage) {
        let gridSize = Self.gridSize
        var cellBrightnessValues = [UInt8](repeating: 0, count: gridSize * gridSize)
        let didDraw = cellBrightnessValues.withUnsafeMutableBytes { bufferPointer -> Bool in
            guard let context = CGContext(
                data: bufferPointer.baseAddress,
                width: gridSize,
                height: gridSize,
                bitsPerComponent: 8,
                bytesPerRow: gridSize,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // Averaging, not sampling: each cell is the mean of its area.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
            return true
        }
        guard didDraw else { return nil }
        self.cellBrightnessValues = cellBrightnessValues
    }

    /// The share (0–1) of cells whose brightness moved past the threshold.
    func changedCellFraction(comparedTo otherFingerprint: ScreenshotFingerprint) -> Double {
        guard cellBrightnessValues.count == otherFingerprint.cellBrightnessValues.count, !cellBrightnessValues.isEmpty else { return 1 }
        let changedCellCount = zip(cellBrightnessValues, otherFingerprint.cellBrightnessValues).filter { cellBrightness, otherCellBrightness in
            abs(Int(cellBrightness) - Int(otherCellBrightness)) >= Self.changedCellBrightnessThreshold
        }.count
        return Double(changedCellCount) / Double(cellBrightnessValues.count)
    }

    func differs(from otherFingerprint: ScreenshotFingerprint) -> Bool {
        guard cellBrightnessValues.count == otherFingerprint.cellBrightnessValues.count else { return true }
        return zip(cellBrightnessValues, otherFingerprint.cellBrightnessValues).contains { cellBrightness, otherCellBrightness in
            abs(Int(cellBrightness) - Int(otherCellBrightness)) >= Self.changedCellBrightnessThreshold
        }
    }
}

/// Whether the part of the screen around a click target changed between
/// the screenshot the model decided from and now — a dialog popped up, the
/// page moved on — so the click would land on something it never saw.
/// The pointer moving or a button lighting up under it changes too little
/// to count.
enum ScreenshotRegionComparison {
    /// Half the side of the square compared, in screen points (turned into
    /// screenshot pixels by the caller, so it means the same on every model).
    static let regionRadiusInPoints: CGFloat = 120
    /// This share of the region's cells changed means it's stale.
    static let changedFractionThatMeansStale = 0.3
    /// The patch right at the target: a small pop-up there (an autocomplete
    /// list) is a tenth of the region but most of this.
    static let targetPatchShareOfRadius: CGFloat = 0.3
    static let targetPatchChangedFractionThatMeansStale = 0.5

    /// Whether the click target's surroundings, or the patch right at it,
    /// changed enough that the click would land on something unseen.
    static func isStale(beforeJPEG: Data, afterJPEG: Data, aroundScreenshotPixel screenshotPixel: CGPoint, regionRadiusInPixels: CGFloat) -> Bool {
        if let regionChange = changedFraction(beforeJPEG: beforeJPEG, afterJPEG: afterJPEG, aroundScreenshotPixel: screenshotPixel, regionRadiusInPixels: regionRadiusInPixels),
           regionChange >= changedFractionThatMeansStale {
            return true
        }
        if let patchChange = changedFraction(beforeJPEG: beforeJPEG, afterJPEG: afterJPEG, aroundScreenshotPixel: screenshotPixel, regionRadiusInPixels: regionRadiusInPixels * targetPatchShareOfRadius),
           patchChange >= targetPatchChangedFractionThatMeansStale {
            return true
        }
        return false
    }

    /// The share (0–1) of the region's 16×16 cells whose brightness moved,
    /// or nil when an image can't be read.
    static func changedFraction(beforeJPEG: Data, afterJPEG: Data, aroundScreenshotPixel screenshotPixel: CGPoint, regionRadiusInPixels: CGFloat = 120) -> Double? {
        guard let beforeImage = decodedImage(beforeJPEG), let afterImage = decodedImage(afterJPEG),
              beforeImage.width == afterImage.width, beforeImage.height == afterImage.height else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: beforeImage.width, height: beforeImage.height)
        let region = CGRect(
            x: screenshotPixel.x - regionRadiusInPixels,
            y: screenshotPixel.y - regionRadiusInPixels,
            width: regionRadiusInPixels * 2,
            height: regionRadiusInPixels * 2
        ).intersection(imageBounds).integral
        guard !region.isEmpty,
              let beforeRegion = beforeImage.cropping(to: region),
              let afterRegion = afterImage.cropping(to: region),
              let beforeFingerprint = ScreenshotFingerprint(image: beforeRegion),
              let afterFingerprint = ScreenshotFingerprint(image: afterRegion) else { return nil }
        return beforeFingerprint.changedCellFraction(comparedTo: afterFingerprint)
    }

    private static func decodedImage(_ jpegData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
