//
//  ChatScreenshotViews.swift
//  elfhub
//
//  Saved screenshots inside chat, shown only when the user turned on "Save
//  screenshots with chats". Each question with a screenshot gets a collapsed
//  "Screenshot" row; a reply that pointed or drew gets a "Screenshot with
//  marks" row. Only one image is stored — the original. The user's own
//  drawing (SavedUserInk) and elfhub's marks (SavedScreenGuidance) are data
//  redrawn on top with the live overlay's own views, which gives a Before /
//  After switch in the row and in the viewer sheet that opens on click.
//

import AppKit
import ImageIO
import SwiftUI

// MARK: - Loading

/// Decodes saved screenshots off the main thread, downsampled for thumbnails
/// so long chats scroll smoothly.
enum SavedScreenshotImageLoader {
    /// `maximumPixelSize` nil loads the full image (the viewer sheet).
    // @concurrent: under NonisolatedNonsendingByDefault a plain nonisolated
    // async function would run on the caller's actor — here, the main thread.
    @concurrent nonisolated static func loadCGImage(from screenshotFileURL: URL, maximumPixelSize: Int?) async -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(screenshotFileURL as CFURL, nil) else { return nil }
        guard let maximumPixelSize else {
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary)
    }
}

// MARK: - Screenshot With Marks

/// The saved screenshot — "before" — or, with `showsMarks`, "after": the
/// user's own drawing and elfhub's pointer and marks drawn on top. The
/// composition is laid out at the captured display's size in points —
/// exactly how the overlay drew it — and then scaled to fit, so strokes,
/// labels and the pointer keep their on-screen proportions.
struct ScreenshotWithGuidanceView: View {
    let screenshotFileURL: URL
    let userInk: SavedUserInk?
    let screenGuidance: SavedScreenGuidance?
    let showsMarks: Bool
    let maximumImagePixelSize: Int?

    @State private var screenshotImage: NSImage?

    var body: some View {
        // The capture keeps the display's aspect ratio, so the display size
        // (when marks were saved) and the image size describe the same shape.
        let compositionSize = screenGuidance?.displaySizeInPoints
            ?? userInk?.displaySizeInPoints
            ?? screenshotImage?.size
            ?? CGSize(width: 16, height: 10)

        GeometryReader { geometry in
            let compositionScale = min(
                geometry.size.width / compositionSize.width,
                geometry.size.height / compositionSize.height
            )
            composition(compositionSize: compositionSize)
                .frame(width: compositionSize.width, height: compositionSize.height, alignment: .topLeading)
                .scaleEffect(compositionScale, anchor: .topLeading)
                .frame(
                    width: compositionSize.width * compositionScale,
                    height: compositionSize.height * compositionScale,
                    alignment: .topLeading
                )
                .clipped()
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(compositionSize.width / compositionSize.height, contentMode: .fit)
        .task(id: screenshotFileURL) {
            guard let screenshotCGImage = await SavedScreenshotImageLoader.loadCGImage(
                from: screenshotFileURL,
                maximumPixelSize: maximumImagePixelSize
            ) else { return }
            screenshotImage = NSImage(
                cgImage: screenshotCGImage,
                size: NSSize(width: screenshotCGImage.width, height: screenshotCGImage.height)
            )
        }
    }

    private func composition(compositionSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let screenshotImage {
                Image(nsImage: screenshotImage)
                    .resizable()
                    .frame(width: compositionSize.width, height: compositionSize.height)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: compositionSize.width, height: compositionSize.height)
            }

            // The user's drawing sits under elfhub's marks, as it did live.
            if showsMarks, let userInk {
                UserInkStrokesView(userInkStrokes: userInk.userInkStrokes, screenFrame: userInk.localScreenFrame)
            }

            if showsMarks, let screenGuidance {
                let placedAnnotations = screenGuidance.placedAnnotations
                // Indexed: the rebuilt PlacedAnnotations get fresh ids on every
                // render, which would make ForEach recreate them each time.
                ForEach(placedAnnotations.indices, id: \.self) { annotationIndex in
                    ScreenAnnotationShapeView(
                        placedAnnotation: placedAnnotations[annotationIndex],
                        screenFrame: screenGuidance.localScreenFrame,
                        animatesAppearance: false
                    )
                }
                if let placedPointer = screenGuidance.placedPointer {
                    PointerAtTargetView(
                        placedPointer: placedPointer,
                        screenFrame: screenGuidance.localScreenFrame,
                        animatesAppearance: false
                    )
                }
            }
        }
    }
}

