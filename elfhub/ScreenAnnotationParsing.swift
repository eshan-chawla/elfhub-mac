//
//  ScreenAnnotationParsing.swift
//  elfhub
//
//  Pure parsing of the annotation tags a model can embed in its reply to draw
//  on the user's screen. Mirrors ScreenActionParser: one regex per tag family,
//  results merged in emission order, tags stripped from the spoken text.
//
//  Tag formats (coordinates in the model's coordinate space; optional
//  :screenN targets another monitor):
//    [HIGHLIGHT:x1,y1,x2,y2:label]   rounded box around a region
//    [CIRCLE:x,y,r:label]            circle around a point
//    [ARROW:x1,y1,x2,y2:label]       arrow from (x1,y1) pointing at (x2,y2)
//    [UNDERLINE:x1,y1,x2,y2]         line under text
//    [NOTE:x,y:text]                 handwritten-style text written on screen
//
//  Annotations are visual only — they never touch the user's apps — so they
//  are not gated by action mode.
//

import CoreGraphics
import Foundation

struct ScreenAnnotationParseResult: Equatable {
    /// The reply with every annotation tag removed.
    let spokenText: String
    /// Annotations in the order the model emitted them, capped.
    let annotations: [ScreenAnnotation]
    let wasCappedToMaximum: Bool
}

enum ScreenAnnotationParser {

    /// More than a handful of marks turns the screen into noise.
    static let maximumAnnotationsPerResponse = 6

    /// Decimal-tolerant number: models occasionally emit "120.5".
    private static let numberPattern = #"(\d+(?:\.\d+)?)"#
    private static let separatorPattern = #"\s*,\s*"#
    /// Optional ":label" then optional ":screenN".
    private static let labelAndScreenSuffixPattern = #"(?::([^\]:]+?))?(?::screen(\d+))?\]"#

    static func parseScreenAnnotations(from responseText: String) -> ScreenAnnotationParseResult {
        var matchedRanges: [NSRange] = []
        var locatedAnnotations: [(location: Int, annotation: ScreenAnnotation)] = []
        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        let fourNumberPattern = [numberPattern, numberPattern, numberPattern, numberPattern]
            .joined(separator: separatorPattern)
        let threeNumberPattern = [numberPattern, numberPattern, numberPattern]
            .joined(separator: separatorPattern)

        collectFourCoordinateAnnotations(
            tagName: "HIGHLIGHT", coordinatePattern: fourNumberPattern,
            in: responseText, fullRange: fullRange,
            into: &locatedAnnotations, ranges: &matchedRanges
        ) { firstPoint, secondPoint in
            .highlight(firstCorner: firstPoint, oppositeCorner: secondPoint)
        }
        collectFourCoordinateAnnotations(
            tagName: "ARROW", coordinatePattern: fourNumberPattern,
            in: responseText, fullRange: fullRange,
            into: &locatedAnnotations, ranges: &matchedRanges
        ) { firstPoint, secondPoint in
            .arrow(tail: firstPoint, head: secondPoint)
        }
        collectFourCoordinateAnnotations(
            tagName: "UNDERLINE", coordinatePattern: fourNumberPattern,
            in: responseText, fullRange: fullRange,
            into: &locatedAnnotations, ranges: &matchedRanges
        ) { firstPoint, secondPoint in
            .underline(start: firstPoint, end: secondPoint)
        }
        collectCircleAnnotations(
            coordinatePattern: threeNumberPattern,
            in: responseText, fullRange: fullRange,
            into: &locatedAnnotations, ranges: &matchedRanges
        )
        collectNoteAnnotations(
            in: responseText, fullRange: fullRange,
            into: &locatedAnnotations, ranges: &matchedRanges
        )

        let orderedAnnotations = locatedAnnotations
            .sorted { $0.location < $1.location }
            .map { $0.annotation }

        return ScreenAnnotationParseResult(
            spokenText: ScreenActionParser.stripRanges(matchedRanges, from: responseText),
            annotations: Array(orderedAnnotations.prefix(maximumAnnotationsPerResponse)),
            wasCappedToMaximum: orderedAnnotations.count > maximumAnnotationsPerResponse
        )
    }

    // MARK: - Family Matchers

