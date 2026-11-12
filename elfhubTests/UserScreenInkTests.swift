//
//  UserScreenInkTests.swift
//  elfhubTests
//
//  Drawing on the screen while holding push-to-talk: recording strokes,
//  mapping them into the screenshot, burning them into the image the model
//  sees, and describing them in words.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import elfhub

@MainActor
struct UserScreenInkTests {

    // MARK: - Recording

    @Test func strokesSkipPointsTooCloseTogether() {
        var userInkStroke = UserInkStroke(startingAt: CGPoint(x: 0, y: 0))
        userInkStroke.append(CGPoint(x: 1, y: 0))   // under the minimum spacing
        userInkStroke.append(CGPoint(x: 5, y: 0))
        userInkStroke.append(CGPoint(x: 5, y: 1))   // under the minimum spacing
        userInkStroke.append(CGPoint(x: 5, y: 10))
        #expect(userInkStroke.points == [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 10)])
    }

    /// Safety net: if a key release was ever missed, the first mouse event
    /// without the shortcut's modifiers stops drawing and lets clicks through.
    @Test func shortcutModifiersAreReadFromMouseEventFlags() {
        let originalShortcutOption = BuddyPushToTalkShortcut.currentShortcutOption
        defer { BuddyPushToTalkShortcut.setCurrentShortcutOption(originalShortcutOption) }

        BuddyPushToTalkShortcut.setCurrentShortcutOption(.controlOption)
        let controlAndOption = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        #expect(BuddyPushToTalkShortcut.areShortcutModifiersHeld(modifierFlagsRawValue: controlAndOption))
        #expect(BuddyPushToTalkShortcut.areShortcutModifiersHeld(modifierFlagsRawValue: controlAndOption | CGEventFlags.maskShift.rawValue))
        #expect(!BuddyPushToTalkShortcut.areShortcutModifiersHeld(modifierFlagsRawValue: CGEventFlags.maskControl.rawValue))

        BuddyPushToTalkShortcut.setCurrentShortcutOption(.shiftControlSpace)
        #expect(BuddyPushToTalkShortcut.areShortcutModifiersHeld(
            modifierFlagsRawValue: CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
        ))
    }

    @Test func coreGraphicsEventLocationsBecomeAppKitPoints() {
        // CG is top-left origin on the primary screen; AppKit is bottom-left.
        #expect(UserScreenInkRecorder.appKitGlobalPoint(
            fromCoreGraphicsGlobalPoint: CGPoint(x: 100, y: 50),
            primaryScreenHeight: 900
        ) == CGPoint(x: 100, y: 850))
    }

    // MARK: - Into the screenshot

    /// A 1440x900-point display at AppKit origin (1440, -200), sent to the
    /// model as a 1280x800 image.
    private func makeCapture(imageData: Data = Data()) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: imageData,
            label: "user's screen",
            isCursorScreen: true,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: CGRect(x: 1440, y: -200, width: 1440, height: 900),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayID: 1
        )
    }

    @Test func appKitPointsMapBackToScreenshotPixels() {
        let capture = makeCapture()
        let screenshotPixel = CGPoint(x: 640, y: 200)
        let appKitGlobalPoint = capture.appKitGlobalPoint(fromScreenshotPixel: screenshotPixel)
        let roundTrippedPixel = capture.screenshotPixel(fromAppKitGlobalPoint: appKitGlobalPoint)
        #expect(abs(roundTrippedPixel.x - 640) < 0.001)
        #expect(abs(roundTrippedPixel.y - 200) < 0.001)
        // Top-left corner of the display is pixel (0, 0).
        #expect(capture.screenshotPixel(fromAppKitGlobalPoint: CGPoint(x: 1440, y: 700)) == .zero)
    }

    @Test func strokesOffTheCapturedDisplayAreLeftOut() {
        let capture = makeCapture()
        var strokeOnCapturedDisplay = UserInkStroke(startingAt: CGPoint(x: 1440 + 144, y: 700 - 90))
        strokeOnCapturedDisplay.append(CGPoint(x: 1440 + 288, y: 700 - 90))
        let strokeOnOtherDisplay = UserInkStroke(startingAt: CGPoint(x: 100, y: 100))

        let strokesInScreenshotPixels = UserInkScreenshotRenderer.strokesInScreenshotPixels(
            [strokeOnCapturedDisplay, strokeOnOtherDisplay],
            on: capture
        )
        #expect(strokesInScreenshotPixels.count == 1)
        #expect(strokesInScreenshotPixels.first?.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
                == [CGPoint(x: 128, y: 80), CGPoint(x: 256, y: 80)])
    }

    @Test func inkIsDrawnIntoTheScreenshot() throws {
        let whiteJPEGData = try makeSolidWhiteJPEG(width: 200, height: 100)
        let inkedJPEGData = try #require(UserInkScreenshotRenderer.drawing(
            [[CGPoint(x: 20, y: 50), CGPoint(x: 180, y: 50)]],
            ontoScreenshotJPEG: whiteJPEGData
        ))

        let inkedPixel = try rgbPixel(atX: 100, y: 50, inJPEG: inkedJPEGData)
        #expect(inkedPixel.red > 200 && inkedPixel.blue < 120)  // orange ink on the stroke
        let untouchedPixel = try rgbPixel(atX: 100, y: 90, inJPEG: inkedJPEGData)
        #expect(untouchedPixel.red > 230 && untouchedPixel.green > 230 && untouchedPixel.blue > 230)
    }

    // MARK: - Describing it to the model

    private func circleStroke(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        (0...36).map { stepIndex in
            let angle = CGFloat(stepIndex) / 36 * 2 * .pi
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    @Test func marksAreClassifiedAsCirclesLinesOrSpots() {
        let circleMarkKind = UserInkDescriber.markKind(forStrokeInScreenshotPixels: circleStroke(center: CGPoint(x: 400, y: 300), radius: 50))
        guard case let .circledArea(topLeft, bottomRight) = circleMarkKind else {
            Issue.record("expected a circled area, got \(String(describing: circleMarkKind))")
            return
        }
        #expect(abs(topLeft.x - 350) < 0.5 && abs(topLeft.y - 250) < 0.5)
        #expect(abs(bottomRight.x - 450) < 0.5 && abs(bottomRight.y - 350) < 0.5)
        #expect(UserInkDescriber.markKind(forStrokeInScreenshotPixels: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 20), CGPoint(x: 210, y: 30)])
                == .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 30)))
        #expect(UserInkDescriber.markKind(forStrokeInScreenshotPixels: [CGPoint(x: 60, y: 60), CGPoint(x: 63, y: 62)])
                == .spot(CGPoint(x: 61.5, y: 61)))
        #expect(UserInkDescriber.markKind(forStrokeInScreenshotPixels: []) == nil)
    }

    @Test func promptNoteUsesTheModelsCoordinates() throws {
        let pixelNote = try #require(UserInkDescriber.promptNote(
            forStrokesInScreenshotPixels: [circleStroke(center: CGPoint(x: 400, y: 300), radius: 50)],
            convention: .imagePixels,
            sentImageSize: CGSize(width: 1280, height: 800)
        ))
        #expect(pixelNote.contains("circled the area from (350, 250) to (450, 350)"))
        #expect(pixelNote.contains("orange"))

        let normalizedNote = try #require(UserInkDescriber.promptNote(
            forStrokesInScreenshotPixels: [[CGPoint(x: 0, y: 0), CGPoint(x: 640, y: 400)]],
            convention: .normalizedTo1000,
            sentImageSize: CGSize(width: 1280, height: 800)
        ))
        #expect(normalizedNote.contains("drew a line from (0, 0) to (500, 500)"))

        #expect(UserInkDescriber.promptNote(forStrokesInScreenshotPixels: [], convention: .imagePixels, sentImageSize: .zero) == nil)
    }

    @Test func modelCoordinatesInvertScreenshotPixels() {
        let sentImageSize = CGSize(width: 1280, height: 800)
        for convention in ModelCoordinateConvention.allCases {
            let modelCoordinate = ScreenshotGeometry.modelCoordinate(
                fromScreenshotPixel: CGPoint(x: 320, y: 600),
                convention: convention,
                sentImageSize: sentImageSize
            )
            let backToPixels = ScreenshotGeometry.screenshotPixel(
                fromModelCoordinate: modelCoordinate,
                convention: convention,
                sentImageSize: sentImageSize
            )
            #expect(abs(backToPixels.x - 320) < 0.001 && abs(backToPixels.y - 600) < 0.001)
        }
    }

    // MARK: - Image helpers

    private func makeSolidWhiteJPEG(width: Int, height: Int) throws -> Data {
        let bitmapContext = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        bitmapContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let whiteImage = try #require(bitmapContext.makeImage())
        let jpegData = NSMutableData()
        let imageDestination = try #require(CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, whiteImage, nil)
        #expect(CGImageDestinationFinalize(imageDestination))
        return jpegData as Data
    }

    /// Reads one pixel with a top-left origin.
    private func rgbPixel(atX x: Int, y: Int, inJPEG jpegData: Data) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let imageSource = try #require(CGImageSourceCreateWithData(jpegData as CFData, nil))
        let decodedImage = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let width = decodedImage.width
        let height = decodedImage.height
        var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapContext = try #require(CGContext(
            data: &pixelBytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        bitmapContext.draw(decodedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let byteOffset = (y * width + x) * 4
        return (pixelBytes[byteOffset], pixelBytes[byteOffset + 1], pixelBytes[byteOffset + 2])
    }
}
