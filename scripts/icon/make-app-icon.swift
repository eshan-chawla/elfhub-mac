// Builds elfhub's app icon from the artwork in brand/source/.
//
// The icon artwork is NOT covered by the AGPL — see brand/LICENSE.md.
// Copyright (c) 2026 Eshan Chawla. All rights reserved.
//
// Run from the repo root:
//   swift scripts/icon/make-app-icon.swift
//
// What it does:
// 1. Takes the full icon design (blue rounded square with the igloo, on a
//    flat dark background) from brand/source/elfhub-icon-source.jpg and
//    removes that background: the background is flood-filled from the image
//    border, so dark pixels inside the artwork (the igloo's doorway) stay.
//    Edge pixels get partial transparency with the background colour
//    un-mixed, so there's no dark fringe.
// 2. Fits the rounded square to Apple's macOS icon grid — an 824 px body on
//    a 1024 px canvas, 100 px margin, with a soft drop shadow — so elfhub
//    sits the same size as other apps in the Dock and Finder.
// 3. Writes every size the asset catalog needs (16–1024 px) into
//    elfhub/Assets.xcassets/AppIcon.appiconset, halving step by step so the
//    small sizes stay sharp. Xcode compiles these into the app's icon.
// 4. Writes brand/elfhub-icon-1024.png and brand/elfhub-icon.svg, plus
//    brand/elfhub-igloo-1024.png and brand/elfhub-igloo.svg from the igloo
//    cut-out (brand/source/elfhub-igloo-cutout-source.png). The artwork is a
//    3D render, so the SVGs embed it as a PNG: tracing it into vector paths
//    would flatten its shading.
// Every PNG and SVG carries the copyright notice in its metadata.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let copyrightNotice = "Copyright (c) 2026 Eshan Chawla. All rights reserved. The elfhub icon is not licensed under AGPL-3.0 and may not be used, copied or modified without written permission."

let iconSourcePath = "brand/source/elfhub-icon-source.jpg"
let iglooCutoutSourcePath = "brand/source/elfhub-igloo-cutout-source.png"
let appIconSetFolderPath = "elfhub/Assets.xcassets/AppIcon.appiconset"
let brandFolderPath = "brand"

// Apple's macOS app icon grid (1024 px canvas).
let iconCanvasSizeInPixels = 1024
let iconBodySizeInPixels: CGFloat = 824
let iconBodyMarginInPixels: CGFloat = 100
let iconShadowOffsetInPixels: CGFloat = 10
let iconShadowBlurInPixels: CGFloat = 20
let iconShadowOpacity: CGFloat = 0.3

// Colour distance (RGB, 0–255) from the flat background. Below the lower
// value a pixel is background; above the upper value it is artwork; in
// between it is an anti-aliased edge pixel.
let backgroundColorDistanceFloodFillLimit = 60.0
let backgroundColorDistanceFullyTransparent = 25.0
let backgroundColorDistanceFullyOpaque = 105.0

let standardRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func failAndExit(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icon: \(message)\n".utf8))
    exit(1)
}

func loadImage(atPath imagePath: String) -> CGImage {
    guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        failAndExit("can't read \(imagePath) (run this from the repo root)")
    }
    return image
}

func makeTransparentContext(widthInPixels: Int, heightInPixels: Int, pixelBuffer: UnsafeMutableRawPointer? = nil) -> CGContext {
    guard let context = CGContext(
        data: pixelBuffer,
        width: widthInPixels,
        height: heightInPixels,
        bitsPerComponent: 8,
        bytesPerRow: widthInPixels * 4,
        space: standardRGBColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        failAndExit("can't create a \(widthInPixels)×\(heightInPixels) drawing context")
    }
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, toPath outputPath: String) {
    guard let imageDestination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        failAndExit("can't write \(outputPath)")
    }
    let pngMetadata: [CFString: Any] = [
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGTitle: "elfhub icon",
            kCGImagePropertyPNGAuthor: "Eshan Chawla",
            kCGImagePropertyPNGCopyright: copyrightNotice,
        ],
    ]
    CGImageDestinationAddImage(imageDestination, image, pngMetadata as CFDictionary)
    guard CGImageDestinationFinalize(imageDestination) else { failAndExit("can't write \(outputPath)") }
    print("Wrote \(outputPath)")
}

