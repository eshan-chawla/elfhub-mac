//
//  NotepadPanelManager.swift
//  elfhub
//
//  The floating notepad window. It opens when a reply starts writing a
//  notepad (CompanionEvent.notepadOpened), gains each line as elfhub
//  reaches it (.notepadLineWritten), and stays until the user clicks its X —
//  new turns, Esc and the overlay's timers don't close it. A new notepad
//  replaces the open one.
//
//  Unlike the click-through overlay, this window takes clicks: text can be
//  selected and copied. It's a non-activating panel, so it never pulls the
//  user out of the app they're in. Like every elfhub window it is left out
//  of screenshots, so the model never sees it — it remembers the notepad
//  through its conversation history instead.
//

import AppKit
import Combine
import SwiftUI

/// What the notepad window shows. Lines are written one at a time: when
/// several arrive together (a model that wrote them back to back, or a reply
/// streaming in with the voice off), each waits `secondsBetweenLines` after
/// the one before, so the window always fills in line by line.
@MainActor
final class NotepadPanelModel: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var markdownLines: [String] = []

    nonisolated static let defaultSecondsBetweenLines: Double = 0.45
    private let secondsBetweenLines: Double
    private var linesWaitingToAppear: [String] = []
    private var lastLineShownDate: Date?
    private var waitingLinesRevealTask: Task<Void, Never>?

    init(secondsBetweenLines: Double = NotepadPanelModel.defaultSecondsBetweenLines) {
        self.secondsBetweenLines = secondsBetweenLines
    }

    var notepad: SavedNotepad {
        SavedNotepad(title: title, markdownLines: markdownLines)
    }

    /// Starts a new, empty notepad; lines still waiting from the old one are dropped.
    func open(title notepadTitle: String) {
        waitingLinesRevealTask?.cancel()
        waitingLinesRevealTask = nil
        linesWaitingToAppear = []
        lastLineShownDate = nil
        title = notepadTitle
        markdownLines = []
    }

    func append(markdownLine: String) {
        linesWaitingToAppear.append(markdownLine)
        // Already pacing earlier lines: this one joins the queue.
        guard waitingLinesRevealTask == nil else { return }
        // After a pause the line shows right away; otherwise it waits its beat.
        if isNextWaitingLineDue {
            showNextWaitingLine()
        }
        if !linesWaitingToAppear.isEmpty {
            waitingLinesRevealTask = Task { [weak self] in
                await self?.revealWaitingLines()
            }
        }
    }

    private var isNextWaitingLineDue: Bool {
        guard let lastLineShownDate else { return true }
        return Date().timeIntervalSince(lastLineShownDate) >= secondsBetweenLines
    }

    private func revealWaitingLines() async {
        while !linesWaitingToAppear.isEmpty, !Task.isCancelled {
            let nextLineIsCodeFence = linesWaitingToAppear.first.map(NotepadBlock.isCodeFenceLine) ?? false
            if !nextLineIsCodeFence, let lastLineShownDate {
                let secondsLeftToWait = secondsBetweenLines - Date().timeIntervalSince(lastLineShownDate)
                if secondsLeftToWait > 0 {
                    try? await Task.sleep(for: .seconds(secondsLeftToWait))
                    if Task.isCancelled { return }
                }
            }
            showNextWaitingLine()
        }
        waitingLinesRevealTask = nil
    }

    private func showNextWaitingLine() {
        guard !linesWaitingToAppear.isEmpty else { return }
        let nextLine = linesWaitingToAppear.removeFirst()
        markdownLines.append(nextLine)
        // A ``` fence draws nothing by itself, so it doesn't use up a beat.
        if !NotepadBlock.isCodeFenceLine(nextLine) {
            lastLineShownDate = Date()
        }
    }
}

@MainActor
final class NotepadPanelManager {
    let notepadPanelModel = NotepadPanelModel()

    private var notepadPanel: NSPanel?
    private var eventSubscription: AnyCancellable?

    /// Space between the window and the screen's edges (and the menu bar).
    private static let screenEdgeInset: CGFloat = 24
    /// The lines scroll once the window would cover more than this much of
    /// the screen's height.
    private static let maximumShareOfScreenHeight: CGFloat = 0.7

    func startListening(to companionEventBus: CompanionEventBus) {
        eventSubscription = companionEventBus.events.sink { [weak self] companionEvent in
            switch companionEvent {
            case let .notepadOpened(title):
                self?.openNotepad(title: title)
            case let .notepadLineWritten(markdownLine):
                self?.notepadPanelModel.append(markdownLine: markdownLine)
            default:
                break
            }
        }
    }

    func closeNotepad() {
        notepadPanel?.orderOut(nil)
        notepadPanel = nil
        notepadPanelModel.open(title: "")
    }

    // MARK: - Window

    /// Opens on the screen the mouse is on — where the user is looking —
    /// in its top-right corner, below the menu bar.
    private func openNotepad(title: String) {
        closeNotepad()
        notepadPanelModel.open(title: title)

        let targetScreen = screenUnderMouse() ?? NSScreen.main
        guard let visibleScreenFrame = targetScreen?.visibleFrame else { return }
        let maximumWindowHeight = visibleScreenFrame.height * Self.maximumShareOfScreenHeight
        let maximumContentHeight = maximumWindowHeight - FloatingNotepadView.headerHeight - 1

        let initialWindowHeight = FloatingNotepadView.headerHeight + 1
        let initialWindowFrame = NSRect(
            x: visibleScreenFrame.maxX - FloatingNotepadView.width - Self.screenEdgeInset,
            y: visibleScreenFrame.maxY - Self.screenEdgeInset - initialWindowHeight,
            width: FloatingNotepadView.width,
            height: initialWindowHeight
        )

        let notepadPanel = NotepadPanel(
            contentRect: initialWindowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notepadPanel.isFloatingPanel = true
        notepadPanel.level = .floating
        notepadPanel.isOpaque = false
        notepadPanel.backgroundColor = .clear
        notepadPanel.hasShadow = true
        notepadPanel.hidesOnDeactivate = false
        notepadPanel.isExcludedFromWindowsMenu = true
        notepadPanel.isMovableByWindowBackground = true
        notepadPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let floatingNotepadView = FloatingNotepadView(
            notepadPanelModel: notepadPanelModel,
            maximumContentHeight: maximumContentHeight,
            onClose: { [weak self] in
                self?.closeNotepad()
            },
            onPreferredHeightChange: { [weak self] preferredWindowHeight in
                self?.resizeNotepadPanel(toHeight: preferredWindowHeight)
            }
        )
        let hostingView = NSHostingView(rootView: floatingNotepadView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        notepadPanel.contentView = hostingView

        // Shown without taking focus; clicking into it to select text makes
        // it key without activating elfhub.
        notepadPanel.orderFrontRegardless()
        self.notepadPanel = notepadPanel
    }

    /// Grows downward: the top edge stays where it is (or where the user
    /// dragged it).
    private func resizeNotepadPanel(toHeight preferredWindowHeight: CGFloat) {
        guard let notepadPanel else { return }
        let currentFrame = notepadPanel.frame
        let resizedFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - preferredWindowHeight,
            width: currentFrame.width,
            height: preferredWindowHeight
        )
        notepadPanel.setFrame(resizedFrame, display: true)
        notepadPanel.invalidateShadow()
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}

/// Borderless panels can't become key by default; this one must, so its
/// text can be selected and copied with ⌘C.
private final class NotepadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
