//
//  ScreenAnnotationParsingTests.swift
//  elfhubTests
//
//  Annotation tag parsing, POINT parsing, and the combined tag decoder that
//  turns a reply into spoken text plus guidance commands.
//

import CoreGraphics
import Testing
@testable import elfhub

struct ScreenAnnotationParsingTests {

    // MARK: - Individual tags

    @Test func parsesHighlightWithLabel() {
        let result = ScreenAnnotationParser.parseScreenAnnotations(
            from: "these two differ [HIGHLIGHT:10,20,110,60:with tax]"
        )
        #expect(result.spokenText == "these two differ")
        #expect(result.annotations == [ScreenAnnotation(
            shape: .highlight(firstCorner: CGPoint(x: 10, y: 20), oppositeCorner: CGPoint(x: 110, y: 60)),
            label: "with tax",
            screenNumber: nil
        )])
    }

    @Test func parsesCircleArrowAndUnderline() {
        let result = ScreenAnnotationParser.parseScreenAnnotations(
            from: "look [CIRCLE:300,400,25:error] then [ARROW:100,100,300,400:this one] and [UNDERLINE:50,500,250,500]"
        )
        #expect(result.annotations.map(\.shape) == [
            .circle(center: CGPoint(x: 300, y: 400), radius: 25),
            .arrow(tail: CGPoint(x: 100, y: 100), head: CGPoint(x: 300, y: 400)),
            .underline(start: CGPoint(x: 50, y: 500), end: CGPoint(x: 250, y: 500)),
        ])
        #expect(result.spokenText == "look then and")
    }

    @Test func noteTextMayContainColonsAndTargetAnotherScreen() {
        let result = ScreenAnnotationParser.parseScreenAnnotations(
            from: "[NOTE:40,60:todo: fix this:screen2]"
        )
        #expect(result.annotations == [ScreenAnnotation(
            shape: .note(anchor: CGPoint(x: 40, y: 60), text: "todo: fix this"),
            label: nil,
            screenNumber: 2
        )])
    }

    @Test func screenSuffixWithoutLabelIsReadAsScreenNumber() {
        let result = ScreenAnnotationParser.parseScreenAnnotations(from: "[HIGHLIGHT:1,2,3,4:screen2]")
        #expect(result.annotations.first?.label == nil)
        #expect(result.annotations.first?.screenNumber == 2)
    }

    @Test func acceptsDecimalCoordinates() {
        let result = ScreenAnnotationParser.parseScreenAnnotations(from: "[CIRCLE:10.5,20.25,8]")
        #expect(result.annotations.first?.shape == .circle(center: CGPoint(x: 10.5, y: 20.25), radius: 8))
    }

    @Test func ignoresZeroRadiusCircle() {
        let result = ScreenAnnotationParser.parseScreenAnnotations(from: "[CIRCLE:10,20,0]")
        #expect(result.annotations.isEmpty)
    }

    @Test func capsAnnotationCount() {
        let manyHighlights = (0..<10).map { "[HIGHLIGHT:\($0),0,10,10]" }.joined()
        let result = ScreenAnnotationParser.parseScreenAnnotations(from: manyHighlights)
        #expect(result.annotations.count == ScreenAnnotationParser.maximumAnnotationsPerResponse)
        #expect(result.wasCappedToMaximum)
    }

    @Test func leavesMalformedTagsInText() {
        let text = "broken [HIGHLIGHT:10,20] tag"
        let result = ScreenAnnotationParser.parseScreenAnnotations(from: text)
        #expect(result.annotations.isEmpty)
        #expect(result.spokenText == text)
    }

    // MARK: - POINT

    @Test func pointTagWithLabelAndScreen() {
        let result = PointTagParser.parsePointTag(from: "over there [POINT:400,300:terminal:screen2]")
        #expect(result.spokenText == "over there")
        #expect(result.coordinate == CGPoint(x: 400, y: 300))
        #expect(result.elementLabel == "terminal")
        #expect(result.screenNumber == 2)
    }

    @Test func pointNoneHasNoCoordinate() {
        let result = PointTagParser.parsePointTag(from: "html is markup [POINT:none]")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == "none")
        #expect(result.spokenText == "html is markup")
    }

    @Test func pointScreenSuffixWithoutLabel() {
        let result = PointTagParser.parsePointTag(from: "[POINT:10,20:screen3]")
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == 3)
    }

    // MARK: - Combined decoder

    @Test func decoderSeparatesPointAnnotationsAndActions() {
        let reply = "filling it in and marking the total [CLICK:640,300:email field][TYPE:me@example.com][HIGHLIGHT:200,400,380,430:total][POINT:640,300:email field]"
        let result = TagGuidanceDecoder.decode(responseText: reply)

        #expect(result.spokenText == "filling it in and marking the total")
        #expect(result.actions == [
            .click(screenshotPixel: CGPoint(x: 640, y: 300), label: "email field", screenNumber: nil),
            .type(text: "me@example.com"),
        ])
        #expect(result.annotations.count == 1)
        #expect(result.pointCommand?.point == CGPoint(x: 640, y: 300))
        #expect(result.pointCommand?.label == "email field")
    }

    @Test func decoderHandlesReplyWithNoTags() {
        let result = TagGuidanceDecoder.decode(responseText: "just an answer")
        #expect(result.spokenText == "just an answer")
        #expect(result.commands.isEmpty)
    }

    @Test func pointIsStillFoundWhenAnnotationsPrecedeIt() {
        // POINT is anchored to the end of the reply; annotation tags before it
        // must be stripped first or it would not match.
        let result = TagGuidanceDecoder.decode(responseText: "see [CIRCLE:5,5,5] here [POINT:5,5:dot]")
        #expect(result.pointCommand?.label == "dot")
        #expect(result.spokenText == "see here")
    }
}
