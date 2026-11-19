//
//  BrandDesignSystemTests.swift
//  elfhubTests
//
//  The brand foundations: colors follow the view's appearance with the
//  brand guide's light and dark values, the interface is set in the
//  system font (SF Pro) while the bundled Fraunces and JetBrains Mono load,
//  and Elf avatars get stable fills and sensible initials.
//

import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import elfhub

@MainActor
struct BrandDesignSystemTests {

    // MARK: - Colors

    private func resolvedHex(_ color: Color, colorScheme: ColorScheme) -> String {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let resolvedColor = color.resolve(in: environment)
        let red = Int((resolvedColor.red * 255).rounded())
        let green = Int((resolvedColor.green * 255).rounded())
        let blue = Int((resolvedColor.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    @Test func colorRolesResolveToTheBrandValuesInLightAndDark() {
        // Warm neutral greys and plain ink — no blue in the interface;
        // status colors and the Elf's orange pen keep their meaning.
        let expectedRoleValues: [(String, Color, String, String)] = [
            ("background", DS.Colors.background, "#FAF9F7", "#1F1F1E"),
            ("surface", DS.Colors.surface1, "#FFFFFF", "#262625"),
            ("surfaceMuted", DS.Colors.surface2, "#F3F2EE", "#2D2D2B"),
            ("text", DS.Colors.textPrimary, "#1F1E1D", "#EEEDE9"),
            ("textMuted", DS.Colors.textSecondary, "#5E5D59", "#B4B2AC"),
            ("textSubtle", DS.Colors.textTertiary, "#77756F", "#8F8D87"),
            ("border", DS.Colors.borderSubtle, "#E8E6E1", "#363634"),
            ("borderStrong", DS.Colors.borderStrong, "#D7D4CE", "#474744"),
            ("accentFill", DS.Colors.accent, "#1F1E1D", "#EEEDE9"),
            ("textOnAccent", DS.Colors.textOnAccent, "#FFFFFF", "#1F1F1E"),
            ("accentText", DS.Colors.accentText, "#1F1E1D", "#EEEDE9"),
            ("accentSoft", DS.Colors.accentSubtle, "#EEECE7", "#353533"),
            ("annotate", DS.Colors.annotate, "#EA580C", "#FB923C"),
            ("sidebar", DS.Colors.sidebar, "#F3F1EC", "#262624"),
            ("sidebarSelected", DS.Colors.sidebarSelected, "#E2DED6", "#3A3A37"),
            ("success", DS.Colors.success, "#15803D", "#4ADE80"),
            ("warning", DS.Colors.warning, "#B45309", "#FBBF24"),
            ("danger", DS.Colors.destructiveText, "#B91C1C", "#F87171"),
        ]
        for (roleName, color, lightHex, darkHex) in expectedRoleValues {
            #expect(resolvedHex(color, colorScheme: .light) == lightHex, "\(roleName) in light")
            #expect(resolvedHex(color, colorScheme: .dark) == darkHex, "\(roleName) in dark")
        }
    }

    @Test func thereAreSixElfAvatarFills() {
        #expect(DS.Colors.elfAvatarFills.count == ElfAvatarAppearance.fillCount)
        #expect(resolvedHex(DS.Colors.elfAvatarFills[0], colorScheme: .light) == "#4A4744")
    }

    // MARK: - Fonts

    @Test func theBundledBrandFontsLoad() {
        BrandFonts.registerBundledFontsIfNeeded()
        for postScriptName in ["JetBrainsMono-Regular", "JetBrainsMono-Medium"] {
            let font = NSFont(name: postScriptName, size: 14)
            #expect(font?.fontName == postScriptName, "\(postScriptName) is bundled and registered")
        }
    }

    @Test func frauncesIsSetCrispAtTheRegularWeight() throws {
        BrandFonts.registerBundledFontsIfNeeded()
        let frauncesFont = try #require(BrandFonts.frauncesDisplayFont(size: 34))
        #expect(CTFontCopyFamilyName(frauncesFont) as String == "Fraunces")
        let variation = try #require(CTFontCopyVariation(frauncesFont) as? [Int: CGFloat])
        let weightAxisIdentifier = 0x77676874
        let softnessAxisIdentifier = 0x534F4654
        let wonkyAxisIdentifier = 0x574F4E4B
        #expect(variation[weightAxisIdentifier] == 400)
        #expect((variation[softnessAxisIdentifier] ?? 0) == 0)
        #expect((variation[wonkyAxisIdentifier] ?? 0) == 0)
    }

    @Test func theInterfaceIsSetInTheSystemFont() {
        // SF Pro, at the size and weight asked for — nothing bundled.
        #expect(DS.Typography.interface(size: 14, weight: .medium) == Font.system(size: 14, weight: .medium))
        #expect(DS.Typography.body == Font.system(size: 14, weight: .regular))
        #expect(DS.Typography.headingMedium == Font.system(size: 18, weight: .semibold))
        // Fraunces below 24 pt falls back to it too.
        #expect(DS.Typography.fraunces(size: 18) == Font.system(size: 18, weight: .semibold))
        #expect(BrandFonts.monoPostScriptName(for: .semibold) == "JetBrainsMono-Medium")
    }

    @Test func interIsNoLongerBundled() {
        let bundledFontFileNames = BrandFonts.bundledFontFileURLs(in: Bundle.main).map(\.lastPathComponent)
        #expect(!bundledFontFileNames.contains { $0.hasPrefix("Inter") })
        #expect(bundledFontFileNames.contains("Fraunces-Variable.ttf"))
        #expect(bundledFontFileNames.contains("JetBrainsMono-Regular.ttf"))
    }

    // MARK: - Avatars

    @Test func initialsComeFromTheFirstTwoWords() {
        #expect(ElfAvatarAppearance.initials(forName: "Juniper") == "J")
        #expect(ElfAvatarAppearance.initials(forName: "Dr Who") == "DW")
        #expect(ElfAvatarAppearance.initials(forName: "r2-d2") == "RD")
        #expect(ElfAvatarAppearance.initials(forName: "anne marie louise") == "AM")
        #expect(ElfAvatarAppearance.initials(forName: "🦊") == "E")
        #expect(ElfAvatarAppearance.initials(forName: "  ") == "E")
    }

    @Test func avatarFillsAreStableAndRespectTheUsersPick() {
        let firstFill = ElfAvatarAppearance.fillIndex(forElfIdentifier: "juniper", avatarColorIndex: nil)
        let secondFill = ElfAvatarAppearance.fillIndex(forElfIdentifier: "juniper", avatarColorIndex: nil)
        #expect(firstFill == secondFill)
        #expect((0..<ElfAvatarAppearance.fillCount).contains(firstFill))
        #expect(ElfAvatarAppearance.fillIndex(forElfIdentifier: "juniper", avatarColorIndex: 4) == 4)
        #expect(ElfAvatarAppearance.fillIndex(forElfIdentifier: "juniper", avatarColorIndex: 7) == 1)
        #expect(ElfAvatarAppearance.fillIndex(forElfIdentifier: "juniper", avatarColorIndex: -1) == 5)
    }

    @Test func elfJSONWithoutAnAvatarColorStillLoads() throws {
        let olderElfJSON = #"{"schemaVersion":1,"identity":{"name":"Juniper","emoji":"🌿"}}"#
        let configuration = try JSONDecoder().decode(ElfConfiguration.self, from: Data(olderElfJSON.utf8))
        #expect(configuration.identity.name == "Juniper")
        #expect(configuration.identity.avatarColorIndex == nil)

        var pickedConfiguration = configuration
        pickedConfiguration.identity.avatarColorIndex = 3
        let roundTripped = try JSONDecoder().decode(ElfConfiguration.self, from: JSONEncoder().encode(pickedConfiguration))
        #expect(roundTripped.identity.avatarColorIndex == 3)
    }

    @Test func taskStatesUseTheBrandsToneTable() {
        #expect(ElfTaskStatus.running.statusTone == .info)
        #expect(ElfTaskStatus.needsInput.statusTone == .warning)
        #expect(ElfTaskStatus.done.statusTone == .success)
        #expect(ElfTaskStatus.failed.statusTone == .danger)
        #expect(ElfTaskStatus.queued.statusTone == .neutral)
        #expect(ElfTaskStatus.cancelled.statusTone == .neutral)
    }
}
