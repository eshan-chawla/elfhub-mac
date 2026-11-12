//
//  UserScreenInk.swift
//  elfhub
//
//  Lets the user draw on their screen while holding push-to-talk: press and
//  drag the mouse to circle, underline or point at something as they speak.
//
//  - UserScreenInkRecorder swallows mouse presses/drags only while the
//    shortcut is held (so the app underneath never gets a stray click) and
//    records each stroke; the overlay draws it live as a solid trailing line.
//  - UserInkScreenshotRenderer burns the strokes into the screenshot the
//    model receives (the only copy kept), so it sees exactly what was marked.
//  - UserInkDescriber adds a short note to the user's message — "circled the
//    area from (x, y) to (x, y)" — in the model's own coordinate space, so
//    "this" and "that" in what they said can be resolved.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Stroke

/// One continuous press-and-drag, in AppKit global points (bottom-left
/// origin) — the same space as the overlay's other marks.
struct UserInkStroke: Equatable {
    private(set) var points: [CGPoint]

    /// Mouse events arrive at display refresh rate; points closer than this
    /// add nothing visible and only bloat the path.
    static let minimumPointSpacing: CGFloat = 2

    init(startingAt startPoint: CGPoint) {
        points = [startPoint]
    }

    mutating func append(_ point: CGPoint) {
        if let lastPoint = points.last,
           hypot(point.x - lastPoint.x, point.y - lastPoint.y) < Self.minimumPointSpacing {
            return
        }
        points.append(point)
    }
}

/// The ink's look, shared by the live trail and the copy burned into the
/// screenshot. Orange, so it's clearly the user's and not elfhub's blue marks.
enum UserInkAppearance {
    /// Matches DS.Colors.overlayUserInk.
    static let inkCGColor = CGColor(srgbRed: 1.0, green: 0.42, blue: 0.1, alpha: 1)
    static let inkLineWidthInPoints: CGFloat = 4
}

// MARK: - Recorder

/// Records strokes while push-to-talk is held. Uses an active event tap that
/// exists only between key-down and key-up, so clicks are swallowed only
/// while the user is deliberately drawing.
@MainActor
final class UserScreenInkRecorder {
    /// Called with every stroke so far whenever one grows, so the overlay can
    /// draw the trail under the cursor as it moves.
    var onStrokesChanged: (([UserInkStroke]) -> Void)?

    private(set) var strokes: [UserInkStroke] = []
    /// True only for a press that this recorder swallowed — a drag that began
    /// before the shortcut was pressed belongs to the app and passes through.
    private var isDrawingStroke = false
    private var primaryScreenHeight: CGFloat = 0
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    var isRecording: Bool { eventTap != nil }

    func startRecording() {
        stopEventTap()
        strokes = []
        isDrawingStroke = false
        // CG event locations are top-left based on the primary (menu bar)
        // screen; AppKit's global space flips around that screen's height.
        primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0

        let monitoredEventTypes: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let userScreenInkRecorder = Unmanaged<UserScreenInkRecorder>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return userScreenInkRecorder.handleEventTap(eventType: eventType, event: event)
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active, so presses and drags can be swallowed while drawing.
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Screen ink: couldn't create CGEvent tap")
            return
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0) else {
            CFMachPortInvalidate(createdEventTap)
            return
        }

