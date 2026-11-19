//
//  GuidanceDecoders.swift
//  elfhub
//
//  Turns a model reply into spoken text plus ScreenGuidanceCommands. Today the
//  only encoding is free-text tags embedded in the reply, which works with
//  every provider (including local models without tool calling). A native
//  tool-call decoder can produce the same commands later without the overlay
//  or executor changing.
//

import CoreGraphics
import Foundation

// MARK: - POINT Tag

/// Result of parsing a [POINT:...] tag from a reply.
struct PointingParseResult: Equatable {
    /// The reply with the [POINT:...] tag removed — this is what gets spoken.
    let spokenText: String
    /// The parsed coordinate, or nil if the model said "none" or no tag was found.
    let coordinate: CGPoint?
    /// Short label describing the element (e.g. "run button"), or "none".
    let elementLabel: String?
    /// Which screen the coordinate refers to (1-based), or nil for the primary-focus screen.
    let screenNumber: Int?
}

enum PointTagParser {

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the END of a
    /// reply. Returns the spoken text (tag removed) and the optional coordinate,
    /// label and screen number.
    static func parsePointTag(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(match.range, in: responseText) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // [POINT:none] has no coordinate groups.
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel = ScreenActionParser.stringGroup(match, at: 3, in: responseText)
        var screenNumber = ScreenActionParser.intGroup(match, at: 4, in: responseText)

        // "[POINT:10,20:screen2]" — the lazy label group swallowed the screen
        // suffix; reinterpret it as the screen number.
        if screenNumber == nil,
           let labelText = elementLabel,
           labelText.lowercased().hasPrefix("screen"),
           let screenNumberFromLabel = Int(labelText.dropFirst("screen".count)) {
            screenNumber = screenNumberFromLabel
            elementLabel = nil
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}

// MARK: - Tag Decoder

struct GuidanceDecodeResult: Equatable {
    /// Reply text with every guidance tag stripped — safe to speak or show.
    let spokenText: String
    /// Point, annotation and action commands, coordinates still in model space.
    let commands: [ScreenGuidanceCommand]
    /// The point tag's label even when it was [POINT:none], for logging.
    let pointLabel: String?

    var actions: [CompanionScreenAction] {
        commands.compactMap { command in
            if case let .act(action) = command { return action }
            return nil
        }
    }

    var annotations: [ScreenAnnotation] {
        commands.compactMap { command in
            if case let .annotate(annotation) = command { return annotation }
            return nil
        }
    }

    var pointCommand: (point: CGPoint, label: String?, screenNumber: Int?)? {
        for command in commands {
            if case let .point(point, label, screenNumber) = command {
                return (point, label, screenNumber)
            }
        }
        return nil
    }
}

/// Decodes free-text guidance tags. Order matters: action and annotation tags
/// can appear anywhere and are stripped first; POINT is parsed last because
/// its pattern is anchored to the end of the reply.
enum TagGuidanceDecoder {

    static func decode(responseText: String) -> GuidanceDecodeResult {
        let actionParseResult = ScreenActionParser.parseScreenActions(from: responseText)
        let annotationParseResult = ScreenAnnotationParser.parseScreenAnnotations(from: actionParseResult.spokenText)
        let pointParseResult = PointTagParser.parsePointTag(from: annotationParseResult.spokenText)

        var commands: [ScreenGuidanceCommand] = []
        if let pointCoordinate = pointParseResult.coordinate {
            commands.append(.point(
                at: pointCoordinate,
                label: pointParseResult.elementLabel,
                screenNumber: pointParseResult.screenNumber
            ))
        }
        commands.append(contentsOf: annotationParseResult.annotations.map { ScreenGuidanceCommand.annotate($0) })
        commands.append(contentsOf: actionParseResult.actions.map { ScreenGuidanceCommand.act($0) })

        return GuidanceDecodeResult(
            spokenText: pointParseResult.spokenText,
            commands: commands,
            pointLabel: pointParseResult.elementLabel
        )
    }
}

// MARK: - Native Tool Calling

/// Guidance as native function tools, for providers configured with tool
/// calling. Same vocabulary as the tags: a point, annotations, actions.
enum GuidanceToolDefinitions {
    static let pointToolName = "point_at"
    static let annotateToolName = "annotate"
    static let screenActionToolName = "perform_screen_action"
    /// Every guidance tool's name — calls to these are drawn on screen, not run.
    static let toolNames: Set<String> = [pointToolName, annotateToolName, screenActionToolName]

    /// The tools offered this turn. Screen actions are only offered when the
    /// user has turned action mode on — observation stays free, acting is opt-in.
    static func toolDefinitions(includingScreenActions: Bool) -> [LanguageModelToolDefinition] {
        var toolDefinitions = [pointToolDefinition, annotateToolDefinition]
        if includingScreenActions {
            toolDefinitions.append(screenActionToolDefinition)
        }
        return toolDefinitions
    }

    static let pointToolDefinition = LanguageModelToolDefinition(
        name: pointToolName,
        description: "Show a pointer directly on one UI element with a short label. Call at most once per reply, after your spoken text.",
        inputSchema: [
            "type": "object",
            "properties": [
                "x": ["type": "number", "description": "x coordinate of the element"],
                "y": ["type": "number", "description": "y coordinate of the element"],
                "label": ["type": "string", "description": "1-3 word name of the element, e.g. \"save button\""],
            ],
            "required": ["x", "y", "label"],
        ]
    )

    static let annotateToolDefinition = LanguageModelToolDefinition(
        name: annotateToolName,
        description: "Draw one mark on the user's screen: a highlight box, circle, arrow, underline, or a short note. Use sparingly — one to three marks per reply.",
        inputSchema: [
            "type": "object",
            "properties": [
                "shape": ["type": "string", "enum": ["highlight", "circle", "arrow", "underline", "note"]],
                "x": ["type": "number", "description": "highlight/underline: first corner or left end; circle: center; arrow: tail; note: top-left"],
                "y": ["type": "number"],
                "x2": ["type": "number", "description": "highlight: opposite corner; arrow: head (what it points at); underline: right end"],
                "y2": ["type": "number"],
                "radius": ["type": "number", "description": "circle radius, same units as x and y"],
                "text": ["type": "string", "description": "note text, under about six words"],
                "label": ["type": "string", "description": "optional short caption for the mark"],
            ],
            "required": ["shape", "x", "y"],
        ]
    )

    static let screenActionToolDefinition = LanguageModelToolDefinition(
        name: screenActionToolName,
        description: "Actually operate the user's screen. Only when the user clearly asked you to DO something. Call once per action, in order; the user previews each and can stop you.",
        inputSchema: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["click", "double_click", "scroll", "type", "key"]],
                "x": ["type": "number", "description": "click/double_click/scroll target x"],
                "y": ["type": "number", "description": "click/double_click/scroll target y"],
                "label": ["type": "string", "description": "short name of the click target"],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "text": ["type": "string", "description": "literal text to type into the focused field"],
                "keys": ["type": "string", "description": "shortcut such as cmd+s, return, tab, esc"],
            ],
            "required": ["action"],
        ]
    )
}

