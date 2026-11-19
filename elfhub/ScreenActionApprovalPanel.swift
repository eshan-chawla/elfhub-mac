//
//  ScreenActionApprovalPanel.swift
//  elfhub
//
//  The approval popup: whenever an Elf waits for the user's okay before
//  acting on the screen (ScreenActionCoordinator.pendingConsent), a small
//  floating window appears over every app saying what it wants to do, with
//  Go ahead and Cancel. Return goes ahead and Esc cancels, right there —
//  the window takes the keyboard without bringing elfhub forward, so the
//  app being worked in stays the active one. It closes as soon as the
//  question is answered (here, by voice, in chat, or by the timeout).
//
//  Return only counts after a short moment, so a Return the user was
//  already pressing in another app when the popup appeared can't approve
//  something they never saw. The popup sits at the bottom of the screen
//  the action is on, or at the top when the target is down there, so it
//  never covers what the pointer is showing. Like every elfhub window it is
//  left out of screenshots.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Placement

/// Where the popup goes on a screen. Pure, so it can be tested.
nonisolated enum ScreenActionApprovalPanelPlacement {
    static let panelWidth: CGFloat = 440
    /// Space between the popup and the edge of the screen's usable area
    /// (above the Dock, below the menu bar).
    static let screenEdgeInset: CGFloat = 32

    /// Bottom center, unless the target is in the lower part of the screen:
    /// then top center, below where the status pill and captions sit.
    static func panelOrigin(
        panelSize: CGSize,
        visibleScreenFrame: CGRect,
        targetPoint: CGPoint?
    ) -> CGPoint {
        let originX = visibleScreenFrame.midX - panelSize.width / 2
        let bottomOriginY = visibleScreenFrame.minY + screenEdgeInset
        let lowerPartOfScreenTop = visibleScreenFrame.minY + visibleScreenFrame.height * 0.45
        if let targetPoint, visibleScreenFrame.contains(targetPoint), targetPoint.y <= lowerPartOfScreenTop {
            // Room left at the top for the pill and a caption under it.
            let topOriginY = visibleScreenFrame.maxY - 140 - panelSize.height
            return CGPoint(x: originX, y: max(topOriginY, bottomOriginY))
        }
        return CGPoint(x: originX, y: bottomOriginY)
    }
}

// MARK: - Panel manager

@MainActor
final class ScreenActionApprovalPanelManager {
    private let screenActionCoordinator: ScreenActionCoordinator
    /// The Elf asking: whoever holds the screen.
    private let askingElf: () -> Elf
    private var approvalPanel: ScreenActionApprovalNSPanel?
    private var shownPendingConsentIdentifier: UUID?
    private var pendingConsentSubscription: AnyCancellable?

    init(screenActionCoordinator: ScreenActionCoordinator, askingElf: @escaping () -> Elf) {
        self.screenActionCoordinator = screenActionCoordinator
        self.askingElf = askingElf
    }

    func startShowingApprovals() {
        // No hop to the next run loop: the popup must be gone before an
        // approved step fires, in case it sits where the click lands.
        pendingConsentSubscription = screenActionCoordinator.$pendingConsent.sink { [weak self] pendingConsent in
            self?.showApproval(for: pendingConsent)
        }
    }

