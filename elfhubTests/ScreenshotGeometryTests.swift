//
//  ScreenshotGeometryTests.swift
//  elfhubTests
//
//  Screenshot sizing per model and coordinate-convention conversion. These
//  decide whether every point, annotation and click lands where the model
//  meant, so they're covered exhaustively.
//

import CoreGraphics
import Testing
@testable import elfhub

struct ScreenshotGeometryTests {

    // MARK: - Capture sizing

    @Test func retinaDisplayIsCappedToClaudeStandardLimits() {
        // 1512x982 point MacBook Pro display at 2x = 3024x1964 native pixels.
        let size = ScreenshotGeometry.targetCaptureSize(
            sourceWidthInPixels: 3024,
            sourceHeightInPixels: 1964,
            profile: .claudeStandardResolution
        )
        #expect(size.widthInPixels <= 1568)
        #expect(size.heightInPixels <= 1568)
        #expect(size.widthInPixels * size.heightInPixels <= 1_150_000)
    }

    @Test func fourByThreeDisplayRespectsTotalPixelLimitNotJustLongEdge() {
        // A long-edge-only cap of 1568 would give 1568x1176 = 1.84 MP, over the limit.
        let size = ScreenshotGeometry.targetCaptureSize(
            sourceWidthInPixels: 2048,
            sourceHeightInPixels: 1536,
            profile: .claudeStandardResolution
        )
        #expect(size.widthInPixels * size.heightInPixels <= 1_150_000)
    }

    @Test func preservesAspectRatioWithinRounding() {
        let size = ScreenshotGeometry.targetCaptureSize(
            sourceWidthInPixels: 5120,
            sourceHeightInPixels: 2880,
            profile: .claudeHighResolution
        )
        let sourceAspectRatio = 5120.0 / 2880.0
        let targetAspectRatio = Double(size.widthInPixels) / Double(size.heightInPixels)
        #expect(abs(sourceAspectRatio - targetAspectRatio) < 0.01)
        #expect(size.widthInPixels <= 1920)
    }

    @Test func neverUpscalesSmallDisplays() {
        let size = ScreenshotGeometry.targetCaptureSize(
            sourceWidthInPixels: 1024,
            sourceHeightInPixels: 768,
            profile: .claudeHighResolution
        )
        #expect(size.widthInPixels == 1024)
        #expect(size.heightInPixels == 768)
    }

    @Test func handlesPortraitDisplays() {
        let size = ScreenshotGeometry.targetCaptureSize(
            sourceWidthInPixels: 2160,
            sourceHeightInPixels: 3840,
            profile: .genericVisionModel(coordinateConvention: .imagePixels)
        )
        #expect(size.heightInPixels <= 1280)
        #expect(size.widthInPixels < size.heightInPixels)
    }

    // MARK: - Coordinate conventions

    @Test func pixelConventionPassesThrough() {
        let point = ScreenshotGeometry.screenshotPixel(
            fromModelCoordinate: CGPoint(x: 640, y: 300),
            convention: .imagePixels,
            sentImageSize: CGSize(width: 1280, height: 800)
        )
        #expect(point == CGPoint(x: 640, y: 300))
    }

    @Test func normalized1000MapsToImagePixels() {
        let point = ScreenshotGeometry.screenshotPixel(
            fromModelCoordinate: CGPoint(x: 500, y: 250),
            convention: .normalizedTo1000,
            sentImageSize: CGSize(width: 1280, height: 800)
        )
        #expect(point == CGPoint(x: 640, y: 200))
    }

    @Test func normalized999MapsCornerToImageCorner() {
        let point = ScreenshotGeometry.screenshotPixel(
            fromModelCoordinate: CGPoint(x: 999, y: 999),
            convention: .normalizedTo999,
            sentImageSize: CGSize(width: 1280, height: 800)
        )
        #expect(abs(point.x - 1280) < 0.001)
        #expect(abs(point.y - 800) < 0.001)
    }

    @Test func normalizedLengthsScaleByImageWidth() {
        let length = ScreenshotGeometry.screenshotPixelLength(
            fromModelLength: 50,
            convention: .normalizedTo1000,
            sentImageSize: CGSize(width: 1280, height: 800)
        )
        #expect(length == 64)
    }

    // MARK: - Anthropic profile selection

    @Test(arguments: [
        ("claude-sonnet-4-6", false),
        ("claude-opus-4-6", false),
        ("claude-haiku-4-5", false),
        ("claude-opus-4-7", true),
        ("claude-opus-4-8", true),
        ("claude-sonnet-5", true),
        ("claude-sonnet-5-5", true),
        ("claude-opus-5-5", true),
        ("claude-fable-5-1", true),
    ])
    func anthropicModelsMapToTheirImageLimits(modelIdentifier: String, expectsHighResolution: Bool) {
        let profile = ModelVisionProfile.forAnthropicModel(identifier: modelIdentifier)
        #expect((profile == .claudeHighResolution) == expectsHighResolution)
    }

    // MARK: - Command normalization

    @Test func normalizerConvertsEveryCoordinateInACommand() {
        let command = ScreenGuidanceCommand.annotate(ScreenAnnotation(
            shape: .circle(center: CGPoint(x: 500, y: 500), radius: 100),
            label: "here",
            screenNumber: 2
        ))
        let converted = ScreenGuidanceCoordinateNormalizer.convertToScreenshotPixels(
            command,
            convention: .normalizedTo1000,
            sentImageSizeForScreenNumber: { screenNumber in
                screenNumber == 2 ? CGSize(width: 2000, height: 1000) : nil
            }
        )
        #expect(converted == .annotate(ScreenAnnotation(
            shape: .circle(center: CGPoint(x: 1000, y: 500), radius: 200),
            label: "here",
            screenNumber: 2
        )))
    }

    @Test func normalizerLeavesTypeAndKeyActionsAlone() {
        let command = ScreenGuidanceCommand.act(.type(text: "hello"))
        let converted = ScreenGuidanceCoordinateNormalizer.convertToScreenshotPixels(
            command,
            convention: .normalizedTo999,
            sentImageSizeForScreenNumber: { _ in CGSize(width: 1000, height: 1000) }
        )
        #expect(converted == command)
    }
}
