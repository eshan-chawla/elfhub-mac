//
//  ElfAvatarPictureTests.swift
//  elfhubTests
//
//  The main Elf always on Igloo Blue, and pictures for any Elf: made
//  square and small, saved in the Elf's own data, shown at once, removable.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import elfhub

@MainActor
struct ElfAvatarPictureTests {

    private func makeTemporaryElfsDirectory() -> (elfsDirectory: URL, cleanUp: () -> Void) {
        let elfsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elfs-\(UUID().uuidString)", isDirectory: true)
        return (elfsDirectory, { try? FileManager.default.removeItem(at: elfsDirectory) })
    }

    /// A solid-color PNG of the given pixel size, written to a temporary file.
    private func writeTestImage(pixelWidth: Int, pixelHeight: Int, fileExtension: String = "png") throws -> URL {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawingContext = try #require(CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        drawingContext.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        drawingContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let image = try #require(drawingContext.makeImage())
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-source-\(UUID().uuidString).\(fileExtension)")
        let imageType = fileExtension == "jpg" ? UTType.jpeg : UTType.png
        let imageDestination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, imageType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, image, nil)
        #expect(CGImageDestinationFinalize(imageDestination))
        return imageURL
    }

    private func pixelSize(ofPNGData pngData: Data) throws -> (width: Int, height: Int) {
        let imageSource = try #require(CGImageSourceCreateWithData(pngData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        return (image.width, image.height)
    }

    private func resolvedHex(_ color: Color) -> String {
        let resolvedColor = color.resolve(in: EnvironmentValues())
        return String(
            format: "#%02X%02X%02X",
            Int((resolvedColor.red * 255).rounded()),
            Int((resolvedColor.green * 255).rounded()),
            Int((resolvedColor.blue * 255).rounded())
        )
    }

    // MARK: - Brand blue

    @Test func theMainElfIsAlwaysOnIglooBlue() throws {
        #expect(resolvedHex(DS.Colors.mainElfAvatarFill) == "#0D66DA")
        #expect(ElfAvatarAppearance.usesBrandBlue(elfIdentifier: ElfManager.mainElfIdentifier))
        #expect(!ElfAvatarAppearance.usesBrandBlue(elfIdentifier: "juniper"))

        // A color saved for the main Elf before this change is ignored.
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        try ElfEditor(editingMainElfOf: elfManager).updateAvatarColorIndex(3)
        let mainElfAvatar = ElfAvatar(elf: try #require(elfManager.elf(withIdentifier: ElfManager.mainElfIdentifier)))
        #expect(resolvedHex(mainElfAvatar.fillColor) == "#0D66DA")
    }

    @Test func sideElfsStillUseTheirPickedColor() throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        let juniper = try elfManager.createElf(identity: .init(name: "Juniper", avatarColorIndex: 1))
        #expect(resolvedHex(ElfAvatar(elf: juniper).fillColor) == resolvedHex(DS.Colors.elfAvatarFills[1]))
    }

    // MARK: - Making the picture

    @Test func aWidePictureBecomesASmallSquare() throws {
        let sourceURL = try writeTestImage(pixelWidth: 1600, pixelHeight: 900)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let pngData = try ElfAvatarPicture.squarePNGData(fromImageAt: sourceURL)
        let size = try pixelSize(ofPNGData: pngData)
        #expect(size.width == ElfAvatarPicture.sideLengthInPixels)
        #expect(size.height == ElfAvatarPicture.sideLengthInPixels)
    }

    @Test func aTallJPEGBecomesASquareToo() throws {
        let sourceURL = try writeTestImage(pixelWidth: 700, pixelHeight: 2000, fileExtension: "jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let size = try pixelSize(ofPNGData: ElfAvatarPicture.squarePNGData(fromImageAt: sourceURL))
        #expect(size.width == size.height)
        #expect(size.width == ElfAvatarPicture.sideLengthInPixels)
    }

    @Test func aSmallPictureIsNotBlownUp() throws {
        let sourceURL = try writeTestImage(pixelWidth: 120, pixelHeight: 80)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let size = try pixelSize(ofPNGData: ElfAvatarPicture.squarePNGData(fromImageAt: sourceURL))
        #expect(size.width == 80)
        #expect(size.height == 80)
    }

    @Test func aFileThatIsNotAPictureIsRefused() throws {
        #expect(throws: ElfAvatarPictureError.unreadableImage) {
            try ElfAvatarPicture.squarePNGData(fromImageData: Data("not a picture".utf8))
        }
    }

    // MARK: - Saving it

    @Test func aPictureIsSavedInTheElfsOwnDataAndCanBeRemoved() async throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        let juniper = try elfManager.createElf(identity: .init(name: "Juniper"))
        let sourceURL = try writeTestImage(pixelWidth: 800, pixelHeight: 800)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let pictureStore = ElfAvatarPictureStore.shared
        #expect(pictureStore.picture(for: juniper.home) == nil)
        let revisionBefore = pictureStore.revision

        let elfEditor = try ElfEditor(elfIdentifier: juniper.id, elfManager: elfManager)
        try await elfEditor.updateAvatarPicture(fromImageAt: sourceURL)

        // Kept in .elfhub/, which elf tools can't reach and exports leave out.
        #expect(juniper.home.avatarPictureURL.deletingLastPathComponent() == juniper.home.appDataDirectory)
        #expect(FileManager.default.fileExists(atPath: juniper.home.avatarPictureURL.path))
        #expect(pictureStore.revision > revisionBefore)
        #expect(pictureStore.picture(for: juniper.home) != nil)
        #expect(throws: ElfHomeError.self) {
            try juniper.home.resolvedURLForElfTool(".elfhub/avatar.png", access: .read)
        }

        try elfEditor.removeAvatarPicture()
        #expect(!FileManager.default.fileExists(atPath: juniper.home.avatarPictureURL.path))
        #expect(pictureStore.picture(for: juniper.home) == nil)
    }

    @Test func theMainElfCanWearAPictureToo() async throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory)
        let sourceURL = try writeTestImage(pixelWidth: 600, pixelHeight: 600)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try await ElfEditor(editingMainElfOf: elfManager).updateAvatarPicture(fromImageAt: sourceURL)
        #expect(ElfAvatarPictureStore.shared.picture(for: elfManager.mainElf.home) != nil)
    }

    @Test func aDeletedElfDoesNotGetItsFolderBackFromAPicture() async throws {
        let (elfsDirectory, cleanUp) = makeTemporaryElfsDirectory()
        defer { cleanUp() }
        let elfManager = ElfManager(elfsDirectory: elfsDirectory, deletedFolderDisposal: .removePermanently)
        let juniper = try elfManager.createElf(identity: .init(name: "Juniper"))
        let elfEditor = try ElfEditor(elfIdentifier: juniper.id, elfManager: elfManager)
        try elfManager.deleteElf(withIdentifier: juniper.id)
        let sourceURL = try writeTestImage(pixelWidth: 300, pixelHeight: 300)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        await #expect(throws: (any Error).self) {
            try await elfEditor.updateAvatarPicture(fromImageAt: sourceURL)
        }
        #expect(!FileManager.default.fileExists(atPath: juniper.home.directory.path))
    }
}