        eventTap = createdEventTap
        eventTapRunLoopSource = createdRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
    }

    /// Ends recording (the shortcut was released) and hands back the strokes.
    @discardableResult
    func stopRecording() -> [UserInkStroke] {
        stopEventTap()
        isDrawingStroke = false
        return strokes
    }

    private func stopEventTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    nonisolated static func appKitGlobalPoint(fromCoreGraphicsGlobalPoint coreGraphicsGlobalPoint: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: coreGraphicsGlobalPoint.x, y: primaryScreenHeight - coreGraphicsGlobalPoint.y)
    }

    private func handleEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // elfhub's own synthetic clicks are never ink.
        if ScreenActionSynthesizer.isSyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        // Safety net: if the key release was missed, the first mouse event
        // without the shortcut's modifiers ends drawing and goes to the app.
        guard BuddyPushToTalkShortcut.areShortcutModifiersHeld(modifierFlagsRawValue: event.flags.rawValue) else {
            stopRecording()
            return Unmanaged.passUnretained(event)
        }

        let appKitGlobalPoint = Self.appKitGlobalPoint(
            fromCoreGraphicsGlobalPoint: event.location,
            primaryScreenHeight: primaryScreenHeight
        )

        switch eventType {
        case .leftMouseDown:
            isDrawingStroke = true
            strokes.append(UserInkStroke(startingAt: appKitGlobalPoint))
            onStrokesChanged?(strokes)
            return nil

        case .leftMouseDragged:
            guard isDrawingStroke, !strokes.isEmpty else { return Unmanaged.passUnretained(event) }
            strokes[strokes.count - 1].append(appKitGlobalPoint)
            onStrokesChanged?(strokes)
            return nil

        case .leftMouseUp:
            guard isDrawingStroke else { return Unmanaged.passUnretained(event) }
            isDrawingStroke = false
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

// MARK: - Into the Screenshot

enum UserInkScreenshotRenderer {

    /// Each stroke mapped into the capture's pixel space (top-left origin).
    /// Strokes with no point on the captured display are left out.
    static func strokesInScreenshotPixels(_ userInkStrokes: [UserInkStroke], on screenCapture: CompanionScreenCapture) -> [[CGPoint]] {
        // Slightly enlarged so points on the display's very edge still count.
        let capturedDisplayFrameIncludingEdges = screenCapture.displayFrame.insetBy(dx: -1, dy: -1)
        return userInkStrokes
            .filter { userInkStroke in
                userInkStroke.points.contains { capturedDisplayFrameIncludingEdges.contains($0) }
            }
            .map { userInkStroke in
                userInkStroke.points.map { screenCapture.screenshotPixel(fromAppKitGlobalPoint: $0) }
            }
    }

    /// The screenshot with the strokes drawn on it, re-encoded as JPEG; nil
    /// if the image can't be decoded or encoded. A white under-stroke keeps
    /// the orange ink readable on any background.
    static func drawing(
        _ strokesInScreenshotPixels: [[CGPoint]],
        ontoScreenshotJPEG screenshotJPEGData: Data,
        lineWidthInPixels: CGFloat = UserInkAppearance.inkLineWidthInPoints
    ) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(screenshotJPEGData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapContext = CGContext(
                data: nil,
                width: screenshotImage.width,
                height: screenshotImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }

        let imageHeight = CGFloat(screenshotImage.height)
        bitmapContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height))

        // Screenshot pixels are top-left based; the bitmap context is bottom-left.
        let inkPath = CGMutablePath()
        for strokePoints in strokesInScreenshotPixels {
            guard let firstPoint = strokePoints.first else { continue }
            let flippedPoints = strokePoints.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }
            inkPath.move(to: flippedPoints[0])
            if strokePoints.count == 1 {
                // A click without a drag still leaves a visible dot.
                inkPath.addLine(to: CGPoint(x: firstPoint.x + 0.1, y: imageHeight - firstPoint.y))
            } else {
                inkPath.addLines(between: flippedPoints)
            }
        }

        bitmapContext.setLineCap(.round)
        bitmapContext.setLineJoin(.round)
        bitmapContext.addPath(inkPath)
        bitmapContext.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        bitmapContext.setLineWidth(lineWidthInPixels + 3)
        bitmapContext.strokePath()
        bitmapContext.addPath(inkPath)
        bitmapContext.setStrokeColor(UserInkAppearance.inkCGColor)
        bitmapContext.setLineWidth(lineWidthInPixels)
        bitmapContext.strokePath()

        guard let inkedImage = bitmapContext.makeImage() else { return nil }
        let inkedJPEGData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(inkedJPEGData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(imageDestination, inkedImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else { return nil }
        return inkedJPEGData as Data
    }
}

// MARK: - Describing It to the Model

