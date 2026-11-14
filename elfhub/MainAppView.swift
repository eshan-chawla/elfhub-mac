//
//  MainAppView.swift
//  elfhub
//
//  The native main-window experience, chat first: a sidebar and a detail pane.
//
//  - The window opens on the chat. The sidebar lists every elf (the Elves
//    hub, see ElfHubViews.swift — main first, each with its own page), then
//    every chat (New chat on top) and, while the optional tutorial runs, a
//    pinned Tutorial row. Its
//    bottom menu opens on hover and offers Settings and Quit. There is no
//    separate home page.
//  - Settings swaps the sidebar to its categories (Models, Modes, Shortcuts,
//    Permissions, Privacy, General) with "Back" to where the user came from
//    (see MainAppSettingsViews.swift).
//  - Until setup is complete the detail pane shows onboarding exclusively
//    (see MainAppOnboardingViews.swift, which also holds the tutorial).
//
//  Every page except the chat uses MainAppPage — one fixed reading column,
//  always aligned to the same edge — so the window keeps its size and
//  nothing shifts between pages. The compact menu-bar panel keeps its own layout (CompanionPanelView);
//  both share the components in CompanionPanelComponents.swift and
//  ModelLayerComponents.swift.
//

import AppKit
import SwiftUI

// MARK: - Sections and Navigation

enum MainAppSection: Hashable {
    case chat
    /// The optional walkthrough; reachable from the sidebar only while it runs.
    case tutorial
    /// One elf's page in the Elves hub, by elf identifier.
    case elf(String)
    case settings(SettingsCategory)

    var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }
}

/// Which page is showing, and where "Back" from Settings returns to.
struct MainAppNavigation: Equatable {
    private(set) var selectedSection: MainAppSection
    /// The last chat/tutorial page, so leaving Settings goes back to it.
    private(set) var lastMainSection: MainAppSection

    init(selectedSection: MainAppSection = .chat) {
        self.selectedSection = selectedSection
        self.lastMainSection = selectedSection.isSettings ? .chat : selectedSection
    }

    var isShowingSettings: Bool {
        selectedSection.isSettings
    }

    mutating func open(_ section: MainAppSection) {
        if !section.isSettings {
            lastMainSection = section
        }
        selectedSection = section
    }

    mutating func leaveSettings() {
        selectedSection = lastMainSection
    }

    /// An elf deleted in the hub or removed in Finder can't keep its page:
    /// its page — and "Back" from Settings — go to the main elf instead.
    mutating func showMainElfIfElfIsGone(existingElfIdentifiers: Set<String>) {
        let mainElfSection = MainAppSection.elf(ElfManager.mainElfIdentifier)
        if case let .elf(selectedElfIdentifier) = selectedSection, !existingElfIdentifiers.contains(selectedElfIdentifier) {
            selectedSection = mainElfSection
        }
        if case let .elf(lastElfIdentifier) = lastMainSection, !existingElfIdentifiers.contains(lastElfIdentifier) {
            lastMainSection = mainElfSection
        }
    }
}

// MARK: - Root View

