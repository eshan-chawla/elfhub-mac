//
//  ElfHubViews.swift
//  elfhub
//
//  The Elfs hub: the sidebar's main Elf row and Elfs section (each side Elf
//  folding out into Chat and Work, "+" to make a new Elf or add a starter
//  one), each Elf's page, and the cards of its settings — who it is (name,
//  what it's for, other names, avatar color), how it answers, its soul.md,
//  its notes about the user (user.md), its skills, its home folder,
//  exporting it as a `.elf` file, and deleting it.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar section

/// The main Elf at the top of the sidebar: its avatar, name and a "Main"
/// tag. Clicking it opens your most recent chat with it; the overview button
/// (shown on hover, or right-click) opens its page — your other Elfs, the
/// work it handed out, its memory and files. The badge counts work it handed
/// out that's still going.
struct MainElfSidebarRow: View {
    @ObservedObject var elfManager: ElfManager
    @ObservedObject var elfTaskScheduler: ElfTaskScheduler
    let isSelected: Bool
    let onOpenChat: () -> Void
    let onOpenOverview: () -> Void

    @State private var isHovered = false
    @State private var isOverviewButtonHovered = false

    private var handedOutTaskCount: Int {
        elfTaskScheduler.tasks.filter { $0.wasAssignedByMainElf && !$0.status.isFinished }.count
    }

