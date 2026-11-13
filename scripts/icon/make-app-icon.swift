// Builds elfhub's app icon from the artwork in brand/source/.
//
// The icon artwork is NOT covered by the AGPL — see brand/LICENSE.md.
// Copyright (c) 2026 Eshan Chawla. All rights reserved.
//
// Run from the repo root (-O keeps it to a few seconds):
//   swift -O scripts/icon/make-app-icon.swift
//
// What it does:
// 1. Takes the full icon design (blue rounded square with the igloo, on a
//    flat dark background) from brand/source/elfhub-icon-source.jpg and
//    removes that background: the background is flood-filled from the image
//    border, so dark pixels inside the artwork (the igloo's doorway) stay.
//    Edge pixels get partial transparency with the background colour
//    un-mixed, so there's no dark fringe.
// 2. Resizes the igloo inside the square (iglooScaleWithinRoundedSquare).
//    The igloo cut-out (brand/source/elfhub-igloo-cutout-source.png) lines
//    up pixel for pixel with the full design, so it marks exactly where the
//    igloo and its shadow are. That area is painted out of the square with
//    a smooth fill from the blue around it, and the cut-out is drawn back
//    at the new size, centred where it was, with a soft contact shadow.
// 3. Fits the rounded square to Apple's macOS icon grid — an 824 px body on
//    a 1024 px canvas, 100 px margin, with a soft drop shadow — so elfhub
//    sits the same size as other apps in the Dock and Finder.
// 4. Writes every size the asset catalog needs (16–1024 px) into
//    elfhub/Assets.xcassets/AppIcon.appiconset, halving step by step so the
//    small sizes stay sharp. Xcode compiles these into the app's icon.
// 5. Writes brand/elfhub-icon-1024.png and brand/elfhub-icon.svg, plus
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

// The igloo's size relative to the source artwork (1 = as drawn).
let iglooScaleWithinRoundedSquare: CGFloat = 0.85

// Painting the original igloo out (source pixels, 2048 px artwork). The
// painted area covers the igloo, the dark floor beside it that the cut-out
// leaves out (the square's blue never has a blue value this low), and
// everything below it, where its shadow fell; it reaches this far beyond
// those and blends into the original over the outer feather width. It
// stays clear of the square's bevelled edge.
let darkestSquareBlueValue: UInt8 = 140
let paintedOutReachInPixels: Float = 70
let paintedOutFeatherInPixels: Float = 24
let squareEdgeKeepOutInPixels = 45
// The smooth fill is solved on a grid this many times coarser than the
// source; the square's blue is a soft gradient, so detail isn't lost.
let paintedOutFillGridScale = 8
let paintedOutFillIterationCount = 1500

// The new contact shadow under the resized igloo (source pixels).
let iglooShadowOffsetInPixels: CGFloat = 18
let iglooShadowBlurInPixels: CGFloat = 44
let iglooShadowColor = CGColor(srgbRed: 0, green: 0.05, blue: 0.3, alpha: 0.5)

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

// MARK: - 2. Resize the igloo

// The igloo cut-out at the source's size. Drawing it into a premultiplied
// context also drops the colour data hidden under its transparent pixels.
let iglooCutoutSourceImage = loadImage(atPath: iglooCutoutSourcePath)
guard iglooCutoutSourceImage.width == sourceWidthInPixels, iglooCutoutSourceImage.height == sourceHeightInPixels else {
    failAndExit("\(iglooCutoutSourcePath) must be the same size as \(iconSourcePath) (it marks where the igloo is)")
}
var iglooPixelBytes = [UInt8](repeating: 0, count: sourcePixelCount * 4)
let iglooCutoutImage = iglooPixelBytes.withUnsafeMutableBytes { pixelBufferPointer -> CGImage in
    let iglooContext = makeTransparentContext(
        widthInPixels: sourceWidthInPixels,
        heightInPixels: sourceHeightInPixels,
        pixelBuffer: pixelBufferPointer.baseAddress
    )
    iglooContext.draw(iglooCutoutSourceImage, in: CGRect(x: 0, y: 0, width: sourceWidthInPixels, height: sourceHeightInPixels))
    return iglooContext.makeImage()!
}
func iglooOpacityByte(pixelIndex: Int) -> UInt8 { iglooPixelBytes[pixelIndex * 4 + 3] }

