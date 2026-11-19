//
//  MainAppView.swift
//  elfhub
//
//  The native main-window experience, chat first: a sidebar and a detail pane.
//
//  - The window opens on the chat. The sidebar lists every elf (the Elfs
//    hub, see ElfHubViews.swift — main first, each with its own page), then
//    every chat (New chat on top) and, while the optional tutorial runs, a
//    pinned Tutorial row. At the bottom: Support (the Support
//    sheet, SupportViews.swift), then Settings last. There is no Quit button and no separate
//    home page.
//  - Settings (the sidebar's Settings row, or ⌘, from the app menu) swaps
//    the sidebar to its categories (General, Models, Tools & capabilities,
//    Controls, Privacy & permissions) with a "Back to …" row naming where the user came
//    from; Esc and ⌘[ go back too (see MainAppSettingsViews.swift).
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
    /// One elf's page in the Elfs hub, by elf identifier.
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
    /// The last chat, tutorial or elf page, so leaving Settings goes back to it.
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

    /// What the Back row at the top of Settings says: where it returns to,
    /// so it's clear Settings is a detour from the chat or an Elf's page.
    /// `elfName` looks up an Elf's name by identifier.
    func settingsBackTitle(elfName: (String) -> String?) -> String {
        switch lastMainSection {
        case .chat:
            return "Back to chat"
        case .tutorial:
            return "Back to the tutorial"
        case let .elf(elfIdentifier):
            guard let elfName = elfName(elfIdentifier) else { return "Back" }
            return "Back to \(elfName)"
        case .settings:
            return "Back"
        }
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
    /// Which view (Chat or Work) each side Elf's page shows, so the sidebar
    /// can open either and the page remembers it.
    @State private var elfPageTabByElfIdentifier: [String: ElfPageTab] = [:]
    /// The Elf whose settings sheet is open.
    @State private var elfSettingsRequest: ElfSettingsRequest?
    /// The Support sheet, from the sidebar's Support button.
    @State private var isShowingSupport = false
    /// The sidebar lists only Recents (the newest few chats) until "All
    /// chats" or "Search chats" opens the full list. Not remembered: every
    /// launch starts with the calm, short sidebar.
    @State private var isShowingAllChats = false
    /// The full list was opened by "Search chats", so its field takes the keyboard.
    @State private var isSearchingChats = false
    /// Set when the one-time "Name your elf" card is answered in this run
    /// (the answer is also saved, see ElfNamingPrompt).
    @State private var namingCardWasAnswered = false

    /// Wide enough for chat titles in the sidebar list.
    private static let sidebarWidth: CGFloat = 240

    /// Shows the pages even before setup is complete — only the visual
    /// snapshot tests set it, since their host app has no permissions.
    private let showsPagesBeforeSetupForSnapshots: Bool

    init(
        companionManager: CompanionManager,
        initialSection: MainAppSection = .chat,
        showsPagesBeforeSetupForSnapshots: Bool = false
    ) {
        self.companionManager = companionManager
        // One view model for the app lifetime (owned by CompanionManager) so
        // the conversation persists across navigation and the chat window.
        self.chatViewModel = companionManager.textChatViewModel
        self.guidedTutorialController = companionManager.guidedTutorialController
        self.elfManager = companionManager.elfManager
        self.showsPagesBeforeSetupForSnapshots = showsPagesBeforeSetupForSnapshots
        self._mainAppNavigation = State(initialValue: MainAppNavigation(selectedSection: initialSection))
    }

    /// Whether the open chat has its own row in the sidebar right now
    /// (Recents shows only the newest few).
    private var isActiveChatListedInSidebar: Bool {
        let listedConversations = isShowingAllChats
            ? chatViewModel.mainConversations
            : ChatConversationSidebarList.recentConversations(chatViewModel.mainConversations)
        return listedConversations.contains { $0.id == chatViewModel.activeConversation.id }
    }

    private var selectedElfIdentifier: String? {
        if case let .elf(elfIdentifier) = mainAppNavigation.selectedSection { return elfIdentifier }
        return nil
    }

    /// Whether the user is fully ready to use the app's active modes.
    /// Setup incomplete → the detail pane must show onboarding, not the surfaces.
    private var isSetupComplete: Bool {
        if showsPagesBeforeSetupForSnapshots { return true }
        return companionManager.hasCompletedOnboarding
            && companionManager.hasPermissionsRequiredForActiveModes
    }

    var body: some View {
        HStack(spacing: 0) {
            // The sidebar follows the appearance: a step off the page, warm
            // grey, with a plain grey pill for the selected row.
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(DS.Colors.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(DS.Colors.borderSubtle)
                        .frame(width: 1)
                }

            // Always fills the window, whatever page is showing — the page's
            // content never decides the window's size. The chat puts its
            // title in the title bar band; every other page leaves it empty.
            VStack(spacing: 0) {
                if !isChatInDetailPane {
                    WindowDragArea()
                        .frame(height: MainWindowChrome.titleBarHeight)
                }
                detailPane
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Buttons that don't pick a style get the brand's secondary
                // button; native toggles and progress take Igloo Blue.
                .buttonStyle(DSButtonStyle(kind: .secondary, size: .small))
                .tint(DS.Colors.controlTint)
        }
        .background(DS.Colors.background)
        // Up into the title bar: each column draws its own top band.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .onReceive(companionManager.$requestedMainAppSection) { requestedMainAppSection in
            guard let requestedMainAppSection else { return }
            mainAppNavigation.open(requestedMainAppSection)
            companionManager.requestedMainAppSection = nil
        }
        // A message typed in the main elf's chat to a side elf: its page
        // (on its chat) is where the question and the reply are.
        .onReceive(chatViewModel.$elfThreadToShowForTypedMessage) { elfThreadToShow in
            guard let elfThreadToShow else { return }
            // The reply shows in that Elf's chat.
            openElfPage(elfThreadToShow, on: .chat)
            chatViewModel.elfThreadToShowForTypedMessage = nil
        }
        // One Elf's settings, from its page's gear or the sidebar.
        .sheet(item: $elfSettingsRequest) { elfSettingsRequest in
            ElfSettingsSheet(
                companionManager: companionManager,
                elfIdentifier: elfSettingsRequest.elfIdentifier,
                onOpenModelSettings: { mainAppNavigation.open(.settings(.models)) },
                onElfDeleted: { mainAppNavigation.open(.elf(ElfManager.mainElfIdentifier)) }
            )
        }
        .sheet(isPresented: $isShowingSupport) {
            SupportSheet()
        }
        // A .elf being imported (from Finder, the hub or onboarding).
        .sheet(item: $companionManager.pendingElfImport) { pendingElfImport in
            ElfImportPreviewSheet(
                importPreview: pendingElfImport.preview,
                onImport: { companionManager.installPendingElfImport() },
                onCancel: { companionManager.cancelPendingElfImport() }
            )
        }
        .alert(
            "Couldn't import that Elf",
            isPresented: Binding(
                get: { companionManager.elfImportErrorMessage != nil },
                set: { isPresented in if !isPresented { companionManager.dismissElfImportError() } }
            )
        ) {
            Button("OK") { companionManager.dismissElfImportError() }
        } message: {
            Text(companionManager.elfImportErrorMessage ?? "")
        }
        // An elf deleted in the hub or removed in Finder can't keep its page.
        .onReceive(elfManager.$elfs) { rosterElfs in
            mainAppNavigation.showMainElfIfElfIsGone(existingElfIdentifiers: Set(rosterElfs.map(\.id)))
            // …and its chat becomes one of the main elf's.
            chatViewModel.detachChatsOfElfsThatAreGone(existingElfIdentifiers: Set(rosterElfs.map(\.id)))
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
            // The window buttons and the brand, in every state.
            sidebarTitleBarBand
            if isSetupComplete && mainAppNavigation.isShowingSettings {
                settingsSidebarContent
                Spacer(minLength: 12)
            } else {
                // During onboarding the detail pane owns the flow, so there is
                // nothing to navigate to yet.
                if isSetupComplete {
                    mainSidebarContent
                } else {
                    Spacer(minLength: 12)
                }
            }

            SidebarFooterButtons(
                showsSettingsButton: isSetupComplete,
                isShowingSettings: mainAppNavigation.isShowingSettings,
                onOpenSettings: { mainAppNavigation.open(.settings(.general)) },
                onOpenSupport: { isShowingSupport = true }
            )
        }
    }

    /// Top: New chat and your Elfs (the main Elf first). Below: the main
    /// Elf's chat history, folded up until you open it. Then the tutorial
    /// (while it runs) and the menu.
    @ViewBuilder
    private var mainSidebarContent: some View {
        SidebarRowButton(isSelected: false, action: {
            chatViewModel.startNewConversation()
            mainAppNavigation.open(.chat)
        }) { _ in
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .frame(width: 16)
                Text("New chat")
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                Spacer()
            }
        }
        .help("Start a new chat with your main Elf")
        .disabled(chatViewModel.isResponding)
        .padding(.horizontal, 10)

        SidebarRowButton(isSelected: false, action: {
            isSearchingChats = true
            isShowingAllChats = true
        }) { _ in
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .frame(width: 16)
                Text("Search chats")
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                Spacer()
            }
        }
        .help("Search every chat with your main Elf")
        .padding(.horizontal, 10)
        .padding(.bottom, 10)

        ElfsSidebarSection(
            elfManager: elfManager,
            companionManager: companionManager,
            elfTaskScheduler: companionManager.elfTaskScheduler,
            selectedElfIdentifier: selectedElfIdentifier.flatMap { $0 == ElfManager.mainElfIdentifier ? nil : $0 },
            // The main Elf's row stands for its chat and its overview; when
            // the open chat is listed below, its own row is the selection.
            isMainElfSelected: selectedElfIdentifier == ElfManager.mainElfIdentifier
                || (mainAppNavigation.selectedSection == .chat && !isActiveChatListedInSidebar),
            onOpenElf: { elfIdentifier, elfPageTab in openElfPage(elfIdentifier, on: elfPageTab) },
            onOpenMainElfChat: {
                chatViewModel.showMostRecentMainChat()
                mainAppNavigation.open(.chat)
            },
            onOpenSettings: { elfIdentifier in elfSettingsRequest = ElfSettingsRequest(elfIdentifier: elfIdentifier) }
        )
        .padding(.bottom, 12)

        // Recents (the newest few chats), or every chat while "All chats" or
        // "Search chats" is open. It scrolls and takes the space down to the
        // menu.
        ChatConversationSidebarList(
            viewModel: chatViewModel,
            isChatShowing: mainAppNavigation.selectedSection == .chat,
            isShowingAllChats: isShowingAllChats,
            focusesSearchField: isSearchingChats,
            onShowAllChats: {
                isSearchingChats = false
                isShowingAllChats = true
            },
            onShowFewerChats: {
                isSearchingChats = false
                isShowingAllChats = false
            },
            onShowChat: { mainAppNavigation.open(.chat) }
        )
        .frame(maxHeight: .infinity, alignment: .top)

        if guidedTutorialController.isActive {
            sidebarRow(
                iconName: "graduationcap",
                title: "Tutorial",
                isSelected: mainAppNavigation.selectedSection == .tutorial,
                badgeColor: DS.Colors.warning,
                action: { mainAppNavigation.open(.tutorial) }
            )
            .padding(.top, 4)
        }
    }

    /// The sidebar's part of the title bar: the window buttons on the left,
    /// then the flat glyph (the 3D igloo is never drawn under 28 pt) and the
    /// wordmark — never typed — in white. Dragging it moves the window.
    private var sidebarTitleBarBand: some View {
        HStack(spacing: 7) {
            Spacer()
                .frame(width: MainWindowChrome.windowButtonsWidth)
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
                .foregroundColor(DS.Colors.sidebarText)
                .accessibilityHidden(true)
            BrandWordmark(height: 13, color: DS.Colors.sidebarText)
            Spacer()
        }
        .frame(height: MainWindowChrome.titleBarHeight)
        .background(WindowDragArea())
    }

    /// Whether the chat is what the detail pane shows (its header is the
    /// title bar band there).
    private var isChatInDetailPane: Bool {
        guard isSetupComplete, !shouldShowNamingCard else { return false }
        switch mainAppNavigation.selectedSection {
        case .chat:
            return true
        case .tutorial:
            return !guidedTutorialController.isActive
        case .elf, .settings:
            return false
        }
    }

    private var settingsSidebarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarBackButton(
                title: mainAppNavigation.settingsBackTitle(elfName: { elfIdentifier in
                    elfManager.elf(withIdentifier: elfIdentifier)?.configuration.identity.name
                }),
                action: { mainAppNavigation.leaveSettings() }
            )
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Text("Settings")
                .font(DS.Typography.headingSmall)
                .foregroundColor(DS.Colors.sidebarText)
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
        SidebarRowButton(isSelected: isSelected, action: action) { isHighlighted in
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                Spacer()
                if let badgeColor {
                    Circle()
                        .fill(isSelected ? DS.Colors.sidebarText : badgeColor)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Elf pages

    private func elfPageTabBinding(forElfIdentifier elfIdentifier: String) -> Binding<ElfPageTab> {
        Binding(
            get: { elfPageTabByElfIdentifier[elfIdentifier] ?? .chat },
            set: { newElfPageTab in elfPageTabByElfIdentifier[elfIdentifier] = newElfPageTab }
        )
    }

    /// Opens a side Elf's page on Chat or Work.
    private func openElfPage(_ elfIdentifier: String, on elfPageTab: ElfPageTab) {
        elfPageTabByElfIdentifier[elfIdentifier] = elfPageTab
        mainAppNavigation.open(.elf(elfIdentifier))
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
                VStack(spacing: 0) {
                    if shouldShowNamingCard {
                        NameYourElfCard(elfManager: elfManager, onAnswered: { namingCardWasAnswered = true })
                    }
                    chatView
                }
                // Back from an elf's page: the main elf's chat again.
                .onAppear { chatViewModel.showMainChat() }
            case let .elf(elfIdentifier):
                ElfHubPage(
                    companionManager: companionManager,
                    elfIdentifier: elfIdentifier,
                    selectedTab: elfPageTabBinding(forElfIdentifier: elfIdentifier),
                    onOpenElf: { openedElfIdentifier in mainAppNavigation.open(.elf(openedElfIdentifier)) },
                    onOpenSettings: { elfSettingsRequest = ElfSettingsRequest(elfIdentifier: elfIdentifier) },
                    onStartNewChat: {
                        chatViewModel.startNewConversation()
                        mainAppNavigation.open(.chat)
                    }
                )
                .id(elfIdentifier)
            case let .settings(settingsCategory):
                SettingsCategoryPage(companionManager: companionManager, settingsCategory: settingsCategory)
            }
        } else {
            OnboardingPane(companionManager: companionManager)
        }
    }

    private var chatView: some View {
        TextChatView(
            viewModel: chatViewModel,
            showsRecentChatsMenu: false,
            onOpenModelSettings: companionManager.isLanguageModelReady
                ? nil
                : { mainAppNavigation.open(.settings(.models)) },
            // The chat's title is the detail pane's part of the title bar —
            // unless the naming card sits above it.
            headerIsInTitleBar: !shouldShowNamingCard
        )
    }

    private var shouldShowNamingCard: Bool {
        ElfNamingPrompt.shouldOffer(
            hasCompletedOnboarding: companionManager.hasCompletedOnboarding,
            mainElfName: elfManager.mainElf.configuration.identity.name,
            wasOffered: namingCardWasAnswered || ElfNamingPrompt.wasOffered()
        )
    }
}

