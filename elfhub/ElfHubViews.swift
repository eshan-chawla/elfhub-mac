//
//  ElfHubViews.swift
//  elfhub
//
//  The Elves hub: the Elves section of the main window's sidebar (every elf,
//  main first, with "+" to make a new elf or add a starter one) and each
//  elf's page — who it is (name, emoji, what it's for, other names), how it
//  answers, its soul.md, its notes about the user (profile.md), its skills,
//  its home folder, exporting it as a `.elf` file, and deleting it.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar section

/// The Elves section of the sidebar: a collapsible list of every elf (main
/// first) and a "+" menu. It scrolls past about six elves so the chats
/// below always keep room.
struct ElvesSidebarSection: View {
    @ObservedObject var elfManager: ElfManager
    /// The elf whose page is showing, if any.
    let selectedElfIdentifier: String?
    let onOpenElf: (String) -> Void

    @AppStorage("elvesSidebarSectionIsExpanded") private var isExpanded = true
    @State private var isShowingNewElfSheet = false
    @State private var addStarterElfErrorMessage: String?
    @State private var isSectionHeaderHovered = false

    private static let elfListMaximumHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Text("Elves")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(isSectionHeaderHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isSectionHeaderHovered = $0 }
                .pointerCursor()
                .help(isExpanded ? "Hide your elves" : "Show your elves")

