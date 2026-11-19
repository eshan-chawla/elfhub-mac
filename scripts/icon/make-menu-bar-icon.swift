// Builds elfhub's menu bar icon: a one-colour igloo glyph that matches the
// app icon: a dome of blocks with the entrance tunnel coming out of it at an
// angle, toward the viewer and to the left, its doorway on the tunnel's
// front face.
//
// The igloo artwork, this glyph included, is NOT covered by the AGPL — see
// brand/LICENSE.md. Copyright (c) 2026 Eshan Chawla. All rights reserved.
//
// Run from the repo root:
//   swift scripts/icon/make-menu-bar-icon.swift [preview.png]
//
// Writes the glyph as one SVG path (22 × 22 pt, the tallest icon that fits
// the menu bar; the igloo is drawn on an 18 pt grid and scaled to fill it)
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

// The igloo is drawn on an 18 pt grid, then scaled up and centred on the
// 22 pt canvas. It's wide and low, so it needs the extra size to read at
// the same weight as other menu bar icons.
let drawingGridSizeInPoints: CGFloat = 18
let glyphCanvasSizeInPoints: CGFloat = 22
let glyphScaleOnCanvas: CGFloat = 1.35

// All measurements in points on the drawing grid, origin at the
// bottom-left, y up.
let groundLineY: CGFloat = 4
let domeCenterX: CGFloat = 9
let domeHorizontalRadius: CGFloat = 7.6
let domeHeight: CGFloat = 9.2
// Two rows of blocks with staggered joints (so they read as bricks) under a
// solid cap, like the snow on top of the artwork's igloo.
let gapBetweenBlocks: CGFloat = 0.8
let firstBlockRowTopY: CGFloat = groundLineY + 3
let secondBlockRowTopY: CGFloat = firstBlockRowTopY + gapBetweenBlocks + 2.4
let firstBlockRowJointX: CGFloat = 13.6
let secondBlockRowJointX: CGFloat = 12.4
// The entrance tunnel comes out of the dome at an angle, as in the artwork:
// its front face (a narrower arch, because it's seen from the side) is left
// of where the tunnel meets the dome, and the tunnel's side shows between
// them. The front face stays inside the dome's outline; a tunnel sticking out
// of the dome's side makes the glyph look like a turtle with its head out.
let tunnelFrontCenterX: CGFloat = 4.6
let tunnelFrontHorizontalRadius: CGFloat = 2.4
let tunnelBackCenterX: CGFloat = 8.0
let tunnelBackHorizontalRadius: CGFloat = 3.2
let tunnelOutlineGap: CGFloat = 0.8
// Tall enough that the gap above the tunnel runs straight into the gap above
// the first row of blocks, so no thin strip of dome is left over the tunnel.
let tunnelHeight: CGFloat = secondBlockRowTopY - groundLineY - tunnelOutlineGap
// One block line along the tunnel's side, like the artwork's tunnel blocks.
let tunnelSideBlockLineY: CGFloat = groundLineY + 2.2
// The doorway: straight sides with a round top, in the middle of the front
// face, with walls thick enough to read as an entrance at menu bar size.
let doorwayCenterX: CGFloat = tunnelFrontCenterX
let doorwayWidth: CGFloat = 2.0
let doorwayHeight: CGFloat = 3.2

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
    let aboveGround = CGPath(rect: CGRect(x: 0, y: groundLineY, width: drawingGridSizeInPoints, height: drawingGridSizeInPoints), transform: nil)
    return fullEllipse.intersection(aboveGround)
}

/// The tunnel seen from the side: its front arch, the arch where it meets
/// the dome, and the flat roof between their tops. `outlineGap` grows it by
/// that much all round, to cut a gap around it.
func tunnelOutline(outlineGap: CGFloat) -> CGPath {
    let frontArch = archAboveGround(
        centerX: tunnelFrontCenterX,
        horizontalRadius: tunnelFrontHorizontalRadius + outlineGap,
        height: tunnelHeight + outlineGap
    )
    let backArch = archAboveGround(
        centerX: tunnelBackCenterX,
        horizontalRadius: tunnelBackHorizontalRadius + outlineGap,
        height: tunnelHeight + outlineGap
    )
    let roofBetweenTheArches = CGPath(
        rect: CGRect(x: tunnelFrontCenterX, y: groundLineY, width: tunnelBackCenterX - tunnelFrontCenterX, height: tunnelHeight + outlineGap),
        transform: nil
    )
    return frontArch.union(backArch).union(roofBetweenTheArches)
}

