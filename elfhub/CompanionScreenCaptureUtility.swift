//
//  CompanionScreenCaptureUtility.swift
//  elfhub
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// Core Graphics display ID for this screen. Used to look up the display's
    /// top-left-origin bounds via CGDisplayBounds when converting a screenshot
    /// pixel into a point that a real CGEvent click can target.
    let displayID: CGDirectDisplayID

    // MARK: - Coordinate Mapping
    //
    // Guidance coordinates arrive in the screenshot's pixel space (top-left
    // origin, e.g. 1280x831). The same pixel has to be expressed in two
    // different global coordinate systems:
    //   - AppKit global (bottom-left origin) to draw the pointer and annotations
    //   - Core Graphics global (top-left origin) to post a real CGEvent click
    // Both start from the same shared scaling step below.

    /// Clamps a screenshot pixel into the image bounds and scales it into this
    /// display's local point space, keeping the top-left origin (y grows downward).
    func displayLocalPoint(fromScreenshotPixel screenshotPixel: CGPoint) -> CGPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)
        let displayWidth = CGFloat(displayWidthInPoints)
        let displayHeight = CGFloat(displayHeightInPoints)

        let clampedX = max(0, min(screenshotPixel.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPixel.y, screenshotHeight))

        return CGPoint(
            x: clampedX * (displayWidth / screenshotWidth),
            y: clampedY * (displayHeight / screenshotHeight)
        )
    }

    /// AppKit global point (bottom-left origin) for the guidance overlay.
    /// Flips Y from the screenshot's top-left origin to AppKit's bottom-left
    /// origin, then offsets by this display's AppKit frame origin.
    func appKitGlobalPoint(fromScreenshotPixel screenshotPixel: CGPoint) -> CGPoint {
        let displayLocalPoint = displayLocalPoint(fromScreenshotPixel: screenshotPixel)
        let appKitY = CGFloat(displayHeightInPoints) - displayLocalPoint.y
        return CGPoint(
            x: displayLocalPoint.x + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    /// Core Graphics global point (top-left origin) for a real CGEvent click.
    /// CGDisplayBounds already reports this display's frame in top-left global
    /// coordinates, so no Y-flip is needed. This avoids the fragile "flip against
    /// the primary screen's height" math that breaks on mixed-resolution and
    /// multi-monitor layouts — the most load-bearing detail for clicking the
    /// right spot.
    func coreGraphicsGlobalPoint(fromScreenshotPixel screenshotPixel: CGPoint) -> CGPoint {
        let displayLocalPoint = displayLocalPoint(fromScreenshotPixel: screenshotPixel)
        let coreGraphicsDisplayBounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: coreGraphicsDisplayBounds.origin.x + displayLocalPoint.x,
            y: coreGraphicsDisplayBounds.origin.y + displayLocalPoint.y
        )
    }

    /// The inverse of appKitGlobalPoint(fromScreenshotPixel:): where an
    /// AppKit global point (e.g. the user's ink) lands in the screenshot.
    func screenshotPixel(fromAppKitGlobalPoint appKitGlobalPoint: CGPoint) -> CGPoint {
        let displayLocalX = appKitGlobalPoint.x - displayFrame.origin.x
        let displayLocalYFromTop = CGFloat(displayHeightInPoints) - (appKitGlobalPoint.y - displayFrame.origin.y)
        return CGPoint(
            x: displayLocalX * (CGFloat(screenshotWidthInPixels) / CGFloat(displayWidthInPoints)),
            y: displayLocalYFromTop * (CGFloat(screenshotHeightInPixels) / CGFloat(displayHeightInPoints))
        )
    }

    /// The same capture with different image bytes (e.g. with the user's ink drawn in).
    func replacingImageData(_ replacementImageData: Data) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: replacementImageData,
            label: label,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: displayWidthInPoints,
            displayHeightInPoints: displayHeightInPoints,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels,
            displayID: displayID
        )
    }

    /// Converts a length in screenshot pixels (e.g. a circle radius) to screen points.
    func pointLength(fromScreenshotPixelLength screenshotPixelLength: CGFloat) -> CGFloat {
        screenshotPixelLength * (CGFloat(displayWidthInPoints) / CGFloat(screenshotWidthInPixels))
    }

    var sentImageSize: CGSize {
        CGSize(width: screenshotWidthInPixels, height: screenshotHeightInPixels)
    }

    /// The capture a guidance command targets: its 1-based screen number when
    /// valid, otherwise the primary-focus screen (where the mouse is), otherwise
    /// the first capture. Shared by pointing, annotating and acting so they
    /// always agree on which display a coordinate belongs to.
    static func targetCapture(screenNumber: Int?, in screenCaptures: [CompanionScreenCapture]) -> CompanionScreenCapture? {
        if let screenNumber, screenNumber >= 1, screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }
        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Index of the screen the cursor is on. Frames and cursor are AppKit
    /// global coordinates (bottom-left origin). CGRect.contains is half-open,
    /// so a shared edge belongs to the screen the cursor just entered — but
    /// it also misses the top edge (NSEvent.mouseLocation can report
    /// y == frame.maxY) and gaps between monitors, so when no frame contains
    /// the cursor the nearest one wins. Nil only when there are no screens.
    nonisolated static func indexOfScreenFrame(containingCursorLocation cursorLocation: CGPoint, in screenFrames: [CGRect]) -> Int? {
        if let containingScreenIndex = screenFrames.firstIndex(where: { $0.contains(cursorLocation) }) {
            return containingScreenIndex
        }

        func distanceFromCursor(to screenFrame: CGRect) -> CGFloat {
            let horizontalDistance = max(screenFrame.minX - cursorLocation.x, 0, cursorLocation.x - screenFrame.maxX)
            let verticalDistance = max(screenFrame.minY - cursorLocation.y, 0, cursorLocation.y - screenFrame.maxY)
            return hypot(horizontalDistance, verticalDistance)
        }

        return screenFrames.indices.min { firstScreenIndex, secondScreenIndex in
            distanceFromCursor(to: screenFrames[firstScreenIndex]) < distanceFromCursor(to: screenFrames[secondScreenIndex])
        }
    }

    /// Captures the display the user's mouse is on — and only that one — as
    /// JPEG data. On a multi-monitor setup the user is focused on the screen
    /// they're pointing at, so the model gets one clear image instead of
    /// several competing ones (also fewer image tokens and less latency).
    /// Returns a one-element array so placement and actions, which look
    /// captures up by screen number, keep working unchanged.
    ///
    /// The image is sized for the active model via ScreenshotGeometry: never
    /// larger than the model's native image limits, because an oversized image
    /// is silently resized by the provider and the model's coordinates then
    /// drift away from the dimensions it was told.
    static func captureCursorScreenAsJPEG(visionProfile: ModelVisionProfile) async throws -> [CompanionScreenCapture] {
        [try await captureDisplayAsJPEG(displayID: nil, visionProfile: visionProfile)]
    }

    /// The same capture of one particular display (nil = the one under the
    /// cursor). A multi-step run stays on the display it started on, even
    /// if the pointer wanders to another one.
    static func captureDisplayAsJPEG(displayID requestedDisplayID: CGDirectDisplayID?, visionProfile: ModelVisionProfile) async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels. Also exclude
        // windows from privacy-blocklisted apps (password managers etc.) so
        // their contents never leave the machine.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let screenCapturePrivacyBlocklist = ScreenCapturePrivacyBlocklist.shared
        let excludedWindows = content.windows.filter { window in
            let owningBundleIdentifier = window.owningApplication?.bundleIdentifier
            return owningBundleIdentifier == ownBundleIdentifier
                || screenCapturePrivacyBlocklist.isBlocked(bundleIdentifier: owningBundleIdentifier)
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        let nsScreenByDisplayID = nsScreensByDisplayID()

        // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
        // displayFrame is in the same coordinate system as NSEvent.mouseLocation
        // and the overlay window frames in ScreenGuidanceOverlayView.
        let displayFrames = content.displays.map { display in
            nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        }

        // The cursor's display; if it can't be resolved (e.g. a display was
        // unplugged mid-turn) the first display still answers the turn.
        let cursorDisplayIndex = indexOfScreenFrame(containingCursorLocation: NSEvent.mouseLocation, in: displayFrames) ?? 0
        let requestedDisplayIndex = requestedDisplayID.flatMap { requestedDisplayID in
            content.displays.firstIndex { $0.displayID == requestedDisplayID }
        }
        if requestedDisplayID != nil && requestedDisplayIndex == nil {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "The display this started on isn't connected any more"])
        }
        let capturedDisplayIndex = requestedDisplayIndex ?? cursorDisplayIndex
        let display = content.displays[capturedDisplayIndex]
        let displayFrame = displayFrames[capturedDisplayIndex]

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        // SCDisplay reports points; the native pixel size is points times
        // the backing scale (2x on Retina). Never upscale beyond it.
        let backingScaleFactor = nsScreenByDisplayID[display.displayID]?.backingScaleFactor ?? 1
        let targetCaptureSize = ScreenshotGeometry.targetCaptureSize(
            sourceWidthInPixels: Int(CGFloat(display.width) * backingScaleFactor),
            sourceHeightInPixels: Int(CGFloat(display.height) * backingScaleFactor),
            profile: visionProfile
        )
        let configuration = SCStreamConfiguration()
        configuration.width = targetCaptureSize.widthInPixels
        configuration.height = targetCaptureSize.heightInPixels

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "user's screen (the one their mouse is on)",
            isCursorScreen: true,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height,
            displayID: display.displayID
        )
    }

    /// Part of a captured display at full resolution (a multi-step run's
    /// zoom), sized to the usual screenshot, as JPEG. The region is in
    /// `capture`'s screenshot pixels; the model keeps answering in the full
    /// screenshot's coordinates.
    static func captureZoomedRegionAsJPEG(
        of capture: CompanionScreenCapture,
        regionInScreenshotPixels: CGRect
    ) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == capture.displayID }) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "The display this started on isn't connected any more"])
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let screenCapturePrivacyBlocklist = ScreenCapturePrivacyBlocklist.shared
        let excludedWindows = content.windows.filter { window in
            let owningBundleIdentifier = window.owningApplication?.bundleIdentifier
            return owningBundleIdentifier == ownBundleIdentifier
                || screenCapturePrivacyBlocklist.isBlocked(bundleIdentifier: owningBundleIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let topLeftInDisplayPoints = capture.displayLocalPoint(fromScreenshotPixel: regionInScreenshotPixels.origin)
        let bottomRightInDisplayPoints = capture.displayLocalPoint(fromScreenshotPixel: CGPoint(
            x: regionInScreenshotPixels.maxX,
            y: regionInScreenshotPixels.maxY
        ))
        let backingScaleFactor = nsScreensByDisplayID()[capture.displayID]?.backingScaleFactor ?? 1
        let nativePixelsPerScreenshotPixel = CGFloat(capture.displayWidthInPoints) * backingScaleFactor
            / CGFloat(max(capture.screenshotWidthInPixels, 1))
        let outputSize = ScreenshotGeometry.zoomedRegionOutputSize(
            regionInScreenshotPixels: regionInScreenshotPixels,
            screenshotSize: capture.sentImageSize,
            nativePixelsPerScreenshotPixel: nativePixelsPerScreenshotPixel
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: topLeftInDisplayPoints.x,
            y: topLeftInDisplayPoints.y,
            width: bottomRightInDisplayPoints.x - topLeftInDisplayPoints.x,
            height: bottomRightInDisplayPoints.y - topLeftInDisplayPoints.y
        )
        configuration.width = outputSize.widthInPixels
        configuration.height = outputSize.heightInPixels

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture the zoomed region"])
        }
        return jpegData
    }

    /// Core Graphics display ID of the screen the cursor is on right now.
    static func displayIDOfScreenUnderCursor() -> CGDirectDisplayID? {
        let screensWithDisplayIDs = nsScreensByDisplayID().map { (displayID: $0.key, screenFrame: $0.value.frame) }
        guard let cursorScreenIndex = indexOfScreenFrame(
            containingCursorLocation: NSEvent.mouseLocation,
            in: screensWithDisplayIDs.map(\.screenFrame)
        ) else { return nil }
        return screensWithDisplayIDs[cursorScreenIndex].displayID
    }

    /// The push-to-talk screenshot is taken at key-down so it's ready when
    /// the user stops talking. If they moved the mouse to another monitor
    /// meanwhile, that screenshot shows the wrong screen and is retaken.
    /// An unknown cursor screen keeps the prefetch rather than guessing.
    nonisolated static func shouldReusePrefetchedScreenCaptures(
        _ prefetchedScreenCaptures: [CompanionScreenCapture]?,
        cursorDisplayIDWhenTurnIsSent: CGDirectDisplayID?
    ) -> Bool {
        guard let prefetchedCapture = prefetchedScreenCaptures?.first else { return false }
        guard let cursorDisplayIDWhenTurnIsSent else { return true }
        return prefetchedCapture.displayID == cursorDisplayIDWhenTurnIsSent
    }

    private static func nsScreensByDisplayID() -> [CGDirectDisplayID: NSScreen] {
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }
        return nsScreenByDisplayID
    }
}
