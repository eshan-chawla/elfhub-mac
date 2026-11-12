//
//  ScreenAnnotationLayerView.swift
//  elfhub
//
//  Draws one annotation on the overlay: highlight boxes, circles, arrows and
//  underlines "draw on" with an animated stroke, and notes are written out
//  character by character in a handwritten face — so it feels like someone
//  is marking up the screen, not like a static sticker appearing.
//

import SwiftUI

struct ScreenAnnotationShapeView: View {
    let placedAnnotation: PlacedAnnotation
    let screenFrame: CGRect
    /// False when redrawing saved marks in chat: drawn fully at once, so they
    /// don't replay every time a row scrolls into view.
    var animatesAppearance: Bool = true

    @State private var strokeDrawProgress: CGFloat = 0

    private let annotationColor = DS.Colors.overlayCursorBlue
    private let strokeLineWidth: CGFloat = 3

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch placedAnnotation.shape {
            case let .highlight(frame):
                let localFrame = frame.overlayLocalRect(inScreenFrame: screenFrame)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(annotationColor.opacity(0.08 * strokeDrawProgress))
                    .frame(width: localFrame.width, height: localFrame.height)
                    .position(x: localFrame.midX, y: localFrame.midY)
                drawnStroke(Path(roundedRect: localFrame, cornerRadius: 8))
                annotationLabel(atLocalPoint: CGPoint(x: localFrame.minX, y: localFrame.minY - 8))

            case let .circle(center, radius):
                let localCenter = center.overlayLocalPoint(inScreenFrame: screenFrame)
                let circleRect = CGRect(
                    x: localCenter.x - radius,
                    y: localCenter.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                drawnStroke(Path(ellipseIn: circleRect))
                annotationLabel(atLocalPoint: CGPoint(x: circleRect.minX, y: circleRect.minY - 8))

            case let .arrow(tail, head):
                let localTail = tail.overlayLocalPoint(inScreenFrame: screenFrame)
                let localHead = head.overlayLocalPoint(inScreenFrame: screenFrame)
                drawnStroke(Self.arrowPath(from: localTail, to: localHead))
                annotationLabel(atLocalPoint: CGPoint(x: localTail.x, y: localTail.y - 8))

            case let .underline(start, end):
                let localStart = start.overlayLocalPoint(inScreenFrame: screenFrame)
                let localEnd = end.overlayLocalPoint(inScreenFrame: screenFrame)
                drawnStroke(Self.linePath(from: localStart, to: localEnd))

            case let .note(anchor, text):
                HandwrittenNoteView(
                    noteText: text,
                    noteColor: annotationColor,
                    animatesAppearance: animatesAppearance
                )
                .position(anchorForNote(anchor.overlayLocalPoint(inScreenFrame: screenFrame), text: text))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .onAppear {
            guard animatesAppearance else {
                strokeDrawProgress = 1
                return
            }
            withAnimation(.easeOut(duration: 0.6)) {
                strokeDrawProgress = 1
            }
        }
    }

    /// Strokes a path progressively from start to end, with a white under-stroke
    /// so the mark reads on both light and dark content.
    private func drawnStroke(_ path: Path) -> some View {
        ZStack {
            path.trim(from: 0, to: strokeDrawProgress)
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: strokeLineWidth + 2.5, lineCap: .round, lineJoin: .round))
            path.trim(from: 0, to: strokeDrawProgress)
                .stroke(annotationColor, style: StrokeStyle(lineWidth: strokeLineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: annotationColor.opacity(0.45), radius: 4)
        }
    }

    @ViewBuilder
    private func annotationLabel(atLocalPoint localPoint: CGPoint) -> some View {
        if let annotationLabel = placedAnnotation.label, !annotationLabel.isEmpty {
            Text(annotationLabel)
                .font(.custom("Noteworthy-Bold", size: 16))
                .foregroundColor(annotationColor)
                .shadow(color: .white, radius: 1.5)
                .shadow(color: .white, radius: 1.5)
                .fixedSize()
                .opacity(strokeDrawProgress)
                // A zero-size frame aligned bottom-leading pins the label's
                // bottom-left corner to the anchor point (position() places
                // the frame's center, which for a zero frame is that point).
                .frame(width: 0, height: 0, alignment: .bottomLeading)
                .position(x: min(max(localPoint.x, 4), screenFrame.width - 200), y: max(localPoint.y, 22))
        }
    }

    /// Keeps a note fully on screen: anchor is its top-left; position() wants its center.
    private func anchorForNote(_ localAnchor: CGPoint, text: String) -> CGPoint {
        let estimatedNoteWidth = min(CGFloat(text.count) * 11 + 16, 360)
        let estimatedNoteHeight: CGFloat = 32
        let centerX = min(max(localAnchor.x + estimatedNoteWidth / 2, estimatedNoteWidth / 2), screenFrame.width - estimatedNoteWidth / 2)
        let centerY = min(max(localAnchor.y + estimatedNoteHeight / 2, estimatedNoteHeight / 2), screenFrame.height - estimatedNoteHeight / 2)
        return CGPoint(x: centerX, y: centerY)
    }

    static func linePath(from start: CGPoint, to end: CGPoint) -> Path {
        var linePath = Path()
        linePath.move(to: start)
        linePath.addLine(to: end)
        return linePath
    }

    /// A line from tail to head with a two-stroke arrowhead at the head. The
    /// shaft is drawn first so the arrowhead appears last as the stroke animates.
    static func arrowPath(from tail: CGPoint, to head: CGPoint) -> Path {
        let arrowheadLength: CGFloat = 16
        let arrowheadSpreadRadians: CGFloat = .pi / 7
        let shaftAngle = atan2(head.y - tail.y, head.x - tail.x)

        let firstBarb = CGPoint(
            x: head.x - arrowheadLength * cos(shaftAngle - arrowheadSpreadRadians),
            y: head.y - arrowheadLength * sin(shaftAngle - arrowheadSpreadRadians)
        )
        let secondBarb = CGPoint(
            x: head.x - arrowheadLength * cos(shaftAngle + arrowheadSpreadRadians),
            y: head.y - arrowheadLength * sin(shaftAngle + arrowheadSpreadRadians)
        )

        var arrowPath = Path()
        arrowPath.move(to: tail)
        arrowPath.addLine(to: head)
        arrowPath.move(to: firstBarb)
        arrowPath.addLine(to: head)
        arrowPath.addLine(to: secondBarb)
        return arrowPath
    }
}

// MARK: - Handwritten Note

/// Text written onto the screen one character at a time in a handwritten face.
struct HandwrittenNoteView: View {
    let noteText: String
    let noteColor: Color
    var animatesAppearance: Bool = true

    @State private var revealedCharacterCount = 0

    var body: some View {
        Text(String(noteText.prefix(revealedCharacterCount)))
            .font(.custom("Noteworthy-Bold", size: 20))
            .foregroundColor(noteColor)
            // Double white halo keeps handwriting legible on any background.
            .shadow(color: .white, radius: 2)
            .shadow(color: .white, radius: 2)
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .task {
                guard animatesAppearance else {
                    revealedCharacterCount = noteText.count
                    return
                }
                for characterCount in 0...noteText.count {
                    revealedCharacterCount = characterCount
                    try? await Task.sleep(nanoseconds: 35_000_000)
                    if Task.isCancelled { return }
                }
            }
    }
}