struct MainAppView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var chatViewModel: TextChatViewModel
    @ObservedObject private var guidedTutorialController: GuidedTutorialController
    @ObservedObject private var elfManager: ElfManager

    @State private var mainAppNavigation = MainAppNavigation()

    /// Wide enough for chat titles in the sidebar list.
    private static let sidebarWidth: CGFloat = 240

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        // One view model for the app lifetime (owned by CompanionManager) so
        // the conversation persists across navigation and the chat window.
        self.chatViewModel = companionManager.textChatViewModel
        self.guidedTutorialController = companionManager.guidedTutorialController
        self.elfManager = companionManager.elfManager
    }

    private var selectedElfIdentifier: String? {
        if case let .elf(elfIdentifier) = mainAppNavigation.selectedSection { return elfIdentifier }
        return nil
    }

    /// Whether the user is fully ready to use the app's active modes.
    /// Setup incomplete → the detail pane must show onboarding, not the surfaces.
    private var isSetupComplete: Bool {
        companionManager.hasCompletedOnboarding
            && companionManager.hasPermissionsRequiredForActiveModes
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(DS.Colors.surface1)

            Divider()
                .background(DS.Colors.borderSubtle)

            // Always fills the window, whatever page is showing — the page's
            // content never decides the window's size.
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .onReceive(companionManager.$requestedMainAppSection) { requestedMainAppSection in
            guard let requestedMainAppSection else { return }
            mainAppNavigation.open(requestedMainAppSection)
            companionManager.requestedMainAppSection = nil
        }
        // An elf deleted in the hub or removed in Finder can't keep its page.
        .onReceive(elfManager.$elves) { rosterElves in
            mainAppNavigation.showMainElfIfElfIsGone(existingElfIdentifiers: Set(rosterElves.map(\.id)))
        }
        // Folders added or removed in Finder show up when elfhub comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            elfManager.reloadRoster()
        }
        // When the tutorial ends while its page is showing, go back to chat.
        .onReceive(guidedTutorialController.$isActive) { isTutorialActive in
            if !isTutorialActive && mainAppNavigation.selectedSection == .tutorial {
                mainAppNavigation.open(.chat)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSetupComplete && mainAppNavigation.isShowingSettings {
                settingsSidebarContent
            } else {
                sidebarHeader
                // During onboarding the detail pane owns the flow, so there is
                // nothing to navigate to yet.
                if isSetupComplete {
                    if guidedTutorialController.isActive {
                        sidebarRow(
                            iconName: "graduationcap",
                            title: "Tutorial",
                            isSelected: mainAppNavigation.selectedSection == .tutorial,
                            badgeColor: DS.Colors.warning,
                            action: { mainAppNavigation.open(.tutorial) }
                        )
                        .padding(.bottom, 6)
                    }

                    ElvesSidebarSection(
                        elfManager: elfManager,
                        selectedElfIdentifier: selectedElfIdentifier,
                        onOpenElf: { elfIdentifier in mainAppNavigation.open(.elf(elfIdentifier)) }
                    )
                    .padding(.bottom, 6)

                    Text("Chats")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)

                    // Below the elves, every saved chat, newest first. It
                    // scrolls and takes the space down to the menu.
                    ChatConversationSidebarList(
                        viewModel: chatViewModel,
                        onShowChat: { mainAppNavigation.open(.chat) }
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }

            if !isSetupComplete || mainAppNavigation.isShowingSettings {
                Spacer(minLength: 12)
            }

            SidebarBottomMenu(
                showsSettingsItem: isSetupComplete,
                isShowingSettings: mainAppNavigation.isShowingSettings,
                onOpenSettings: { mainAppNavigation.open(.settings(.models)) }
            )
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.6), radius: 4)

            Text("elfhub")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var settingsSidebarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarBackButton(action: { mainAppNavigation.leaveSettings() })
                .padding(.horizontal, 10)
                .padding(.top, 12)

            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

            ForEach(SettingsCategory.allCases) { settingsCategory in
                sidebarRow(
                    iconName: settingsCategory.systemImageName,
                    title: settingsCategory.displayTitle,
                    isSelected: mainAppNavigation.selectedSection == .settings(settingsCategory),
                    badgeColor: nil,
                    action: { mainAppNavigation.open(.settings(settingsCategory)) }
                )
            }
        }
    }

    private func sidebarRow(
        iconName: String,
        title: String,
        isSelected: Bool,
        badgeColor: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                Spacer()

                if let badgeColor {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.horizontal, 10)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if isSetupComplete {
            switch mainAppNavigation.selectedSection {
            case .tutorial where guidedTutorialController.isActive:
                GuidedTutorialPane(
                    companionManager: companionManager,
                    guidedTutorialController: guidedTutorialController,
                    onSelectSection: { mainAppNavigation.open($0) }
                )
            case .chat, .tutorial:
                TextChatView(
                    viewModel: chatViewModel,
                    showsRecentChatsMenu: false,
                    onOpenModelSettings: companionManager.isLanguageModelReady
                        ? nil
                        : { mainAppNavigation.open(.settings(.models)) }
                )
            case let .elf(elfIdentifier):
                ElfHubPage(
                    companionManager: companionManager,
                    elfIdentifier: elfIdentifier,
                    onOpenModelSettings: { mainAppNavigation.open(.settings(.models)) },
                    onElfDeleted: { mainAppNavigation.open(.elf(ElfManager.mainElfIdentifier)) }
                )
                .id(elfIdentifier)
            case let .settings(settingsCategory):
                SettingsCategoryPage(companionManager: companionManager, settingsCategory: settingsCategory)
            }
        } else {
            OnboardingPane(companionManager: companionManager)
        }
    }

    private var statusDotColor: Color {
        if !isSetupComplete {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .processing, .responding:
            return DS.Colors.blue400
        }
    }
}

