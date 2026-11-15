//
//  ComputerUseToolCallTranslator.swift
//  elfhub
//
//  Pure translation of one step of a multi-step run on the user's screen.
//  Claude calls the members of its computer toolset (`left_click`,
//  `screenshot`, `zoom`, …, with `toolset_name: "computer"`); every other
//  tool-calling model calls elfhub's extended `perform_screen_action`. Both
//  become the same ComputerUseStepCommand, in the sent screenshot's pixel
//  space, so everything after this (consent, execution, the next
//  screenshot) is shared. Anything out of range is refused with a reason
//  the model can act on instead of being guessed at.
//

import CoreGraphics
import Foundation

/// What one step of a run asks for.
enum ComputerUseStepCommand: Equatable {
    /// Act on the screen, `repeatCount` times in a row (a key pressed
    /// three times, a long scroll).
    case act(CompanionScreenAction, repeatCount: Int)
    /// Return a fresh screenshot.
    case screenshot
    /// Return this part of the screen at full resolution.
    case zoom(regionInScreenshotPixels: CGRect)
    /// Wait for something to load.
    case wait(seconds: Double)
    /// Say where the pointer is.
    case cursorPosition
    /// Not carried out; the reason goes back to the model as an error.
    case refuse(reason: String)
}

enum ComputerUseToolCallTranslator {

    /// The toolset name Claude's computer calls carry.
    static let claudeComputerToolsetName = "computer"
    static let maximumWaitInSeconds: Double = 10
    static let maximumRepeatCount = 20
    /// Claude's scroll amount counts wheel clicks; one of elfhub's scroll
    /// steps moves six lines, about two clicks.
    static let wheelClicksPerScrollStep = 2

    /// Whether this call is a step on the screen (rather than pointing, a
    /// note, or an elf's own tool).
    static func isComputerUseCall(_ toolCall: LanguageModelToolCall) -> Bool {
        toolCall.toolsetName == claudeComputerToolsetName || toolCall.toolName == GuidanceToolDefinitions.screenActionToolName
    }

    static func command(
        for toolCall: LanguageModelToolCall,
        convention: ModelCoordinateConvention,
        sentImageSize: CGSize
    ) -> ComputerUseStepCommand {
        let arguments = toolCall.argumentsDictionary
        let stepReader = StepArgumentReader(arguments: arguments, convention: convention, sentImageSize: sentImageSize)
        if toolCall.toolsetName == claudeComputerToolsetName {
            return claudeToolsetCommand(memberName: toolCall.toolName, stepReader: stepReader)
        }
        return functionToolCommand(stepReader: stepReader)
    }

    // MARK: - Claude's computer toolset

