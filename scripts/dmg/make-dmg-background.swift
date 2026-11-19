// Draws the background of the DMG window: an arrow from the app to the
// Applications folder and a "Drag elfhub to Applications" caption.
//
// Run from the repo root after changing the design, then commit the result:
//   swift scripts/dmg/make-dmg-background.swift
//
// It writes 1x and 2x PNGs into a temporary folder and combines them into
// scripts/dmg/dmg-background.tiff (one multi-resolution image, so the window
// looks sharp on Retina screens). The window size and icon positions must
// match the create-dmg call in scripts/release.sh.

import AppKit

let windowWidthInPoints: CGFloat = 660
let windowHeightInPoints: CGFloat = 400
// Icon centers, measured from the window's top-left like create-dmg's
// --icon / --app-drop-link positions.
let appIconCenterFromTopLeft = CGPoint(x: 160, y: 195)
let applicationsIconCenterFromTopLeft = CGPoint(x: 500, y: 195)
let iconSizeInPoints: CGFloat = 100

let outputDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let finalTIFFURL = outputDirectoryURL.appendingPathComponent("dmg-background.tiff")

func renderBackgroundPNG(scaleFactor: CGFloat, to pngFileURL: URL) throws {
    let pixelWidth = Int(windowWidthInPoints * scaleFactor)
    let pixelHeight = Int(windowHeightInPoints * scaleFactor)
    guard let bitmapImageRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "make-dmg-background", code: 1)
    }
    // Draw in points; the rep's pixel size gives the 2x detail.
    bitmapImageRep.size = NSSize(width: windowWidthInPoints, height: windowHeightInPoints)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapImageRep)

    // AppKit's origin is bottom-left; convert the top-left icon positions.
    func pointFromTopLeft(_ topLeftPoint: CGPoint) -> CGPoint {
        CGPoint(x: topLeftPoint.x, y: windowHeightInPoints - topLeftPoint.y)
    }

    // Soft light background. Finder draws the icon labels itself, dark in
    // light mode — keep this light so they stay readable.
    let backgroundGradient = NSGradient(
        starting: NSColor(calibratedRed: 0.975, green: 0.975, blue: 0.985, alpha: 1),
        ending: NSColor(calibratedRed: 0.915, green: 0.92, blue: 0.94, alpha: 1)
    )
    backgroundGradient?.draw(
        in: NSRect(x: 0, y: 0, width: windowWidthInPoints, height: windowHeightInPoints),
        angle: -90
    )

    // Caption above the icons.
    let captionText = "Drag elfhub to Applications" as NSString
    let captionParagraphStyle = NSMutableParagraphStyle()
    captionParagraphStyle.alignment = .center
    let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1),
        .paragraphStyle: captionParagraphStyle
    ]
    captionText.draw(
        in: NSRect(x: 0, y: windowHeightInPoints - 82, width: windowWidthInPoints, height: 30),
        withAttributes: captionAttributes
    )

    // Curved arrow from the app icon's right edge to the Applications
    // icon's left edge, bowing slightly upward.
    let iconGapInPoints: CGFloat = 22
    let arrowStartPoint = pointFromTopLeft(CGPoint(
        x: appIconCenterFromTopLeft.x + iconSizeInPoints / 2 + iconGapInPoints,
        y: appIconCenterFromTopLeft.y
    ))
    let arrowEndPoint = pointFromTopLeft(CGPoint(
        x: applicationsIconCenterFromTopLeft.x - iconSizeInPoints / 2 - iconGapInPoints,
        y: applicationsIconCenterFromTopLeft.y
    ))
    let arrowBowHeightInPoints: CGFloat = 12
    let arrowControlPoint = CGPoint(
        x: (arrowStartPoint.x + arrowEndPoint.x) / 2,
        y: arrowStartPoint.y + arrowBowHeightInPoints * 2
    )
    let arrowColor = NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.95, alpha: 1)

    let arrowShaftPath = NSBezierPath()
    arrowShaftPath.move(to: arrowStartPoint)
    arrowShaftPath.curve(to: arrowEndPoint, controlPoint1: arrowControlPoint, controlPoint2: arrowControlPoint)
    arrowShaftPath.lineWidth = 5
    arrowShaftPath.lineCapStyle = .round
    arrowColor.setStroke()
    arrowShaftPath.stroke()

    // Arrowhead pointing along the curve's direction at its end.
    let arrowheadDirectionAngle = atan2(arrowEndPoint.y - arrowControlPoint.y, arrowEndPoint.x - arrowControlPoint.x)
    let arrowheadLengthInPoints: CGFloat = 18
    let arrowheadSpreadAngle: CGFloat = .pi / 6
    let arrowheadPath = NSBezierPath()
    arrowheadPath.move(to: CGPoint(
        x: arrowEndPoint.x - arrowheadLengthInPoints * cos(arrowheadDirectionAngle - arrowheadSpreadAngle),
        y: arrowEndPoint.y - arrowheadLengthInPoints * sin(arrowheadDirectionAngle - arrowheadSpreadAngle)
    ))
    arrowheadPath.line(to: arrowEndPoint)
    arrowheadPath.line(to: CGPoint(
        x: arrowEndPoint.x - arrowheadLengthInPoints * cos(arrowheadDirectionAngle + arrowheadSpreadAngle),
        y: arrowEndPoint.y - arrowheadLengthInPoints * sin(arrowheadDirectionAngle + arrowheadSpreadAngle)
    ))
    arrowheadPath.lineWidth = 5
    arrowheadPath.lineCapStyle = .round
    arrowheadPath.lineJoinStyle = .round
    arrowheadPath.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmapImageRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-dmg-background", code: 2)
    }
    try pngData.write(to: pngFileURL)
}

let temporaryDirectoryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("elfhub-dmg-background-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
// tiffutil pairs "name.png" with "name@2x.png" when combining.
let oneXPNGURL = temporaryDirectoryURL.appendingPathComponent("dmg-background.png")
let twoXPNGURL = temporaryDirectoryURL.appendingPathComponent("dmg-background@2x.png")
try renderBackgroundPNG(scaleFactor: 1, to: oneXPNGURL)
try renderBackgroundPNG(scaleFactor: 2, to: twoXPNGURL)

let tiffutilProcess = Process()
tiffutilProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutilProcess.arguments = ["-cathidpicheck", oneXPNGURL.path, twoXPNGURL.path, "-out", finalTIFFURL.path]
try tiffutilProcess.run()
tiffutilProcess.waitUntilExit()
guard tiffutilProcess.terminationStatus == 0 else {
    fatalError("tiffutil failed with status \(tiffutilProcess.terminationStatus)")
}
print("Wrote \(finalTIFFURL.path)")
print("Previews: \(oneXPNGURL.path), \(twoXPNGURL.path)")