    private static func collectFourCoordinateAnnotations(
        tagName: String,
        coordinatePattern: String,
        in text: String,
        fullRange: NSRange,
        into locatedAnnotations: inout [(location: Int, annotation: ScreenAnnotation)],
        ranges matchedRanges: inout [NSRange],
        makeShape: (CGPoint, CGPoint) -> ScreenAnnotationShape
    ) {
        let pattern = #"\["# + tagName + ":" + coordinatePattern + labelAndScreenSuffixPattern
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        for match in regex.matches(in: text, range: fullRange) {
            guard let coordinates = doubleGroups(match, indices: 1...4, in: text) else { continue }
            let (label, screenNumber) = labelAndScreenNumber(match, labelIndex: 5, screenIndex: 6, in: text)
            let shape = makeShape(
                CGPoint(x: coordinates[0], y: coordinates[1]),
                CGPoint(x: coordinates[2], y: coordinates[3])
            )
            locatedAnnotations.append((match.range.location, ScreenAnnotation(shape: shape, label: label, screenNumber: screenNumber)))
            matchedRanges.append(match.range)
        }
    }

    private static func collectCircleAnnotations(
        coordinatePattern: String,
        in text: String,
        fullRange: NSRange,
        into locatedAnnotations: inout [(location: Int, annotation: ScreenAnnotation)],
        ranges matchedRanges: inout [NSRange]
    ) {
        let pattern = #"\[CIRCLE:"# + coordinatePattern + labelAndScreenSuffixPattern
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        for match in regex.matches(in: text, range: fullRange) {
            guard let coordinates = doubleGroups(match, indices: 1...3, in: text),
                  coordinates[2] > 0 else { continue }
            let (label, screenNumber) = labelAndScreenNumber(match, labelIndex: 4, screenIndex: 5, in: text)
            let shape = ScreenAnnotationShape.circle(
                center: CGPoint(x: coordinates[0], y: coordinates[1]),
                radius: CGFloat(coordinates[2])
            )
            locatedAnnotations.append((match.range.location, ScreenAnnotation(shape: shape, label: label, screenNumber: screenNumber)))
            matchedRanges.append(match.range)
        }
    }

    private static func collectNoteAnnotations(
        in text: String,
        fullRange: NSRange,
        into locatedAnnotations: inout [(location: Int, annotation: ScreenAnnotation)],
        ranges matchedRanges: inout [NSRange]
    ) {
        // Note text may contain ":" (e.g. "todo: fix"), so it is matched lazily
        // up to an optional trailing ":screenN" and the closing bracket.
        let pattern = #"\[NOTE:"# + numberPattern + separatorPattern + numberPattern + #":([^\]]+?)(?::screen(\d+))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        for match in regex.matches(in: text, range: fullRange) {
            guard let coordinates = doubleGroups(match, indices: 1...2, in: text),
                  let noteText = ScreenActionParser.stringGroup(match, at: 3, in: text) else { continue }
            let screenNumber = ScreenActionParser.intGroup(match, at: 4, in: text)
            let shape = ScreenAnnotationShape.note(anchor: CGPoint(x: coordinates[0], y: coordinates[1]), text: noteText)
            locatedAnnotations.append((match.range.location, ScreenAnnotation(shape: shape, label: nil, screenNumber: screenNumber)))
            matchedRanges.append(match.range)
        }
    }

    // MARK: - Helpers

    private static func doubleGroups(_ match: NSTextCheckingResult, indices: ClosedRange<Int>, in text: String) -> [Double]? {
        var values: [Double] = []
        for index in indices {
            guard let range = Range(match.range(at: index), in: text),
                  let value = Double(text[range]) else { return nil }
            values.append(value)
        }
        return values
    }

    /// Reads the optional label and screen groups. A label of exactly
    /// "screenN" with no separate screen group means the model wrote
    /// "[TAG:...:screen2]" with no label — the lazy label group swallowed the
    /// screen suffix, so it is reinterpreted as the screen number.
    private static func labelAndScreenNumber(
        _ match: NSTextCheckingResult,
        labelIndex: Int,
        screenIndex: Int,
        in text: String
    ) -> (label: String?, screenNumber: Int?) {
        let label = ScreenActionParser.stringGroup(match, at: labelIndex, in: text)
        let screenNumber = ScreenActionParser.intGroup(match, at: screenIndex, in: text)
        if screenNumber == nil,
           let label,
           label.lowercased().hasPrefix("screen"),
           let screenNumberFromLabel = Int(label.dropFirst("screen".count)) {
            return (nil, screenNumberFromLabel)
        }
        return (label, screenNumber)
    }
}
