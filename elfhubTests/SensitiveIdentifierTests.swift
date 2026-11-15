//
//  SensitiveIdentifierTests.swift
//  elfhubTests
//
//  Personal numbers blacked out of screenshots before they leave the Mac:
//  card numbers that pass the checksum, US social security and Canadian
//  social insurance numbers, Ontario health card numbers, and whatever
//  follows a health or patient label — but not phone numbers, order
//  numbers, prices or dates without a birth-date label.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import elfhub

struct SensitiveIdentifierTests {

    private func maskedTexts(in text: String) -> [String] {
        SensitiveIdentifierDetector.sensitiveRanges(in: text).map { String(text[$0]) }
    }

    @Test func cardNumbersThatPassTheChecksumAreFound() {
        #expect(maskedTexts(in: "Visa 4111 1111 1111 1111 exp 04/29") == ["4111 1111 1111 1111"])
        #expect(maskedTexts(in: "card 5500-0000-0000-0004") == ["5500-0000-0000-0004"])
        #expect(maskedTexts(in: "order 4111 1111 1111 1112").isEmpty)
    }

    @Test func socialInsuranceAndHealthCardNumbersAreFound() {
        #expect(maskedTexts(in: "SSN 078-05-1120") == ["078-05-1120"])
        #expect(maskedTexts(in: "SIN: 046 454 286") == ["046 454 286"])
        #expect(maskedTexts(in: "OHIP 1234-567-890-AB") == ["1234-567-890-AB"])
    }

    @Test func whateverFollowsAHealthOrPatientLabelIsFound() {
        #expect(maskedTexts(in: "MRN: 00482913") == ["00482913"])
        #expect(maskedTexts(in: "PHN 9876 543 210") == ["9876 543 210"])
        #expect(maskedTexts(in: "Date of birth: 1984-03-12") == ["1984-03-12"])
        #expect(maskedTexts(in: "DOB 03/12/1984") == ["03/12/1984"])
        #expect(maskedTexts(in: "Patient ID #A12-4471") == ["A12-4471"])
    }

    @Test func everydayNumbersAreLeftAlone() {
        #expect(maskedTexts(in: "Call (416) 555-0199 or 1-800-555-0100").isEmpty)
        #expect(maskedTexts(in: "Order #112-3345678-9900112 shipped March 12, 2026").isEmpty)
        #expect(maskedTexts(in: "Total $1,299.99 — saved 2026-11-15").isEmpty)
    }

    @Test func aBoxFromTextRecognitionBecomesPixelsFromTheTop() {
        // Vision's boxes are normalized with the origin at the bottom left.
        let pixelRect = ScreenshotSensitiveContentMasker.pixelRect(
            fromNormalizedBoundingBox: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.05),
            imageWidth: 1000,
            imageHeight: 800
        )
        #expect(pixelRect == CGRect(x: 500, y: 560, width: 250, height: 40).insetBy(dx: -ScreenshotSensitiveContentMasker.paddingInPixels, dy: -ScreenshotSensitiveContentMasker.paddingInPixels))
    }

    @Test func aCardNumberOnTheScreenIsBlackedOut() async throws {
        let context = try #require(CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        ("Card 4111 1111 1111 1111" as NSString).draw(at: CGPoint(x: 40, y: 120), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let renderedImage = try #require(context.makeImage())
        let screenshotJPEGData = try #require(NSBitmapImageRep(cgImage: renderedImage).representation(using: .jpeg, properties: [:]))

        let maskingResult = await ScreenshotSensitiveContentMasker.masking(screenshotJPEGData)
        #expect(maskingResult.maskedItemCount == 1)
        #expect(maskingResult.jpegData != screenshotJPEGData)
    }
}
