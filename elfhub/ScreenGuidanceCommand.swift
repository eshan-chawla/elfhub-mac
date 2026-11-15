//
//  ScreenGuidanceCommand.swift
//  elfhub
//
//  One internal vocabulary for everything elfhub does on the user's screen:
//  point at something, draw an annotation, or act. Free-text tags today (and
//  native tool calls later) are decoded into these commands, so the overlay
//  and the action executor never depend on a wire format.
//
//  Coordinates move through three spaces, in order:
//    1. model space     — whatever the model emitted (pixels or a 0–999/0–1000 grid)
//    2. screenshot pixels — the sent image's pixels (ScreenGuidanceCoordinateNormalizer)
//    3. screen points   — AppKit global points for the overlay, Core Graphics
//                         global points for events and Accessibility
//  Commands hold space 1 or 2; Placed* types below hold space 3.
//

import CoreGraphics
import Foundation

// MARK: - Commands

/// A shape elfhub can draw on screen.
enum ScreenAnnotationShape: Equatable {
    /// A rounded box around a region, given by two opposite corners.
    case highlight(firstCorner: CGPoint, oppositeCorner: CGPoint)
    case circle(center: CGPoint, radius: CGFloat)
    /// An arrow drawn from tail to head (the head is what it points at).
    case arrow(tail: CGPoint, head: CGPoint)
    case underline(start: CGPoint, end: CGPoint)
    /// Handwritten-style text written onto the screen, anchored at its top-left.
    case note(anchor: CGPoint, text: String)
}

struct ScreenAnnotation: Equatable {
    let shape: ScreenAnnotationShape
    let label: String?
    /// 1-based screen number from the screenshot labels; nil means the
    /// primary-focus screen.
    let screenNumber: Int?
}

enum ScreenGuidanceCommand: Equatable {
    case point(at: CGPoint, label: String?, screenNumber: Int?)
    case annotate(ScreenAnnotation)
    case act(CompanionScreenAction)
}

// MARK: - Coordinate Normalization

/// Converts every coordinate in a command from the model's coordinate space
/// into the sent screenshot's pixel space. A no-op for pixel conventions.
enum ScreenGuidanceCoordinateNormalizer {

