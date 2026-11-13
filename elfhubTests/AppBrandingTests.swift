//
//  AppBrandingTests.swift
//  elfhubTests
//
//  The igloo menu bar icon ships in the app's asset catalog as a 22 pt
//  template image, so macOS tints it for light and dark menu bars.
//

import AppKit
import Testing
@testable import elfhub

@MainActor
struct AppBrandingTests {

    @Test func theMenuBarIconIsTheIglooTemplateImage() throws {
        let menuBarIcon = try #require(MenuBarPanelManager.makeMenuBarIcon())
        #expect(menuBarIcon.isTemplate)
        #expect(menuBarIcon.size == NSSize(width: 22, height: 22))
    }
}
