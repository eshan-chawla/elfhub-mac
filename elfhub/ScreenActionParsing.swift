//
//  ScreenActionParsing.swift
//  elfhub
//
//  Pure parsing for elfhub's screen actions. Kept in its own module (rather
//  than growing CompanionManager) and free of any UI, event posting, or AppKit
//  state so it can be unit-tested in isolation — see elfhubTests. How much
//  consent an action needs is decided separately, from the real target, by
//  ConsentPolicy.
//
//  Claude emits action tags inside its normal spoken reply, e.g.
//     "sure, saving that now [CLICK:640,300:save button][KEY:cmd+s]"
//  This file turns that text into an ordered list of CompanionScreenAction
//  values plus the spoken text with the tags stripped out. It intentionally
//  leaves the existing [POINT:...] tag alone — CompanionManager still parses
//  that separately so pointing behavior is unchanged.
//

import CoreGraphics
import Foundation

// MARK: - Actions

/// A single real action elfhub can take on screen. Coordinates are in the
/// screenshot's pixel space (top-left origin), exactly like the [POINT] tag;
/// they are mapped to real click points later via CompanionScreenCapture.
enum CompanionScreenAction: Equatable {
    case click(screenshotPixel: CGPoint, label: String?, screenNumber: Int?)
    case doubleClick(screenshotPixel: CGPoint, label: String?, screenNumber: Int?)
    /// Scrolls the content under the point by `amountInTenthsOfScreen`
    /// tenths of the screen's height — a known distance in every app,
    /// unlike wheel "lines", which each app turns into its own distance.
    case scroll(screenshotPixel: CGPoint, direction: ScreenActionSynthesizer.ScrollDirection, screenNumber: Int?, amountInTenthsOfScreen: Int = CompanionScreenAction.defaultScrollAmountInTenthsOfScreen)
    case type(text: String)
    case key(comboString: String)
    // Used by the multi-step loop (computer use); single-shot replies and
    // tags never produce these.
    case rightClick(screenshotPixel: CGPoint, label: String?, screenNumber: Int?)
    case tripleClick(screenshotPixel: CGPoint, label: String?, screenNumber: Int?)
    /// Press at one point, move to another, release (moving a slider,
    /// selecting text, dragging a file).
    case drag(fromScreenshotPixel: CGPoint, toScreenshotPixel: CGPoint, screenNumber: Int?)
    /// Move the pointer without clicking (to show a hover menu).
    case moveMouse(screenshotPixel: CGPoint, screenNumber: Int?)
    /// Open an app by name, or a web address in the user's browser.
    case openApplication(name: String)
    case openWebsite(url: URL)

    /// Half a screen, when no amount is given (the [SCROLL] tag).
    static let defaultScrollAmountInTenthsOfScreen = 5

    /// Short human-readable description used in the consent card and narration,
    /// e.g. "click the save button" or "press cmd+s".
    var humanReadableDescription: String {
        switch self {
        case let .click(_, label, _):
            return "click \(label.map { "the \($0)" } ?? "here")"
        case let .doubleClick(_, label, _):
            return "double-click \(label.map { "the \($0)" } ?? "here")"
        case let .scroll(_, direction, _, _):
            return "scroll \(direction.rawValue)"
        case let .type(text):
            return "type \"\(text)\""
        case let .key(comboString):
            return "press \(comboString)"
        case let .rightClick(_, label, _):
            return "right-click \(label.map { "the \($0)" } ?? "here")"
        case let .tripleClick(_, label, _):
            return "triple-click \(label.map { "the \($0)" } ?? "here")"
        case .drag:
            return "drag from here to there"
        case .moveMouse:
            return "move the pointer here"
        case let .openApplication(name):
            return "open \(name)"
        case let .openWebsite(url):
            return "open \(url.host ?? url.absoluteString)"
        }
    }
}

// MARK: - Parse Result

struct ScreenActionParseResult: Equatable {
    /// The reply with every action tag removed — safe to hand to POINT parsing
    /// and then to TTS.
    let spokenText: String
    /// Actions in the order Claude emitted them.
    let actions: [CompanionScreenAction]

    /// True if the response contained the maximum-or-more action tags and the
    /// list was capped. Surfaced so the caller can note the truncation.
    let wasCappedToMaximum: Bool
}

// MARK: - Parser

enum ScreenActionParser {

    /// Upper bound on actions executed from a single reply. Approach A is blind
    /// between actions (Claude can't see the result of one before the next), so
    /// long chains are unsafe; short focus-based chains (click→type→return) are
    /// the sweet spot.
    static let maximumActionsPerResponse = 4

