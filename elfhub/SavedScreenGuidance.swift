//
//  SavedScreenGuidance.swift
//  elfhub
//
//  The pointer and marks elfhub drew for one reply, saved as small vector data
//  next to the chat — never as a second, marked-up image. The chat redraws
//  them on top of the one saved screenshot with the same views the live
//  overlay uses, so the "with marks" version looks like what the user saw.
//
//  Coordinates are display-local AppKit points (bottom-left origin): the
//  placed guidance minus the captured display's origin. That keeps the exact
//  on-screen result, including Accessibility snapping and the element ring.
//

import CoreGraphics
import Foundation

struct SavedScreenGuidance: Codable, Equatable {
    struct SavedPointer: Codable, Equatable {
        let tipPoint: CGPoint
        let label: String?
        let highlightedElementFrame: CGRect?
    }

    struct SavedAnnotation: Codable, Equatable {
        let shape: PlacedAnnotationShape
        let label: String?
    }

    /// Size of the captured display; the saved screenshot has the same
    /// aspect ratio, so marks are laid out in this space and scaled with it.
    let displaySizeInPoints: CGSize
    let pointer: SavedPointer?
    let annotations: [SavedAnnotation]

    /// Keeps the guidance placed on the captured display, made relative to
    /// it. Nil when nothing was drawn there, so replies without marks carry
    /// no guidance at all.
    init?(pointer placedPointer: PlacedPointer?, annotations placedAnnotations: [PlacedAnnotation], displayFrame: CGRect) {
        let displayOrigin = displayFrame.origin

        func displayLocalPoint(_ appKitGlobalPoint: CGPoint) -> CGPoint {
            CGPoint(x: appKitGlobalPoint.x - displayOrigin.x, y: appKitGlobalPoint.y - displayOrigin.y)
        }

        func displayLocalRect(_ appKitGlobalRect: CGRect) -> CGRect {
            CGRect(origin: displayLocalPoint(appKitGlobalRect.origin), size: appKitGlobalRect.size)
        }

        var savedPointer: SavedPointer?
        if let placedPointer, placedPointer.displayFrame == displayFrame {
            savedPointer = SavedPointer(
                tipPoint: displayLocalPoint(placedPointer.appKitGlobalPoint),
                label: placedPointer.label,
                highlightedElementFrame: placedPointer.highlightedElementFrame.map(displayLocalRect)
            )
        }

        let savedAnnotations = placedAnnotations
            .filter { $0.displayFrame == displayFrame }
            .map { placedAnnotation -> SavedAnnotation in
                let displayLocalShape: PlacedAnnotationShape
                switch placedAnnotation.shape {
                case let .highlight(frame):
                    displayLocalShape = .highlight(frame: displayLocalRect(frame))
                case let .circle(center, radius):
                    displayLocalShape = .circle(center: displayLocalPoint(center), radius: radius)
                case let .arrow(tail, head):
                    displayLocalShape = .arrow(tail: displayLocalPoint(tail), head: displayLocalPoint(head))
                case let .underline(start, end):
                    displayLocalShape = .underline(start: displayLocalPoint(start), end: displayLocalPoint(end))
                case let .note(anchor, text):
                    displayLocalShape = .note(anchor: displayLocalPoint(anchor), text: text)
                }
                return SavedAnnotation(shape: displayLocalShape, label: placedAnnotation.label)
            }

        guard savedPointer != nil || !savedAnnotations.isEmpty else { return nil }
        self.displaySizeInPoints = displayFrame.size
        self.pointer = savedPointer
        self.annotations = savedAnnotations
    }

    // MARK: - Rebuilt for drawing

    /// A display-sized frame at the origin; the overlay views draw into it
    /// exactly as they draw onto a real screen.
    var localScreenFrame: CGRect {
        CGRect(origin: .zero, size: displaySizeInPoints)
    }

    var placedPointer: PlacedPointer? {
        pointer.map { savedPointer in
            PlacedPointer(
                appKitGlobalPoint: savedPointer.tipPoint,
                displayFrame: localScreenFrame,
                label: savedPointer.label,
                highlightedElementFrame: savedPointer.highlightedElementFrame
            )
        }
    }

    var placedAnnotations: [PlacedAnnotation] {
        annotations.map { savedAnnotation in
            PlacedAnnotation(shape: savedAnnotation.shape, label: savedAnnotation.label, displayFrame: localScreenFrame)
        }
    }
}

// MARK: - The User's Own Drawing

/// What the user drew while holding push-to-talk, saved as stroke data on
/// their question. The stored screenshot is the original ("before"); the
/// chat draws these strokes on top for the "after" view — one image, both
/// versions. (The model itself received the image with the ink drawn in.)
struct SavedUserInk: Codable, Equatable {
    /// Same space as SavedScreenGuidance: display-local AppKit points.
    let displaySizeInPoints: CGSize
    let strokes: [[CGPoint]]

    /// Keeps the strokes that touch the captured display — the same ones
    /// burned into the image the model saw — made relative to it.
    init?(userInkStrokes: [UserInkStroke], displayFrame: CGRect) {
        // Slightly enlarged so points on the display's very edge still count
        // (matches UserInkScreenshotRenderer.strokesInScreenshotPixels).
        let displayFrameIncludingEdges = displayFrame.insetBy(dx: -1, dy: -1)
        let displayLocalStrokes = userInkStrokes
            .filter { userInkStroke in
                userInkStroke.points.contains { displayFrameIncludingEdges.contains($0) }
            }
            .map { userInkStroke in
                userInkStroke.points.map { point in
                    CGPoint(x: point.x - displayFrame.origin.x, y: point.y - displayFrame.origin.y)
                }
            }
        guard !displayLocalStrokes.isEmpty else { return nil }
        self.displaySizeInPoints = displayFrame.size
        self.strokes = displayLocalStrokes
    }

    var localScreenFrame: CGRect {
        CGRect(origin: .zero, size: displaySizeInPoints)
    }

    /// Rebuilt for UserInkStrokesView, the same view that drew the live trail.
    var userInkStrokes: [UserInkStroke] {
        strokes.compactMap { strokePoints in
            guard let firstPoint = strokePoints.first else { return nil }
            var userInkStroke = UserInkStroke(startingAt: firstPoint)
            for point in strokePoints.dropFirst() {
                userInkStroke.append(point)
            }
            return userInkStroke
        }
    }
}
