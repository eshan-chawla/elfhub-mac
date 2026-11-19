//
//  ComputerUseToolCallTranslatorTests.swift
//  elfhubTests
//
//  What one step of a multi-step run asks for: Claude's computer toolset
//  members and elfhub's own perform_screen_action (for other models, in
//  their coordinate convention) become the same step commands; anything
//  out of range is refused with a reason the model can act on.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

struct ComputerUseToolCallTranslatorTests {

    private let sentImageSize = CGSize(width: 1280, height: 800)

    private func toolsetCall(_ memberName: String, _ argumentsJSON: String) -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: "toolu_1", toolName: memberName, argumentsJSON: argumentsJSON, toolsetName: "computer")
    }

    private func functionCall(_ argumentsJSON: String) -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: "call_1", toolName: GuidanceToolDefinitions.screenActionToolName, argumentsJSON: argumentsJSON)
    }

    private func command(_ toolCall: LanguageModelToolCall, convention: ModelCoordinateConvention = .imagePixels) -> ComputerUseStepCommand {
        ComputerUseToolCallTranslator.command(for: toolCall, convention: convention, sentImageSize: sentImageSize)
    }

    @Test func claudeToolsetMembersBecomeSteps() {
        #expect(command(toolsetCall("screenshot", "{}")) == .screenshot)
        #expect(command(toolsetCall("cursor_position", "{}")) == .cursorPosition)
        #expect(command(toolsetCall("left_click", #"{"coordinate":[500,300]}"#))
            == .act(.click(screenshotPixel: CGPoint(x: 500, y: 300), label: nil, screenNumber: nil), repeatCount: 1))
        #expect(command(toolsetCall("right_click", #"{"coordinate":[10,20]}"#))
            == .act(.rightClick(screenshotPixel: CGPoint(x: 10, y: 20), label: nil, screenNumber: nil), repeatCount: 1))
        #expect(command(toolsetCall("double_click", #"{"coordinate":[10,20]}"#))
            == .act(.doubleClick(screenshotPixel: CGPoint(x: 10, y: 20), label: nil, screenNumber: nil), repeatCount: 1))
        #expect(command(toolsetCall("triple_click", #"{"coordinate":[10,20]}"#))
            == .act(.tripleClick(screenshotPixel: CGPoint(x: 10, y: 20), label: nil, screenNumber: nil), repeatCount: 1))
        #expect(command(toolsetCall("left_click_drag", #"{"start_coordinate":[1,2],"coordinate":[30,40]}"#))
            == .act(.drag(fromScreenshotPixel: CGPoint(x: 1, y: 2), toScreenshotPixel: CGPoint(x: 30, y: 40), screenNumber: nil), repeatCount: 1))
        #expect(command(toolsetCall("mouse_move", #"{"coordinate":[7,8]}"#))
            == .act(.moveMouse(screenshotPixel: CGPoint(x: 7, y: 8), screenNumber: nil), repeatCount: 1))
        #expect(command(toolsetCall("type", #"{"text":"hello"}"#)) == .act(.type(text: "hello"), repeatCount: 1))
        #expect(command(toolsetCall("key", #"{"text":"cmd+s","repeat":3}"#)) == .act(.key(comboString: "cmd+s"), repeatCount: 3))
        #expect(command(toolsetCall("wait", #"{"duration":2}"#)) == .wait(seconds: 2))
        #expect(command(toolsetCall("zoom", #"{"region":[100,200,400,350]}"#)) == .zoom(regionInScreenshotPixels: CGRect(x: 100, y: 200, width: 300, height: 150)))
        // One scroll, as far as asked (each unit a tenth of the screen) —
        // not a row of separate scrolls.
        #expect(command(toolsetCall("scroll", #"{"coordinate":[500,400],"scroll_direction":"down","scroll_amount":6}"#))
            == .act(.scroll(screenshotPixel: CGPoint(x: 500, y: 400), direction: .down, screenNumber: nil, amountInTenthsOfScreen: 6), repeatCount: 1))
        #expect(command(toolsetCall("scroll", #"{"coordinate":[500,400],"scroll_direction":"up"}"#))
            == .act(.scroll(screenshotPixel: CGPoint(x: 500, y: 400), direction: .up, screenNumber: nil, amountInTenthsOfScreen: CompanionScreenAction.defaultScrollAmountInTenthsOfScreen), repeatCount: 1))
    }

    @Test func outOfRangeOrUnsupportedStepsAreRefusedWithAReason() {
        func isRefused(_ stepCommand: ComputerUseStepCommand) -> Bool {
            if case .refuse = stepCommand { return true }
            return false
        }
        #expect(isRefused(command(toolsetCall("left_click", #"{"coordinate":[5000,300]}"#))))
        #expect(isRefused(command(toolsetCall("left_click", "{}"))))
        #expect(isRefused(command(toolsetCall("left_click", #"{"coordinate":[5,5],"text":"hyper"}"#))))
        #expect(command(toolsetCall("wait", #"{"duration":60}"#)) == .wait(seconds: 60), "a minute's wait for something to load")
        #expect(command(toolsetCall("wait", #"{"duration":300}"#)) == .wait(seconds: 300))
        #expect(isRefused(command(toolsetCall("wait", #"{"duration":301}"#))))
        #expect(isRefused(command(toolsetCall("key", #"{"text":"a","repeat":50}"#))))
        #expect(isRefused(command(toolsetCall("type", #"{"text":""}"#))))
        #expect(isRefused(command(toolsetCall("hold_key", #"{"text":"shift","duration":1}"#))))
        #expect(isRefused(command(toolsetCall("zoom", #"{"region":[400,350,100,200]}"#))))
    }

    @Test func clicksAndScrollsCanHoldKeys() {
        #expect(command(toolsetCall("left_click", #"{"coordinate":[500,300],"text":"cmd"}"#))
            == .act(.withModifierKeys(["cmd"], .click(screenshotPixel: CGPoint(x: 500, y: 300), label: nil, screenNumber: nil)), repeatCount: 1))
        #expect(command(toolsetCall("scroll", #"{"coordinate":[500,400],"scroll_direction":"down","scroll_amount":3,"text":"shift"}"#))
            == .act(.withModifierKeys(["shift"], .scroll(screenshotPixel: CGPoint(x: 500, y: 400), direction: .down, screenNumber: nil, amountInTenthsOfScreen: 3)), repeatCount: 1))
        #expect(command(functionCall(#"{"action":"click","x":10,"y":20,"modifiers":"cmd+shift"}"#))
            == .act(.withModifierKeys(["cmd", "shift"], .click(screenshotPixel: CGPoint(x: 10, y: 20), label: nil, screenNumber: nil)), repeatCount: 1))
        // Claude says "super" for the command key.
        #expect(command(toolsetCall("left_click", #"{"coordinate":[5,5],"text":"super"}"#))
            == .act(.withModifierKeys(["cmd"], .click(screenshotPixel: CGPoint(x: 5, y: 5), label: nil, screenNumber: nil)), repeatCount: 1))
        #expect(CompanionScreenAction.withModifierKeys(["cmd"], .click(screenshotPixel: .zero, label: "link", screenNumber: nil)).humanReadableDescription == "cmd+click the link")
    }

    @Test func otherModelsUseTheExtendedScreenActionToolInTheirOwnCoordinates() {
        // Gemini-style 0–999 grid: the middle of the image is the middle.
        #expect(command(functionCall(#"{"action":"click","x":499.5,"y":499.5,"label":"ok"}"#), convention: .normalizedTo999)
            == .act(.click(screenshotPixel: CGPoint(x: 640, y: 400), label: "ok", screenNumber: nil), repeatCount: 1))
        #expect(command(functionCall(#"{"action":"drag","x":0,"y":0,"x2":10,"y2":20}"#))
            == .act(.drag(fromScreenshotPixel: .zero, toScreenshotPixel: CGPoint(x: 10, y: 20), screenNumber: nil), repeatCount: 1))
        #expect(command(functionCall(#"{"action":"key","keys":"tab","repeat":2}"#)) == .act(.key(comboString: "tab"), repeatCount: 2))
        #expect(command(functionCall(#"{"action":"scroll","x":10,"y":20,"direction":"down","repeat":3}"#))
            == .act(.scroll(screenshotPixel: CGPoint(x: 10, y: 20), direction: .down, screenNumber: nil, amountInTenthsOfScreen: 3), repeatCount: 1))
        #expect(command(functionCall(#"{"action":"take_screenshot"}"#)) == .screenshot)
        #expect(command(functionCall(#"{"action":"zoom","x":0,"y":0,"x2":640,"y2":400}"#)) == .zoom(regionInScreenshotPixels: CGRect(x: 0, y: 0, width: 640, height: 400)))
        #expect(command(functionCall(#"{"action":"wait","seconds":1.5}"#)) == .wait(seconds: 1.5))
    }

    @Test func aZoomFillsTheUsualScreenshotSizeButNeverPassesTheScreensOwnPixels() {
        // A 300×150-pixel region of a 1280×800 screenshot of a 2560×1600
        // Retina screen is 600×300 real pixels: shown at that size, not blown up.
        let retinaZoom = ScreenshotGeometry.zoomedRegionOutputSize(
            regionInScreenshotPixels: CGRect(x: 0, y: 0, width: 300, height: 150),
            screenshotSize: sentImageSize,
            nativePixelsPerScreenshotPixel: 2
        )
        #expect(retinaZoom.widthInPixels == 600 && retinaZoom.heightInPixels == 300)
        // A wide region is scaled down to fit the screenshot's width.
        let wideZoom = ScreenshotGeometry.zoomedRegionOutputSize(
            regionInScreenshotPixels: CGRect(x: 0, y: 0, width: 1000, height: 100),
            screenshotSize: sentImageSize,
            nativePixelsPerScreenshotPixel: 2
        )
        #expect(wideZoom.widthInPixels == 1280 && wideZoom.heightInPixels == 128)
    }

    @Test func aScrollMovesAKnownDistanceInSmallSmoothSteps() {
        // Five tenths of a 900-point-tall screen is 450 points.
        #expect(ScreenActionSynthesizer.scrollDistanceInPoints(amountInTenthsOfScreen: 5, displayHeightInPoints: 900) == 450)
        // Small steps add up to exactly the distance, none bigger than the step size.
        let chunks = ScreenActionSynthesizer.scrollChunksInPoints(totalDistanceInPoints: 450)
        #expect(chunks.reduce(0, +) == 450)
        #expect(chunks.allSatisfy { $0 > 0 && $0 <= ScreenActionSynthesizer.maximumScrollChunkInPoints })
        #expect(ScreenActionSynthesizer.scrollChunksInPoints(totalDistanceInPoints: 0).isEmpty)
    }

    @Test func onlyComputerCallsAreHandled() {
        #expect(ComputerUseToolCallTranslator.isComputerUseCall(toolsetCall("left_click", "{}")))
        #expect(ComputerUseToolCallTranslator.isComputerUseCall(functionCall("{}")))
        #expect(!ComputerUseToolCallTranslator.isComputerUseCall(LanguageModelToolCall(toolCallIdentifier: "x", toolName: "point_at", argumentsJSON: "{}")))
    }
}