var iglooTopRow = sourceHeightInPixels
var iglooBottomRow = 0
var iglooLeftColumn = sourceWidthInPixels
var iglooRightColumn = 0
for pixelIndex in 0..<sourcePixelCount where iglooOpacityByte(pixelIndex: pixelIndex) > 128 {
    let row = pixelIndex / sourceWidthInPixels
    let column = pixelIndex % sourceWidthInPixels
    iglooTopRow = min(iglooTopRow, row)
    iglooBottomRow = max(iglooBottomRow, row)
    iglooLeftColumn = min(iglooLeftColumn, column)
    iglooRightColumn = max(iglooRightColumn, column)
}
guard iglooRightColumn > iglooLeftColumn else { failAndExit("\(iglooCutoutSourcePath) has no igloo in it") }

// The lowest igloo pixel in each column; everything under it is shadow.
var lowestIglooRowByColumn = [Int](repeating: -1, count: sourceWidthInPixels)
for pixelIndex in 0..<sourcePixelCount where iglooOpacityByte(pixelIndex: pixelIndex) > 0 {
    let column = pixelIndex % sourceWidthInPixels
    lowestIglooRowByColumn[column] = max(lowestIglooRowByColumn[column], pixelIndex / sourceWidthInPixels)
}

// Distance from every pixel to the igloo, the dark floor beside it or the
// area under it, by a two-pass chamfer transform.
let diagonalStepInPixels: Float = 1.4142
var distanceToIglooOrShadow = [Float](repeating: 1_000_000, count: sourcePixelCount)
for pixelIndex in 0..<sourcePixelCount {
    let row = pixelIndex / sourceWidthInPixels
    let column = pixelIndex % sourceWidthInPixels
    let isIglooPixel = iglooOpacityByte(pixelIndex: pixelIndex) > 0
    let isOldShadowPixel = lowestIglooRowByColumn[column] >= 0 && row > lowestIglooRowByColumn[column]
    let isInsideIglooArea = row >= iglooTopRow && row <= iglooBottomRow
        && column >= iglooLeftColumn && column <= iglooRightColumn
    let isDarkFloorPixel = isInsideIglooArea
        && sourcePixelBytes[pixelIndex * 4 + 3] == 255
        && sourcePixelBytes[pixelIndex * 4 + 2] < darkestSquareBlueValue
    if isIglooPixel || isOldShadowPixel || isDarkFloorPixel { distanceToIglooOrShadow[pixelIndex] = 0 }
}
for row in 0..<sourceHeightInPixels {
    for column in 0..<sourceWidthInPixels {
        let pixelIndex = row * sourceWidthInPixels + column
        var shortestDistance = distanceToIglooOrShadow[pixelIndex]
        if column > 0 { shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex - 1] + 1) }
        if row > 0 {
            shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex - sourceWidthInPixels] + 1)
            if column > 0 { shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex - sourceWidthInPixels - 1] + diagonalStepInPixels) }
            if column < sourceWidthInPixels - 1 { shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex - sourceWidthInPixels + 1] + diagonalStepInPixels) }
        }
        distanceToIglooOrShadow[pixelIndex] = shortestDistance
    }
}
for row in stride(from: sourceHeightInPixels - 1, through: 0, by: -1) {
    for column in stride(from: sourceWidthInPixels - 1, through: 0, by: -1) {
        let pixelIndex = row * sourceWidthInPixels + column
        var shortestDistance = distanceToIglooOrShadow[pixelIndex]
        if column < sourceWidthInPixels - 1 { shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex + 1] + 1) }
        if row < sourceHeightInPixels - 1 {
            shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex + sourceWidthInPixels] + 1)
            if column < sourceWidthInPixels - 1 { shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex + sourceWidthInPixels + 1] + diagonalStepInPixels) }
            if column > 0 { shortestDistance = min(shortestDistance, distanceToIglooOrShadow[pixelIndex + sourceWidthInPixels - 1] + diagonalStepInPixels) }
        }
        distanceToIglooOrShadow[pixelIndex] = shortestDistance
    }
}

