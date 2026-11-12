//
//  ScreenActionParsingTests.swift
//  elfhubTests
//
//  Unit tests for the pure screen-action parsing: the logic that decides what
//  elfhub will do. How much consent each action needs is ConsentPolicy's job
//  (ConsentPolicyTests); the event-posting layer itself can only be exercised
//  by a real build.
//

import CoreGraphics
import Testing
@testable import elfhub

struct ScreenActionParsingTests {

    // MARK: - Basic parsing

    @Test func parsesSingleClickWithLabel() {
        let result = ScreenActionParser.parseScreenActions(
            from: "sure, saving that for you [CLICK:640,300:save button]"
        )

        #expect(result.spokenText == "sure, saving that for you")
        #expect(result.actions == [
            .click(screenshotPixel: CGPoint(x: 640, y: 300), label: "save button", screenNumber: nil)
        ])
        #expect(result.wasCappedToMaximum == false)
    }

    @Test func parsesClickOnSpecificScreen() {
        let result = ScreenActionParser.parseScreenActions(
            from: "over on your other monitor [CLICK:400,300:terminal:screen2]"
        )

        #expect(result.actions == [
            .click(screenshotPixel: CGPoint(x: 400, y: 300), label: "terminal", screenNumber: 2)
        ])
    }

    @Test func parsesDoubleClickWithoutLabel() {
        let result = ScreenActionParser.parseScreenActions(from: "[DOUBLECLICK:10,20]")
        #expect(result.actions == [
            .doubleClick(screenshotPixel: CGPoint(x: 10, y: 20), label: nil, screenNumber: nil)
        ])
    }

    @Test func parsesTypeAndKeyActions() {
        let result = ScreenActionParser.parseScreenActions(
            from: "filling it in [TYPE:me@example.com][KEY:return]"
        )

        #expect(result.spokenText == "filling it in")
        #expect(result.actions == [
            .type(text: "me@example.com"),
            .key(comboString: "return"),
        ])
    }

    @Test func parsesScrollWithDirection() {
        let result = ScreenActionParser.parseScreenActions(from: "[SCROLL:500,400:down]")
        #expect(result.actions == [
            .scroll(screenshotPixel: CGPoint(x: 500, y: 400), direction: .down, screenNumber: nil)
        ])
    }

    // MARK: - Ordering & multiple actions

    @Test func preservesEmissionOrderAcrossFamilies() {
        let result = ScreenActionParser.parseScreenActions(
            from: "doing it [CLICK:1,1:field][TYPE:hi][KEY:return]"
        )

        #expect(result.actions == [
            .click(screenshotPixel: CGPoint(x: 1, y: 1), label: "field", screenNumber: nil),
            .type(text: "hi"),
            .key(comboString: "return"),
        ])
    }

    @Test func capsToMaximumActionsPerResponse() {
        // Five clicks — one over the cap of four.
        let tags = (1...5).map { "[CLICK:\($0),\($0):b\($0)]" }.joined()
        let result = ScreenActionParser.parseScreenActions(from: "go \(tags)")

        #expect(result.actions.count == ScreenActionParser.maximumActionsPerResponse)
        #expect(result.wasCappedToMaximum == true)
    }

    // MARK: - No actions / POINT coexistence

    @Test func returnsNoActionsWhenNoTagsPresent() {
        let text = "html is the skeleton of a web page."
        let result = ScreenActionParser.parseScreenActions(from: text)
        #expect(result.actions.isEmpty)
        #expect(result.spokenText == text)
    }

    @Test func leavesPointTagUntouchedForDownstreamParsing() {
        // The [POINT:...] tag must survive so PointTagParser.parsePointTag
        // can still handle it. Only action tags are stripped here.
        let text = "look here [POINT:100,200:menu]"
        let result = ScreenActionParser.parseScreenActions(from: text)
        #expect(result.actions.isEmpty)
        #expect(result.spokenText == text)
    }

    @Test func ignoresEmptyTypeTag() {
        let result = ScreenActionParser.parseScreenActions(from: "nothing [TYPE:]")
        #expect(result.actions.isEmpty)
    }
}