    private static func claudeToolsetCommand(memberName: String, stepReader: StepArgumentReader) -> ComputerUseStepCommand {
        switch memberName {
        case "screenshot":
            return .screenshot
        case "cursor_position":
            return .cursorPosition
        case "zoom":
            guard let region = stepReader.region(named: "region") else {
                return .refuse(reason: "zoom needs a region [x0, y0, x1, y1] inside the screenshot, top-left corner first.")
            }
            return .zoom(regionInScreenshotPixels: region)
        case "left_click", "right_click", "double_click", "triple_click", "mouse_move":
            if let modifierRefusal = stepReader.modifierRefusal() { return modifierRefusal }
            guard let targetPoint = stepReader.point(named: "coordinate") else {
                return stepReader.missingOrOffScreenPointRefusal(named: "coordinate")
            }
            return .act(pointerAction(memberName: memberName, targetPoint: targetPoint, label: nil), repeatCount: 1)
        case "left_click_drag":
            if let modifierRefusal = stepReader.modifierRefusal() { return modifierRefusal }
            guard let startPoint = stepReader.point(named: "start_coordinate") else {
                return stepReader.missingOrOffScreenPointRefusal(named: "start_coordinate")
            }
            guard let endPoint = stepReader.point(named: "coordinate") else {
                return stepReader.missingOrOffScreenPointRefusal(named: "coordinate")
            }
            return .act(.drag(fromScreenshotPixel: startPoint, toScreenshotPixel: endPoint, screenNumber: nil), repeatCount: 1)
        case "scroll":
            if let modifierRefusal = stepReader.modifierRefusal() { return modifierRefusal }
            guard let targetPoint = stepReader.point(named: "coordinate") else {
                return stepReader.missingOrOffScreenPointRefusal(named: "coordinate")
            }
            guard let direction = stepReader.string(named: "scroll_direction").flatMap(ScreenActionSynthesizer.ScrollDirection.init(rawValue:)) else {
                return .refuse(reason: "scroll needs scroll_direction: up, down, left or right.")
            }
            let wheelClicks = stepReader.integer(named: "scroll_amount") ?? 3
            guard (1...(maximumRepeatCount * wheelClicksPerScrollStep)).contains(wheelClicks) else {
                return .refuse(reason: "scroll_amount must be between 1 and \(maximumRepeatCount * wheelClicksPerScrollStep).")
            }
            let scrollSteps = Int((Double(wheelClicks) / Double(wheelClicksPerScrollStep)).rounded(.up))
            return .act(.scroll(screenshotPixel: targetPoint, direction: direction, screenNumber: nil), repeatCount: scrollSteps)
        case "type":
            guard let text = stepReader.rawString(named: "text"), !text.isEmpty else {
                return .refuse(reason: "type needs the text to type.")
            }
            return .act(.type(text: text), repeatCount: 1)
        case "key":
            return keyCommand(comboString: stepReader.string(named: "text"), repeatCount: stepReader.integer(named: "repeat") ?? 1)
        case "wait":
            return waitCommand(seconds: stepReader.number(named: "duration"))
        default:
            return .refuse(reason: "\(memberName) isn't available here; use clicks, keys, typing, scrolling or a screenshot instead.")
        }
    }

    // MARK: - elfhub's perform_screen_action (other models)

    private static func functionToolCommand(stepReader: StepArgumentReader) -> ComputerUseStepCommand {
        guard let actionName = stepReader.string(named: "action") else {
            return .refuse(reason: "perform_screen_action needs an action.")
        }
        let label = stepReader.string(named: "label")
        switch actionName {
        case "take_screenshot", "screenshot":
            return .screenshot
        case "zoom":
            guard let firstCorner = stepReader.point(xName: "x", yName: "y"),
                  let oppositeCorner = stepReader.point(xName: "x2", yName: "y2"),
                  let region = StepArgumentReader.region(from: firstCorner, to: oppositeCorner) else {
                return .refuse(reason: "zoom needs x, y (top-left) and x2, y2 (bottom-right) inside the screenshot.")
            }
            return .zoom(regionInScreenshotPixels: region)
        case "click", "right_click", "double_click", "triple_click", "move":
            guard let targetPoint = stepReader.point(xName: "x", yName: "y") else {
                return .refuse(reason: "\(actionName) needs x and y inside the screenshot.")
            }
            let memberName = ["click": "left_click", "move": "mouse_move"][actionName] ?? actionName
            return .act(pointerAction(memberName: memberName, targetPoint: targetPoint, label: label), repeatCount: 1)
        case "drag":
            guard let startPoint = stepReader.point(xName: "x", yName: "y"),
                  let endPoint = stepReader.point(xName: "x2", yName: "y2") else {
                return .refuse(reason: "drag needs x, y (where to press) and x2, y2 (where to let go) inside the screenshot.")
            }
            return .act(.drag(fromScreenshotPixel: startPoint, toScreenshotPixel: endPoint, screenNumber: nil), repeatCount: 1)
        case "scroll":
            guard let targetPoint = stepReader.point(xName: "x", yName: "y"),
                  let direction = stepReader.string(named: "direction").flatMap(ScreenActionSynthesizer.ScrollDirection.init(rawValue:)) else {
                return .refuse(reason: "scroll needs x, y and a direction (up, down, left, right).")
            }
            let repeatCount = stepReader.integer(named: "repeat") ?? 1
            guard (1...maximumRepeatCount).contains(repeatCount) else {
                return .refuse(reason: "repeat must be between 1 and \(maximumRepeatCount).")
            }
            return .act(.scroll(screenshotPixel: targetPoint, direction: direction, screenNumber: nil), repeatCount: repeatCount)
        case "type":
            guard let text = stepReader.rawString(named: "text"), !text.isEmpty else {
                return .refuse(reason: "type needs the text to type.")
            }
            return .act(.type(text: text), repeatCount: 1)
        case "key":
            return keyCommand(comboString: stepReader.string(named: "keys"), repeatCount: stepReader.integer(named: "repeat") ?? 1)
        case "wait":
            return waitCommand(seconds: stepReader.number(named: "seconds"))
        default:
            return .refuse(reason: "\(actionName) isn't an action perform_screen_action knows.")
        }
    }