    private func showApproval(for pendingConsent: PendingScreenActionConsent?) {
        guard let pendingConsent else {
            closeApprovalPanel()
            return
        }
        guard pendingConsent.id != shownPendingConsentIdentifier else { return }
        closeApprovalPanel()
        shownPendingConsentIdentifier = pendingConsent.id

        let firstTargetPoint = pendingConsent.resolvedActions.lazy.compactMap(\.appKitTargetPoint).first
        let targetScreen = firstTargetPoint.flatMap { targetPoint in
            NSScreen.screens.first { NSMouseInRect(targetPoint, $0.frame, false) }
        } ?? screenUnderMouse() ?? NSScreen.main
        guard let visibleScreenFrame = targetScreen?.visibleFrame else { return }

        let approvalPopupView = ScreenActionApprovalPopupView(
            pendingConsent: pendingConsent,
            askingElf: askingElf(),
            onGoAhead: { [weak self] in
                self?.screenActionCoordinator.confirmPendingActions(approvalProvenance: .userClickedConfirm)
            },
            onCancel: { [weak self] in
                self?.screenActionCoordinator.cancelPendingActions()
            }
        )
        let hostingView = ApprovalFirstClickHostingView(rootView: approvalPopupView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        let fittingSize = hostingView.fittingSize
        let panelSize = CGSize(width: ScreenActionApprovalPanelPlacement.panelWidth, height: max(fittingSize.height, 120))
        let panelOrigin = ScreenActionApprovalPanelPlacement.panelOrigin(
            panelSize: panelSize,
            visibleScreenFrame: visibleScreenFrame,
            targetPoint: firstTargetPoint
        )

        let approvalPanel = ScreenActionApprovalNSPanel(
            contentRect: NSRect(origin: panelOrigin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        approvalPanel.isFloatingPanel = true
        approvalPanel.level = .floating
        approvalPanel.isOpaque = false
        approvalPanel.backgroundColor = .clear
        approvalPanel.hasShadow = false
        approvalPanel.hidesOnDeactivate = false
        approvalPanel.isExcludedFromWindowsMenu = true
        approvalPanel.isMovableByWindowBackground = true
        approvalPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        approvalPanel.contentView = hostingView

        // Shown over every app and given the keyboard, so Return and Esc
        // answer it — without activating elfhub, so the app being worked
        // in stays active and gets the keyboard back when it closes.
        approvalPanel.orderFrontRegardless()
        approvalPanel.makeKey()
        self.approvalPanel = approvalPanel
    }

    private func closeApprovalPanel() {
        approvalPanel?.orderOut(nil)
        approvalPanel = nil
        shownPendingConsentIdentifier = nil
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}

/// Borderless panels can't become key by default; this one must, so Return
/// and Esc reach its buttons.
private final class ScreenActionApprovalNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The popup never activates elfhub, so the first click on it lands while
/// another app is active; without this it would only make the panel key.
private final class ApprovalFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Popup

struct ScreenActionApprovalPopupView: View {
    let pendingConsent: PendingScreenActionConsent
    let askingElf: Elf
    let onGoAhead: () -> Void
    let onCancel: () -> Void

    /// Return and clicks only count after this, so a key already on its
    /// way to another app can't approve something unseen.
    nonisolated static let answerArmingDelaySeconds: Double = 0.6
    @State private var acceptsAnswers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ElfAvatar(elf: askingElf, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pendingConsent.includesHighRiskAction
                         ? "Confirm this action"
                         : "\(askingElf.configuration.identity.name) wants to")
                        .font(DS.Typography.smallMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(pendingConsent.summary)
                        .font(DS.Typography.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                DSStatusBadge(text: "Waiting on you", tone: .warning)
            }

            if let firstConfirmationEffect = pendingConsent.confirmationEffects.first {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(DS.Typography.interface(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                    Text("This would \(firstConfirmationEffect.spokenVerb) something. Check it before you go ahead.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button(action: onGoAhead) {
                    HStack(spacing: 6) {
                        Text("Go ahead")
                        Image(systemName: "return")
                            .font(DS.Typography.interface(size: 11, weight: .semibold))
                    }
                }
                .dsPrimaryButtonStyle(isFullWidth: true, size: .small)
                .keyboardShortcut(.defaultAction)
                .disabled(!acceptsAnswers)
                .pointerCursor(isEnabled: acceptsAnswers)

                Button(action: onCancel) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        Text("esc")
                            .font(DS.Typography.interface(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .dsSecondaryButtonStyle(isFullWidth: true, size: .small)
                .keyboardShortcut(.cancelAction)
                .pointerCursor()
            }

            Text(spokenAnswerHint)
                .font(DS.Typography.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .padding(.leading, 3)
        .frame(width: ScreenActionApprovalPanelPlacement.panelWidth - 24)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        // An approval waiting on you: the amber left edge, as on the card.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DS.Colors.warning)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.dialog, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .dsShadow(.large)
        .padding(12)
        .task(id: pendingConsent.id) {
            acceptsAnswers = false
            try? await Task.sleep(for: .seconds(Self.answerArmingDelaySeconds))
            acceptsAnswers = true
        }
    }

    private var spokenAnswerHint: String {
        if let firstConfirmationEffect = pendingConsent.confirmationEffects.first {
            return "Or say \u{201C}yes, \(firstConfirmationEffect.spokenVerb) it\u{201D}. Stops by itself after a minute."
        }
        return "Or say \u{201C}go\u{201D}. Stops by itself after a minute."
    }
}