/// Whether a pixel is far enough inside the square that painting it can't
/// touch the bevelled edge.
func isWellInsideRoundedSquare(row: Int, column: Int) -> Bool {
    for (rowOffset, columnOffset) in [(-squareEdgeKeepOutInPixels, 0), (squareEdgeKeepOutInPixels, 0), (0, -squareEdgeKeepOutInPixels), (0, squareEdgeKeepOutInPixels)] {
        let checkedRow = row + rowOffset
        let checkedColumn = column + columnOffset
        guard checkedRow >= 0, checkedRow < sourceHeightInPixels, checkedColumn >= 0, checkedColumn < sourceWidthInPixels,
              sourcePixelBytes[(checkedRow * sourceWidthInPixels + checkedColumn) * 4 + 3] == 255 else { return false }
    }
    return true
}

func isPaintedOutPixel(pixelIndex: Int) -> Bool {
    distanceToIglooOrShadow[pixelIndex] <= paintedOutReachInPixels
        && isWellInsideRoundedSquare(row: pixelIndex / sourceWidthInPixels, column: pixelIndex % sourceWidthInPixels)
}

// A coarse grid of the square's colour (unpremultiplied, 0–255). Cells that
// touch the painted-out area are unknown and get a smooth (harmonic) fill
// from their known neighbours.
let fillGridWidth = sourceWidthInPixels / paintedOutFillGridScale
let fillGridHeight = sourceHeightInPixels / paintedOutFillGridScale
let fillGridCellCount = fillGridWidth * fillGridHeight
var fillGridColorChannels = [[Float]](repeating: [Float](repeating: 0, count: fillGridCellCount), count: 3)
var isFillGridCellUnknown = [Bool](repeating: false, count: fillGridCellCount)
for gridRow in 0..<fillGridHeight {
    for gridColumn in 0..<fillGridWidth {
        let cellIndex = gridRow * fillGridWidth + gridColumn
        var premultipliedColorSums: [Float] = [0, 0, 0]
        var opacitySum: Float = 0
        for row in (gridRow * paintedOutFillGridScale)..<((gridRow + 1) * paintedOutFillGridScale) {
            for column in (gridColumn * paintedOutFillGridScale)..<((gridColumn + 1) * paintedOutFillGridScale) {
                let pixelIndex = row * sourceWidthInPixels + column
                if isPaintedOutPixel(pixelIndex: pixelIndex) { isFillGridCellUnknown[cellIndex] = true }
                for channelIndex in 0..<3 { premultipliedColorSums[channelIndex] += Float(sourcePixelBytes[pixelIndex * 4 + channelIndex]) }
                opacitySum += Float(sourcePixelBytes[pixelIndex * 4 + 3]) / 255
            }
        }
        for channelIndex in 0..<3 {
            fillGridColorChannels[channelIndex][cellIndex] = opacitySum > 0 ? premultipliedColorSums[channelIndex] / opacitySum : 0
        }
    }
}

