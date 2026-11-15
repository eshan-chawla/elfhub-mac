//
//  ScreenshotSensitiveContentMasker.swift
//  elfhub
//
//  Blacks out personal numbers in a screenshot before it leaves the Mac:
//  payment card numbers (only ones that pass the card checksum), US social
//  security and Canadian social insurance numbers, Ontario health card
//  numbers, and whatever follows a health or patient label (health card,
//  PHN, MRN, patient ID, medical record, member ID, date of birth). Text is
//  found with Apple's on-device text recognition; nothing is sent anywhere
//  to do it. Phone numbers, order numbers, prices and ordinary dates are
//  left alone so everyday help still works.
//
//  On by default ("Hide personal numbers in screenshots", Settings ›
//  Privacy). The pattern matching is pure (SensitiveIdentifierDetector) and
//  unit-tested.
//

import AppKit
import Foundation
import Vision

enum SensitiveIdentifierDetector {

    /// Card numbers: 13–19 digits in a row, or in groups of four (Amex 4-6-5).
    nonisolated private static let cardNumberPattern = #"\b(?:\d{13,19}|\d{4}(?:[ -]\d{4}){2}[ -]\d{1,4}|\d{4}[ -]\d{6}[ -]\d{5})\b"#
    nonisolated private static let socialSecurityNumberPattern = #"\b\d{3}-\d{2}-\d{4}\b"#
    nonisolated private static let socialInsuranceNumberPattern = #"\b\d{3}[ -]\d{3}[ -]\d{3}\b"#
    nonisolated private static let ontarioHealthCardPattern = #"\b\d{4}[ -]?\d{3}[ -]?\d{3}[ -]?[A-Z]{2}\b"#
    /// A health or patient label, then its value: number-like tokens (each
    /// starting with a digit, the first optionally with one letter).
    nonisolated private static let labeledIdentifierPattern = #"(?i:\b(?:MRN|PHN|health ?card(?: number| no\.?)?|health number|patient ?(?:id|number|no\.?)|medical record(?: number| no\.?)?|member ?id|date of birth|DOB|birth ?date)\b)\s*[:#]?\s*#?\s*([A-Z]?\d[\dA-Z]*(?:[ /.\-]\d[\dA-Z]*)*)"#

    /// The parts of `text` to black out, in order, never overlapping.
    nonisolated static func sensitiveRanges(in text: String) -> [Range<String.Index>] {
        var foundRanges: [Range<String.Index>] = []
        foundRanges += matches(of: cardNumberPattern, in: text).filter { passesLuhnCheck(String(text[$0])) }
        foundRanges += matches(of: socialSecurityNumberPattern, in: text)
        foundRanges += matches(of: socialInsuranceNumberPattern, in: text).filter { passesLuhnCheck(String(text[$0])) }
        foundRanges += matches(of: ontarioHealthCardPattern, in: text)
        foundRanges += matches(of: labeledIdentifierPattern, in: text, captureGroup: 1)
        return mergedRanges(foundRanges)
    }

    /// The card checksum, which almost no order or phone number passes.
    nonisolated static func passesLuhnCheck(_ candidate: String) -> Bool {
        let digits = candidate.compactMap { $0.wholeNumberValue }
        guard digits.count >= 9 else { return false }
        var checksum = 0
        for (positionFromRight, digit) in digits.reversed().enumerated() {
            if positionFromRight % 2 == 1 {
                let doubledDigit = digit * 2
                checksum += doubledDigit > 9 ? doubledDigit - 9 : doubledDigit
            } else {
                checksum += digit
            }
        }
        return checksum % 10 == 0
    }

    nonisolated private static func matches(of pattern: String, in text: String, captureGroup: Int = 0) -> [Range<String.Index>] {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regularExpression.matches(in: text, range: fullRange).compactMap { match in
            Range(match.range(at: captureGroup), in: text)
        }
    }