/// Decodes native guidance tool calls into the same commands the tag decoder
/// produces. Malformed calls are skipped rather than failing the turn.
enum ToolCallGuidanceDecoder {

    static func decode(responseText: String, toolCalls: [LanguageModelToolCall]) -> GuidanceDecodeResult {
        var commands: [ScreenGuidanceCommand] = []
        var pointLabel: String?
        var annotationCount = 0
        var actionCount = 0

        for toolCall in toolCalls {
            let arguments = toolCall.argumentsDictionary
            let screenNumber = intValue(arguments["screen"])

            switch toolCall.toolName {
            case GuidanceToolDefinitions.pointToolName:
                // One pointer per reply, like the single POINT tag.
                guard pointLabel == nil,
                      let x = doubleValue(arguments["x"]), let y = doubleValue(arguments["y"]) else { continue }
                let label = stringValue(arguments["label"])
                pointLabel = label ?? "element"
                commands.insert(.point(at: CGPoint(x: x, y: y), label: label, screenNumber: screenNumber), at: 0)

            case GuidanceToolDefinitions.annotateToolName:
                guard annotationCount < ScreenAnnotationParser.maximumAnnotationsPerResponse,
                      let shape = annotationShape(from: arguments) else { continue }
                annotationCount += 1
                commands.append(.annotate(ScreenAnnotation(
                    shape: shape,
                    label: stringValue(arguments["label"]),
                    screenNumber: screenNumber
                )))

            case GuidanceToolDefinitions.screenActionToolName:
                guard actionCount < ScreenActionParser.maximumActionsPerResponse,
                      let action = screenAction(from: arguments, screenNumber: screenNumber) else { continue }
                actionCount += 1
                commands.append(.act(action))

            default:
                continue
            }
        }

        return GuidanceDecodeResult(
            spokenText: responseText.trimmingCharacters(in: .whitespacesAndNewlines),
            commands: commands,
            pointLabel: pointLabel
        )
    }

