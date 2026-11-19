//
//  ScreenAnnotationLayerView.swift
//  elfhub
//
//  Draws one annotation on the overlay with the Elf's pen (brand chapter 06):
//  Annotation Orange, a light outer edge and a soft shadow so every mark
//  reads on any background, one clean round-ended stroke, a soft 20% wash for
//  highlights, labels as white text on an orange pill, and notes as a small
//  white card with an orange edge. Marks fade in with the brand's one
//  entrance — a calm hand, not a show — and appear at once with Reduce Motion.
//

import SwiftUI

struct ScreenAnnotationShapeView: View {
    let placedAnnotation: PlacedAnnotation
    let screenFrame: CGRect
    /// False when redrawing saved marks in chat: drawn fully at once, so they
    /// don't replay every time a row scrolls into view.
    var animatesAppearance: Bool = true

    /// 0 → 1 as the mark fades in (the brand's one entrance; marks are not
    /// drawn on stroke by stroke).
    @State private var strokeDrawProgress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let annotationColor = DS.Colors.elfPen
    private let strokeLineWidth: CGFloat = 2.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch placedAnnotation.shape {
            case let .highlight(frame):
                let localFrame = frame.overlayLocalRect(inScreenFrame: screenFrame)
                // A soft orange wash, about 20% strength.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(annotationColor.opacity(0.2 * strokeDrawProgress))
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
                ScreenNoteCard(noteText: text)
                    .opacity(strokeDrawProgress)
                .position(anchorForNote(anchor.overlayLocalPoint(inScreenFrame: screenFrame), text: text))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .onAppear {
            guard animatesAppearance, !reduceMotion else {
                strokeDrawProgress = 1
                return
            }
            withAnimation(DS.Motion.slow) {
                strokeDrawProgress = 1
            }
        }
    }

    /// One clean stroke with round ends, over a light outer edge so the
    /// mark reads on any background (orange content included), fading in.
    private func drawnStroke(_ path: Path) -> some View {
        ZStack {
            path.stroke(DS.Colors.elfPenEdge, style: StrokeStyle(lineWidth: strokeLineWidth + 3, lineCap: .round, lineJoin: .round))
            path.stroke(annotationColor, style: StrokeStyle(lineWidth: strokeLineWidth, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
        .opacity(strokeDrawProgress)
    }

    @ViewBuilder
    private func annotationLabel(atLocalPoint localPoint: CGPoint) -> some View {
        if let annotationLabel = placedAnnotation.label, !annotationLabel.isEmpty {
            // A short label beside the mark: white text on an orange pill.
            Text(annotationLabel)
                .font(DS.Typography.interface(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(annotationColor))
                .overlay(Capsule().strokeBorder(DS.Colors.elfPenEdge, lineWidth: 1))
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

// MARK: - Note card

/// A longer note an Elf leaves on the screen: a small white card with an
/// orange left edge, rounded corners and a soft shadow, in Inter. It's the
/// same in light and dark appearance, since it sits on whatever the screen
/// shows. Text appears whole — no typing effect on text people read.
struct ScreenNoteCard: View {
    let noteText: String

    var body: some View {
        Text(noteText)
            .font(DS.Typography.interface(size: 14, weight: .medium))
            .foregroundColor(Color(hex: "#0F172A"))
            .lineSpacing(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.leading, 3)
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(DS.Colors.elfPen)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .shadow(color: DS.Colors.night.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}
