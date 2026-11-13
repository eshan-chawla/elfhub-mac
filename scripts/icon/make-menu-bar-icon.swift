// Builds elfhub's menu bar icon: a one-colour igloo glyph (dome with block
// lines, the entrance tunnel and its doorway) that matches the app icon.
//
// The igloo artwork, this glyph included, is NOT covered by the AGPL — see
// brand/LICENSE.md. Copyright (c) 2026 Eshan Chawla. All rights reserved.
//
// Run from the repo root:
//   swift scripts/icon/make-menu-bar-icon.swift [preview.png]
//
// Writes the glyph as one SVG path (18 × 18 pt, macOS's menu bar icon size)
// to elfhub/Assets.xcassets/MenuBarIcon.imageset/menu-bar-igloo.svg, where
// the asset catalog keeps it as a vector template image (macOS tints it for
// light and dark menu bars), and to brand/elfhub-menu-bar-igloo.svg. With an
// argument, also writes a large preview PNG there.
//
// The shape is built with CoreGraphics path operations (the gaps between
// blocks and around the tunnel are cut out), so the SVG has no masks.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let copyrightNotice = "Copyright (c) 2026 Eshan Chawla. All rights reserved. The elfhub icon is not licensed under AGPL-3.0 and may not be used, copied or modified without written permission."

let glyphCanvasSizeInPoints: CGFloat = 18

// All measurements in points, origin at the bottom-left, y up.
let groundLineY: CGFloat = 4
let domeCenterX: CGFloat = 10.4
let domeHorizontalRadius: CGFloat = 6.6
let domeHeight: CGFloat = 9
let gapBetweenBlocks: CGFloat = 0.8
let firstBlockRowTopY: CGFloat = groundLineY + 3
let secondBlockRowTopY: CGFloat = firstBlockRowTopY + gapBetweenBlocks + 2.4
let firstBlockRowJointX: CGFloat = 14.2
let secondBlockRowJointX: CGFloat = 11.8
let tunnelCenterX: CGFloat = 5.4
let tunnelHorizontalRadius: CGFloat = 3.6
let tunnelHeight: CGFloat = 5
let tunnelOutlineGap: CGFloat = 0.9
let doorwayCenterX: CGFloat = 5.0
let doorwayHorizontalRadius: CGFloat = 1.35
let doorwayHeight: CGFloat = 3.1

func failAndExit(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-menu-bar-icon: \(message)\n".utf8))
    exit(1)
}

/// The part of an ellipse (centred on the ground line) above the ground.
func archAboveGround(centerX: CGFloat, horizontalRadius: CGFloat, height: CGFloat) -> CGPath {
    let fullEllipse = CGPath(
        ellipseIn: CGRect(x: centerX - horizontalRadius, y: groundLineY - height, width: horizontalRadius * 2, height: height * 2),
        transform: nil
    )
    let aboveGround = CGPath(rect: CGRect(x: 0, y: groundLineY, width: glyphCanvasSizeInPoints, height: glyphCanvasSizeInPoints), transform: nil)
    return fullEllipse.intersection(aboveGround)
}

let canvasWidth = glyphCanvasSizeInPoints
let blockGaps = CGMutablePath()
blockGaps.addRect(CGRect(x: 0, y: firstBlockRowTopY, width: canvasWidth, height: gapBetweenBlocks))
blockGaps.addRect(CGRect(x: 0, y: secondBlockRowTopY, width: canvasWidth, height: gapBetweenBlocks))
blockGaps.addRect(CGRect(x: firstBlockRowJointX, y: groundLineY, width: gapBetweenBlocks, height: firstBlockRowTopY - groundLineY))
blockGaps.addRect(CGRect(
    x: secondBlockRowJointX,
    y: firstBlockRowTopY + gapBetweenBlocks,
    width: gapBetweenBlocks,
    height: secondBlockRowTopY - firstBlockRowTopY - gapBetweenBlocks
))

let dome = archAboveGround(centerX: domeCenterX, horizontalRadius: domeHorizontalRadius, height: domeHeight)
let tunnel = archAboveGround(centerX: tunnelCenterX, horizontalRadius: tunnelHorizontalRadius, height: tunnelHeight)
let tunnelWithOutlineGap = archAboveGround(
    centerX: tunnelCenterX,
    horizontalRadius: tunnelHorizontalRadius + tunnelOutlineGap,
    height: tunnelHeight + tunnelOutlineGap
)
let doorway = archAboveGround(centerX: doorwayCenterX, horizontalRadius: doorwayHorizontalRadius, height: doorwayHeight)