// Start each unknown cell from a straight blend of the nearest known cells
// to its left and right (the blue changes mostly top to bottom), then relax.
var unknownFillGridCellIndices: [Int] = []
for gridRow in 0..<fillGridHeight {
    var gridColumn = 0
    while gridColumn < fillGridWidth {
        guard isFillGridCellUnknown[gridRow * fillGridWidth + gridColumn] else { gridColumn += 1; continue }
        let firstUnknownColumn = gridColumn
        while gridColumn < fillGridWidth && isFillGridCellUnknown[gridRow * fillGridWidth + gridColumn] { gridColumn += 1 }
        let knownLeftColumn = max(firstUnknownColumn - 1, 0)
        let knownRightColumn = min(gridColumn, fillGridWidth - 1)
        for unknownColumn in firstUnknownColumn..<gridColumn {
            let blendFraction = Float(unknownColumn - knownLeftColumn) / Float(max(knownRightColumn - knownLeftColumn, 1))
            let cellIndex = gridRow * fillGridWidth + unknownColumn
            for channelIndex in 0..<3 {
                let leftValue = fillGridColorChannels[channelIndex][gridRow * fillGridWidth + knownLeftColumn]
                let rightValue = fillGridColorChannels[channelIndex][gridRow * fillGridWidth + knownRightColumn]
                fillGridColorChannels[channelIndex][cellIndex] = leftValue + (rightValue - leftValue) * blendFraction
            }
            unknownFillGridCellIndices.append(cellIndex)
        }
    }
}
for _ in 0..<paintedOutFillIterationCount {
    for cellIndex in unknownFillGridCellIndices {
        for channelIndex in 0..<3 {
            let neighbourAverage = (fillGridColorChannels[channelIndex][cellIndex - 1]
                + fillGridColorChannels[channelIndex][cellIndex + 1]
                + fillGridColorChannels[channelIndex][cellIndex - fillGridWidth]
                + fillGridColorChannels[channelIndex][cellIndex + fillGridWidth]) / 4
            fillGridColorChannels[channelIndex][cellIndex] = neighbourAverage
        }
    }
}

// Paint the fill over the old igloo and shadow, sampled smoothly from the
// grid, blending into the original over the feather.
func fillGridColorValue(channelIndex: Int, atSourceColumn column: Int, row: Int) -> Float {
    let gridX = min(max((Float(column) + 0.5) / Float(paintedOutFillGridScale) - 0.5, 0), Float(fillGridWidth - 1))
    let gridY = min(max((Float(row) + 0.5) / Float(paintedOutFillGridScale) - 0.5, 0), Float(fillGridHeight - 1))
    let leftColumn = Int(gridX), topRow = Int(gridY)
    let rightColumn = min(leftColumn + 1, fillGridWidth - 1), bottomRow = min(topRow + 1, fillGridHeight - 1)
    let horizontalFraction = gridX - Float(leftColumn), verticalFraction = gridY - Float(topRow)
    let channelValues = fillGridColorChannels[channelIndex]
    let topValue = channelValues[topRow * fillGridWidth + leftColumn] * (1 - horizontalFraction) + channelValues[topRow * fillGridWidth + rightColumn] * horizontalFraction
    let bottomValue = channelValues[bottomRow * fillGridWidth + leftColumn] * (1 - horizontalFraction) + channelValues[bottomRow * fillGridWidth + rightColumn] * horizontalFraction
    return topValue * (1 - verticalFraction) + bottomValue * verticalFraction
}
for pixelIndex in 0..<sourcePixelCount where isPaintedOutPixel(pixelIndex: pixelIndex) {
    let fillWeight = min((paintedOutReachInPixels - distanceToIglooOrShadow[pixelIndex]) / paintedOutFeatherInPixels, 1)
    let row = pixelIndex / sourceWidthInPixels
    let column = pixelIndex % sourceWidthInPixels
    let byteOffset = pixelIndex * 4
    let opacity = Float(sourcePixelBytes[byteOffset + 3]) / 255
    for channelIndex in 0..<3 {
        let originalValue = opacity > 0 ? Float(sourcePixelBytes[byteOffset + channelIndex]) / opacity : 0
        let filledValue = fillGridColorValue(channelIndex: channelIndex, atSourceColumn: column, row: row)
        let blendedValue = filledValue * fillWeight + originalValue * (1 - fillWeight)
        sourcePixelBytes[byteOffset + channelIndex] = UInt8(min(max(blendedValue * opacity, 0), 255).rounded())
    }
}

