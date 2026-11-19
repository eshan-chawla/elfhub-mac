//
//  FullScreenOverlayTests.swift
//  elfhubTests
//
//  The overlay (status pill, pointer, marks) must show over another app's
//  full-screen Space. elfhub is a regular Dock app, so that takes a
//  non-activating panel that joins every Space as a full-screen auxiliary —
//  and it must still never take focus or clicks.
//

import AppKit
import Testing
@testable import elfhub

@MainActor
struct FullScreenOverlayTests {

    @Test func theOverlayIsANonActivatingPanelThatJoinsFullScreenSpaces() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let overlayWindow = OverlayWindow(screen: screen)

        #expect(overlayWindow.styleMask.contains(.nonactivatingPanel),
                "a regular app's plain window never shows over another app's full-screen Space")
        #expect(overlayWindow.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(overlayWindow.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(overlayWindow.level.rawValue >= NSWindow.Level.screenSaver.rawValue)
        #expect(!overlayWindow.hidesOnDeactivate, "the pill shows while another app is in front")
        #expect(overlayWindow.ignoresMouseEvents)
        #expect(!overlayWindow.canBecomeKey)
        #expect(!overlayWindow.canBecomeMain)
    }
}