let domeWithBlocks = dome.subtracting(blockGaps).subtracting(tunnelWithOutlineGap)
let tunnelWithDoorway = tunnel.subtracting(doorway)
let iglooGlyph = domeWithBlocks.union(tunnelWithDoorway)

let glyphBounds = iglooGlyph.boundingBoxOfPath
guard glyphBounds.minX >= 0, glyphBounds.maxX <= canvasWidth, glyphBounds.minY >= 0, glyphBounds.maxY <= canvasWidth else {
    failAndExit("the glyph doesn't fit the \(Int(canvasWidth)) pt canvas: \(glyphBounds)")
}

// SVG's y axis points down, so every y is flipped.
func svgNumber(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value)).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}
func svgPoint(_ point: CGPoint) -> String {
    "\(svgNumber(point.x)) \(svgNumber(canvasWidth - point.y))"
}
var svgPathCommands: [String] = []
iglooGlyph.applyWithBlock { pathElementPointer in
    let pathElement = pathElementPointer.pointee
    switch pathElement.type {
    case .moveToPoint:
        svgPathCommands.append("M\(svgPoint(pathElement.points[0]))")
    case .addLineToPoint:
        svgPathCommands.append("L\(svgPoint(pathElement.points[0]))")
    case .addQuadCurveToPoint:
        svgPathCommands.append("Q\(svgPoint(pathElement.points[0])) \(svgPoint(pathElement.points[1]))")
    case .addCurveToPoint:
        svgPathCommands.append("C\(svgPoint(pathElement.points[0])) \(svgPoint(pathElement.points[1])) \(svgPoint(pathElement.points[2]))")
    case .closeSubpath:
        svgPathCommands.append("Z")
    @unknown default:
        failAndExit("unexpected path element")
    }
}

let glyphSizeText = svgNumber(canvasWidth)
let svgText = """
<?xml version="1.0" encoding="UTF-8"?>
<!-- \(copyrightNotice) -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(glyphSizeText) \(glyphSizeText)" width="\(glyphSizeText)" height="\(glyphSizeText)">
  <title>elfhub</title>
  <path fill="#000000" fill-rule="nonzero" d="\(svgPathCommands.joined(separator: " "))"/>
</svg>

"""

for outputPath in ["elfhub/Assets.xcassets/MenuBarIcon.imageset/menu-bar-igloo.svg", "brand/elfhub-menu-bar-igloo.svg"] {
    do {
        try Data(svgText.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("Wrote \(outputPath)")
    } catch {
        failAndExit("can't write \(outputPath) (run this from the repo root): \(error.localizedDescription)")
    }
}

// Optional preview: the glyph at 1×, 2× and 16× on light and dark bars.
if CommandLine.arguments.count > 1 {
    let previewPath = CommandLine.arguments[1]
    let previewScales: [CGFloat] = [1, 2, 16]
    let previewWidth = Int(previewScales.reduce(0) { $0 + canvasWidth * $1 + 20 }) + 20
    let previewHeight = Int(canvasWidth * 16 + 40) * 2
    let previewContext = CGContext(
        data: nil, width: previewWidth, height: previewHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for (barIndex, barColors) in [(CGFloat(0.93), CGFloat(0.1)), (CGFloat(0.15), CGFloat(0.95))].enumerated() {
        let barOriginY = CGFloat(barIndex * previewHeight / 2)
        previewContext.setFillColor(gray: barColors.0, alpha: 1)
        previewContext.fill(CGRect(x: 0, y: barOriginY, width: CGFloat(previewWidth), height: CGFloat(previewHeight / 2)))
        var drawingOriginX: CGFloat = 20
        for previewScale in previewScales {
            previewContext.saveGState()
            previewContext.translateBy(x: drawingOriginX, y: barOriginY + 20)
            previewContext.scaleBy(x: previewScale, y: previewScale)
            previewContext.addPath(iglooGlyph)
            previewContext.setFillColor(gray: barColors.1, alpha: 1)
            previewContext.fillPath()
            previewContext.restoreGState()
            drawingOriginX += canvasWidth * previewScale + 20
        }
    }
    let previewDestination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: previewPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(previewDestination, previewContext.makeImage()!, nil)
    CGImageDestinationFinalize(previewDestination)
    print("Wrote \(previewPath)")
}