let canvasWidth = glyphCanvasSizeInPoints
let drawingGridWidth = drawingGridSizeInPoints
let blockGaps = CGMutablePath()
blockGaps.addRect(CGRect(x: 0, y: firstBlockRowTopY, width: drawingGridWidth, height: gapBetweenBlocks))
blockGaps.addRect(CGRect(x: 0, y: secondBlockRowTopY, width: drawingGridWidth, height: gapBetweenBlocks))
blockGaps.addRect(CGRect(x: firstBlockRowJointX, y: groundLineY, width: gapBetweenBlocks, height: firstBlockRowTopY - groundLineY))
blockGaps.addRect(CGRect(
    x: secondBlockRowJointX,
    y: firstBlockRowTopY + gapBetweenBlocks,
    width: gapBetweenBlocks,
    height: secondBlockRowTopY - firstBlockRowTopY - gapBetweenBlocks
))

// The dome left of the tunnel's front face is cut away up to the first block
// gap (where the cut's edge disappears into the gap), so no thin sliver of
// dome shows beside the tunnel.
let domeBesideTunnelFront = CGPath(
    rect: CGRect(x: 0, y: groundLineY, width: tunnelFrontCenterX, height: firstBlockRowTopY + gapBetweenBlocks - groundLineY),
    transform: nil
)
let dome = archAboveGround(centerX: domeCenterX, horizontalRadius: domeHorizontalRadius, height: domeHeight)
let domeWithBlocks = dome
    .subtracting(blockGaps)
    .subtracting(tunnelOutline(outlineGap: tunnelOutlineGap))
    .subtracting(domeBesideTunnelFront)

let tunnelFrontFace = archAboveGround(centerX: tunnelFrontCenterX, horizontalRadius: tunnelFrontHorizontalRadius, height: tunnelHeight)
let tunnelFrontFaceWithOutlineGap = archAboveGround(
    centerX: tunnelFrontCenterX,
    horizontalRadius: tunnelFrontHorizontalRadius + tunnelOutlineGap,
    height: tunnelHeight + tunnelOutlineGap
)
let tunnelSideBlockLine = CGPath(rect: CGRect(x: 0, y: tunnelSideBlockLineY, width: drawingGridWidth, height: gapBetweenBlocks), transform: nil)
let tunnelSide = tunnelOutline(outlineGap: 0)
    .subtracting(tunnelFrontFaceWithOutlineGap)
    .subtracting(tunnelSideBlockLine)

let doorwayTopRadius = doorwayWidth / 2
let doorwayStraightSides = CGPath(
    rect: CGRect(x: doorwayCenterX - doorwayTopRadius, y: groundLineY, width: doorwayWidth, height: doorwayHeight - doorwayTopRadius),
    transform: nil
)
let doorwayRoundTop = CGPath(
    ellipseIn: CGRect(x: doorwayCenterX - doorwayTopRadius, y: groundLineY + doorwayHeight - doorwayWidth, width: doorwayWidth, height: doorwayWidth),
    transform: nil
)
let doorway = doorwayStraightSides.union(doorwayRoundTop)
let tunnelFrontFaceWithDoorway = tunnelFrontFace.subtracting(doorway)

let iglooOnDrawingGrid = domeWithBlocks.union(tunnelSide).union(tunnelFrontFaceWithDoorway)

// Scale up and centre on the canvas.
let iglooBoundsOnDrawingGrid = iglooOnDrawingGrid.boundingBoxOfPath
var scaleAndCentreTransform = CGAffineTransform(translationX: canvasWidth / 2, y: canvasWidth / 2)
    .scaledBy(x: glyphScaleOnCanvas, y: glyphScaleOnCanvas)
    .translatedBy(x: -iglooBoundsOnDrawingGrid.midX, y: -iglooBoundsOnDrawingGrid.midY)
guard let iglooGlyph = iglooOnDrawingGrid.copy(using: &scaleAndCentreTransform) else {
    failAndExit("couldn't scale the glyph")
}

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

// Optional preview: the glyph at 1×, 2× and 13× on light and dark bars.
if CommandLine.arguments.count > 1 {
    let previewPath = CommandLine.arguments[1]
    let previewScales: [CGFloat] = [1, 2, 13]
    let previewWidth = Int(previewScales.reduce(0) { $0 + canvasWidth * $1 + 20 }) + 20
    let previewHeight = Int(canvasWidth * 13 + 40) * 2
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
