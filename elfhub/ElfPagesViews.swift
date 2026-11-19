//
//  ElfPagesViews.swift
//  elfhub
//
//  The Elf pages' parts that aren't the editor cards (those stay in
//  ElfHubViews):
//    - ElfPageHeader: avatar, name, a line, and the Settings (gear) button.
//    - ElfSettingsSheet: every setting of one Elf in a sheet, opened by the
//      gear or from the sidebar — the pages themselves are for chat and work.
//    - ElfFilesSection + ElfFilePreviewSheet: everything in an Elf's folder,
//      for auditing what it keeps and changes.
//    - MainElfCaptainPage: the main Elf's own page. It's the Elf in charge:
//      your other Elfs and what they're doing, the work it handed out, its
//      memory of you, and its files. It talks with you in the sidebar's chats
//      and never works in the background itself.
//

import AppKit
import SwiftUI

// MARK: - Header

struct ElfPageHeader<Trailing: View>: View {
    let elf: Elf
    let subtitle: String
    var avatarSize: CGFloat = 32
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ElfAvatar(elf: elf, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(elf.configuration.identity.name)
                    .font(avatarSize >= 48 ? DS.Typography.headingLarge : DS.Typography.headingSmall)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// The gear that opens an Elf's settings sheet.
struct ElfSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                Text("Settings")
            }
        }
        .dsSecondaryButtonStyle(size: .small)
        .help("Identity, how it answers, soul, notes about you, skills, folders and export")
    }
}

// MARK: - Settings sheet