// MARK: - Collapsible Row

/// A small "Screenshot" row under a message, collapsed by default so chats
/// stay compact. Expanded, it shows a thumbnail that opens the viewer and,
/// when anything was drawn on it, a Before / After switch.
struct CollapsibleScreenshotRow: View {
    let title: String
    let screenshotFileURL: URL
    let userInk: SavedUserInk?
    let screenGuidance: SavedScreenGuidance?
    /// Opens the viewer on the version currently shown (true = after).
    let onOpenViewer: (_ showsMarks: Bool) -> Void

    @State private var isExpanded = false
    @State private var isHeaderHovered = false
    @State private var isThumbnailHovered = false
    /// Starts on "after": the drawing is the point of the screenshot.
    @State private var showsMarks = true

    private var hasMarks: Bool {
        userInk != nil || screenGuidance != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: hasMarks ? "scribble.variable" : "photo")
                        .font(.system(size: 10, weight: .medium))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(isHeaderHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHeaderHovered ? 0.06 : 0))
                )
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide screenshot" : "Show screenshot")
            .onHover { isHeaderHovered = $0 }
            .pointerCursor()

            if isExpanded {
                if hasMarks {
                    BeforeAfterPicker(showsMarks: $showsMarks)
                        .controlSize(.mini)
                }

                Button(action: { onOpenViewer(showsMarks) }) {
                    ScreenshotWithGuidanceView(
                        screenshotFileURL: screenshotFileURL,
                        userInk: userInk,
                        screenGuidance: screenGuidance,
                        showsMarks: showsMarks,
                        maximumImagePixelSize: 640
                    )
                    .frame(maxWidth: 260, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isThumbnailHovered ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Open screenshot")
                .onHover { isThumbnailHovered = $0 }
                .pointerCursor()
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Viewer Sheet

/// What the viewer sheet should show; Identifiable so it can drive `.sheet(item:)`.
struct ScreenshotViewerRequest: Identifiable {
    let id = UUID()
    let screenshotFileURL: URL
    /// The user's drawing and elfhub's marks, if any — enable the switch.
    let userInk: SavedUserInk?
    let screenGuidance: SavedScreenGuidance?
    let initiallyShowsMarks: Bool

    var hasMarks: Bool {
        userInk != nil || screenGuidance != nil
    }
}

/// Before (the original) / After (with the drawing and marks) — both drawn
/// from the one saved image.
struct BeforeAfterPicker: View {
    @Binding var showsMarks: Bool

    var body: some View {
        Picker("Version", selection: $showsMarks) {
            Text("Before").tag(false)
            Text("After").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Before: the screenshot as captured. After: with the drawing and marks.")
        .pointerCursor()
    }
}

/// The full screenshot in a sheet over the chat, with a Before / After
/// switch when anything was drawn on it. Esc or Done closes it.
struct ScreenshotViewerSheet: View {
    let screenshotViewerRequest: ScreenshotViewerRequest

    @Environment(\.dismiss) private var dismiss
    @State private var showsMarks: Bool

    init(screenshotViewerRequest: ScreenshotViewerRequest) {
        self.screenshotViewerRequest = screenshotViewerRequest
        _showsMarks = State(initialValue: screenshotViewerRequest.initiallyShowsMarks
            && screenshotViewerRequest.hasMarks)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(screenshotViewerRequest.hasMarks ? (showsMarks ? "Screenshot — after" : "Screenshot — before") : "Screenshot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                if screenshotViewerRequest.hasMarks {
                    BeforeAfterPicker(showsMarks: $showsMarks)
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(DS.Colors.borderSubtle)

            ScreenshotWithGuidanceView(
                screenshotFileURL: screenshotViewerRequest.screenshotFileURL,
                userInk: screenshotViewerRequest.userInk,
                screenGuidance: screenshotViewerRequest.screenGuidance,
                showsMarks: showsMarks,
                maximumImagePixelSize: nil
            )
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 420, idealHeight: 640)
        .background(DS.Colors.background)
    }
}
