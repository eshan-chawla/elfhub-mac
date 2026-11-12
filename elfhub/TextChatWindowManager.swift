//
//  TextChatWindowManager.swift
//  elfhub
//
//  Opens the compact text-chat window (from the menu bar panel). It shares
//  the app's single TextChatViewModel with the main window's Chat section, so
//  both show the same conversation and saved chats.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class TextChatWindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let textChatViewModel: TextChatViewModel

    init(textChatViewModel: TextChatViewModel) {
        self.textChatViewModel = textChatViewModel
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: TextChatView(viewModel: textChatViewModel, showsRecentChatsMenu: true))

        let chatWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        chatWindow.title = "elfhub — Chat"
        chatWindow.contentView = hostingView
        chatWindow.isReleasedWhenClosed = false
        chatWindow.center()
        chatWindow.delegate = self

        window = chatWindow
        chatWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