/// One Elf's settings in a sheet: the same cards as before, minus the work
/// (tasks and changes live on its page's Work view).
struct ElfSettingsSheet: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var elfEditor: ElfEditor
    let onOpenModelSettings: () -> Void
    let onElfDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        companionManager: CompanionManager,
        elfIdentifier: String,
        onOpenModelSettings: @escaping () -> Void,
        onElfDeleted: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self.onOpenModelSettings = onOpenModelSettings
        self.onElfDeleted = onElfDeleted
        let elfManager = companionManager.elfManager
        _elfEditor = StateObject(wrappedValue: (try? ElfEditor(elfIdentifier: elfIdentifier, elfManager: elfManager))
            ?? ElfEditor(editingMainElfOf: elfManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            ElfPageHeader(
                elf: elfEditor.elf,
                subtitle: elfEditor.isMainElf ? "Your main Elf's settings" : "Settings"
            ) {
                Button("Done") { dismiss() }
                    .dsPrimaryButtonStyle(size: .small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider().background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ElfSettingsContent(
                        companionManager: companionManager,
                        elfEditor: elfEditor,
                        onOpenModelSettings: {
                            dismiss()
                            onOpenModelSettings()
                        },
                        onElfDeleted: {
                            dismiss()
                            onElfDeleted()
                        },
                        includesWorkSections: false
                    )
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .background(DS.Colors.background)
        .buttonStyle(DSButtonStyle(kind: .secondary, size: .small))
        .tint(DS.Colors.controlTint)
    }
}

/// Which Elf's settings sheet is open (for `.sheet(item:)`).
struct ElfSettingsRequest: Identifiable, Equatable {
    let elfIdentifier: String
    var id: String { elfIdentifier }
}

// MARK: - Files

/// Everything in an Elf's folder, grouped by folder, newest first — so you
/// can see exactly what it keeps. Files it changed recently are marked.
struct ElfFilesSection: View {
    @ObservedObject var elfEditor: ElfEditor

    @State private var fileEntries: [ElfFileEntry] = []
    @State private var latestChangeDateByPath: [String: Date] = [:]
    @State private var collapsedFolderPaths: Set<String> = []
    @State private var previewedFileEntry: ElfFileEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LayerFieldLabel(text: "Files")
                Spacer()
                Button("Show in Finder") { elfEditor.revealHomeInFinder() }
                    .dsGhostButtonStyle(size: .small)
            }
            Text("Everything in \(elfEditor.elf.configuration.identity.name)'s folder on this Mac. Click a file to read it.")
                .font(DS.Typography.small)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if fileEntries.isEmpty {
                Text("No files yet.")
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            }

            ForEach(ElfFileEntry.groupedByFolder(fileEntries), id: \.folderPath) { folderGroup in
                folderGroupView(folderPath: folderGroup.folderPath, fileEntries: folderGroup.fileEntries)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .onChange(of: elfEditor.elfFileCount) { _, _ in reload() }
        .sheet(item: $previewedFileEntry) { fileEntry in
            ElfFilePreviewSheet(elfHome: elfEditor.home, fileEntry: fileEntry)
        }
    }

    private func folderGroupView(folderPath: String, fileEntries: [ElfFileEntry]) -> some View {
        let isExpanded = !collapsedFolderPaths.contains(folderPath)
        return VStack(alignment: .leading, spacing: 2) {
            if !folderPath.isEmpty {
                Button {
                    if isExpanded { collapsedFolderPaths.insert(folderPath) } else { collapsedFolderPaths.remove(folderPath) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(DS.Typography.interface(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: "folder")
                        Text(folderPath + "/")
                            .font(DS.Typography.code)
                        Text("\(fileEntries.count)")
                            .font(DS.Typography.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            if isExpanded {
                ForEach(fileEntries) { fileEntry in
                    ElfFileRow(
                        fileEntry: fileEntry,
                        latestChangeDate: latestChangeDateByPath[fileEntry.path],
                        isIndented: !folderPath.isEmpty,
                        onOpen: { previewedFileEntry = fileEntry }
                    )
                }
            }
        }
    }

    private func reload() {
        fileEntries = elfEditor.home.fileEntries()
        var latestChangeDates: [String: Date] = [:]
        for changeLogEntry in ElfChangeLog(home: elfEditor.home).entries() {
            for changedPath in [changeLogEntry.path] + [changeLogEntry.renamedToPath].compactMap({ $0 }) {
                if latestChangeDates[changedPath].map({ $0 < changeLogEntry.date }) ?? true {
                    latestChangeDates[changedPath] = changeLogEntry.date
                }
            }
        }
        latestChangeDateByPath = latestChangeDates
    }
}

private struct ElfFileRow: View {
    let fileEntry: ElfFileEntry
    /// When the Elf last changed it through its tools, if it did.
    let latestChangeDate: Date?
    let isIndented: Bool
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundColor(DS.Colors.textTertiary)
                Text(fileEntry.fileName)
                    .font(DS.Typography.bodyMedium)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let latestChangeDate {
                    DSStatusBadge(text: "Changed by the Elf \(latestChangeDate.formatted(.relative(presentation: .named)))", tone: .info)
                }
                Spacer(minLength: 8)
                Text(fileEntry.modifiedAt.formatted(.relative(presentation: .named)))
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                Text(ByteCountFormatter.string(fromByteCount: fileEntry.byteCount, countStyle: .file))
                    .font(DS.Typography.mono(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.leading, isIndented ? 22 : 0)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .help(fileEntry.path)
    }
}

/// A file's text, read-only, with Show in Finder.
struct ElfFilePreviewSheet: View {
    let elfHome: ElfHome
    let fileEntry: ElfFileEntry

    @Environment(\.dismiss) private var dismiss

    /// Long files show their start, like read_file's first page.
    private static let previewCharacterLimit = 20_000

    private var fileURL: URL? {
        try? elfHome.resolvedURLInsideHome(fileEntry.path)
    }

    private var previewText: String {
        guard let fileURL, let fileData = try? Data(contentsOf: fileURL) else {
            return "This file can't be read."
        }
        guard let fileText = String(data: fileData, encoding: .utf8) else {
            return "This isn't a text file (\(ByteCountFormatter.string(fromByteCount: fileEntry.byteCount, countStyle: .file)))."
        }
        guard fileText.count > Self.previewCharacterLimit else { return fileText }
        return String(fileText.prefix(Self.previewCharacterLimit)) + "\n\n… (open it in Finder for the rest)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileEntry.fileName)
                        .font(DS.Typography.headingSmall)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(fileEntry.path)
                        .font(DS.Typography.code)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Button("Show in Finder") {
                    if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                }
                .dsSecondaryButtonStyle(size: .small)
                Button("Done") { dismiss() }
                    .dsPrimaryButtonStyle(size: .small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider().background(DS.Colors.borderSubtle)
            ScrollView {
                Text(previewText)
                    .font(DS.Typography.code)
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 600)
        .background(DS.Colors.background)
    }
}

// MARK: - The main Elf's page

/// The Elf in charge: it talks with you (its chats are in the sidebar),
/// keeps its memory of you, and hands longer work to your other Elfs.
struct MainElfCaptainPage: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var elfEditor: ElfEditor
    @ObservedObject private var elfManager: ElfManager
    @ObservedObject private var elfTaskScheduler: ElfTaskScheduler
    @ObservedObject private var mainElfMemoryKeeper: MainElfMemoryKeeper
    let onOpenElf: (String) -> Void
    let onOpenSettings: () -> Void
    let onStartNewChat: () -> Void

    @AppStorage(MainElfMemorySettings.isEnabledKey) private var buildsMemoryFromChats = true
    @State private var isShowingNewElfSheet = false

    init(
        companionManager: CompanionManager,
        elfEditor: ElfEditor,
        onOpenElf: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void,
        onStartNewChat: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self.elfEditor = elfEditor
        self.elfManager = companionManager.elfManager
        self.elfTaskScheduler = companionManager.elfTaskScheduler
        self.mainElfMemoryKeeper = companionManager.mainElfMemoryKeeper
        self.onOpenElf = onOpenElf
        self.onOpenSettings = onOpenSettings
        self.onStartNewChat = onStartNewChat
    }

    private var sideElfs: [Elf] {
        elfManager.elfs.filter { $0.id != ElfManager.mainElfIdentifier }
    }

    private var handedOutTasks: [ElfTask] {
        Array(elfTaskScheduler.tasks.filter(\.wasAssignedByMainElf).reversed().prefix(10))
    }

    var body: some View {
        MainAppPage {
            ElfPageHeader(
                elf: elfEditor.elf,
                subtitle: "Your main Elf. It talks with you, remembers what matters to you, and hands longer work to your other Elfs.",
                avatarSize: 48
            ) {
                HStack(spacing: 8) {
                    ElfSettingsButton(action: onOpenSettings)
                    Button("New chat", action: onStartNewChat)
                        .dsPrimaryButtonStyle(size: .small)
                }
            }
            .padding(.bottom, 4)

            yourElfsCard
                .mainAppCard()
            handedOutCard
                .mainAppCard()
            memoryCard
                .mainAppCard()
            ElfFilesSection(elfEditor: elfEditor)
                .mainAppCard()
            ElfChangesSection(elfEditor: elfEditor)
                .mainAppCard()
        }
        .onAppear { elfEditor.reload() }
        .sheet(isPresented: $isShowingNewElfSheet) {
            NewElfSheet(elfManager: elfManager, onCreated: { createdElf in onOpenElf(createdElf.id) })
        }
    }

    // MARK: Your Elfs

    private var yourElfsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LayerFieldLabel(text: "Your Elfs")
                Spacer()
                Button("Add an Elf") { isShowingNewElfSheet = true }
                    .dsGhostButtonStyle(size: .small)
            }
            if sideElfs.isEmpty {
                Text("No other Elfs yet. Add one, and \(elfEditor.elf.configuration.identity.name) can hand it longer work.")
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sideElfs) { sideElf in
                ElfRosterStatusRow(
                    elf: sideElf,
                    currentTask: elfTaskScheduler.tasks.last { $0.elfIdentifier == sideElf.id && !$0.status.isFinished },
                    onOpen: { onOpenElf(sideElf.id) }
                )
            }
        }
    }

    // MARK: Handed out

    private var handedOutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Handed out")
            Text("Longer work \(elfEditor.elf.configuration.identity.name) gave your other Elfs, newest first. It tells you when each is done.")
                .font(DS.Typography.small)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if handedOutTasks.isEmpty {
                Text("Nothing handed out yet.")
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 2)
            }
            ForEach(handedOutTasks) { handedOutTask in
                VStack(alignment: .leading, spacing: 4) {
                    if let assignedElf = elfManager.elf(withIdentifier: handedOutTask.elfIdentifier) {
                        HStack(spacing: 6) {
                            ElfAvatar(elf: assignedElf, size: 20)
                            Text("To \(assignedElf.configuration.identity.name)")
                                .font(DS.Typography.smallMedium)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                    ElfTaskRow(elfTask: handedOutTask, elfTaskScheduler: elfTaskScheduler)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        let userNotesSections = UserNotesSections(userNotesText: elfEditor.profileText)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                LayerFieldLabel(text: "Memory")
                Spacer()
                if buildsMemoryFromChats {
                    Button(mainElfMemoryKeeper.isUpdating ? "Updating…" : "Update memory now") {
                        Task {
                            await mainElfMemoryKeeper.updateNow()
                            elfEditor.reload()
                        }
                    }
                    .dsSecondaryButtonStyle(size: .small)
                    .disabled(mainElfMemoryKeeper.isUpdating)
                }
                Button("Edit") { onOpenSettings() }
                    .dsGhostButtonStyle(size: .small)
            }

            Text(memoryStatusLine)
                .font(DS.Typography.small)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !buildsMemoryFromChats {
                HStack(spacing: 8) {
                    DSStatusBadge(text: "Off", tone: .neutral)
                    Button("Turn on") { buildsMemoryFromChats = true }
                        .dsGhostButtonStyle(size: .small)
                }
            } else if mainElfMemoryKeeper.hasRepeatedFailures {
                DSStatusBadge(text: "Couldn't update. Check your model in Settings › Models.", tone: .warning)
            }

            memorySection(title: "About you", lines: userNotesSections.aboutYouLines, emptyText: "Nothing yet. It notes what you tell it about yourself.")
            memorySection(title: "What you've talked about", lines: userNotesSections.talkedAboutLines, emptyText: "Nothing yet. Each chat is added half an hour after it goes quiet.")
            if !userNotesSections.otherLines.isEmpty {
                memorySection(title: "Other notes", lines: userNotesSections.otherLines, emptyText: "")
            }
        }
    }

    private var memoryStatusLine: String {
        guard buildsMemoryFromChats else {
            return "Memory is off: \(elfEditor.elf.configuration.identity.name) keeps only notes it writes itself."
        }
        guard let lastUpdate = mainElfMemoryKeeper.memoryState.lastUpdate else {
            return "Not updated yet. Half an hour after a chat goes quiet, it's added here (sent once to your model)."
        }
        return "Last updated \(lastUpdate.date.formatted(.relative(presentation: .named))) from \u{201C}\(lastUpdate.conversationTitle)\u{201D}."
    }

    private func memorySection(title: String, lines: [String], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DS.Typography.smallMedium)
                .foregroundColor(DS.Colors.textSecondary)
            if lines.isEmpty {
                Text(emptyText)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// user.md split for display: the two memory sections and anything else
/// the Elf wrote. Lines keep their text, without list markers.
nonisolated struct UserNotesSections: Equatable {
    var aboutYouLines: [String] = []
    var talkedAboutLines: [String] = []
    var otherLines: [String] = []

    init(userNotesText: String) {
        enum CurrentSection { case other, aboutYou, talkedAbout }
        var currentSection = CurrentSection.other
        for rawLine in userNotesText.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("#") {
                switch trimmedLine {
                case MainElfMemoryPlanner.aboutYouHeading: currentSection = .aboutYou
                case MainElfMemoryPlanner.talkedAboutHeading: currentSection = .talkedAbout
                default: if trimmedLine.hasPrefix("## ") { currentSection = .other }
                }
                continue
            }
            var displayedLine = trimmedLine
            for listMarker in ["- ", "* "] where displayedLine.hasPrefix(listMarker) {
                displayedLine = String(displayedLine.dropFirst(listMarker.count))
            }
            guard !displayedLine.isEmpty else { continue }
            switch currentSection {
            case .aboutYou: aboutYouLines.append(displayedLine)
            case .talkedAbout: talkedAboutLines.append(displayedLine)
            case .other: otherLines.append(displayedLine)
            }
        }
    }
}

/// One of your other Elfs on the main Elf's page: what it's doing now.
private struct ElfRosterStatusRow: View {
    let elf: Elf
    let currentTask: ElfTask?
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                ElfAvatar(elf: elf, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(elf.configuration.identity.name)
                        .font(DS.Typography.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(currentTask?.instruction ?? (elf.configuration.identity.description.isEmpty ? "Nothing to do right now." : elf.configuration.identity.description))
                        .font(DS.Typography.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                statusBadge
                Image(systemName: "chevron.right")
                    .font(DS.Typography.interface(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch currentTask?.status {
        case .running?: DSStatusBadge(text: "Working", tone: .info)
        // The same words as each task's own row (ElfTaskRow).
        case .needsInput?: DSStatusBadge(text: "Has a question", tone: .warning)
        case .queued?: DSStatusBadge(text: "Waiting to start", tone: .neutral)
        default: DSStatusBadge(text: "Idle", tone: .neutral)
        }
    }
}
