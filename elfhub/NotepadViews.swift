//
//  NotepadViews.swift
//  elfhub
//
//  How a notepad looks, shared by the floating window (NotepadPanelManager)
//  and the saved copy in chat: the rendered markdown, the copy button
//  (plain text by default, Markdown from its menu), the floating card with
//  its close button, and the chat card.
//

import AppKit
import SwiftUI

// MARK: - Content

/// The notepad's lines rendered as headings, lists, quotes and code. Read
/// only, but selectable so any part can be copied.
struct NotepadContentView: View {
    let markdownLines: [String]
    /// The floating window fades each new line in as elfhub writes it.
    var animatesNewLines = false

    var body: some View {
        let notepadBlocks = NotepadBlock.blocks(fromMarkdownLines: markdownLines)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notepadBlocks.indices, id: \.self) { blockIndex in
                blockView(notepadBlocks[blockIndex])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(animatesNewLines ? .easeOut(duration: 0.3) : nil, value: notepadBlocks.count)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ notepadBlock: NotepadBlock) -> some View {
        switch notepadBlock.kind {
        case let .heading(level):
            Text(NotepadBlock.attributedText(fromInlineMarkdown: notepadBlock.text))
                .font(.system(size: level == 1 ? 17 : (level == 2 ? 15 : 13.5), weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.top, 2)

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .foregroundColor(DS.Colors.textSecondary)
                inlineText(notepadBlock.text)
            }

        case let .numbered(number):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textSecondary)
                inlineText(notepadBlock.text)
            }

        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.Colors.textTertiary)
                    .frame(width: 2)
                inlineText(notepadBlock.text)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 2)

        case .code:
            Text(notepadBlock.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )

        case .paragraph:
            inlineText(notepadBlock.text)
        }
    }

    private func inlineText(_ inlineMarkdown: String) -> some View {
        Text(NotepadBlock.attributedText(fromInlineMarkdown: inlineMarkdown))
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Copy

enum NotepadClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Click copies friendly plain text (no markdown symbols); the arrow next
/// to it offers "Copy as Markdown". A checkmark confirms the copy.
struct NotepadCopyButton: View {
    let notepad: SavedNotepad

    @State private var showsCopiedConfirmation = false
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button("Copy") { copy(notepad.plainText) }
            Button("Copy as Markdown") { copy(notepad.markdownText) }
        } label: {
            Image(systemName: showsCopiedConfirmation ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
        } primaryAction: {
            copy(notepad.plainText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundColor(showsCopiedConfirmation ? DS.Colors.success : (isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0))
        )
        .onHover { isHovered = $0 }
        .help("Copy the notepad as plain text — the arrow also has Copy as Markdown")
        .pointerCursor()
    }

    private func copy(_ text: String) {
        NotepadClipboard.copy(text)
        withAnimation(.easeOut(duration: 0.15)) {
            showsCopiedConfirmation = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) {
                showsCopiedConfirmation = false
            }
        }
    }
}

// MARK: - Floating Window Content

/// The notepad window on the screen: close at the top left, title, copy at
/// the top right, then the lines — scrolling once they outgrow the screen.
struct FloatingNotepadView: View {
    @ObservedObject var notepadPanelModel: NotepadPanelModel
    /// Tallest the lines may get before they scroll (from the screen's size).
    let maximumContentHeight: CGFloat
    let onClose: () -> Void
    /// The window's height follows its content; reported here.
    let onPreferredHeightChange: (CGFloat) -> Void

    static let width: CGFloat = 380
    static let headerHeight: CGFloat = 40
    private static let contentPadding: CGFloat = 14

    @State private var measuredContentHeight: CGFloat = 0
    @State private var isCloseButtonHovered = false

    private var visibleContentHeight: CGFloat {
        min(measuredContentHeight, maximumContentHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            lines
        }
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: visibleContentHeight) { _, newVisibleContentHeight in
            onPreferredHeightChange(Self.headerHeight + 1 + newVisibleContentHeight)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isCloseButtonHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(Color.white.opacity(isCloseButtonHovered ? 0.16 : 0.08))
                    )
            }
            .buttonStyle(.plain)
            .onHover { isCloseButtonHovered = $0 }
            .help("Close the notepad (it stays saved in the chat)")
            .pointerCursor()

            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text(notepadPanelModel.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            NotepadCopyButton(notepad: notepadPanelModel.notepad)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
        // The whole header (outside its buttons) is the handle for moving
        // the window anywhere on screen.
        .background(NotepadWindowDragArea())
    }

    private var lines: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView(.vertical, showsIndicators: measuredContentHeight > maximumContentHeight) {
                VStack(spacing: 0) {
                    NotepadContentView(markdownLines: notepadPanelModel.markdownLines, animatesNewLines: true)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomOfLinesIdentifier)
                }
                .padding(Self.contentPadding)
                .background(
                    GeometryReader { contentGeometry in
                        Color.clear.preference(key: NotepadContentHeightPreferenceKey.self, value: contentGeometry.size.height)
                    }
                )
            }
            .frame(height: visibleContentHeight)
            .onPreferenceChange(NotepadContentHeightPreferenceKey.self) { contentHeight in
                measuredContentHeight = contentHeight
            }
            .onChange(of: notepadPanelModel.markdownLines.count) {
                // Follow the writing, like a teacher's hand moving down the page.
                withAnimation(.easeOut(duration: 0.3)) {
                    scrollViewProxy.scrollTo(Self.bottomOfLinesIdentifier, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomOfLinesIdentifier = "notepad-bottom-of-lines"
}

/// Drags the window it sits in. SwiftUI content doesn't move a borderless
/// window by itself (NSHostingView never lets a mouse-down move it), so the
/// header hosts this AppKit view, which hands the drag to the window. Shows
/// an open hand so it reads as something you can grab.
private struct NotepadWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDraggingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowDraggingView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct NotepadContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - In Chat

/// The notepad a reply wrote, shown whole under that reply in chat.
struct SavedNotepadCard: View {
    let notepad: SavedNotepad

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(notepad.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                NotepadCopyButton(notepad: notepad)
            }
            NotepadContentView(markdownLines: notepad.markdownLines)
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}
