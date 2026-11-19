//
//  CursorScreenCaptureTests.swift
//  elfhubTests
//
//  Only the display under the mouse cursor is captured: picking that display
//  (including screen edges and gaps between monitors).
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct CursorScreenCaptureTests {

    // MARK: - Picking the cursor's screen

    /// A 1440x900 screen on the left and a taller 1920x1080 screen to its
    /// right, offset downward — AppKit global coordinates (bottom-left origin).
    private let twoScreenFrames = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: -200, width: 1920, height: 1080),
    ]

    @Test func cursorInsideAScreenPicksThatScreen() {
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: CGPoint(x: 2000, y: 300), in: twoScreenFrames) == 1)
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: CGPoint(x: 100, y: 100), in: twoScreenFrames) == 0)
    }

    @Test func cursorOnTopEdgeStillPicksThatScreen() {
        // NSEvent.mouseLocation can report y == frame.maxY at the top of a screen.
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: CGPoint(x: 700, y: 900), in: twoScreenFrames) == 0)
    }

    @Test func cursorOnSharedEdgePicksTheScreenItEntered() {
        // x == 1440 is the right screen's first column.
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: CGPoint(x: 1440, y: 300), in: twoScreenFrames) == 1)
    }

    @Test func cursorOutsideEveryScreenPicksTheNearestOne() {
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: CGPoint(x: 3500, y: 0), in: twoScreenFrames) == 1)
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: CGPoint(x: -50, y: 450), in: twoScreenFrames) == 0)
    }

    @Test func noScreensMeansNoSelection() {
        #expect(CompanionScreenCaptureUtility.indexOfScreenFrame(containingCursorLocation: .zero, in: []) == nil)
    }

    // MARK: - Reusing the push-to-talk prefetch

    private func makeCapture(displayID: CGDirectDisplayID) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: Data(),
            label: "user's screen",
            isCursorScreen: true,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayID: displayID
        )
    }

    @Test func prefetchedCaptureIsReusedWhenCursorStayedOnItsScreen() {
        #expect(CompanionScreenCaptureUtility.shouldReusePrefetchedScreenCaptures([makeCapture(displayID: 7)], cursorDisplayIDWhenTurnIsSent: 7))
    }

    @Test func prefetchedCaptureIsDiscardedWhenCursorChangedScreens() {
        #expect(!CompanionScreenCaptureUtility.shouldReusePrefetchedScreenCaptures([makeCapture(displayID: 7)], cursorDisplayIDWhenTurnIsSent: 9))
        #expect(!CompanionScreenCaptureUtility.shouldReusePrefetchedScreenCaptures(nil, cursorDisplayIDWhenTurnIsSent: 7))
        #expect(!CompanionScreenCaptureUtility.shouldReusePrefetchedScreenCaptures([], cursorDisplayIDWhenTurnIsSent: 7))
    }

    @Test func prefetchedCaptureIsKeptWhenCursorScreenIsUnknown() {
        #expect(CompanionScreenCaptureUtility.shouldReusePrefetchedScreenCaptures([makeCapture(displayID: 7)], cursorDisplayIDWhenTurnIsSent: nil))
    }

    // MARK: - A stray screen number from the model

    @Test func outOfRangeScreenNumberFallsBackToTheOnlyCapture() {
        let onlyCapture = makeCapture(displayID: 7)
        #expect(CompanionScreenCapture.targetCapture(screenNumber: 2, in: [onlyCapture])?.displayID == 7)
        #expect(CompanionScreenCapture.targetCapture(screenNumber: nil, in: [onlyCapture])?.displayID == 7)
    }
}
