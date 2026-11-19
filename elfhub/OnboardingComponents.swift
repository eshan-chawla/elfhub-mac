//
//  OnboardingComponents.swift
//  elfhub
//
//  Pieces of the first-run setup (OnboardingPane): the stacked logo for the
//  welcome, the step marker, the Fraunces step heading, the Elf avatar
//  color picker, and the line that follows the natural voice's download
//  after the voice step.
//

import SwiftUI

// MARK: - Stacked logo

/// The brand's stacked lockup (brand chapter 02): the brand mark (the 3D
/// igloo on its tile — never smaller than 28 pt) with the wordmark centered
/// under it, 1.25 × the mark's width, 0.2 × its height below. The wordmark
/// is ink in light appearance and white in dark.
struct BrandStackedLockup: View {
    var markSize: CGFloat = 72

    @Environment(\.colorScheme) private var colorScheme

    /// The wordmark's artwork is 2781 × 833.
    private static let wordmarkAspectRatio: CGFloat = 2781.0 / 833.0

    var body: some View {
        VStack(spacing: markSize * 0.2) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: max(markSize, 28), height: max(markSize, 28))
                .accessibilityHidden(true)
            Image("Wordmark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(Self.wordmarkAspectRatio, contentMode: .fit)
                .frame(width: markSize * 1.25)
                .foregroundColor(colorScheme == .dark ? .white : DS.Colors.textPrimary)
                .accessibilityLabel("elfhub")
        }
    }
}

/// The "elfhub" wordmark: always the outlined vector, never typed. Ink in
/// light appearance, white in dark (or `color` when given, e.g. white on the
/// dark sidebar).
struct BrandWordmark: View {
    var height: CGFloat = 16
    var color: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("Wordmark")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(2781.0 / 833.0, contentMode: .fit)
            .frame(height: height)
            .foregroundColor(color ?? (colorScheme == .dark ? .white : DS.Colors.textPrimary))
            .accessibilityLabel("elfhub")
    }
}

// MARK: - Step marker

/// The brand's section marker: an index in blue, a short rule, then the
/// label in the mono label style — "02 ── Your Elf".
struct OnboardingStepMarker: View {
    let stepNumber: Int
    let stepCount: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", stepNumber))
                .dsLabelStyle()
                .foregroundColor(DS.Colors.accentText)
            Rectangle()
                .fill(DS.Colors.borderStrong)
                .frame(width: 16, height: 1)
            Text(title)
                .dsLabelStyle()
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Text("\(stepNumber) of \(stepCount)")
                .font(DS.Typography.small)
                .foregroundColor(DS.Colors.textTertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(stepNumber) of \(stepCount): \(title)")
    }
}

// MARK: - Step heading

/// A step's heading in Fraunces (onboarding is the one place for the
/// brand's warm voice at full size) and its one supporting paragraph.
struct OnboardingStepHeading: View {
    let title: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .dsDisplayHeading(size: 28)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Avatar color

/// The six side-Elf avatar fills as swatches (the main Elf is always on
/// Igloo Blue, so it has no picker). The chosen one has a focus-blue
/// ring; each is a 32 pt target.
struct ElfAvatarColorPicker: View {
    @Binding var selectedFillIndex: Int

    private static let fillNames = ["Graphite", "Teal", "Ice violet", "Amber", "Rose", "Night"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<ElfAvatarAppearance.fillCount, id: \.self) { fillIndex in
                let isSelected = fillIndex == selectedFillIndex
                Button(action: { selectedFillIndex = fillIndex }) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Colors.elfAvatarFills[fillIndex])
                        // A hairline so the Night fill still reads on a dark card.
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(DS.Colors.borderStrong, lineWidth: 1)
                        )
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DS.Colors.focusRing, lineWidth: 2)
                                .padding(-4)
                                .opacity(isSelected ? 1 : 0)
                        )
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(Self.fillNames[fillIndex])
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Natural voice download

/// Follows the natural voice's download once onboarding's voice step has
/// started it: progress while it downloads, and what happened if it
/// failed, with Try again. Shows nothing otherwise.
struct NaturalVoiceDownloadStatusRow: View {
    @ObservedObject var onDeviceVoiceModelStore: OnDeviceVoiceModelStore
    /// Starts the download again with the chosen voice.
    let onTryAgain: () -> Void

    private var modelIdentifier: String { OnboardingNaturalVoice.modelIdentifier }

    var body: some View {
        if let downloadProgress = onDeviceVoiceModelStore.downloadProgressByRepositoryIdentifier[modelIdentifier] {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading the natural voice…")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int((downloadProgress.fractionCompleted * 100).rounded()))%")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .monospacedDigit()
                }
                ProgressView(value: downloadProgress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .tint(DS.Colors.controlTint)
                Text("Apple's voice speaks until it's ready. You can carry on.")
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .mainAppCard()
        } else if let downloadErrorMessage = onDeviceVoiceModelStore.downloadErrorMessageByRepositoryIdentifier[modelIdentifier] {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The natural voice didn't download.")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(downloadErrorMessage)
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Try again", action: onTryAgain)
                    .dsSecondaryButtonStyle(size: .small)
            }
            .mainAppCard()
        }
    }
}