let iglooFreeArtworkImage = sourcePixelBytes.withUnsafeMutableBytes { pixelBufferPointer -> CGImage in
    makeTransparentContext(
        widthInPixels: sourceWidthInPixels,
        heightInPixels: sourceHeightInPixels,
        pixelBuffer: pixelBufferPointer.baseAddress
    ).makeImage()!
}

// Draw the igloo back at its new size, centred where it was. CoreGraphics
// draws from the bottom-left, so rows are flipped.
let iglooCenterX = CGFloat(iglooLeftColumn + iglooRightColumn + 1) / 2
let iglooCenterYFromBottom = CGFloat(sourceHeightInPixels) - CGFloat(iglooTopRow + iglooBottomRow + 1) / 2
let artworkContext = makeTransparentContext(widthInPixels: sourceWidthInPixels, heightInPixels: sourceHeightInPixels)
artworkContext.draw(iglooFreeArtworkImage, in: CGRect(x: 0, y: 0, width: sourceWidthInPixels, height: sourceHeightInPixels))
artworkContext.setShadow(
    offset: CGSize(width: 0, height: -iglooShadowOffsetInPixels * iglooScaleWithinRoundedSquare),
    blur: iglooShadowBlurInPixels * iglooScaleWithinRoundedSquare,
    color: iglooShadowColor
)
artworkContext.draw(
    iglooCutoutImage,
    in: CGRect(
        x: iglooCenterX - iglooCenterX * iglooScaleWithinRoundedSquare,
        y: iglooCenterYFromBottom - iglooCenterYFromBottom * iglooScaleWithinRoundedSquare,
        width: CGFloat(sourceWidthInPixels) * iglooScaleWithinRoundedSquare,
        height: CGFloat(sourceHeightInPixels) * iglooScaleWithinRoundedSquare
    )
)
let backgroundRemovedImage = artworkContext.makeImage()!

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

// MARK: - 3. Fit it to Apple's grid

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

// MARK: - 4. Every size for the asset catalog

writePNG(masterIconImage, toPath: "\(appIconSetFolderPath)/1024-mac.png")
var previousSizeImage = masterIconImage
for iconSizeInPixels in [512, 256, 128, 64, 32, 16] {
    let downscaleContext = makeTransparentContext(widthInPixels: iconSizeInPixels, heightInPixels: iconSizeInPixels)
    downscaleContext.draw(previousSizeImage, in: CGRect(x: 0, y: 0, width: iconSizeInPixels, height: iconSizeInPixels))
    previousSizeImage = downscaleContext.makeImage()!
    writePNG(previousSizeImage, toPath: "\(appIconSetFolderPath)/\(iconSizeInPixels)-mac.png")
}

// MARK: - 5. Brand files

writePNG(masterIconImage, toPath: "\(brandFolderPath)/elfhub-icon-1024.png")
writeSVG(embedding: masterIconImage, title: "elfhub", toPath: "\(brandFolderPath)/elfhub-icon.svg")

// The igloo on its own (no rounded square), at 1024 px.
let iglooContext = makeTransparentContext(widthInPixels: iconCanvasSizeInPixels, heightInPixels: iconCanvasSizeInPixels)
iglooContext.draw(iglooCutoutImage, in: CGRect(x: 0, y: 0, width: iconCanvasSizeInPixels, height: iconCanvasSizeInPixels))
let iglooImage = iglooContext.makeImage()!
writePNG(iglooImage, toPath: "\(brandFolderPath)/elfhub-igloo-1024.png")
writeSVG(embedding: iglooImage, title: "elfhub igloo", toPath: "\(brandFolderPath)/elfhub-igloo.svg")