// MARK: - Sidebar Bottom Menu

/// The collapsible bar at the bottom of the sidebar. Hovering opens it
/// upward into Settings and Quit; it closes shortly after the pointer
/// leaves. Clicking the bar toggles it too, for trackpad and keyboard users.
/// It grows into the sidebar's empty space, so it never covers navigation.
private struct SidebarBottomMenu: View {
    /// False during onboarding: settings are part of the onboarding flow.
    let showsSettingsItem: Bool
    let isShowingSettings: Bool
    let onOpenSettings: () -> Void

    @State private var isExpanded = false
    @State private var isBarHovered = false
    @State private var collapseTask: Task<Void, Never>?

    /// Grace period before closing, so moving between the bar and its rows
    /// (or briefly overshooting) doesn't make it flicker.
    private static let collapseDelaySeconds: Double = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if showsSettingsItem {
                        SidebarMenuRow(
                            iconName: "gearshape",
                            title: "Settings",
                            isCurrent: isShowingSettings,
                            action: {
                                collapseImmediately()
                                onOpenSettings()
                            }
                        )
                    }
                    SidebarMenuRow(
                        iconName: "power",
                        title: "Quit elfhub",
                        isCurrent: false,
                        action: { NSApp.terminate(nil) }
                    )
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(showsSettingsItem ? "Settings & more" : "More")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                }
                .foregroundColor(isBarHovered || isExpanded ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isBarHovered || isExpanded ? 0.06 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings and Quit")
            .onHover { isBarHovered = $0 }
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .onHover { isHovering in
            if isHovering {
                collapseTask?.cancel()
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded = true
                }
            } else {
                scheduleCollapse()
            }
        }
    }

    private func toggleExpanded() {
        collapseTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            isExpanded.toggle()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.collapseDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = false
            }
        }
    }

    private func collapseImmediately() {
        collapseTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            isExpanded = false
        }
    }
}

/// One row in the bottom menu, highlighted on hover.
private struct SidebarMenuRow: View {
    let iconName: String
    let title: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundColor(isCurrent ? DS.Colors.accentText : DS.Colors.textTertiary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered || isCurrent ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// "‹ Back" at the top of the Settings sidebar.
private struct SidebarBackButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to where you were")
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

// MARK: - Page Layout

/// The one page layout every main-window page uses (except Chat): a fixed
/// reading column, centered in the pane, scrolling vertically.
/// Pages used to pick their own widths and the scroll view centered the
/// narrower ones, so content jumped between onboarding, the tutorial and the
/// rest; one column of the same width keeps every page in the same place.
struct MainAppPage<Content: View>: View {
    let title: String?
    let subtitle: String?
    let content: Content

    private let readingColumnMaximumWidth: CGFloat = 720

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if title != nil || subtitle != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let title {
                            Text(title)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                content
            }
            .padding(28)
            .frame(maxWidth: readingColumnMaximumWidth, alignment: .leading)
            // Center the column in wide windows instead of leaving all the
            // empty space on the right.
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(DS.Colors.background)
    }
}

// MARK: - Shared Card Background

private struct MainAppCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}

extension View {
    func mainAppCard() -> some View {
        modifier(MainAppCardBackground())
    }
}
