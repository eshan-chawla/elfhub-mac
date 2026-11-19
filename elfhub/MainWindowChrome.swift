//
//  MainWindowChrome.swift
//  elfhub
//
//  The main window's title bar is part of its content: no grey strip and no
//  title text, the dark sidebar running up behind the close / minimize /
//  zoom buttons, and the top band of each column holding what belongs there
//  (the brand in the sidebar, the chat's title in the chat). The window is
//  set up for this in MainWindowPresenter (elfhubApp.swift); the views here
//  keep the band the same height everywhere and let it move the window.
//

import AppKit
import SwiftUI

enum MainWindowChrome {
    /// The title bar band: the height a unified toolbar gives the window,
    /// with the window buttons centered in it.
    static let titleBarHeight: CGFloat = 52
    /// Room the close, minimize and zoom buttons take at the band's left,
    /// with a gap after them.
    static let windowButtonsWidth: CGFloat = 90
}

/// An empty stretch of title bar: dragging it moves the window, and a
/// double-click does what the user chose in System Settings for title bars
/// (zoom or minimize). Put it behind the band's content; buttons on top of
/// it still get their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragAreaView {
        WindowDragAreaView()
    }

    func updateNSView(_ nsView: WindowDragAreaView, context: Context) {}
}

final class WindowDragAreaView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performTitleBarDoubleClickAction(in: window)
            return
        }
        window.performDrag(with: event)
    }

    /// System Settings › Desktop & Dock › "Double-click a window's title
    /// bar to": zoom (the default), minimize, or nothing.
    static func performTitleBarDoubleClickAction(in window: NSWindow) {
        let doubleClickAction = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch doubleClickAction {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }
}