    nonisolated private static func mergedRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in sortedRanges {
            if let lastRange = merged.last, range.lowerBound <= lastRange.upperBound {
                merged[merged.count - 1] = lastRange.lowerBound..<max(lastRange.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

enum ScreenshotSensitiveContentMasker {
    /// Extra black around each number, so no digit edge peeks out.
    nonisolated static let paddingInPixels: CGFloat = 3

    static let isEnabledKey = "hidesPersonalNumbersInScreenshots"

    /// On unless the user switched it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }

    struct MaskingResult {
        let jpegData: Data
        let maskedItemCount: Int
    }

    /// The screenshot with every personal number blacked out (the same data
    /// when there were none or it couldn't be read). Runs off the main thread.
    nonisolated static func masking(_ screenshotJPEGData: Data) async -> MaskingResult {
        await Task.detached(priority: .userInitiated) {
            maskingSynchronously(screenshotJPEGData)
        }.value
    }

    nonisolated private static func maskingSynchronously(_ screenshotJPEGData: Data) -> MaskingResult {
        let unchangedResult = MaskingResult(jpegData: screenshotJPEGData, maskedItemCount: 0)
        guard let imageSource = CGImageSourceCreateWithData(screenshotJPEGData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return unchangedResult }

        let textRecognitionRequest = VNRecognizeTextRequest()
        // Fast: about 0.05–0.15 s a screenshot and it reads printed digits
        // well. Accurate loads a model on first use that can take close to a
        // minute, which would stall the first turn. Language correction
        // would "fix" numbers into words.
        textRecognitionRequest.recognitionLevel = .fast
        textRecognitionRequest.usesLanguageCorrection = false
        let requestHandler = VNImageRequestHandler(cgImage: screenshotImage, options: [:])
        guard (try? requestHandler.perform([textRecognitionRequest])) != nil,
              let textObservations = textRecognitionRequest.results else { return unchangedResult }

        var rectanglesToBlackOut: [CGRect] = []
        for textObservation in textObservations {
            guard let recognizedText = textObservation.topCandidates(1).first else { continue }
            for sensitiveRange in SensitiveIdentifierDetector.sensitiveRanges(in: recognizedText.string) {
                // The exact characters when Vision can say where they are,
                // otherwise the whole line.
                let normalizedBox = (try? recognizedText.boundingBox(for: sensitiveRange))?.boundingBox ?? textObservation.boundingBox
                rectanglesToBlackOut.append(pixelRect(
                    fromNormalizedBoundingBox: normalizedBox,
                    imageWidth: CGFloat(screenshotImage.width),
                    imageHeight: CGFloat(screenshotImage.height)
                ))
            }
        }
        guard !rectanglesToBlackOut.isEmpty else { return unchangedResult }

        guard let drawingContext = CGContext(
            data: nil,
            width: screenshotImage.width,
            height: screenshotImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return unchangedResult }
        let imageHeight = CGFloat(screenshotImage.height)
        drawingContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height))
        drawingContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rectangleFromTop in rectanglesToBlackOut {
            // Core Graphics draws from the bottom up.
            drawingContext.fill(CGRect(
                x: rectangleFromTop.minX,
                y: imageHeight - rectangleFromTop.maxY,
                width: rectangleFromTop.width,
                height: rectangleFromTop.height
            ))
        }
        guard let maskedImage = drawingContext.makeImage(),
              let maskedJPEGData = NSBitmapImageRep(cgImage: maskedImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return unchangedResult
        }
        return MaskingResult(jpegData: maskedJPEGData, maskedItemCount: rectanglesToBlackOut.count)
    }

    /// A text-recognition box (normalized, origin bottom left) in image
    /// pixels from the top left, with padding.
    nonisolated static func pixelRect(fromNormalizedBoundingBox normalizedBox: CGRect, imageWidth: CGFloat, imageHeight: CGFloat) -> CGRect {
        CGRect(
            x: normalizedBox.minX * imageWidth,
            y: (1 - normalizedBox.maxY) * imageHeight,
            width: normalizedBox.width * imageWidth,
            height: normalizedBox.height * imageHeight
        ).insetBy(dx: -paddingInPixels, dy: -paddingInPixels)
    }
}