func pngData(of image: CGImage) -> Data {
    let pngDataBuffer = NSMutableData()
    guard let imageDestination = CGImageDestinationCreateWithData(pngDataBuffer, UTType.png.identifier as CFString, 1, nil) else {
        failAndExit("can't encode a PNG")
    }
    CGImageDestinationAddImage(imageDestination, image, nil)
    guard CGImageDestinationFinalize(imageDestination) else { failAndExit("can't encode a PNG") }
    return pngDataBuffer as Data
}

/// An SVG that scales the artwork to any size. The render is embedded as a
/// PNG because it is shaded 3D artwork, not shapes.
func writeSVG(embedding image: CGImage, title: String, toPath outputPath: String) {
    let base64EncodedPNG = pngData(of: image).base64EncodedString()
    let svgText = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- \(copyrightNotice) -->
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 \(image.width) \(image.height)" width="\(image.width)" height="\(image.height)">
      <title>\(title)</title>
      <metadata>\(copyrightNotice)</metadata>
      <image width="\(image.width)" height="\(image.height)" xlink:href="data:image/png;base64,\(base64EncodedPNG)"/>
    </svg>

    """
    do {
        try Data(svgText.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("Wrote \(outputPath)")
    } catch {
        failAndExit("can't write \(outputPath): \(error.localizedDescription)")
    }
}

// MARK: - 1. Remove the flat background from the full design

let iconSourceImage = loadImage(atPath: iconSourcePath)
let sourceWidthInPixels = iconSourceImage.width
let sourceHeightInPixels = iconSourceImage.height
let sourcePixelCount = sourceWidthInPixels * sourceHeightInPixels

// Premultiplied RGBA, first row = top of the image.
var sourcePixelBytes = [UInt8](repeating: 0, count: sourcePixelCount * 4)
sourcePixelBytes.withUnsafeMutableBytes { pixelBufferPointer in
    let sourceContext = makeTransparentContext(
        widthInPixels: sourceWidthInPixels,
        heightInPixels: sourceHeightInPixels,
        pixelBuffer: pixelBufferPointer.baseAddress
    )
    sourceContext.draw(iconSourceImage, in: CGRect(x: 0, y: 0, width: sourceWidthInPixels, height: sourceHeightInPixels))
}

// The background colour, averaged from a patch in the top-left corner.
let cornerPatchSizeInPixels = 32
var backgroundColorSums = [0.0, 0.0, 0.0]
for patchRow in 0..<cornerPatchSizeInPixels {
    for patchColumn in 0..<cornerPatchSizeInPixels {
        let byteOffset = (patchRow * sourceWidthInPixels + patchColumn) * 4
        for channelIndex in 0..<3 {
            backgroundColorSums[channelIndex] += Double(sourcePixelBytes[byteOffset + channelIndex])
        }
    }
}
let backgroundColor = backgroundColorSums.map { $0 / Double(cornerPatchSizeInPixels * cornerPatchSizeInPixels) }

func colorDistanceFromBackground(pixelIndex: Int) -> Double {
    let byteOffset = pixelIndex * 4
    var squaredDistance = 0.0
    for channelIndex in 0..<3 {
        let channelDifference = Double(sourcePixelBytes[byteOffset + channelIndex]) - backgroundColor[channelIndex]
        squaredDistance += channelDifference * channelDifference
    }
    return squaredDistance.squareRoot()
}

// Flood fill from every border pixel through background-coloured pixels.
var isBackgroundPixel = [Bool](repeating: false, count: sourcePixelCount)
var pixelIndicesToVisit: [Int] = []
for column in 0..<sourceWidthInPixels {
    pixelIndicesToVisit.append(column)
    pixelIndicesToVisit.append((sourceHeightInPixels - 1) * sourceWidthInPixels + column)
}
for row in 0..<sourceHeightInPixels {
    pixelIndicesToVisit.append(row * sourceWidthInPixels)
    pixelIndicesToVisit.append(row * sourceWidthInPixels + sourceWidthInPixels - 1)
}
while let pixelIndex = pixelIndicesToVisit.popLast() {
    if isBackgroundPixel[pixelIndex] { continue }
    if colorDistanceFromBackground(pixelIndex: pixelIndex) >= backgroundColorDistanceFloodFillLimit { continue }
    isBackgroundPixel[pixelIndex] = true
    let row = pixelIndex / sourceWidthInPixels
    let column = pixelIndex % sourceWidthInPixels
    if row > 0 { pixelIndicesToVisit.append(pixelIndex - sourceWidthInPixels) }
    if row < sourceHeightInPixels - 1 { pixelIndicesToVisit.append(pixelIndex + sourceWidthInPixels) }
    if column > 0 { pixelIndicesToVisit.append(pixelIndex - 1) }
    if column < sourceWidthInPixels - 1 { pixelIndicesToVisit.append(pixelIndex + 1) }
}

// Background pixels and artwork pixels within 2 px of the background are
// edge candidates: their transparency comes from how far their colour is
// from the background. Everything else is solid artwork.
let edgeReachInPixels = 2
var isEdgeCandidatePixel = isBackgroundPixel
for row in 0..<sourceHeightInPixels {
    for column in 0..<sourceWidthInPixels where isBackgroundPixel[row * sourceWidthInPixels + column] {
        for rowOffset in -edgeReachInPixels...edgeReachInPixels {
            for columnOffset in -edgeReachInPixels...edgeReachInPixels {
                let neighbourRow = row + rowOffset
                let neighbourColumn = column + columnOffset
                guard neighbourRow >= 0, neighbourRow < sourceHeightInPixels,
                      neighbourColumn >= 0, neighbourColumn < sourceWidthInPixels else { continue }
                isEdgeCandidatePixel[neighbourRow * sourceWidthInPixels + neighbourColumn] = true
            }
        }
    }
}

var artworkTopRow = sourceHeightInPixels
var artworkBottomRow = 0
var artworkLeftColumn = sourceWidthInPixels
var artworkRightColumn = 0
for pixelIndex in 0..<sourcePixelCount {
    var opacity = 1.0
    if isEdgeCandidatePixel[pixelIndex] {
        let colorDistance = colorDistanceFromBackground(pixelIndex: pixelIndex)
        opacity = (colorDistance - backgroundColorDistanceFullyTransparent)
            / (backgroundColorDistanceFullyOpaque - backgroundColorDistanceFullyTransparent)
        opacity = min(max(opacity, 0), 1)
    }

    let byteOffset = pixelIndex * 4
    // Un-mix the background: observed = opacity × artwork + (1 − opacity) ×
    // background, stored premultiplied (opacity × artwork).
    for channelIndex in 0..<3 {
        let observedValue = Double(sourcePixelBytes[byteOffset + channelIndex])
        let premultipliedArtworkValue = observedValue - (1 - opacity) * backgroundColor[channelIndex]
        sourcePixelBytes[byteOffset + channelIndex] = UInt8(min(max(premultipliedArtworkValue, 0), opacity * 255).rounded())
    }
    sourcePixelBytes[byteOffset + 3] = UInt8((opacity * 255).rounded())

    if opacity > 0.5 {
        let row = pixelIndex / sourceWidthInPixels
        let column = pixelIndex % sourceWidthInPixels
        artworkTopRow = min(artworkTopRow, row)
        artworkBottomRow = max(artworkBottomRow, row)
        artworkLeftColumn = min(artworkLeftColumn, column)
        artworkRightColumn = max(artworkRightColumn, column)
    }
}

let backgroundRemovedImage = sourcePixelBytes.withUnsafeMutableBytes { pixelBufferPointer -> CGImage in
    makeTransparentContext(
        widthInPixels: sourceWidthInPixels,
        heightInPixels: sourceHeightInPixels,
        pixelBuffer: pixelBufferPointer.baseAddress
    ).makeImage()!
}

// CGImage cropping uses top-left coordinates, like the pixel rows above.
let artworkBoundsInSource = CGRect(
    x: artworkLeftColumn,
    y: artworkTopRow,
    width: artworkRightColumn - artworkLeftColumn + 1,
    height: artworkBottomRow - artworkTopRow + 1
)
guard artworkBoundsInSource.width > CGFloat(sourceWidthInPixels) / 2,
      let roundedSquareImage = backgroundRemovedImage.cropping(to: artworkBoundsInSource) else {
    failAndExit("couldn't find the rounded square in \(iconSourcePath)")
}
print("Rounded square in the source: \(Int(artworkBoundsInSource.width))×\(Int(artworkBoundsInSource.height)) px at (\(artworkLeftColumn), \(artworkTopRow))")

// MARK: - 2. Fit it to Apple's grid

let masterIconContext = makeTransparentContext(widthInPixels: iconCanvasSizeInPixels, heightInPixels: iconCanvasSizeInPixels)
masterIconContext.setShadow(
    offset: CGSize(width: 0, height: -iconShadowOffsetInPixels),
    blur: iconShadowBlurInPixels,
    color: CGColor(gray: 0, alpha: iconShadowOpacity)
)
// The source square is a few pixels wider than tall; it's fitted to the
// square body exactly (a ~2% squeeze), which keeps its whole rim.
masterIconContext.draw(
    roundedSquareImage,
    in: CGRect(
        x: iconBodyMarginInPixels,
        y: CGFloat(iconCanvasSizeInPixels) - iconBodyMarginInPixels - iconBodySizeInPixels,
        width: iconBodySizeInPixels,
        height: iconBodySizeInPixels
    )
)
let masterIconImage = masterIconContext.makeImage()!

// MARK: - 3. Every size for the asset catalog

writePNG(masterIconImage, toPath: "\(appIconSetFolderPath)/1024-mac.png")
var previousSizeImage = masterIconImage
for iconSizeInPixels in [512, 256, 128, 64, 32, 16] {
    let downscaleContext = makeTransparentContext(widthInPixels: iconSizeInPixels, heightInPixels: iconSizeInPixels)
    downscaleContext.draw(previousSizeImage, in: CGRect(x: 0, y: 0, width: iconSizeInPixels, height: iconSizeInPixels))
    previousSizeImage = downscaleContext.makeImage()!
    writePNG(previousSizeImage, toPath: "\(appIconSetFolderPath)/\(iconSizeInPixels)-mac.png")
}

// MARK: - 4. Brand files

writePNG(masterIconImage, toPath: "\(brandFolderPath)/elfhub-icon-1024.png")
writeSVG(embedding: masterIconImage, title: "elfhub", toPath: "\(brandFolderPath)/elfhub-icon.svg")

// The igloo on its own (no rounded square), at 1024 px. Drawing it into a
// premultiplied context also drops the colour data hidden under its
// transparent pixels.
let iglooCutoutSourceImage = loadImage(atPath: iglooCutoutSourcePath)
let iglooContext = makeTransparentContext(widthInPixels: iconCanvasSizeInPixels, heightInPixels: iconCanvasSizeInPixels)
iglooContext.draw(iglooCutoutSourceImage, in: CGRect(x: 0, y: 0, width: iconCanvasSizeInPixels, height: iconCanvasSizeInPixels))
let iglooImage = iglooContext.makeImage()!
writePNG(iglooImage, toPath: "\(brandFolderPath)/elfhub-igloo-1024.png")
writeSVG(embedding: iglooImage, title: "elfhub igloo", toPath: "\(brandFolderPath)/elfhub-igloo.svg")