    /// `sentImageSizeForScreenNumber` returns the pixel size of the screenshot
    /// a command targets (nil screen number = primary-focus screen). Commands
    /// whose screen can't be resolved are returned unchanged.
    static func convertToScreenshotPixels(
        _ command: ScreenGuidanceCommand,
        convention: ModelCoordinateConvention,
        sentImageSizeForScreenNumber: (Int?) -> CGSize?
    ) -> ScreenGuidanceCommand {
        guard convention != .imagePixels else { return command }

        func convertPoint(_ modelPoint: CGPoint, screenNumber: Int?) -> CGPoint {
            guard let sentImageSize = sentImageSizeForScreenNumber(screenNumber) else { return modelPoint }
            return ScreenshotGeometry.screenshotPixel(
                fromModelCoordinate: modelPoint,
                convention: convention,
                sentImageSize: sentImageSize
            )
        }

        func convertLength(_ modelLength: CGFloat, screenNumber: Int?) -> CGFloat {
            guard let sentImageSize = sentImageSizeForScreenNumber(screenNumber) else { return modelLength }
            return ScreenshotGeometry.screenshotPixelLength(
                fromModelLength: modelLength,
                convention: convention,
                sentImageSize: sentImageSize
            )
        }

        switch command {
        case let .point(modelPoint, label, screenNumber):
            return .point(at: convertPoint(modelPoint, screenNumber: screenNumber), label: label, screenNumber: screenNumber)

        case let .annotate(annotation):
            let screenNumber = annotation.screenNumber
            let convertedShape: ScreenAnnotationShape
            switch annotation.shape {
            case let .highlight(firstCorner, oppositeCorner):
                convertedShape = .highlight(
                    firstCorner: convertPoint(firstCorner, screenNumber: screenNumber),
                    oppositeCorner: convertPoint(oppositeCorner, screenNumber: screenNumber)
                )
            case let .circle(center, radius):
                convertedShape = .circle(
                    center: convertPoint(center, screenNumber: screenNumber),
                    radius: convertLength(radius, screenNumber: screenNumber)
                )
            case let .arrow(tail, head):
                convertedShape = .arrow(
                    tail: convertPoint(tail, screenNumber: screenNumber),
                    head: convertPoint(head, screenNumber: screenNumber)
                )
            case let .underline(start, end):
                convertedShape = .underline(
                    start: convertPoint(start, screenNumber: screenNumber),
                    end: convertPoint(end, screenNumber: screenNumber)
                )
            case let .note(anchor, text):
                convertedShape = .note(anchor: convertPoint(anchor, screenNumber: screenNumber), text: text)
            }
            return .annotate(ScreenAnnotation(shape: convertedShape, label: annotation.label, screenNumber: screenNumber))

        case let .act(action):
            switch action {
            case let .click(modelPoint, label, screenNumber):
                return .act(.click(screenshotPixel: convertPoint(modelPoint, screenNumber: screenNumber), label: label, screenNumber: screenNumber))
            case let .doubleClick(modelPoint, label, screenNumber):
                return .act(.doubleClick(screenshotPixel: convertPoint(modelPoint, screenNumber: screenNumber), label: label, screenNumber: screenNumber))
            case let .scroll(modelPoint, direction, screenNumber):
                return .act(.scroll(screenshotPixel: convertPoint(modelPoint, screenNumber: screenNumber), direction: direction, screenNumber: screenNumber))
            case let .rightClick(modelPoint, label, screenNumber):
                return .act(.rightClick(screenshotPixel: convertPoint(modelPoint, screenNumber: screenNumber), label: label, screenNumber: screenNumber))
            case let .tripleClick(modelPoint, label, screenNumber):
                return .act(.tripleClick(screenshotPixel: convertPoint(modelPoint, screenNumber: screenNumber), label: label, screenNumber: screenNumber))
            case let .drag(modelStartPoint, modelEndPoint, screenNumber):
                return .act(.drag(
                    fromScreenshotPixel: convertPoint(modelStartPoint, screenNumber: screenNumber),
                    toScreenshotPixel: convertPoint(modelEndPoint, screenNumber: screenNumber),
                    screenNumber: screenNumber
                ))
            case let .moveMouse(modelPoint, screenNumber):
                return .act(.moveMouse(screenshotPixel: convertPoint(modelPoint, screenNumber: screenNumber), screenNumber: screenNumber))
            case .type, .key:
                return command
            }
        }
    }
}

// MARK: - Placed Guidance (screen points, ready to render)

/// The pointer, placed on a real screen. Rendered by the overlay at the target
/// itself — there is no resting or mouse-following cursor.
struct PlacedPointer: Identifiable, Equatable {
    let id = UUID()
    /// Where the pointer's tip goes, in AppKit global coordinates.
    let appKitGlobalPoint: CGPoint
    /// The display the target is on (AppKit global frame), so only that
    /// screen's overlay draws it.
    let displayFrame: CGRect
    let label: String?
    /// The real UI element's frame (AppKit global) when Accessibility found
    /// one under the target, drawn as a soft ring so the user sees exactly
    /// what is meant.
    let highlightedElementFrame: CGRect?
}

/// An annotation shape in AppKit global coordinates.
enum PlacedAnnotationShape: Equatable, Codable {
    case highlight(frame: CGRect)
    case circle(center: CGPoint, radius: CGFloat)
    case arrow(tail: CGPoint, head: CGPoint)
    case underline(start: CGPoint, end: CGPoint)
    case note(anchor: CGPoint, text: String)
}

struct PlacedAnnotation: Identifiable, Equatable {
    let id = UUID()
    let shape: PlacedAnnotationShape
    let label: String?
    let displayFrame: CGRect
}