    /// Parses all action tags from Claude's reply, in emission order, and returns
    /// the spoken text with those tags stripped. Does NOT touch [POINT:...].
    static func parseScreenActions(from responseText: String) -> ScreenActionParseResult {
        var matchedRanges: [NSRange] = []
        var locatedActions: [(location: Int, action: CompanionScreenAction)] = []

        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        // Each family is matched with its own regex; results are merged and
        // re-sorted by position so emission order is preserved regardless of
        // which family a tag belongs to.
        collectClickActions(in: responseText, fullRange: fullRange,
                            into: &locatedActions, ranges: &matchedRanges)
        collectScrollActions(in: responseText, fullRange: fullRange,
                            into: &locatedActions, ranges: &matchedRanges)
        collectTypeActions(in: responseText, fullRange: fullRange,
                            into: &locatedActions, ranges: &matchedRanges)
        collectKeyActions(in: responseText, fullRange: fullRange,
                            into: &locatedActions, ranges: &matchedRanges)

        let orderedActions = locatedActions
            .sorted { $0.location < $1.location }
            .map { $0.action }

        let wasCapped = orderedActions.count > maximumActionsPerResponse
        let cappedActions = Array(orderedActions.prefix(maximumActionsPerResponse))

        let spokenText = stripRanges(matchedRanges, from: responseText)

        return ScreenActionParseResult(
            spokenText: spokenText,
            actions: cappedActions,
            wasCappedToMaximum: wasCapped
        )
    }

    // MARK: - Family Matchers

    private static func collectClickActions(
        in text: String,
        fullRange: NSRange,
        into locatedActions: inout [(location: Int, action: CompanionScreenAction)],
        ranges matchedRanges: inout [NSRange]
    ) {
        let pattern = #"\[(CLICK|DOUBLECLICK):(\d+)\s*,\s*(\d+)(?::([^\]:]+?))?(?::screen(\d+))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match,
                  let verbRange = Range(match.range(at: 1), in: text),
                  let xRange = Range(match.range(at: 2), in: text),
                  let yRange = Range(match.range(at: 3), in: text),
                  let x = Double(text[xRange]),
                  let y = Double(text[yRange]) else { return }

            let label = stringGroup(match, at: 4, in: text)
            let screenNumber = intGroup(match, at: 5, in: text)
            let screenshotPixel = CGPoint(x: x, y: y)

            let action: CompanionScreenAction = text[verbRange] == "DOUBLECLICK"
                ? .doubleClick(screenshotPixel: screenshotPixel, label: label, screenNumber: screenNumber)
                : .click(screenshotPixel: screenshotPixel, label: label, screenNumber: screenNumber)

            locatedActions.append((match.range.location, action))
            matchedRanges.append(match.range)
        }
    }

    private static func collectScrollActions(
        in text: String,
        fullRange: NSRange,
        into locatedActions: inout [(location: Int, action: CompanionScreenAction)],
        ranges matchedRanges: inout [NSRange]
    ) {
        let pattern = #"\[SCROLL:(\d+)\s*,\s*(\d+):(up|down|left|right)(?::screen(\d+))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match,
                  let xRange = Range(match.range(at: 1), in: text),
                  let yRange = Range(match.range(at: 2), in: text),
                  let directionRange = Range(match.range(at: 3), in: text),
                  let x = Double(text[xRange]),
                  let y = Double(text[yRange]),
                  let direction = ScreenActionSynthesizer.ScrollDirection(rawValue: String(text[directionRange]))
            else { return }

            let screenNumber = intGroup(match, at: 4, in: text)
            let action: CompanionScreenAction = .scroll(
                screenshotPixel: CGPoint(x: x, y: y),
                direction: direction,
                screenNumber: screenNumber
            )
            locatedActions.append((match.range.location, action))
            matchedRanges.append(match.range)
        }
    }

    private static func collectTypeActions(
        in text: String,
        fullRange: NSRange,
        into locatedActions: inout [(location: Int, action: CompanionScreenAction)],
        ranges matchedRanges: inout [NSRange]
    ) {
        let pattern = #"\[TYPE:([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let textRange = Range(match.range(at: 1), in: text) else { return }
            let typedText = String(text[textRange])
            guard !typedText.isEmpty else { return }
            locatedActions.append((match.range.location, .type(text: typedText)))
            matchedRanges.append(match.range)
        }
    }

    private static func collectKeyActions(
        in text: String,
        fullRange: NSRange,
        into locatedActions: inout [(location: Int, action: CompanionScreenAction)],
        ranges matchedRanges: inout [NSRange]
    ) {
        let pattern = #"\[KEY:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let comboRange = Range(match.range(at: 1), in: text) else { return }
            let comboString = String(text[comboRange]).trimmingCharacters(in: .whitespaces)
            guard !comboString.isEmpty else { return }
            locatedActions.append((match.range.location, .key(comboString: comboString)))
            matchedRanges.append(match.range)
        }
    }

    // MARK: - Helpers (shared with ScreenAnnotationParser and PointTagParser)

    static func stringGroup(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func intGroup(_ match: NSTextCheckingResult, at index: Int, in text: String) -> Int? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    /// Removes the matched tag ranges from the text (right-to-left so earlier
    /// offsets stay valid) and trims leftover whitespace.
    static func stripRanges(_ ranges: [NSRange], from text: String) -> String {
        var mutableText = text as NSString
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            mutableText = mutableText.replacingCharacters(in: range, with: "") as NSString
        }
        return (mutableText as String)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