// MARK: - Sidebar Footer

/// Support, then Settings at the very bottom of the sidebar. There is no Quit:
/// closing the window or the Dock menu does that. Settings is left out
/// during onboarding, which is the setup itself.
private struct SidebarFooterButtons: View {
    let showsSettingsButton: Bool
    let isShowingSettings: Bool
    let onOpenSettings: () -> Void
    let onOpenSupport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarMenuRow(
                iconName: "questionmark.circle",
                title: "Support",
                isCurrent: false,
                action: onOpenSupport
            )
            if showsSettingsButton {
                SidebarMenuRow(
                    iconName: "gearshape",
                    title: "Settings",
                    isCurrent: isShowingSettings,
                    action: onOpenSettings
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
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
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundColor(isHovered || isCurrent ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                Text(title)
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                    .foregroundColor(isHovered || isCurrent ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? DS.Colors.sidebarHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// "‹ Back to chat" at the top of the Settings sidebar: a full-width row
/// like the others, naming where it returns to, with its keys on the right.
/// Esc and ⌘[ do the same (hidden buttons, so the shortcuts only exist while
/// Settings is showing).
private struct SidebarBackButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(DS.Typography.interface(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("esc")
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.sidebarTextMuted)
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundColor(isHovered ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? DS.Colors.sidebarHover : DS.Colors.sidebarHover.opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (Esc or ⌘[)")
        .onHover { isHovered = $0 }
        .pointerCursor()
        .background {
            // Keyboard shortcuts for the same action; never seen or focused.
            Group {
                Button("", action: action).keyboardShortcut(.cancelAction)
                Button("", action: action).keyboardShortcut("[", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
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
                                .font(DS.Typography.headingLarge)
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(DS.Typography.body)
                                .foregroundColor(DS.Colors.textSecondary)
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
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }
}

extension View {
    func mainAppCard() -> some View {
        modifier(MainAppCardBackground())
    }
}

// MARK: - Sidebar row

/// A row on the brand's dark sidebar: labels in the muted sidebar color at
/// rest and white on hover; the selected row is a filled Igloo Blue pill
/// with a white label (blue text is unreadable on the dark sidebar). The
/// content gets whether the row is highlighted, for its own details.
struct SidebarRowButton<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: (_ isHighlighted: Bool) -> Label

    @State private var isHovered = false

    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: @escaping (_ isHighlighted: Bool) -> Label) {
        self.isSelected = isSelected
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label(isSelected || isHovered)
                .foregroundColor(isSelected || isHovered ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                        .fill(isSelected ? DS.Colors.sidebarSelected : (isHovered ? DS.Colors.sidebarHover : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}
