//
//  CompanionStatusPillView.swift
//  elfhub
//
//  The small status pill at the top-center of the primary-focus screen, just
//  under the menu bar / notch. It shows what elfhub is doing — listening,
//  thinking, speaking (with a caption of the reply) or acting — so status
//  never depends on a cursor following the mouse. Rendered inside the
//  click-through overlay, so it is purely informational; Esc stops elfhub.
//

import SwiftUI

struct CompanionStatusPillView: View {
    let statusPillPhase: CompanionStatusPillPhase
    let audioPowerLevel: CGFloat

    private let captionMaximumWidth: CGFloat = 520

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingIndicator
            pillText
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: captionMaximumWidth)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch statusPillPhase {
        case .listening:
            ListeningWaveformView(audioPowerLevel: audioPowerLevel)
        case .thinking, .acting:
            ThinkingSpinnerView()
        case .speaking:
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 7, height: 7)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.8), radius: 4)
        case .hint:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.overlayCursorBlue)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var pillText: some View {
        switch statusPillPhase {
        case .listening:
            pillLabel("listening")
        case .thinking:
            pillLabel("thinking")
        case let .speaking(caption):
            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(3)
                .truncationMode(.head)
        case let .acting(summary):
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                Text("press esc to stop")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
        case let .hint(hintText):
            pillLabel(hintText)
        case .hidden:
            EmptyView()
        }
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.92))
    }
}

// MARK: - Listening Waveform

/// Small waveform reacting to the live microphone level while push-to-talk is held.
struct ListeningWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(for: barIndex, timelineDate: timelineContext.date)
                        )
                }
            }
            .frame(height: 16)
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Thinking Spinner

/// Small spinning arc shown while the model is working or actions are running.
struct ThinkingSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}
