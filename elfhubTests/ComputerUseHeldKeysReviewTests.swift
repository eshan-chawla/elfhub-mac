//
//  ComputerUseHeldKeysReviewTests.swift
//  elfhubTests
//
//  What the third review asked for:
//   - a click near something that keeps moving goes through when the model
//     repeats it after seeing the fresh screenshot;
//   - a small pop-up right over the target still counts as a change;
//   - the user's own keys aren't given elfhub's held keys;
//   - keys held around typing never slip past the password rules;
//   - the card names the real element for any click with keys held;
//   - the conversation history keeps typed text only as a length.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct ComputerUseHeldKeysReviewTests {

    private func toolsetCall(_ identifier: String, _ memberName: String, _ argumentsJSON: String) -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: identifier, toolName: memberName, argumentsJSON: argumentsJSON, toolsetName: "computer")
    }

    private func makeSession(screen: FakeComputerUseScreen) -> ComputerUseSession {
        ComputerUseSession(
            screen: screen,
            firstCapture: FakeComputerUseScreen.capture(imageData: FakeComputerUseScreen.jpegData(withBoxAt: nil)),
            coordinateConvention: .imagePixels
        )
    }

    @Test func aClickRepeatedAfterTheFreshScreenshotGoesThroughEvenIfTheAreaKeepsMoving() async {
        let screen = FakeComputerUseScreen()
        screen.targetRegionHasChanged = true
        let session = makeSession(screen: screen)
        _ = await session.runStep([toolsetCall("a", "left_click", #"{"coordinate":[300,200]}"#)])
        #expect(screen.performedActions.isEmpty)
        _ = await session.runStep([toolsetCall("b", "left_click", #"{"coordinate":[304,203]}"#)])
        #expect(screen.performedActions.count == 1)
    }

    private func jpegData(drawing draw: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        draw(context)
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .jpeg, properties: [:])!
    }

    @Test func aSmallPopUpRightOverTheTargetCounts() {
        let before = jpegData { _ in }
        // An autocomplete list 70 pixels square right where the click lands.
        let popUpOverTarget = jpegData { $0.fill(CGRect(x: 605, y: 365, width: 70, height: 70)) }
        #expect(ScreenshotRegionComparison.isStale(beforeJPEG: before, afterJPEG: popUpOverTarget, aroundScreenshotPixel: CGPoint(x: 640, y: 400), regionRadiusInPixels: 120))
        // The pointer resting near it doesn't.
        let pointerNearby = jpegData { $0.fill(CGRect(x: 650, y: 380, width: 12, height: 18)) }
        #expect(!ScreenshotRegionComparison.isStale(beforeJPEG: before, afterJPEG: pointerNearby, aroundScreenshotPixel: CGPoint(x: 640, y: 400), regionRadiusInPixels: 120))
    }

    @Test func theUsersOwnKeysArentGivenElfhubsHeldKeys() {
        #expect(UserInterruptionMonitor.shouldSwallowUsersEvent(eventType: .keyDown, isHoldingModifierKeys: true))
        #expect(UserInterruptionMonitor.shouldSwallowUsersEvent(eventType: .leftMouseDown, isHoldingModifierKeys: true))
        #expect(!UserInterruptionMonitor.shouldSwallowUsersEvent(eventType: .keyDown, isHoldingModifierKeys: false))
        #expect(!UserInterruptionMonitor.shouldSwallowUsersEvent(eventType: .mouseMoved, isHoldingModifierKeys: true))
    }

    @Test func keysHeldAroundTypingNeverSlipPastThePasswordRules() {
        let wrappedTyping = CompanionScreenAction.withModifierKeys(["shift"], .type(text: "hunter2"))
        #expect(!wrappedTyping.isPointerActionWithKeysHeld)
        let decision = ConsentPolicy.evaluate(ScreenActionConsentContext(
            action: wrappedTyping,
            targetElementFacts: nil,
            frontmostApplicationBundleIdentifier: "com.apple.Terminal",
            isTargetApplicationPrivacyBlocked: false,
            userUtterance: "type it",
            isSecureEventInputActive: true
        ))
        guard case .usersStep = decision else {
            Issue.record("typing with keys held while secure input is on must be the user's step, got \(decision)")
            return
        }
        #expect(CompanionScreenAction.withModifierKeys(["cmd"], .click(screenshotPixel: .zero, label: nil, screenNumber: nil)).isPointerActionWithKeysHeld)
    }

    @Test func theCardNamesTheRealElementForAnyClickWithKeysHeld() {
        let resolvedAction = ResolvedScreenAction(
            action: .withModifierKeys(["cmd"], .drag(fromScreenshotPixel: .zero, toScreenshotPixel: CGPoint(x: 10, y: 10), screenNumber: nil)),
            coreGraphicsTargetPoint: .zero,
            appKitTargetPoint: .zero,
            displayFrame: nil,
            targetElementFacts: AccessibilityElementFacts(
                frameInCoreGraphicsGlobalCoordinates: nil, role: "AXImage", subrole: nil, title: "Budget.numbers",
                isSecureTextField: false, isDefaultButton: false, owningApplicationBundleIdentifier: "com.apple.finder"
            ),
            frontmostApplicationBundleIdentifier: "com.apple.finder",
            consentDecision: .proceedWithPreview,
            consequentialEffect: nil
        )
        #expect(resolvedAction.humanReadableDescription == "cmd+drag “Budget.numbers”")
    }

    @Test func theHistoryKeepsTypedTextOnlyAsALength() async {
        let screen = FakeComputerUseScreen()
        screen.performedDescriptionToReport = "click “Export”"
        let session = makeSession(screen: screen)
        _ = await session.runStep([
            toolsetCall("a", "left_click", #"{"coordinate":[100,200]}"#),
            toolsetCall("b", "type", #"{"text":"my secret note"}"#),
        ])
        #expect(session.performedStepDescriptions == ["click “Export”", "type 14 characters"])
    }
}