                Menu {
                    Button("New elf…") { isShowingNewElfSheet = true }
                    let availableStarterTemplates = elfManager.availableStarterTemplates
                    if !availableStarterTemplates.isEmpty {
                        Divider()
                        ForEach(availableStarterTemplates) { starterTemplate in
                            Button("Add \(starterTemplate.identity.emoji) \(starterTemplate.identity.name)") {
                                addStarterElf(starterTemplate)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerCursor()
                .help("Add an elf")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(elfManager.elves) { elf in
                            ElfSidebarRow(
                                elf: elf,
                                isSelected: elf.id == selectedElfIdentifier,
                                action: { onOpenElf(elf.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: Self.elfListMaximumHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isShowingNewElfSheet) {
            NewElfSheet(elfManager: elfManager, onCreated: { createdElf in onOpenElf(createdElf.id) })
        }
        .alert(
            "Couldn't add that elf",
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
            onOpenElf(createdElf.id)
        } catch {
            addStarterElfErrorMessage = error.localizedDescription
        }
    }
}

/// One elf in the sidebar: its emoji (or a sparkle) and name.
private struct ElfSidebarRow: View {
    let elf: Elf
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if elf.configuration.identity.emoji.isEmpty {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    } else {
                        Text(elf.configuration.identity.emoji)
                            .font(.system(size: 12))
                    }
                }
                .frame(width: 16)

                Text(elf.configuration.identity.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected || isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(isHovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .padding(.horizontal, 10)
    }
}

// MARK: - New elf

/// Name a new elf (with an optional emoji and line about what it's for).
/// The name is checked as it's typed; problems that block it disable Create,
/// a warning (it's the start of another elf's name) only shows.
struct NewElfSheet: View {
    @ObservedObject var elfManager: ElfManager
    let onCreated: (Elf) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""
    @State private var name = ""
    @State private var description = ""
    @State private var createErrorMessage: String?

    private var nameProblems: [ElfNameProblem] {
        ElfNameRules.problems(
            forName: name,
            otherElfNames: ElfNameRules.namesInUse(byElves: elfManager.elves, excludingElfWithIdentifier: nil)
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
            Text("New elf")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Give it a name you'd call it by. You can shape its soul, notes and skills on its page.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canCreate { create() } }
            }
            if let nameProblemMessage {
                Text(nameProblemMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
            TextField("What this elf is for (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
            if let createErrorMessage {
                Text(createErrorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
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
                emoji: ElfNameRules.normalizedEmoji(emoji),
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
/// switching elves builds a fresh editor. An elf that's gone by the time the
/// page opens shows the main elf instead.
struct ElfHubPage: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var elfEditor: ElfEditor
    let onOpenModelSettings: () -> Void
    let onElfDeleted: () -> Void

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

    private var pageTitle: String {
        let identity = elfEditor.elf.configuration.identity
        return identity.emoji.isEmpty ? identity.name : "\(identity.emoji) \(identity.name)"
    }

    private var pageSubtitle: String {
        let trimmedDescription = elfEditor.elf.configuration.identity.description
        if !trimmedDescription.isEmpty { return trimmedDescription }
        return elfEditor.isMainElf ? "Your main elf — the one you talk to." : "One of your elves."
    }

    var body: some View {
        MainAppPage(title: pageTitle, subtitle: pageSubtitle) {
            if !elfEditor.isMainElf {
                Text("You'll be able to talk to \(elfEditor.elf.configuration.identity.name) by name soon. For now you can shape its soul, notes and skills.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ElfSettingsContent(
                companionManager: companionManager,
                elfEditor: elfEditor,
                onOpenModelSettings: onOpenModelSettings,
                onElfDeleted: onElfDeleted
            )
        }
    }
}

struct ElfSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var elfEditor: ElfEditor
    let onOpenModelSettings: () -> Void
    let onElfDeleted: () -> Void

    var body: some View {
        Text("An elf's soul, its notes about you and its skills go to your language model with every question, like the rest of the conversation. They're plain files in its home folder — edit them here or in any text editor.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        ElfIdentitySection(elfEditor: elfEditor)
            .mainAppCard()
        ElfBehaviourSection(elfEditor: elfEditor)
            .mainAppCard()
        ElfModelAndVoiceSummarySection(
            elfEditor: elfEditor,
            mainElfName: companionManager.elfManager.mainElf.configuration.identity.name,
            onOpenModelSettings: onOpenModelSettings
        )
        .mainAppCard()
        ElfMarkdownFileSection(
            title: "Soul",
            fileName: "soul.md",
            explanation: "Instructions this elf follows in every reply. Only you change this file — the elf can suggest changes for you to approve.",
            savedText: elfEditor.soulText,
            characterLimit: ElfHome.soulCharacterLimit,
            editorHeight: 240,
            onSave: { try elfEditor.saveSoul($0) },
            resetButtonTitle: "Reset to the starter soul…",
            resetConfirmationMessage: "This replaces soul.md with the soul a new elf starts with.",
            onReset: { try elfEditor.resetSoulToStarter() }
        )
        .mainAppCard()
        ElfMarkdownFileSection(
            title: "What it knows about you",
            fileName: "profile.md",
            explanation: "Your personal preferences, as this elf noted them. Edit or clear anything. Never shared in an export unless you include it.",
            savedText: elfEditor.profileText,
            characterLimit: ElfHome.profileCharacterLimit,
            editorHeight: 140,
            onSave: { try elfEditor.saveProfile($0) },
            resetButtonTitle: "Clear…",
            resetConfirmationMessage: "This deletes every note in profile.md.",
            onReset: { try elfEditor.clearProfile() }
        )
        .mainAppCard()
        ElfSkillsSection(elfEditor: elfEditor)
            .mainAppCard()
        ElfHomeAndExportSection(companionManager: companionManager, elfEditor: elfEditor)
            .mainAppCard()
        if !elfEditor.isMainElf {
            ElfDeleteSection(elfManager: companionManager.elfManager, elfEditor: elfEditor, onElfDeleted: onElfDeleted)
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

// MARK: - Model and voice

/// Which language model and voice the elf uses. Every elf uses the ones in
/// Settings › Models for now; per-elf choices come with side elves.
private struct ElfModelAndVoiceSummarySection: View {
    @ObservedObject var elfEditor: ElfEditor
    let mainElfName: String
    let onOpenModelSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayerFieldLabel(text: "Model & voice")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(elfEditor.isMainElf
                     ? "Uses your language model and voice from Settings › Models."
                     : "Uses the same model and voice as \(mainElfName) for now.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Settings › Models") { onOpenModelSettings() }
                    .pointerCursor()
            }
        }
    }
}

// MARK: - Delete

/// Deleting a side elf: its folder goes to the Trash, so it can be put back.
private struct ElfDeleteSection: View {
    @ObservedObject var elfManager: ElfManager
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
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
            }
        }
        .confirmationDialog("Delete \(elfName)?", isPresented: $isConfirmingDelete) {
            Button("Delete \(elfName)", role: .destructive) {
                do {
                    try elfManager.deleteElf(withIdentifier: elfEditor.elf.id)
                    onElfDeleted()
                } catch {
                    deleteErrorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("\(elfName) and its folder go to the Trash. You can put the folder back in Elves to restore it.")
        }
    }
}

// MARK: - Identity

private struct ElfIdentitySection: View {
    @ObservedObject var elfEditor: ElfEditor


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Identity")
            HStack(alignment: .top, spacing: 8) {
                ElfCommittingTextField(
                    placeholder: "Emoji",
                    savedText: elfEditor.elf.configuration.identity.emoji,
                    onCommit: { proposedEmoji in
                        try elfEditor.updateEmoji(proposedEmoji)
                        return elfEditor.elf.configuration.identity.emoji
                    }
                )
                .frame(width: 56)
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
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
            ElfCommittingTextField(
                placeholder: "What this elf is for (optional)",
                savedText: elfEditor.elf.configuration.identity.description,
                onCommit: { newDescription in
                    try elfEditor.updateDescription(newDescription)
                    return elfEditor.elf.configuration.identity.description
                }
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Other names it answers to, separated by commas (optional)")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
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
                    .font(.system(size: 12, weight: .medium))
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
                detail: "Lets your elf note your personal preferences in profile.md as you talk.",
                isOn: behaviourToggleBinding(\.takesNotes)
            )
            SettingsToggleRow(
                iconName: "books.vertical",
                title: "Learn skills from our work",
                detail: "Lets your elf save how things are done at work (tools, steps, conventions) as skills.",
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

// MARK: - soul.md / profile.md

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
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Text("\(editedText.count) / \(characterLimit)")
                    .font(.system(size: 10))
                    .foregroundColor(editedText.count > characterLimit ? DS.Colors.warning : DS.Colors.textTertiary)
            }
            Text(explanation)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: Binding(get: { editedText }, set: { draftText = $0 }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: editorHeight)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }

            HStack(spacing: 8) {
                Button("Save") { save() }
                    .disabled(!hasUnsavedChanges)
                    .keyboardShortcut("s", modifiers: .command)
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
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button("New skill") {
                    skillBeingEdited = ElfSkillEditorRequest(skill: ElfSkill(name: "", description: "", body: ""), isNew: true)
                }
                .pointerCursor()
            }
            Text("Working knowledge your elf learned — how things are done at work, your tools, your conventions. Shared in exports.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if elfEditor.skills.isEmpty {
                Text("No skills yet.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            }
            ForEach(elfEditor.skills) { skill in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.system(size: 11))
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            TextField("Name, for example \"Deploying the web app\"", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("One line on what it covers", text: $description)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { elfEditor.revealHomeInFinder() }
                    .pointerCursor()
            }
            HStack(spacing: 8) {
                Text("Its own files (files/): \(elfEditor.elfFileCount) \(elfEditor.elfFileCount == 1 ? "file" : "files")")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Open") { elfEditor.revealFilesInFinder() }
                    .pointerCursor()
            }

            Divider().background(DS.Colors.borderSubtle)

            LayerFieldLabel(text: "Export")
            Text("Save this elf as a .elf file to keep or share. It always has its config, soul.md and skills. Your notes (profile.md) and its files are left out unless you include them. API keys are never exported.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export elf…") { presentExportPanel() }
                    .pointerCursor()
                if let exportMessage {
                    Text(exportMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func presentExportPanel() {
        let exportOptionsModel = ElfExportOptionsModel()
        let savePanel = NSSavePanel()
        savePanel.title = "Export elf"
        savePanel.nameFieldStringValue = ElfExporter.packageBaseName(forElfName: elfEditor.elf.configuration.identity.name) + ".elf"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "elf") ?? .zip]
        savePanel.canCreateDirectories = true
        let accessoryHostingView = NSHostingView(rootView: ElfExportOptionsView(exportOptionsModel: exportOptionsModel))
        accessoryHostingView.frame.size = accessoryHostingView.fittingSize
        savePanel.accessoryView = accessoryHostingView

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }
        do {
            try elfEditor.export(
                to: destinationURL,
                options: exportOptionsModel.options,
                preferredModels: companionManager.preferredModelsForElfExport()
            )
            exportMessage = "Exported to \(destinationURL.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            exportMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// The save panel's two switches, both off by default.
private final class ElfExportOptionsModel: ObservableObject {
    @Published var options = ElfExporter.Options()
}

private struct ElfExportOptionsView: View {
    @ObservedObject var exportOptionsModel: ElfExportOptionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Always included: elf.json, soul.md, skills/")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Toggle("Include profile.md (notes about you)", isOn: $exportOptionsModel.options.includesProfile)
                .toggleStyle(.checkbox)
            Toggle("Include the elf's files (files/)", isOn: $exportOptionsModel.options.includesFiles)
                .toggleStyle(.checkbox)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }
}
