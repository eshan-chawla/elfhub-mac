//
//  ElfSettingsViews.swift
//  elfhub
//
//  Settings › Elf: who the elf is (name, how it answers), its soul.md, its
//  notes about the user (profile.md), the skills it learned, its home
//  folder, and exporting it as a `.elf` file.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Elf for the main elf, until the Elves hub gives every elf a
/// page. Owns the editor so it lives as long as the page.
struct MainElfSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var mainElfEditor: ElfEditor

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _mainElfEditor = StateObject(wrappedValue: ElfEditor(editingMainElfOf: companionManager.elfManager))
    }

    var body: some View {
        ElfSettingsContent(companionManager: companionManager, elfEditor: mainElfEditor)
    }
}

struct ElfSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var elfEditor: ElfEditor

    var body: some View {
        Text("Your elf's soul, its notes about you and its skills go to your language model with every question, like the rest of the conversation. They're plain files in its home folder — edit them here or in any text editor.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        ElfIdentitySection(elfEditor: elfEditor)
            .mainAppCard()
        ElfBehaviourSection(elfEditor: elfEditor)
            .mainAppCard()
        ElfMarkdownFileSection(
            title: "Soul",
            fileName: "soul.md",
            explanation: "Instructions your elf follows in every reply. Only you change this file — the elf can suggest changes for you to approve.",
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
            explanation: "Your personal preferences, as your elf noted them. Edit or clear anything. Never shared in an export unless you include it.",
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
            .onAppear { elfEditor.reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                elfEditor.reload()
            }
    }
}

// MARK: - Identity

private struct ElfIdentitySection: View {
    @ObservedObject var elfEditor: ElfEditor

    /// The name as typed; saved through the name rules when the user
    /// presses Return or leaves the field, so a half-typed or clashing name
    /// never reaches elf.json.
    @State private var nameDraft = ""
    @State private var nameProblemMessage: String?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Identity")
            HStack(alignment: .top, spacing: 8) {
                ElfCommittingTextField(
                    placeholder: "Emoji",
                    savedText: elfEditor.elf.configuration.identity.emoji,
                    onCommit: { proposedEmoji in try elfEditor.updateEmoji(proposedEmoji) }
                )
                .frame(width: 56)
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .onSubmit { saveNameDraft() }
                    .onChange(of: isNameFieldFocused) { _, isFocused in
                        if !isFocused { saveNameDraft() }
                    }
            }
            if let nameProblemMessage {
                Text(nameProblemMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
            }
            ElfCommittingTextField(
                placeholder: "What this elf is for (optional)",
                savedText: elfEditor.elf.configuration.identity.description,
                onCommit: { newDescription in try elfEditor.updateDescription(newDescription) }
            )
        }
        .onAppear { nameDraft = elfEditor.elf.configuration.identity.name }
    }

    private func saveNameDraft() {
        guard nameDraft != elfEditor.elf.configuration.identity.name else {
            nameProblemMessage = nil
            return
        }
        do {
            try elfEditor.rename(to: nameDraft)
            nameDraft = elfEditor.elf.configuration.identity.name
            nameProblemMessage = nil
        } catch {
            nameProblemMessage = error.localizedDescription
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
    let onCommit: (String) throws -> Void

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
            try onCommit(draftText)
            errorMessage = nil
            // The saved value may differ from what was typed (trimmed, or
            // only the first emoji kept).
            draftText = savedText
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
                onCommit: { newTone in try elfEditor.updateBehaviour { $0.tone = newTone } }
            )
            ElfCommittingTextField(
                placeholder: "Always reply in… (optional, for example \"British English\")",
                savedText: elfEditor.elf.configuration.behaviour.language,
                onCommit: { newLanguage in try elfEditor.updateBehaviour { $0.language = newLanguage } }
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
