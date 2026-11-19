//
//  CompanionStatusPillView.swift
//  elfhub
//
//  The small status pill at the top-center of the primary-focus screen, just
//  under the menu bar / notch. It shows what elfhub is doing — listening,
//  thinking or acting (what the Elf says goes in LiveCaptionPanel, below) — so status
//  never depends on a cursor following the mouse. Rendered inside the
//  click-through overlay, so it is purely informational; Esc stops elfhub.
//

import SwiftUI

struct CompanionStatusPillView: View {
    let statusPillPhase: CompanionStatusPillPhase
    let audioPowerLevel: CGFloat

    private let pillMaximumWidth: CGFloat = 520

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingIndicator
            pillText
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            // Night, the igloo's doorway: the same in light and dark, and
            // readable over anything on screen.
            Capsule(style: .continuous)
                .fill(DS.Colors.night.opacity(0.94))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: pillMaximumWidth)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch statusPillPhase {
        case .listening:
            ListeningWaveformView(audioPowerLevel: audioPowerLevel)
        case .thinking, .acting:
            ThinkingSpinnerView()
        case .hint:
            Image(systemName: "info.circle")
                .font(DS.Typography.interface(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.accentOnDark)
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
        case let .acting(summary):
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("esc")
                        .font(DS.Typography.mono(size: 10, weight: .medium))
                        .textCase(.uppercase)
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous).fill(Color.white.opacity(0.14)))
                    Text("to stop")
                        .font(DS.Typography.interface(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        case let .hint(hintText):
            pillLabel(hintText)
        case .hidden:
            EmptyView()
        }
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.interface(size: 12, weight: .medium))
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
                    // The listening pulse is the Elf's pen about to be used: orange.
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.elfPen)
                        .frame(
                            width: 2,
                            height: barHeight(for: barIndex, timelineDate: timelineContext.date)
                        )
                }
            }
            .frame(height: 16)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.accentOnDark.opacity(0.0),
                        DS.Colors.accentOnDark
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            // With Reduce Motion on, the ring stays still: the pill's
            // "thinking" text already says what's happening.
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// MARK: - Live caption panel

/// What the Elf is saying, as it says it (live captions, or a reply that
/// isn't spoken). A rectangle under the status pill on night — the same in
/// light and dark, readable over anything — whose newest line sits at the
/// bottom: older lines move up and fade out at the top instead of being
/// cut off with an ellipsis.
struct LiveCaptionPanel: View {
    let transcript: LiveCaptionTranscript

    static let panelWidth: CGFloat = 640
    private static let horizontalPadding: CGFloat = 18
    private static let captionFontSize: CGFloat = 16
    private static let lineHeight: CGFloat = 24
    private static let maximumVisibleLineCount: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The caption's full height at the panel's width; the panel shows up to
    /// four lines of it, the newest at the bottom.
    @State private var measuredTextHeight: CGFloat = 0

    private var maximumTextHeight: CGFloat { Self.lineHeight * Self.maximumVisibleLineCount }
    private var isOverflowing: Bool { measuredTextHeight > maximumTextHeight + 1 }

    var body: some View {
        let textWidth = Self.panelWidth - Self.horizontalPadding * 2
        Text(transcript.visibleText)
            .font(DS.Typography.interface(size: Self.captionFontSize, weight: .medium))
            .foregroundColor(.white)
            .lineSpacing(Self.lineHeight - Self.captionFontSize - 4)
            .multilineTextAlignment(.leading)
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { textGeometry in
                    Color.clear.preference(key: LiveCaptionTextHeightKey.self, value: textGeometry.size.height)
                }
            )
            // As tall as the text, up to four lines; taller text keeps its
            // newest lines at the bottom and moves the oldest off the top.
            .frame(height: min(max(measuredTextHeight, Self.lineHeight), maximumTextHeight), alignment: .bottom)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(isOverflowing ? 0.2 : 1), location: 0),
                        .init(color: .black, location: isOverflowing ? 0.35 : 0),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onPreferenceChange(LiveCaptionTextHeightKey.self) { newTextHeight in
                measuredTextHeight = newTextHeight
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .fill(DS.Colors.night.opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 4)
            .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: measuredTextHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(transcript.visibleText)
    }
}

private struct LiveCaptionTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