    // MARK: - Shared pieces

    private static func pointerAction(memberName: String, targetPoint: CGPoint, label: String?) -> CompanionScreenAction {
        switch memberName {
        case "right_click": return .rightClick(screenshotPixel: targetPoint, label: label, screenNumber: nil)
        case "double_click": return .doubleClick(screenshotPixel: targetPoint, label: label, screenNumber: nil)
        case "triple_click": return .tripleClick(screenshotPixel: targetPoint, label: label, screenNumber: nil)
        case "mouse_move": return .moveMouse(screenshotPixel: targetPoint, screenNumber: nil)
        default: return .click(screenshotPixel: targetPoint, label: label, screenNumber: nil)
        }
    }

    private static func keyCommand(comboString: String?, repeatCount: Int) -> ComputerUseStepCommand {
        guard let comboString else {
            return .refuse(reason: "key needs the key or shortcut to press, like cmd+s or return.")
        }
        guard (1...maximumRepeatCount).contains(repeatCount) else {
            return .refuse(reason: "repeat must be between 1 and \(maximumRepeatCount).")
        }
        return .act(.key(comboString: comboString), repeatCount: repeatCount)
    }

    private static func waitCommand(seconds: Double?) -> ComputerUseStepCommand {
        guard let seconds, seconds > 0, seconds <= maximumWaitInSeconds else {
            return .refuse(reason: "wait between 0 and \(Int(maximumWaitInSeconds)) seconds at a time, then take a screenshot.")
        }
        return .wait(seconds: seconds)
    }
}

/// Reads one step's arguments, turning the model's coordinates into the
/// sent screenshot's pixels and refusing points outside it.
private struct StepArgumentReader {
    let arguments: [String: Any]
    let convention: ModelCoordinateConvention
    let sentImageSize: CGSize

    func string(named argumentName: String) -> String? {
        guard let rawString = rawString(named: argumentName) else { return nil }
        let trimmedString = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedString.isEmpty ? nil : trimmedString
    }

    /// Text exactly as written (spaces and newlines in typed text matter).
    func rawString(named argumentName: String) -> String? {
        arguments[argumentName] as? String
    }

    func number(named argumentName: String) -> Double? {
        Self.number(from: arguments[argumentName])
    }

    func integer(named argumentName: String) -> Int? {
        number(named: argumentName).map { Int($0.rounded()) }
    }

    /// A `[x, y]` argument (Claude's toolset), in screenshot pixels.
    func point(named argumentName: String) -> CGPoint? {
        guard let coordinatePair = arguments[argumentName] as? [Any], coordinatePair.count == 2,
              let x = Self.number(from: coordinatePair[0]), let y = Self.number(from: coordinatePair[1]) else { return nil }
        return screenshotPixelIfOnScreen(modelPoint: CGPoint(x: x, y: y))
    }

    /// Separate x and y arguments (perform_screen_action), in screenshot pixels.
    func point(xName: String, yName: String) -> CGPoint? {
        guard let x = number(named: xName), let y = number(named: yName) else { return nil }
        return screenshotPixelIfOnScreen(modelPoint: CGPoint(x: x, y: y))
    }