enum UserInkDescriber {
    enum MarkKind: Equatable {
        /// A click (or a tiny wiggle) on one spot.
        case spot(CGPoint)
        /// A loop that comes back near where it started: the user circled this area.
        case circledArea(topLeft: CGPoint, bottomRight: CGPoint)
        /// An open stroke — an underline, arrow or line between two places.
        case line(from: CGPoint, to: CGPoint)
    }

    /// A drag shorter than this is a click on a spot.
    private static let maximumSpotPathLengthInPixels: CGFloat = 12

    /// Classifies one stroke given in screenshot pixels.
    static func markKind(forStrokeInScreenshotPixels strokePoints: [CGPoint]) -> MarkKind? {
        guard let firstPoint = strokePoints.first, let lastPoint = strokePoints.last else { return nil }

        let minimumX = strokePoints.map(\.x).min() ?? firstPoint.x
        let maximumX = strokePoints.map(\.x).max() ?? firstPoint.x
        let minimumY = strokePoints.map(\.y).min() ?? firstPoint.y
        let maximumY = strokePoints.map(\.y).max() ?? firstPoint.y

        var pathLength: CGFloat = 0
        for (previousPoint, nextPoint) in zip(strokePoints, strokePoints.dropFirst()) {
            pathLength += hypot(nextPoint.x - previousPoint.x, nextPoint.y - previousPoint.y)
        }

        if pathLength < maximumSpotPathLengthInPixels {
            return .spot(CGPoint(x: (minimumX + maximumX) / 2, y: (minimumY + maximumY) / 2))
        }

        // Closed enough to be a circle: the ends meet relative to the mark's
        // size, and the path went around rather than straight across.
        let largestSide = max(maximumX - minimumX, maximumY - minimumY)
        let distanceBetweenEnds = hypot(lastPoint.x - firstPoint.x, lastPoint.y - firstPoint.y)
        let endsMeet = distanceBetweenEnds <= max(largestSide * 0.35, 24)
        let wentAround = pathLength >= largestSide * 2.2
        if endsMeet && wentAround {
            return .circledArea(
                topLeft: CGPoint(x: minimumX, y: minimumY),
                bottomRight: CGPoint(x: maximumX, y: maximumY)
            )
        }
        return .line(from: firstPoint, to: lastPoint)
    }

    /// A note appended to the user's message, with every coordinate in the
    /// model's own convention. Nil when there are no marks.
    static func promptNote(
        forStrokesInScreenshotPixels strokesInScreenshotPixels: [[CGPoint]],
        convention: ModelCoordinateConvention,
        sentImageSize: CGSize
    ) -> String? {
        func modelCoordinateText(_ screenshotPixel: CGPoint) -> String {
            let modelCoordinate = ScreenshotGeometry.modelCoordinate(
                fromScreenshotPixel: screenshotPixel,
                convention: convention,
                sentImageSize: sentImageSize
            )
            return "(\(Int(modelCoordinate.x.rounded())), \(Int(modelCoordinate.y.rounded())))"
        }

        let markDescriptions = strokesInScreenshotPixels.compactMap { strokePoints -> String? in
            switch markKind(forStrokeInScreenshotPixels: strokePoints) {
            case let .spot(spotPoint):
                return "clicked the spot at \(modelCoordinateText(spotPoint))"
            case let .circledArea(topLeft, bottomRight):
                return "circled the area from \(modelCoordinateText(topLeft)) to \(modelCoordinateText(bottomRight))"
            case let .line(startPoint, endPoint):
                return "drew a line from \(modelCoordinateText(startPoint)) to \(modelCoordinateText(endPoint))"
            case nil:
                return nil
            }
        }
        guard !markDescriptions.isEmpty else { return nil }

        return "[while speaking, the user drew on their screen in orange ink, which you can see in the screenshot: they "
            + markDescriptions.joined(separator: ", then ")
            + ". when they say \"this\", \"that\" or \"here\", they most likely mean what they marked. the orange ink is theirs, not part of what's on screen.]"
    }
}
