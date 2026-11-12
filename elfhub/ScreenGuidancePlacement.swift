//
//  ScreenGuidancePlacement.swift
//  elfhub
//
//  Places pointer and annotation commands (already in screenshot pixels) onto
//  real screens, refining them against the actual UI through Accessibility:
//  a pointer gets a ring around the real element it lands on, and a highlight
//  box snaps to the control it roughly covers.
//

import CoreGraphics
import Foundation

@MainActor
enum ScreenGuidancePlacement {

    /// Places the pointer's tip at the model's point. When that point lands
    /// inside a real, reasonably sized element, the element is outlined too —
    /// the tip itself stays put so it never covers the element's label.
    static func placePointer(
        atScreenshotPixel screenshotPixel: CGPoint,
        label: String?,
        on targetCapture: CompanionScreenCapture
    ) async -> PlacedPointer {
        let coreGraphicsPoint = targetCapture.coreGraphicsGlobalPoint(fromScreenshotPixel: screenshotPixel)
        let elementFacts = await AccessibilityElementLocator.elementFacts(atCoreGraphicsGlobalPoint: coreGraphicsPoint)

        var highlightedElementFrame: CGRect?
        if let elementFacts,
           let elementFrame = elementFacts.frameInCoreGraphicsGlobalCoordinates,
           elementFrame.contains(coreGraphicsPoint),
           AccessibilitySnapping.isElementUsableForSnapping(
               elementFrame: elementFrame,
               role: elementFacts.role,
               displayBounds: CGDisplayBounds(targetCapture.displayID)
           ) {
            highlightedElementFrame = GlobalCoordinateSpaceConversion.appKitRect(fromCoreGraphicsGlobalRect: elementFrame)
        }

        return PlacedPointer(
            appKitGlobalPoint: targetCapture.appKitGlobalPoint(fromScreenshotPixel: screenshotPixel),
            displayFrame: targetCapture.displayFrame,
            label: label ?? elementFacts?.title,
            highlightedElementFrame: highlightedElementFrame
        )
    }

    static func placeAnnotation(
        _ annotation: ScreenAnnotation,
        on targetCapture: CompanionScreenCapture
    ) async -> PlacedAnnotation {
        let placedShape: PlacedAnnotationShape
        switch annotation.shape {
        case let .highlight(firstCorner, oppositeCorner):
            placedShape = .highlight(frame: await placedHighlightFrame(
                firstCorner: firstCorner,
                oppositeCorner: oppositeCorner,
                on: targetCapture
            ))
        case let .circle(center, radius):
            placedShape = .circle(
                center: targetCapture.appKitGlobalPoint(fromScreenshotPixel: center),
                radius: targetCapture.pointLength(fromScreenshotPixelLength: radius)
            )
        case let .arrow(tail, head):
            placedShape = .arrow(
                tail: targetCapture.appKitGlobalPoint(fromScreenshotPixel: tail),
                head: targetCapture.appKitGlobalPoint(fromScreenshotPixel: head)
            )
        case let .underline(start, end):
            placedShape = .underline(
                start: targetCapture.appKitGlobalPoint(fromScreenshotPixel: start),
                end: targetCapture.appKitGlobalPoint(fromScreenshotPixel: end)
            )
        case let .note(anchor, text):
            placedShape = .note(anchor: targetCapture.appKitGlobalPoint(fromScreenshotPixel: anchor), text: text)
        }

        return PlacedAnnotation(shape: placedShape, label: annotation.label, displayFrame: targetCapture.displayFrame)
    }

    /// The highlight box in AppKit global coordinates, snapped to the real
    /// element at its center when the two substantially overlap.
    private static func placedHighlightFrame(
        firstCorner: CGPoint,
        oppositeCorner: CGPoint,
        on targetCapture: CompanionScreenCapture
    ) async -> CGRect {
        let firstCoreGraphicsCorner = targetCapture.coreGraphicsGlobalPoint(fromScreenshotPixel: firstCorner)
        let oppositeCoreGraphicsCorner = targetCapture.coreGraphicsGlobalPoint(fromScreenshotPixel: oppositeCorner)
        let modelCoreGraphicsFrame = CGRect(
            x: min(firstCoreGraphicsCorner.x, oppositeCoreGraphicsCorner.x),
            y: min(firstCoreGraphicsCorner.y, oppositeCoreGraphicsCorner.y),
            width: abs(firstCoreGraphicsCorner.x - oppositeCoreGraphicsCorner.x),
            height: abs(firstCoreGraphicsCorner.y - oppositeCoreGraphicsCorner.y)
        )

        var finalCoreGraphicsFrame = modelCoreGraphicsFrame
        let modelFrameCenter = CGPoint(x: modelCoreGraphicsFrame.midX, y: modelCoreGraphicsFrame.midY)
        if let elementFacts = await AccessibilityElementLocator.elementFacts(atCoreGraphicsGlobalPoint: modelFrameCenter),
           let elementFrame = elementFacts.frameInCoreGraphicsGlobalCoordinates,
           AccessibilitySnapping.isElementUsableForSnapping(
               elementFrame: elementFrame,
               role: elementFacts.role,
               displayBounds: CGDisplayBounds(targetCapture.displayID)
           ),
           let snappedFrame = AccessibilitySnapping.snappedHighlightFrame(
               modelFrame: modelCoreGraphicsFrame,
               elementFrame: elementFrame
           ) {
            finalCoreGraphicsFrame = snappedFrame
        }

        return GlobalCoordinateSpaceConversion.appKitRect(fromCoreGraphicsGlobalRect: finalCoreGraphicsFrame)
    }
}