    private static func annotationShape(from arguments: [String: Any]) -> ScreenAnnotationShape? {
        guard let shapeName = stringValue(arguments["shape"]),
              let x = doubleValue(arguments["x"]), let y = doubleValue(arguments["y"]) else { return nil }
        let firstPoint = CGPoint(x: x, y: y)
        let secondPoint: CGPoint? = {
            guard let x2 = doubleValue(arguments["x2"]), let y2 = doubleValue(arguments["y2"]) else { return nil }
            return CGPoint(x: x2, y: y2)
        }()

        switch shapeName {
        case "highlight":
            return secondPoint.map { .highlight(firstCorner: firstPoint, oppositeCorner: $0) }
        case "circle":
            guard let radius = doubleValue(arguments["radius"]), radius > 0 else { return nil }
            return .circle(center: firstPoint, radius: CGFloat(radius))
        case "arrow":
            return secondPoint.map { .arrow(tail: firstPoint, head: $0) }
        case "underline":
            return secondPoint.map { .underline(start: firstPoint, end: $0) }
        case "note":
            guard let noteText = stringValue(arguments["text"]) else { return nil }
            return .note(anchor: firstPoint, text: noteText)
        default:
            return nil
        }
    }

    private static func screenAction(from arguments: [String: Any], screenNumber: Int?) -> CompanionScreenAction? {
        guard let actionName = stringValue(arguments["action"]) else { return nil }
        let targetPoint: CGPoint? = {
            guard let x = doubleValue(arguments["x"]), let y = doubleValue(arguments["y"]) else { return nil }
            return CGPoint(x: x, y: y)
        }()
        let label = stringValue(arguments["label"])

        switch actionName {
        case "click":
            return targetPoint.map { .click(screenshotPixel: $0, label: label, screenNumber: screenNumber) }
        case "double_click":
            return targetPoint.map { .doubleClick(screenshotPixel: $0, label: label, screenNumber: screenNumber) }
        case "scroll":
            guard let targetPoint,
                  let direction = stringValue(arguments["direction"]).flatMap(ScreenActionSynthesizer.ScrollDirection.init(rawValue:)) else {
                return nil
            }
            return .scroll(screenshotPixel: targetPoint, direction: direction, screenNumber: screenNumber)
        case "type":
            return stringValue(arguments["text"]).map { .type(text: $0) }
        case "key":
            return stringValue(arguments["keys"]).map { .key(comboString: $0) }
        default:
            return nil
        }
    }

    // JSON numbers may arrive as Int, Double or (from some local servers) strings.
    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        doubleValue(value).map { Int($0) }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedString.isEmpty ? nil : trimmedString
    }
}
