//
//  ScreenshotGeometry.swift
//  elfhub
//
//  Single owner of two things every pointing, annotation and click depends on:
//
//  1. How big each screenshot should be for the active model. Sending an image
//     larger than the model's native limit makes the provider silently resize
//     it, while the prompt still describes the original dimensions — the model
//     then answers in a coordinate space that no longer matches, and every
//     point drifts. So capture size is chosen per model, never "bigger is better".
//
//  2. Which coordinate convention the model answers in. Claude and OpenAI-style
//     models answer in the sent image's pixels; Gemini and several local VLMs
//     (e.g. Qwen-VL) answer in a normalized 0–999 / 0–1000 grid. Everything is
//     converted back to sent-image pixels here, before CompanionScreenCapture
//     maps pixels to real screen points.
//
//  Pure value logic with no AppKit dependency, so it is fully unit-tested.
//

import CoreGraphics
import Foundation

// MARK: - Coordinate Convention

/// The coordinate space a model uses when it names a point on a screenshot.
enum ModelCoordinateConvention: String, Codable, CaseIterable, Identifiable {
    /// Pixel coordinates in the image exactly as it was sent (top-left origin).
    case imagePixels
    /// Both axes normalized to 0…999 regardless of image size (Gemini).
    case normalizedTo999
    /// Both axes normalized to 0…1000 regardless of image size (Qwen-VL and others).
    case normalizedTo1000

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .imagePixels: return "Image pixels"
        case .normalizedTo999: return "Normalized 0–999"
        case .normalizedTo1000: return "Normalized 0–1000"
        }
    }

    /// The largest value on each axis for normalized conventions; nil for pixels.
    var normalizedAxisMaximum: CGFloat? {
        switch self {
        case .imagePixels: return nil
        case .normalizedTo999: return 999
        case .normalizedTo1000: return 1000
        }
    }

    /// One line appended to each screenshot's label so the model knows which
    /// space to answer in.
    func screenshotLabelSuffix(sentImageWidthInPixels: Int, sentImageHeightInPixels: Int) -> String {
        switch self {
        case .imagePixels:
            return " (image dimensions: \(sentImageWidthInPixels)x\(sentImageHeightInPixels) pixels)"
        case .normalizedTo999:
            return " (give coordinates normalized to 0-999 on both axes, origin top-left)"
        case .normalizedTo1000:
            return " (give coordinates normalized to 0-1000 on both axes, origin top-left)"
        }
    }

    /// Sentence for the system prompt describing the coordinate space.
    var systemPromptCoordinateDescription: String {
        switch self {
        case .imagePixels:
            return "the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward."
        case .normalizedTo999:
            return "give every coordinate normalized to 0-999 on both axes, where (0,0) is the top-left corner of the image and (999,999) is the bottom-right. x increases rightward, y increases downward."
        case .normalizedTo1000:
            return "give every coordinate normalized to 0-1000 on both axes, where (0,0) is the top-left corner of the image and (1000,1000) is the bottom-right. x increases rightward, y increases downward."
        }
    }
}

// MARK: - Vision Profile

/// Image limits and coordinate convention for one model.
struct ModelVisionProfile: Equatable {
    /// Longest edge, in pixels, of an image sent to the model.
    let maximumLongEdgeInPixels: Int
    /// Upper bound on width × height of an image sent to the model.
    let maximumTotalPixels: Int
    let coordinateConvention: ModelCoordinateConvention

    /// Claude Sonnet 4.6 / Opus 4.6 and earlier: 1568 px long edge, ~1.15 MP.
    static let claudeStandardResolution = ModelVisionProfile(
        maximumLongEdgeInPixels: 1568,
        maximumTotalPixels: 1_150_000,
        coordinateConvention: .imagePixels
    )

    /// Claude Opus 4.7+, Sonnet 5+ and the Claude 5.x family accept up to
    /// 2576 px / 3.75 MP, but Anthropic recommends ~1080p screenshots for
    /// screen work as the best accuracy/cost balance, so we cap there.
    static let claudeHighResolution = ModelVisionProfile(
        maximumLongEdgeInPixels: 1920,
        maximumTotalPixels: 1920 * 1200,
        coordinateConvention: .imagePixels
    )

    /// Conservative default for OpenAI-compatible endpoints and local VLMs,
    /// which often downscale internally and are slow on large images.
    static func genericVisionModel(coordinateConvention: ModelCoordinateConvention) -> ModelVisionProfile {
        ModelVisionProfile(
            maximumLongEdgeInPixels: 1280,
            maximumTotalPixels: 1280 * 800,
            coordinateConvention: coordinateConvention
        )
    }

    /// Picks the Claude profile from a model id. High-resolution vision started
    /// with Opus 4.7 and covers Opus 4.8, Sonnet 5 and every 5.x model.
    static func forAnthropicModel(identifier modelIdentifier: String) -> ModelVisionProfile {
        let lowercasedModelIdentifier = modelIdentifier.lowercased()
        let highResolutionModelPatterns = [
            #"opus-4-[7-9]"#,
            #"claude-[a-z]+-([5-9]|[1-9][0-9])(\b|-)"#
        ]
        let isHighResolutionModel = highResolutionModelPatterns.contains { pattern in
            lowercasedModelIdentifier.range(of: pattern, options: .regularExpression) != nil
        }
        return isHighResolutionModel ? claudeHighResolution : claudeStandardResolution
    }
}