    var body: some View {
        SidebarRowButton(isSelected: isSelected, action: onOpenChat) { _ in
            HStack(spacing: 8) {
                ElfAvatar(elf: elfManager.mainElf, size: 22)
                Text(elfManager.mainElf.configuration.identity.name)
                    .font(DS.Typography.interface(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("Main")
                    .font(DS.Typography.interface(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.sidebarTextMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.Colors.contrastTint.opacity(isSelected ? 0.22 : 0.1)))
                Spacer()
                if handedOutTaskCount > 0 {
                    SidebarTaskCountBadge(taskCount: handedOutTaskCount, isOnSelectedRow: isSelected)
                }
                // Room for the overview button laid over the row.
                Color.clear.frame(width: 22, height: 1)
            }
        }
        .overlay(alignment: .trailing) {
            Button(action: onOpenOverview) {
                Image(systemName: "square.grid.2x2")
                    .font(DS.Typography.interface(size: 11, weight: .medium))
                    .foregroundColor(isOverviewButtonHovered || isSelected ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(isOverviewButtonHovered ? DS.Colors.contrastTint.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isOverviewButtonHovered = $0 }
            .pointerCursor()
            .help("Overview: your Elfs, handed-out work, memory and files")
            .padding(.trailing, 6)
            .opacity(isHovered || isSelected ? 1 : 0)
        }
        .onHover { isHovered = $0 }
        .help("Your recent chat with your main Elf")
        .padding(.horizontal, 10)
    }
}

/// How many tasks are going: blue for working, white on a selected (blue) row.
struct SidebarTaskCountBadge: View {
    let taskCount: Int
    let isOnSelectedRow: Bool

    var body: some View {
        Text("\(taskCount)")
            .font(DS.Typography.interface(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.sidebarText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(DS.Colors.contrastTint.opacity(isOnSelectedRow ? 0.14 : 0.1)))
            .help("\(taskCount) task\(taskCount == 1 ? "" : "s") in the background")
    }
}

/// Your Elfs at the top of the sidebar: the main Elf always on top (it
/// never folds away, so it's clear who you're talking to), then "Other
/// Elfs" — a header with their count that folds open the rest, each opening
/// its page (Chat and Work are the page's tabs), with a "+" menu to add
/// one. The list scrolls past about six Elfs.
struct ElfsSidebarSection: View {
    @ObservedObject var elfManager: ElfManager
    /// For importing a .elf from the "+" menu.
    let companionManager: CompanionManager
    @ObservedObject var elfTaskScheduler: ElfTaskScheduler
    /// The side Elf whose page is showing, if any.
    let selectedElfIdentifier: String?
    /// Whether the main Elf's row is the selected one (its chat or overview).
    let isMainElfSelected: Bool
    let onOpenElf: (_ elfIdentifier: String, _ elfPageTab: ElfPageTab) -> Void
    /// Opens your most recent chat with the main Elf.
    let onOpenMainElfChat: () -> Void
    let onOpenSettings: (_ elfIdentifier: String) -> Void

    @AppStorage("elfsSidebarSectionIsExpanded") private var isExpanded = true
    @State private var isShowingNewElfSheet = false
    @State private var addStarterElfErrorMessage: String?
    @State private var isSectionHeaderHovered = false

    private static let elfListMaximumHeight: CGFloat = 220

    private var sideElfs: [Elf] {
        elfManager.elfs.filter { $0.id != ElfManager.mainElfIdentifier }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The main Elf is always on top and never folds away: it's the
            // one you talk to unless you pick another, and the one in charge.
            MainElfSidebarRow(
                elfManager: elfManager,
                elfTaskScheduler: elfTaskScheduler,
                isSelected: isMainElfSelected,
                onOpenChat: onOpenMainElfChat,
                onOpenOverview: { onOpenElf(ElfManager.mainElfIdentifier, .chat) }
            )
            .contextMenu {
                Button("Open recent chat", action: onOpenMainElfChat)
                Button("Open overview") { onOpenElf(ElfManager.mainElfIdentifier, .chat) }
                Divider()
                Button("Settings…") { onOpenSettings(ElfManager.mainElfIdentifier) }
            }
            .padding(.bottom, 6)

            // Your other Elfs, folded under their own header.
            HStack(spacing: 4) {
                Button {
                    withAnimation(DS.Motion.fast) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(DS.Typography.interface(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Text("Elfs")
                            .dsLabelStyle()
                        if !sideElfs.isEmpty {
                            Text("\(sideElfs.count)")
                                .font(DS.Typography.interface(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.sidebarTextMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DS.Colors.contrastTint.opacity(0.08)))
                        }
                        Spacer()
                    }
                    .foregroundColor(isSectionHeaderHovered ? DS.Colors.sidebarText : DS.Colors.sidebarTextMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isSectionHeaderHovered = $0 }
                .pointerCursor()
                .help(isExpanded ? "Hide your other Elfs" : "Show your other Elfs")

                Menu {
                    Button("New Elf…") { isShowingNewElfSheet = true }
                    Button("Import .elf…") { ElfImportPicker.chooseAndPreview(companionManager: companionManager) }
                    let availableStarterTemplates = elfManager.availableStarterTemplates
                    if !availableStarterTemplates.isEmpty {
                        Divider()
                        ForEach(availableStarterTemplates) { starterTemplate in
                            Button("Add \(starterTemplate.identity.name)") {
                                addStarterElf(starterTemplate)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(DS.Typography.interface(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.sidebarTextMuted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerCursor()
                .help("Add an Elf")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sideElfs) { sideElf in
                            SideElfSidebarRow(
                                elf: sideElf,
                                activeTaskCount: elfTaskScheduler.tasks.filter { elfTask in
                                    elfTask.elfIdentifier == sideElf.id && !elfTask.status.isFinished
                                }.count,
                                isSelected: sideElf.id == selectedElfIdentifier,
                                onOpen: { elfPageTab in onOpenElf(sideElf.id, elfPageTab) },
                                onOpenSettings: { onOpenSettings(sideElf.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: Self.elfListMaximumHeight)
                .fixedSize(horizontal: false, vertical: true)
                if sideElfs.isEmpty {
                    Text("Add an Elf with + for longer work your main Elf can hand off.")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.sidebarTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 2)
                }
            }
        }
        .sheet(isPresented: $isShowingNewElfSheet) {
            NewElfSheet(elfManager: elfManager, onCreated: { createdElf in onOpenElf(createdElf.id, .chat) })
        }
        .alert(
            "Couldn't add that Elf",
            isPresented: Binding(
                get: { addStarterElfErrorMessage != nil },
                set: { isPresented in if !isPresented { addStarterElfErrorMessage = nil } }
            )
        ) {
            Button("OK") { addStarterElfErrorMessage = nil }
        } message: {
            Text(addStarterElfErrorMessage ?? "")
        }
    }

    private func addStarterElf(_ starterTemplate: ElfStarterTemplate) {
        do {
            let createdElf = try elfManager.createElf(fromStarterTemplate: starterTemplate)
            onOpenElf(createdElf.id, .chat)
        } catch {
            addStarterElfErrorMessage = error.localizedDescription
        }
    }
}

/// One of your other Elfs: avatar, name and a badge with its tasks. Opens
/// its page (Chat and Work are the page's own tabs); right-click for more.
private struct SideElfSidebarRow: View {
    let elf: Elf
    let activeTaskCount: Int
    let isSelected: Bool
    let onOpen: (ElfPageTab) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        SidebarRowButton(isSelected: isSelected, action: { onOpen(.chat) }) { _ in
            HStack(spacing: 8) {
                ElfAvatar(elf: elf, size: 20)
                Text(elf.configuration.identity.name)
                    .font(DS.Typography.interface(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if activeTaskCount > 0 {
                    SidebarTaskCountBadge(taskCount: activeTaskCount, isOnSelectedRow: isSelected)
                }
            }
        }
        .padding(.horizontal, 10)
        .contextMenu {
            Button("Open chat") { onOpen(.chat) }
            Button("Open work") { onOpen(.work) }
            Divider()
            Button("Settings…", action: onOpenSettings)
        }
    }
}

// MARK: - New elf

/// Name a new Elf (with an optional line about what it's for).
/// The name is checked as it's typed; problems that block it disable Create,
/// a warning (it's the start of another elf's name) only shows.
struct NewElfSheet: View {
    @ObservedObject var elfManager: ElfManager
    let onCreated: (Elf) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var createErrorMessage: String?

    private var nameProblems: [ElfNameProblem] {
        ElfNameRules.problems(
            forName: name,
            otherElfNames: ElfNameRules.namesInUse(byElfs: elfManager.elfs, excludingElfWithIdentifier: nil)
        )
    }

    private var canCreate: Bool {
        nameProblems.allSatisfy(\.isWarning)
    }

    /// The empty name is shown only as a disabled Create, not as an error.
    private var nameProblemMessage: String? {
        nameProblems.first { $0 != .empty }?.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Elf")
                .font(DS.Typography.interface(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Give it a name you'd call it by. You can shape its soul, notes and skills on its page.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ElfAvatar(name: name, fillIndex: ElfAvatarAppearance.fillIndex(forElfIdentifier: name.lowercased(), avatarColorIndex: nil), size: 32)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canCreate { create() } }
            }
            if let nameProblemMessage {
                Text(nameProblemMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
            TextField("What this Elf is for (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
            if let createErrorMessage {
                Text(createErrorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .pointerCursor(isEnabled: canCreate)
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(DS.Colors.background)
    }

    private func create() {
        do {
            let createdElf = try elfManager.createElf(identity: ElfConfiguration.Identity(
                name: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            dismiss()
            onCreated(createdElf)
        } catch {
            createErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Elf page

/// One elf's page in the hub. The caller gives it `.id(elfIdentifier)` so
/// switching elfs builds a fresh editor. An elf that's gone by the time the
/// page opens shows the main elf instead.
struct ElfHubPage: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var elfEditor: ElfEditor
    /// Chat or Work, kept by the main window so the sidebar can open either.
    @Binding var selectedTab: ElfPageTab
    let onOpenElf: (String) -> Void
    let onOpenSettings: () -> Void
    let onStartNewChat: () -> Void

    init(
        companionManager: CompanionManager,
        elfIdentifier: String,
        selectedTab: Binding<ElfPageTab>,
        onOpenElf: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void,
        onStartNewChat: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self._selectedTab = selectedTab
        self.onOpenElf = onOpenElf
        self.onOpenSettings = onOpenSettings
        self.onStartNewChat = onStartNewChat
        let elfManager = companionManager.elfManager
        _elfEditor = StateObject(wrappedValue: (try? ElfEditor(elfIdentifier: elfIdentifier, elfManager: elfManager))
            ?? ElfEditor(editingMainElfOf: elfManager))
    }

    private var pageSubtitle: String {
        let trimmedDescription = elfEditor.elf.configuration.identity.description
        if !trimmedDescription.isEmpty { return trimmedDescription }
        return "Talk to it here, or anywhere by starting with its name: \u{201C}\(elfEditor.elf.configuration.identity.name), …\u{201D}"
    }

    var body: some View {
        if elfEditor.isMainElf {
            // The Elf in charge: its own page; its chats are in the sidebar.
            MainElfCaptainPage(
                companionManager: companionManager,
                elfEditor: elfEditor,
                onOpenElf: onOpenElf,
                onOpenSettings: onOpenSettings,
                onStartNewChat: onStartNewChat
            )
        } else {
            sideElfPage
        }
    }

    /// A side Elf's page: its one ongoing chat, and its work (tasks, files,
    /// changes). Its settings open in a sheet from the gear.
    private var sideElfPage: some View {
        VStack(spacing: 0) {
            ElfPageHeader(elf: elfEditor.elf, subtitle: pageSubtitle) {
                HStack(spacing: 10) {
                    Picker("", selection: $selectedTab) {
                        ForEach(ElfPageTab.allCases) { elfPageTab in
                            Text(elfPageTab.title).tag(elfPageTab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .pointerCursor()
                    ElfSettingsButton(action: onOpenSettings)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().background(DS.Colors.borderSubtle)

            switch selectedTab {
            case .chat:
                TextChatView(viewModel: companionManager.textChatViewModel, showsRecentChatsMenu: false)
                    .onAppear { companionManager.textChatViewModel.openElfThread(forElfIdentifier: elfEditor.elf.id) }
            case .work:
                MainAppPage {
                    Text("What \(elfEditor.elf.configuration.identity.name) worked on: tasks you or \(companionManager.elfManager.mainElf.configuration.identity.name) gave it, the files in its folder, and every change it made.")
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ElfTasksSection(elfEditor: elfEditor, elfTaskScheduler: companionManager.elfTaskScheduler)
                        .mainAppCard()
                    ElfFilesSection(elfEditor: elfEditor)
                        .mainAppCard()
                    ElfChangesSection(elfEditor: elfEditor)
                        .mainAppCard()
                }
                .onAppear { elfEditor.reload() }
            }
        }
        .background(DS.Colors.background)
    }
}

/// The views of a side Elf's page.
enum ElfPageTab: String, CaseIterable, Identifiable {
    case chat
    case work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .work: return "Work"
        }
    }
}

struct ElfSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var elfEditor: ElfEditor
    let onOpenModelSettings: () -> Void
    let onElfDeleted: () -> Void
    /// Its tasks and file changes; a side elf shows them on its Work tab.
    var includesWorkSections = true

    var body: some View {
        Text("An Elf's soul, its notes about you and its skills go to your language model with every question it answers, like the rest of the conversation. They're plain files in its home folder — edit them here or in any text editor.")
            .font(DS.Typography.interface(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        ElfIdentitySection(elfEditor: elfEditor, elfManager: companionManager.elfManager)
            .mainAppCard()
        ElfBehaviourSection(elfEditor: elfEditor)
            .mainAppCard()
        ElfModelAndVoiceSummarySection(
            elfEditor: elfEditor,
            companionManager: companionManager,
            providerConfigurationStore: companionManager.providerConfigurationStore,
            mainElfName: companionManager.elfManager.mainElf.configuration.identity.name,
            onOpenModelSettings: onOpenModelSettings
        )
        .mainAppCard()
        ElfMarkdownFileSection(
            title: "Soul",
            fileName: "soul.md",
            explanation: "Instructions this Elf follows in every reply. Only you change this file — the Elf can suggest changes for you to approve.",
            savedText: elfEditor.soulText,
            characterLimit: ElfHome.soulCharacterLimit,
            editorHeight: 240,
            onSave: { try elfEditor.saveSoul($0) },
            resetButtonTitle: "Reset to the starter soul…",
            resetConfirmationMessage: "This replaces soul.md with the soul a new Elf starts with.",
            onReset: { try elfEditor.resetSoulToStarter() }
        )
        .mainAppCard()
        ElfMarkdownFileSection(
            title: "What it knows about you",
            fileName: "user.md",
            explanation: "Your personal preferences, as this Elf noted them. Edit or clear anything. Never shared in an export unless you include it.",
            savedText: elfEditor.profileText,
            characterLimit: ElfHome.userNotesCharacterLimit,
            editorHeight: 140,
            onSave: { try elfEditor.saveProfile($0) },
            resetButtonTitle: "Clear…",
            resetConfirmationMessage: "This deletes every note in user.md.",
            onReset: { try elfEditor.clearProfile() }
        )
        .mainAppCard()
        ElfSkillsSection(elfEditor: elfEditor)
            .mainAppCard()
        if includesWorkSections {
            ElfTasksSection(elfEditor: elfEditor, elfTaskScheduler: companionManager.elfTaskScheduler)
                .mainAppCard()
        }
        ElfFolderGrantsSection(elfEditor: elfEditor)
            .mainAppCard()
        if includesWorkSections {
            ElfChangesSection(elfEditor: elfEditor)
                .mainAppCard()
        }
        ElfHomeAndExportSection(companionManager: companionManager, elfEditor: elfEditor)
            .mainAppCard()
        if !elfEditor.isMainElf {
            ElfDeleteSection(
                elfManager: companionManager.elfManager,
                elfTaskScheduler: companionManager.elfTaskScheduler,
                elfEditor: elfEditor,
                onElfDeleted: onElfDeleted
            )
                .mainAppCard()
        }
        Color.clear
            .frame(height: 0)
            .onAppear { elfEditor.reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                elfEditor.reload()
            }
    }
}

// MARK: - Your folders

/// Folders on this Mac the elf may use: read only unless changes are
/// allowed for that folder. Kept on this Mac, never exported.
private struct ElfFolderGrantsSection: View {
    @ObservedObject var elfEditor: ElfEditor
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LayerFieldLabel(text: "Your folders it can use")
                Spacer()
                Button("Add folder…") { chooseFolder() }
                    .pointerCursor()
            }
            Text("Read only unless you allow changes; every change is kept in its Changes list so you can undo it. These stay on this Mac and are never exported.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if elfEditor.folderGrants.isEmpty {
                Text("No folders yet.")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(elfEditor.folderGrants, id: \.path) { folderGrant in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(folderGrant.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(DS.Typography.mono(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Toggle("Allow changes", isOn: Binding(
                        get: { folderGrant.allowsWriting },
                        set: { allowsWriting in
                            perform {
                                try elfEditor.updateFolderGrants { folderGrants in
                                    if let grantIndex = folderGrants.firstIndex(where: { $0.path == folderGrant.path }) {
                                        folderGrants[grantIndex].allowsWriting = allowsWriting
                                    }
                                }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(DS.Typography.interface(size: 11))
                    .pointerCursor()
                    Button("Remove") {
                        perform { try elfEditor.updateFolderGrants { $0.removeAll { $0.path == folderGrant.path } } }
                    }
                    .pointerCursor()
                }
            }
            if !elfEditor.folderGrants.isEmpty {
                Toggle(isOn: Binding(
                    get: { elfEditor.elf.configuration.capabilities.allowsWebAndUserFoldersTogether },
                    set: { allowsBoth in perform { try elfEditor.updateCapabilities { $0.allowsWebAndUserFoldersTogether = allowsBoth } } }
                )) {
                    Text("Allow the web and these folders in the same task (off: a page it reads can't steer it into your files)")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .pointerCursor()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
        }
    }

    private func chooseFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose a folder \(elfEditor.elf.configuration.identity.name) can use"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let folderURL = openPanel.url else { return }
        let chosenPath = folderURL.standardizedFileURL.path
        if let grantProblem = ElfFolderTools.grantProblem(forFolder: folderURL) {
            errorMessage = grantProblem
            return
        }
        perform {
            try elfEditor.updateFolderGrants { folderGrants in
                if !folderGrants.contains(where: { $0.path == chosenPath }) {
                    folderGrants.append(ElfFolderGrant(path: chosenPath, allowsWriting: false))
                }
            }
        }
    }

    private func perform(_ edit: () throws -> Void) {
        do {
            try edit()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Tasks

/// The elf's background tasks, newest first: what it's working on, what it
/// asks (answer here), and what it finished. Unfinished ones can be stopped.
struct ElfTasksSection: View {
    @ObservedObject var elfEditor: ElfEditor
    @ObservedObject var elfTaskScheduler: ElfTaskScheduler

    private static let listedTaskLimit = 20

    private var elfTasks: [ElfTask] {
        Array(elfTaskScheduler.tasks.filter { $0.elfIdentifier == elfEditor.elf.id }.reversed().prefix(Self.listedTaskLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayerFieldLabel(text: "Tasks")
            Text(elfEditor.isMainElf
                 ? "Work you handed to a background copy of this Elf. Ask it to look into something and it can carry on while you do other things."
                 : "Work this Elf does in the background, newest first. Ask it by name — “\(elfEditor.elf.configuration.identity.name), research …” — or through your main Elf.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if elfTasks.isEmpty {
                Text("No tasks yet.")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            }
            ForEach(elfTasks) { elfTask in
                ElfTaskRow(elfTask: elfTask, elfTaskScheduler: elfTaskScheduler)
            }
        }
    }
}

struct ElfTaskRow: View {
    let elfTask: ElfTask
    @ObservedObject var elfTaskScheduler: ElfTaskScheduler

    @State private var answerDraft = ""
    @State private var answerErrorMessage: String?
    @State private var isShowingNotes = false

    private var statusText: String {
        switch elfTask.status {
        case .queued: return "Waiting to start"
        case .running: return "Working…"
        case .needsInput: return "Has a question"
        case .done: return "Done"
        case .failed: return "Couldn't finish"
        case .cancelled: return "Stopped"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(elfTask.instruction)
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                Spacer()
                // One state, one tone, everywhere — always with its word.
                DSStatusBadge(text: statusText, tone: elfTask.status.statusTone)
                if !elfTask.status.isFinished {
                    Button("Stop") { elfTaskScheduler.cancel(taskIdentifier: elfTask.id) }
                        .pointerCursor()
                        .help("Stop this task")
                }
            }
            if let resultSummary = elfTask.result?.summary {
                Text(resultSummary)
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let filePaths = elfTask.result?.filePaths, !filePaths.isEmpty {
                    Text("Files: " + filePaths.joined(separator: ", "))
                        .font(DS.Typography.mono(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            if let failureReason = elfTask.failureReason {
                Text(failureReason)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
            if elfTask.status == .needsInput, let pendingQuestion = elfTask.pendingQuestion {
                Text(pendingQuestion)
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 8) {
                    TextField("Your answer", text: $answerDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendAnswer() }
                    Button("Answer") { sendAnswer() }
                        .disabled(answerDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .pointerCursor(isEnabled: !answerDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let answerErrorMessage {
                    Text(answerErrorMessage)
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.destructive)
                }
            }
            if !elfTask.progressNotes.isEmpty {
                DisclosureGroup(isExpanded: $isShowingNotes) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(elfTask.progressNotes.enumerated()), id: \.offset) { _, progressNote in
                            Text("· " + progressNote)
                                .font(DS.Typography.interface(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } label: {
                    Text("Notes (\(elfTask.progressNotes.count))")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
    }

    private func sendAnswer() {
        let trimmedAnswer = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }
        do {
            try elfTaskScheduler.answer(taskIdentifier: elfTask.id, answer: trimmedAnswer)
            answerDraft = ""
            answerErrorMessage = nil
        } catch {
            answerErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Changes

/// The elf's newest changes to its files, each with Undo (Redo for an
/// undo). Changes made after the elf read a file or a web page carry a
/// warning, since that text may have steered it.
struct ElfChangesSection: View {
    @ObservedObject var elfEditor: ElfEditor

    @State private var changeLogEntries: [ElfChangeLogEntry] = []
    @State private var entryAwaitingForcedUndo: ElfChangeLogEntry?
    @State private var undoErrorMessage: String?

    private static let listedEntryLimit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayerFieldLabel(text: "Changes")
            Text("What this Elf changed in its folder, newest first. Undo puts a file back the way it was.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if changeLogEntries.isEmpty {
                Text("No changes yet.")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            }
            ForEach(changeLogEntries) { changeLogEntry in
                ElfChangeRow(
                    changeLogEntry: changeLogEntry,
                    onUndo: { undo(changeLogEntry, force: false) }
                )
            }
            if let undoErrorMessage {
                Text(undoErrorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
        }
        .onAppear { reloadEntries() }
        .onChange(of: elfEditor.elfFileCount) { _, _ in reloadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadEntries()
        }
        .confirmationDialog(
            "This file changed since then.",
            isPresented: Binding(
                get: { entryAwaitingForcedUndo != nil },
                set: { isPresented in if !isPresented { entryAwaitingForcedUndo = nil } }
            )
        ) {
            Button("Undo anyway", role: .destructive) {
                if let entryAwaitingForcedUndo { undo(entryAwaitingForcedUndo, force: true) }
            }
        } message: {
            Text("Undoing puts back the earlier version. The newer one is kept here, so you can undo this too.")
        }
    }

    private func reloadEntries() {
        changeLogEntries = Array(ElfChangeLog(home: elfEditor.home).entries().prefix(Self.listedEntryLimit))
    }

    private func undo(_ changeLogEntry: ElfChangeLogEntry, force: Bool) {
        do {
            try ElfChangeLog(home: elfEditor.home).undo(entryIdentifier: changeLogEntry.id, force: force)
            undoErrorMessage = nil
            entryAwaitingForcedUndo = nil
            elfEditor.reload()
        } catch ElfChangeLogError.fileChangedSinceThisChange {
            entryAwaitingForcedUndo = changeLogEntry
        } catch {
            undoErrorMessage = error.localizedDescription
        }
        reloadEntries()
    }
}

private struct ElfChangeRow: View {
    let changeLogEntry: ElfChangeLogEntry
    let onUndo: () -> Void

    @State private var isUndoHovered = false

    private var wasSteeredByWhatItRead: Bool {
        changeLogEntry.influencedBy.contains(.file) || changeLogEntry.influencedBy.contains(.web)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: changeLogEntry.operation == .revert ? "arrow.uturn.backward" : "doc.text")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(ElfFileTools.chatNote(for: changeLogEntry))
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(changeLogEntry.isUndone ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                    .strikethrough(changeLogEntry.isUndone)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(changeLogEntry.date.formatted(.relative(presentation: .named)))
                    .font(DS.Typography.interface(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if wasSteeredByWhatItRead {
                Image(systemName: "exclamationmark.triangle")
                    .font(DS.Typography.interface(size: 10))
                    .foregroundColor(DS.Colors.warning)
                    .help("Made after the Elf read a file or a web page, which may have steered it. Check it's what you wanted.")
            }
            Spacer()
            if changeLogEntry.isUndone {
                Text("undone")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                Button(changeLogEntry.operation == .revert ? "Redo" : "Undo") { onUndo() }
                    .buttonStyle(.plain)
                    .font(DS.Typography.interface(size: 11, weight: .medium))
                    .foregroundColor(isUndoHovered ? DS.Colors.textPrimary : DS.Colors.accentText)
                    .onHover { isUndoHovered = $0 }
                    .pointerCursor()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Model and voice

/// Which language model and voice the elf uses. The main elf uses the ones
/// in Settings › Models; another elf can pick its own from those already
/// set up on this Mac (kept per Mac, never exported), or follow main's.
private struct ElfModelAndVoiceSummarySection: View {
    @ObservedObject var elfEditor: ElfEditor
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var providerConfigurationStore: ProviderConfigurationStore
    let mainElfName: String
    let onOpenModelSettings: () -> Void

    @State private var isShowingSystemVoiceChooser = false
    @State private var errorMessage: String?

    private var selectedConfiguration: ProviderConfiguration? {
        elfEditor.localSettings.languageModelConfigurationIdentifier.flatMap { configurationIdentifier in
            providerConfigurationStore.configurations.first { $0.id == configurationIdentifier }
        }
    }

    private var selectedSpeechOutputMode: SpeechOutputMode? {
        elfEditor.localSettings.voice.flatMap { SpeechOutputMode(rawValue: $0.speechOutputModeRawValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Model & voice")
            if elfEditor.isMainElf {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Uses your language model and voice from Settings › Models.")
                        .font(DS.Typography.interface(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Settings › Models") { onOpenModelSettings() }
                        .pointerCursor()
                }
            } else {
                languageModelRow
                if let selectedConfiguration, !selectedConfiguration.supportsToolCalling {
                    Text("This model can't use tools, so \(elfEditor.elf.configuration.identity.name)'s background work will run on \(mainElfName)'s model.")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if elfEditor.localSettings.languageModelConfigurationIdentifier != nil, selectedConfiguration == nil {
                    Text("That model isn't set up on this Mac any more, so \(mainElfName)'s is used.")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
                voiceRow
                if let errorMessage {
                    Text(errorMessage)
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.destructive)
                }
            }
        }
        .sheet(isPresented: $isShowingSystemVoiceChooser) {
            SystemVoiceChooserSheet(
                selectedVoiceIdentifier: Binding(
                    get: { elfEditor.localSettings.voice?.voiceIdentifier ?? "" },
                    set: { newVoiceIdentifier in
                        updateVoice(speechOutputMode: .system, voiceIdentifier: newVoiceIdentifier.isEmpty ? nil : newVoiceIdentifier)
                    }
                ),
                elfName: elfEditor.elf.configuration.identity.name
            )
        }
    }

    private var languageModelRow: some View {
        HStack {
            Text("Language model")
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Picker("", selection: Binding<UUID?>(
                get: { elfEditor.localSettings.languageModelConfigurationIdentifier },
                set: { newConfigurationIdentifier in
                    perform { try elfEditor.updateLocalSettings { $0.languageModelConfigurationIdentifier = newConfigurationIdentifier } }
                }
            )) {
                Text("Same as \(mainElfName)").tag(UUID?.none)
                ForEach(providerConfigurationStore.configurations) { configuration in
                    Text(configuration.displayName + (configuration.model.isEmpty ? "" : " · " + configuration.model))
                        .tag(UUID?.some(configuration.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .pointerCursor()
        }
    }

    /// For an elf on the on-device voice model: one of that model's voices,
    /// or the one chosen in Settings › Models.
    private var onDeviceModelVoicePicker: some View {
        ElfOnDeviceModelVoicePicker(
            onDeviceVoiceModelStore: OnDeviceVoiceModelLayers.shared.store,
            savedVoiceIdentifier: elfEditor.localSettings.voice?.voiceIdentifier,
            onVoiceChosen: { voiceIdentifier in
                try? elfEditor.updateLocalSettings { localSettings in
                    localSettings.voice?.voiceIdentifier = voiceIdentifier
                }
            }
        )
    }

    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Voice")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding<SpeechOutputMode?>(
                    get: { selectedSpeechOutputMode },
                    set: { newSpeechOutputMode in
                        if let newSpeechOutputMode {
                            updateVoice(speechOutputMode: newSpeechOutputMode, voiceIdentifier: nil)
                        } else {
                            perform { try elfEditor.updateLocalSettings { $0.voice = nil } }
                        }
                    }
                )) {
                    Text("Same as \(mainElfName)").tag(SpeechOutputMode?.none)
                    ForEach(SpeechOutputMode.allCases) { speechOutputMode in
                        Text(speechOutputMode.displayLabel).tag(SpeechOutputMode?.some(speechOutputMode))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }
            switch selectedSpeechOutputMode {
            case .system:
                HStack {
                    Text(elfEditor.localSettings.voice?.voiceIdentifier.flatMap { AVSpeechSynthesisVoiceName.name(forIdentifier: $0) } ?? "The voice in Settings › Models")
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Button("Choose…") { isShowingSystemVoiceChooser = true }
                        .pointerCursor()
                }
            case .elevenLabs:
                elevenLabsVoicePicker
            case .none where companionManager.speechOutputMode == .elevenLabs && !elfEditor.isMainElf:
                // Same voice service as main, but its own ElevenLabs voice.
                Text("Speaks as \(automaticElevenLabsVoiceName), its own ElevenLabs voice, so it doesn't sound like \(mainElfName). Pick ElevenLabs above to choose another.")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .openAICompatibleSpeech:
                ElfCommittingTextField(
                    placeholder: "Voice name (empty: the one in Settings)",
                    savedText: elfEditor.localSettings.voice?.voiceIdentifier ?? "",
                    onCommit: { voiceIdentifierText in
                        let trimmedVoiceIdentifier = voiceIdentifierText.trimmingCharacters(in: .whitespacesAndNewlines)
                        try elfEditor.updateLocalSettings { localSettings in
                            localSettings.voice?.voiceIdentifier = trimmedVoiceIdentifier.isEmpty ? nil : trimmedVoiceIdentifier
                        }
                        return elfEditor.localSettings.voice?.voiceIdentifier ?? ""
                    }
                )
            case .onDeviceModel:
                onDeviceModelVoicePicker
            case .off, .none:
                EmptyView()
            }
        }
    }

    /// This Elf's own ElevenLabs voice when nobody picked one.
    private var automaticElevenLabsVoiceIdentifier: String {
        companionManager.automaticElevenLabsVoiceIdentifier(for: elfEditor.elf)
    }

    private var automaticElevenLabsVoiceName: String {
        ElevenLabsVoiceDirectory.shared.displayName(forVoiceIdentifier: automaticElevenLabsVoiceIdentifier) ?? "its own voice"
    }

    private var elevenLabsVoicePicker: some View {
        ElevenLabsVoicePicker(
            voiceDirectory: ElevenLabsVoiceDirectory.shared,
            selectedVoiceIdentifier: elfEditor.localSettings.voice?.voiceIdentifier,
            automaticVoiceIdentifier: automaticElevenLabsVoiceIdentifier,
            automaticExplanation: "a voice none of your other Elfs use",
            onSelect: { chosenVoiceIdentifier in
                perform {
                    try elfEditor.updateLocalSettings { localSettings in
                        localSettings.voice?.voiceIdentifier = chosenVoiceIdentifier
                    }
                }
            },
            onPreview: { voiceIdentifier in
                companionManager.previewElevenLabsVoice(voiceIdentifier, elfName: elfEditor.elf.configuration.identity.name)
            }
        )
    }

    private func updateVoice(speechOutputMode: SpeechOutputMode, voiceIdentifier: String?) {
        perform {
            try elfEditor.updateLocalSettings { localSettings in
                localSettings.voice = ElfVoiceSelection(speechOutputModeRawValue: speechOutputMode.rawValue, voiceIdentifier: voiceIdentifier)
            }
        }
    }

    private func perform(_ edit: () throws -> Void) {
        do {
            try edit()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// An installed Apple voice's name, for showing which one an elf uses.
enum AVSpeechSynthesisVoiceName {
    static func name(forIdentifier voiceIdentifier: String) -> String? {
        AVSpeechSynthesisVoice(identifier: voiceIdentifier)?.name
    }
}

// MARK: - Delete

/// Deleting a side elf: its folder goes to the Trash, so it can be put back.
private struct ElfDeleteSection: View {
    @ObservedObject var elfManager: ElfManager
    let elfTaskScheduler: ElfTaskScheduler
    @ObservedObject var elfEditor: ElfEditor
    let onElfDeleted: () -> Void

    @State private var isConfirmingDelete = false
    @State private var deleteErrorMessage: String?

    private var elfName: String { elfEditor.elf.configuration.identity.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayerFieldLabel(text: "Delete")
            HStack {
                Button("Delete \(elfName)…", role: .destructive) { isConfirmingDelete = true }
                    .pointerCursor()
                if let deleteErrorMessage {
                    Text(deleteErrorMessage)
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.destructive)
                }
            }
        }
        .confirmationDialog("Delete \(elfName)?", isPresented: $isConfirmingDelete) {
            Button("Delete \(elfName)", role: .destructive) {
                let deletedElfIdentifier = elfEditor.elf.id
                Task { @MainActor in
                    // Its background work stops first, so nothing writes into
                    // the folder as it goes to the Trash.
                    await elfTaskScheduler.cancelAndForgetTasks(forElfIdentifier: deletedElfIdentifier)
                    do {
                        try elfManager.deleteElf(withIdentifier: deletedElfIdentifier)
                        onElfDeleted()
                    } catch {
                        deleteErrorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("\(elfName) and its folder go to the Trash, and its background tasks stop. You can put the folder back in Elfs to restore it.")
        }
    }
}

// MARK: - Identity

private struct ElfIdentitySection: View {
    @ObservedObject var elfEditor: ElfEditor
    @ObservedObject var elfManager: ElfManager


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Identity")
            HStack(alignment: .center, spacing: 10) {
                ElfAvatar(elf: elfEditor.elf, size: 32)
                // Saved through the name rules on Return or blur, and it
                // follows a rename made elsewhere (elf.json edited in another
                // app), so leaving the field never undoes that rename.
                ElfCommittingTextField(
                    placeholder: "Name",
                    savedText: elfEditor.elf.configuration.identity.name,
                    onCommit: { newName in
                        try elfEditor.rename(to: newName)
                        return elfEditor.elf.configuration.identity.name
                    }
                )
            }
            // A name that's the start of another elf's is allowed, with a
            // warning that saying it may reach either elf.
            if let nameWarningMessage = elfEditor.nameWarningMessage {
                Text(nameWarningMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
            // The main Elf is always on Igloo Blue; side Elfs pick a color.
            // Either can wear a picture instead, which covers the color.
            if !ElfAvatarAppearance.usesBrandBlue(elfIdentifier: elfEditor.elf.id) {
                ElfAvatarColorPicker(selectedFillIndex: Binding(
                    get: {
                        ElfAvatarAppearance.fillIndex(
                            forElfIdentifier: elfEditor.elf.id,
                            avatarColorIndex: elfEditor.elf.configuration.identity.avatarColorIndex
                        )
                    },
                    set: { newFillIndex in try? elfEditor.updateAvatarColorIndex(newFillIndex) }
                ))
            }
            ElfAvatarPictureButtons(elfIdentifier: elfEditor.elf.id, elfManager: elfManager)
            ElfCommittingTextField(
                placeholder: "What this Elf is for (optional)",
                savedText: elfEditor.elf.configuration.identity.description,
                onCommit: { newDescription in
                    try elfEditor.updateDescription(newDescription)
                    return elfEditor.elf.configuration.identity.description
                }
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Other names it answers to, separated by commas (optional)")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                ElfCommittingTextField(
                    placeholder: "For example \"June, Juni\"",
                    savedText: elfEditor.elf.configuration.identity.aliases.joined(separator: ", "),
                    onCommit: { aliasesText in
                        try elfEditor.updateAliases(aliasesText.components(separatedBy: ","))
                        return elfEditor.elf.configuration.identity.aliases.joined(separator: ", ")
                    }
                )
            }
        }
    }
}

/// A text field that saves when the user presses Return or leaves it — not
/// on every keystroke, so a half-typed value never reaches elf.json — and
/// shows why a save failed underneath. It follows the saved value when
/// that changes elsewhere (say, a reload) while the user isn't typing.
struct ElfCommittingTextField: View {
    let placeholder: String
    let savedText: String
    /// Saves the typed text and returns the text as saved, which may differ
    /// (trimmed, or only the first emoji kept).
    let onCommit: (String) throws -> String

    @State private var draftText = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $draftText)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commitDraft() }
                .onChange(of: isFocused) { _, isNowFocused in
                    if !isNowFocused { commitDraft() }
                }
            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
        }
        .onAppear { draftText = savedText }
        .onChange(of: savedText) { _, newSavedText in
            if !isFocused { draftText = newSavedText }
        }
    }

    private func commitDraft() {
        guard draftText != savedText else {
            errorMessage = nil
            return
        }
        do {
            draftText = try onCommit(draftText)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Behaviour

private struct ElfBehaviourSection: View {
    @ObservedObject var elfEditor: ElfEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "How it answers")
            HStack {
                Text("Reply length")
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { elfEditor.elf.configuration.behaviour.replyLength },
                    set: { newReplyLength in try? elfEditor.updateBehaviour { $0.replyLength = newReplyLength } }
                )) {
                    ForEach(ElfConfiguration.Behaviour.ReplyLength.allCases, id: \.self) { replyLength in
                        Text(replyLength.displayName).tag(replyLength)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }
            ElfCommittingTextField(
                placeholder: "Tone, for example \"calm and encouraging\" (optional)",
                savedText: elfEditor.elf.configuration.behaviour.tone,
                onCommit: { newTone in
                    try elfEditor.updateBehaviour { $0.tone = newTone }
                    return elfEditor.elf.configuration.behaviour.tone
                }
            )
            ElfCommittingTextField(
                placeholder: "Always reply in… (optional, for example \"British English\")",
                savedText: elfEditor.elf.configuration.behaviour.language,
                onCommit: { newLanguage in
                    try elfEditor.updateBehaviour { $0.language = newLanguage }
                    return elfEditor.elf.configuration.behaviour.language
                }
            )

            SettingsToggleRow(
                iconName: "person.text.rectangle",
                title: "Take notes about me",
                detail: "Lets your Elf note your personal preferences in user.md as you talk.",
                isOn: behaviourToggleBinding(\.takesNotes)
            )
            SettingsToggleRow(
                iconName: "globe",
                title: "Can use the web",
                detail: elfEditor.isMainElf
                    ? "Off for your main Elf by default: it hands web research to your other Elfs."
                    : "Searches and opens web pages for its tasks — only pages it's led to: search results and their links, or addresses you give it. What it reads goes to your language model like the rest of the conversation.",
                isOn: Binding(
                    get: { elfEditor.elf.configuration.capabilities.isWebEnabled(isMainElf: elfEditor.isMainElf) },
                    set: { isWebEnabled in
                        // A failed save (the elf's folder is gone) sends the page back to main.
                        try? elfEditor.updateCapabilities { $0.webEnabled = isWebEnabled }
                    }
                )
            )
            SettingsToggleRow(
                iconName: "books.vertical",
                title: "Learn skills from our work",
                detail: "Lets your Elf save how things are done at work (tools, steps, conventions) as skills.",
                isOn: behaviourToggleBinding(\.learnsSkills)
            )
        }
    }

    private func behaviourToggleBinding(_ behaviourKeyPath: WritableKeyPath<ElfConfiguration.Behaviour, Bool>) -> Binding<Bool> {
        Binding(
            get: { elfEditor.elf.configuration.behaviour[keyPath: behaviourKeyPath] },
            set: { newValue in try? elfEditor.updateBehaviour { $0[keyPath: behaviourKeyPath] = newValue } }
        )
    }
}

// MARK: - soul.md / user.md

/// An editor for one markdown file with Save / Revert and a reset action.
private struct ElfMarkdownFileSection: View {
    let title: String
    let fileName: String
    let explanation: String
    let savedText: String
    let characterLimit: Int
    let editorHeight: CGFloat
    let onSave: (String) throws -> Void
    let resetButtonTitle: String
    let resetConfirmationMessage: String
    let onReset: () throws -> Void

    @State private var draftText: String?
    @State private var errorMessage: String?
    @State private var isConfirmingReset = false

    private var editedText: String { draftText ?? savedText }
    private var hasUnsavedChanges: Bool { draftText != nil && draftText != savedText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                LayerFieldLabel(text: title)
                Text(fileName)
                    .font(DS.Typography.mono(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Text("\(editedText.count) / \(characterLimit)")
                    .font(DS.Typography.interface(size: 10))
                    .foregroundColor(editedText.count > characterLimit ? DS.Colors.warning : DS.Colors.textTertiary)
            }
            Text(explanation)
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: Binding(get: { editedText }, set: { draftText = $0 }))
                .font(DS.Typography.mono(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: editorHeight)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }

            HStack(spacing: 8) {
                Button("Save") { save() }
                    .disabled(!hasUnsavedChanges)
                    // soul.md and user.md editors share a page: only the one
                    // with unsaved changes answers ⌘S.
                    .keyboardShortcut(hasUnsavedChanges ? KeyboardShortcut("s", modifiers: .command) : nil)
                    .pointerCursor(isEnabled: hasUnsavedChanges)
                Button("Revert") {
                    draftText = nil
                    errorMessage = nil
                }
                .disabled(!hasUnsavedChanges)
                .pointerCursor(isEnabled: hasUnsavedChanges)
                Spacer()
                Button(resetButtonTitle) { isConfirmingReset = true }
                    .pointerCursor()
            }
        }
        .confirmationDialog(resetButtonTitle.replacingOccurrences(of: "…", with: "?"), isPresented: $isConfirmingReset) {
            Button(resetButtonTitle.replacingOccurrences(of: "…", with: ""), role: .destructive) {
                do {
                    try onReset()
                    draftText = nil
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text(resetConfirmationMessage)
        }
    }

    private func save() {
        do {
            try onSave(editedText)
            draftText = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Skills

private struct ElfSkillsSection: View {
    @ObservedObject var elfEditor: ElfEditor
    @State private var skillBeingEdited: ElfSkillEditorRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LayerFieldLabel(text: "Skills")
                Text("skills/")
                    .font(DS.Typography.mono(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button("New skill") {
                    skillBeingEdited = ElfSkillEditorRequest(skill: ElfSkill(name: "", description: "", body: ""), isNew: true)
                }
                .pointerCursor()
            }
            Text("Working knowledge your Elf learned — how things are done at work, your tools, your conventions. Shared in exports.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if elfEditor.skills.isEmpty {
                Text("No skills yet.")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            }
            ForEach(elfEditor.skills) { skill in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(DS.Typography.interface(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(DS.Typography.interface(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Button("Edit") { skillBeingEdited = ElfSkillEditorRequest(skill: skill, isNew: false) }
                        .pointerCursor()
                }
                .padding(.vertical, 4)
            }
        }
        .sheet(item: $skillBeingEdited) { skillEditorRequest in
            ElfSkillEditorSheet(elfEditor: elfEditor, skillEditorRequest: skillEditorRequest)
        }
    }
}

private struct ElfSkillEditorRequest: Identifiable {
    let id = UUID()
    let skill: ElfSkill
    let isNew: Bool
}

private struct ElfSkillEditorSheet: View {
    @ObservedObject var elfEditor: ElfEditor
    let skillEditorRequest: ElfSkillEditorRequest

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var bodyText: String
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    init(elfEditor: ElfEditor, skillEditorRequest: ElfSkillEditorRequest) {
        self.elfEditor = elfEditor
        self.skillEditorRequest = skillEditorRequest
        _name = State(initialValue: skillEditorRequest.skill.name)
        _description = State(initialValue: skillEditorRequest.skill.description)
        _bodyText = State(initialValue: skillEditorRequest.skill.body)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(skillEditorRequest.isNew ? "New skill" : "Edit skill")
                .font(DS.Typography.interface(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            TextField("Name, for example \"Deploying the web app\"", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("One line on what it covers", text: $description)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText)
                .font(DS.Typography.mono(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
            HStack {
                if !skillEditorRequest.isNew {
                    Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                        .pointerCursor()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .pointerCursor(isEnabled: canSave)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
        .background(DS.Colors.background)
        .confirmationDialog("Delete this skill?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                try? elfEditor.deleteSkill(skillEditorRequest.skill)
                dismiss()
            }
        }
    }

    private func save() {
        do {
            try elfEditor.saveSkill(
                ElfSkill(
                    slug: skillEditorRequest.skill.slug,
                    name: name,
                    description: description,
                    body: bodyText,
                    unrecognizedFrontmatterLines: skillEditorRequest.skill.unrecognizedFrontmatterLines
                ),
                isNewSkill: skillEditorRequest.isNew
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Home folder and export

private struct ElfHomeAndExportSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var elfEditor: ElfEditor
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Home folder")
            HStack(spacing: 8) {
                Text(elfEditor.home.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(DS.Typography.mono(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { elfEditor.revealHomeInFinder() }
                    .pointerCursor()
            }
            HStack(spacing: 8) {
                Text("Its own files (files/): \(elfEditor.elfFileCount) \(elfEditor.elfFileCount == 1 ? "file" : "files")")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Open") { elfEditor.revealFilesInFinder() }
                    .pointerCursor()
            }

            Divider().background(DS.Colors.borderSubtle)

            LayerFieldLabel(text: "Export")
            Text("Save this Elf as a .elf file to keep or share. It always has its config, soul.md, skills and files; its notes about you (user.md) unless you leave them out; chats with it only if you include them. Keys, its folder grants, changes and tasks are never exported.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export Elf…") { presentExportPanel() }
                    .pointerCursor()
                if let exportMessage {
                    Text(exportMessage)
                        .font(DS.Typography.interface(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func presentExportPanel() {
        let exportOptionsModel = ElfExportOptionsModel()
        let savePanel = NSSavePanel()
        savePanel.title = "Export Elf"
        savePanel.nameFieldStringValue = ElfExporter.packageBaseName(forElfName: elfEditor.elf.configuration.identity.name) + ".elf"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "elf") ?? .zip]
        savePanel.canCreateDirectories = true
        let accessoryHostingView = NSHostingView(rootView: ElfExportOptionsView(
            exportOptionsModel: exportOptionsModel,
            elfName: elfEditor.elf.configuration.identity.name
        ))
        accessoryHostingView.frame.size = accessoryHostingView.fittingSize
        savePanel.accessoryView = accessoryHostingView

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }
        do {
            try elfEditor.export(
                to: destinationURL,
                options: exportOptionsModel.options,
                preferredModels: companionManager.preferredModelsForElfExport(),
                chats: companionManager.chatConversationStore.conversations
            )
            exportMessage = "Exported to \(destinationURL.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            exportMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// The save panel's two switches: notes about you (on), chats (off).
private final class ElfExportOptionsModel: ObservableObject {
    @Published var options = ElfExporter.Options()
}

private struct ElfExportOptionsView: View {
    @ObservedObject var exportOptionsModel: ElfExportOptionsModel
    let elfName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Always included: its config, soul.md, skills and files")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(.secondary)
            Toggle("Include its notes about you (user.md)", isOn: $exportOptionsModel.options.includesProfile)
                .toggleStyle(.checkbox)
            Toggle("Include chats with \(elfName)", isOn: $exportOptionsModel.options.includesChats)
                .toggleStyle(.checkbox)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }
}

// MARK: - Importing

/// Lets the user pick a .elf file to import (its preview follows).
enum ElfImportPicker {
    @MainActor
    static func chooseAndPreview(companionManager: CompanionManager) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import an Elf"
        openPanel.allowedContentTypes = [UTType(filenameExtension: "elf") ?? .zip]
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let packageURL = openPanel.url else { return }
        companionManager.requestElfImport(from: packageURL)
    }
}

/// What a .elf would add, before anything is written: Import or Cancel.
struct ElfImportPreviewSheet: View {
    let importPreview: ElfImportPreview
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(importPreview.elfName)?")
                .font(DS.Typography.interface(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if !importPreview.description.isEmpty {
                Text(importPreview.description)
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                previewLine("Its soul, skills and \(importPreview.fileCount) file\(importPreview.fileCount == 1 ? "" : "s")")
                previewLine(importPreview.includesProfile ? "Its notes about the person who made it (user.md)" : "No notes about anyone")
                if importPreview.chatCount > 0 {
                    previewLine("\(importPreview.chatCount) chat\(importPreview.chatCount == 1 ? "" : "s"), added to your chats")
                }
                if !importPreview.configuration.identity.aliases.isEmpty {
                    previewLine("Also answers to: " + importPreview.configuration.identity.aliases.prefix(ElfNameRules.maximumAliasCount).joined(separator: ", "))
                }
                previewLine("The web and folder access start off; you choose them on its page")
            }
            if let modelHint = importPreview.modelHint {
                Text(modelHint)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only import Elfs from people you trust: its soul and skills shape what it says and does.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Import") { onImport() }
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(DS.Colors.background)
    }

    private func previewLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·").foregroundColor(DS.Colors.textTertiary)
            Text(text)
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An elf's voice from the downloaded voice model; follows downloads and
/// model changes as they happen. A voice saved for another model shows as
/// the one in Settings (that's what it speaks with).
private struct ElfOnDeviceModelVoicePicker: View {
    @ObservedObject var onDeviceVoiceModelStore: OnDeviceVoiceModelStore
    let savedVoiceIdentifier: String?
    let onVoiceChosen: (String?) -> Void

    var body: some View {
        if let activeModelIdentifier = onDeviceVoiceModelStore.activeTextToSpeechModelIdentifier,
           onDeviceVoiceModelStore.isInstalled(activeModelIdentifier) {
            let availableVoices = onDeviceVoiceModelStore.availableVoices(forModelIdentifier: activeModelIdentifier)
            let shownVoiceIdentifier = savedVoiceIdentifier.flatMap { saved in availableVoices.contains { $0.id == saved } ? saved : nil } ?? ""
            Picker("Voice", selection: Binding<String>(
                get: { shownVoiceIdentifier },
                set: { onVoiceChosen($0.isEmpty ? nil : $0) }
            )) {
                Text("The voice in Settings › Models").tag("")
                ForEach(availableVoices) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .pointerCursor()
        } else {
            Text("Download and choose a voice model in Settings › Models first.")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

// MARK: - Task status tones

extension ElfTaskStatus {
    /// The brand's tone for each state (chapter 07): working is blue (never
    /// amber), waiting on the user amber, done green, failed red, queued and
    /// cancelled grey.
    var statusTone: DSStatusTone {
        switch self {
        case .queued, .cancelled: return .neutral
        case .running: return .info
        case .needsInput: return .warning
        case .done: return .success
        case .failed: return .danger
        }
    }
}