    /// A `[x0, y0, x1, y1]` region, top-left corner first.
    func region(named argumentName: String) -> CGRect? {
        guard let corners = arguments[argumentName] as? [Any], corners.count == 4 else { return nil }
        let cornerNumbers = corners.compactMap(Self.number(from:))
        guard cornerNumbers.count == 4,
              let firstCorner = screenshotPixelIfOnScreen(modelPoint: CGPoint(x: cornerNumbers[0], y: cornerNumbers[1])),
              let oppositeCorner = screenshotPixelIfOnScreen(modelPoint: CGPoint(x: cornerNumbers[2], y: cornerNumbers[3])) else { return nil }
        return Self.region(from: firstCorner, to: oppositeCorner)
    }

    static func region(from topLeftCorner: CGPoint, to bottomRightCorner: CGPoint) -> CGRect? {
        guard bottomRightCorner.x > topLeftCorner.x, bottomRightCorner.y > topLeftCorner.y else { return nil }
        return CGRect(
            x: topLeftCorner.x,
            y: topLeftCorner.y,
            width: bottomRightCorner.x - topLeftCorner.x,
            height: bottomRightCorner.y - topLeftCorner.y
        )
    }

    /// Clicks and scrolls with keys held aren't carried out yet.
    func modifierRefusal() -> ComputerUseStepCommand? {
        guard string(named: "text") != nil else { return nil }
        return .refuse(reason: "clicking or scrolling with keys held isn't supported; do it without the keys, or use a keyboard shortcut.")
    }

    func missingOrOffScreenPointRefusal(named argumentName: String) -> ComputerUseStepCommand {
        .refuse(reason: "\(argumentName) must be an [x, y] point inside the screenshot (\(Int(sentImageSize.width))×\(Int(sentImageSize.height))).")
    }

    private func screenshotPixelIfOnScreen(modelPoint: CGPoint) -> CGPoint? {
        let screenshotPixel = ScreenshotGeometry.screenshotPixel(
            fromModelCoordinate: modelPoint,
            convention: convention,
            sentImageSize: sentImageSize
        )
        guard screenshotPixel.x >= 0, screenshotPixel.y >= 0,
              screenshotPixel.x <= sentImageSize.width, screenshotPixel.y <= sentImageSize.height else { return nil }
        return screenshotPixel
    }

    private static func number(from value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

extension GuidanceToolDefinitions {

    /// perform_screen_action during a multi-step run (every model except
    /// Claude with its own toolset): each call runs right away and returns
    /// a fresh screenshot, so the model sees what happened before deciding
    /// the next step.
    static let computerUseStepToolDefinition = LanguageModelToolDefinition(
        name: screenActionToolName,
        description: "Operate the user's screen one step at a time. Each call runs right away (the user sees a pointer on the target first and can stop you) and returns a fresh screenshot showing the result — look at it before the next step. Only when the user asked you to DO something.",
        inputSchema: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["click", "double_click", "triple_click", "right_click", "move", "drag", "scroll", "type", "key", "wait", "take_screenshot", "zoom"],
                ],
                "x": ["type": "number", "description": "target x (drag: where to press; zoom: left edge)"],
                "y": ["type": "number", "description": "target y (drag: where to press; zoom: top edge)"],
                "x2": ["type": "number", "description": "drag: where to let go; zoom: right edge"],
                "y2": ["type": "number", "description": "drag: where to let go; zoom: bottom edge"],
                "label": ["type": "string", "description": "short name of the click target"],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "text": ["type": "string", "description": "literal text to type into the focused field"],
                "keys": ["type": "string", "description": "shortcut such as cmd+s, return, tab, esc"],
                "repeat": ["type": "integer", "description": "key or scroll: how many times (1-20)"],
                "seconds": ["type": "number", "description": "wait: how long, up to 10"],
            ],
            "required": ["action"],
        ]
    )
}