// MARK: - Geometry

enum ScreenshotGeometry {

    /// Output size for a screenshot of a display whose native resolution is
    /// `sourceWidthInPixels` × `sourceHeightInPixels`, honoring both the
    /// long-edge and total-pixel limits and never upscaling. Aspect ratio is
    /// preserved (to within rounding).
    static func targetCaptureSize(
        sourceWidthInPixels: Int,
        sourceHeightInPixels: Int,
        profile: ModelVisionProfile
    ) -> (widthInPixels: Int, heightInPixels: Int) {
        guard sourceWidthInPixels > 0, sourceHeightInPixels > 0 else {
            return (1, 1)
        }

        let sourceWidth = Double(sourceWidthInPixels)
        let sourceHeight = Double(sourceHeightInPixels)
        let sourceLongEdge = max(sourceWidth, sourceHeight)

        let longEdgeScale = Double(profile.maximumLongEdgeInPixels) / sourceLongEdge
        let totalPixelScale = (Double(profile.maximumTotalPixels) / (sourceWidth * sourceHeight)).squareRoot()
        let scale = min(1.0, longEdgeScale, totalPixelScale)

        let targetWidth = max(1, Int((sourceWidth * scale).rounded(.down)))
        let targetHeight = max(1, Int((sourceHeight * scale).rounded(.down)))
        return (targetWidth, targetHeight)
    }

    /// Output size for a zoom into `regionInScreenshotPixels`: as large as
    /// the usual screenshot allows (aspect ratio kept), but never more
    /// pixels than the screen really has there — blowing it up adds nothing.
    static func zoomedRegionOutputSize(
        regionInScreenshotPixels: CGRect,
        screenshotSize: CGSize,
        nativePixelsPerScreenshotPixel: CGFloat
    ) -> (widthInPixels: Int, heightInPixels: Int) {
        guard regionInScreenshotPixels.width > 0, regionInScreenshotPixels.height > 0 else { return (1, 1) }
        let fitScale = min(
            screenshotSize.width / regionInScreenshotPixels.width,
            screenshotSize.height / regionInScreenshotPixels.height
        )
        let scale = min(fitScale, max(nativePixelsPerScreenshotPixel, 1))
        return (
            max(1, Int((regionInScreenshotPixels.width * scale).rounded())),
            max(1, Int((regionInScreenshotPixels.height * scale).rounded()))
        )
    }

    /// True when an image of this size is within a model's limits, so a
    /// screenshot taken for one model can be sent to another unchanged.
    static func imageFits(widthInPixels: Int, heightInPixels: Int, profile: ModelVisionProfile) -> Bool {
        max(widthInPixels, heightInPixels) <= profile.maximumLongEdgeInPixels
            && widthInPixels * heightInPixels <= profile.maximumTotalPixels
    }

    /// Converts a coordinate the model returned into the sent image's pixel
    /// space (top-left origin). Pixel conventions pass through unchanged.
    static func screenshotPixel(
        fromModelCoordinate modelCoordinate: CGPoint,
        convention: ModelCoordinateConvention,
        sentImageSize: CGSize
    ) -> CGPoint {
        guard let normalizedAxisMaximum = convention.normalizedAxisMaximum else {
            return modelCoordinate
        }
        return CGPoint(
            x: modelCoordinate.x / normalizedAxisMaximum * sentImageSize.width,
            y: modelCoordinate.y / normalizedAxisMaximum * sentImageSize.height
        )
    }

    /// The inverse of screenshotPixel(fromModelCoordinate:): expresses a
    /// screenshot pixel in the model's convention, e.g. to tell it where the
    /// user drew.
    static func modelCoordinate(
        fromScreenshotPixel screenshotPixel: CGPoint,
        convention: ModelCoordinateConvention,
        sentImageSize: CGSize
    ) -> CGPoint {
        guard let normalizedAxisMaximum = convention.normalizedAxisMaximum,
              sentImageSize.width > 0, sentImageSize.height > 0 else {
            return screenshotPixel
        }
        return CGPoint(
            x: screenshotPixel.x / sentImageSize.width * normalizedAxisMaximum,
            y: screenshotPixel.y / sentImageSize.height * normalizedAxisMaximum
        )
    }

    /// Converts a length the model returned (e.g. a circle radius) into sent
    /// image pixels. Normalized lengths scale by the image's horizontal axis.
    static func screenshotPixelLength(
        fromModelLength modelLength: CGFloat,
        convention: ModelCoordinateConvention,
        sentImageSize: CGSize
    ) -> CGFloat {
        guard let normalizedAxisMaximum = convention.normalizedAxisMaximum else {
            return modelLength
        }
        return modelLength / normalizedAxisMaximum * sentImageSize.width
    }
}
