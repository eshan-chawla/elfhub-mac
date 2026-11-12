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

struct ElfSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var elfManager: ElfManager

    var body: some View {
        Text("Your elf's soul, its notes about you and its skills go to your language model with every question, like the rest of the conversation. They're plain files in its home folder — edit them here or in any text editor.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        ElfIdentitySection(elfManager: elfManager)
            .mainAppCard()
        ElfBehaviourSection(elfManager: elfManager)
            .mainAppCard()
        ElfMarkdownFileSection(
            title: "Soul",
            fileName: "soul.md",
            explanation: "Instructions your elf follows in every reply. Only you change this file — the elf can suggest changes for you to approve.",
            savedText: elfManager.soulText,
            characterLimit: ElfHome.soulCharacterLimit,
            editorHeight: 240,
            onSave: { try elfManager.saveSoul($0) },
            resetButtonTitle: "Reset to the starter soul…",
            resetConfirmationMessage: "This replaces soul.md with the soul a new elf starts with.",
            onReset: { try elfManager.resetSoulToStarter() }
        )
        .mainAppCard()
        ElfMarkdownFileSection(
            title: "What it knows about you",
            fileName: "profile.md",
            explanation: "Your personal preferences, as your elf noted them. Edit or clear anything. Never shared in an export unless you include it.",
            savedText: elfManager.profileText,
            characterLimit: ElfHome.profileCharacterLimit,
            editorHeight: 140,
            onSave: { try elfManager.saveProfile($0) },
            resetButtonTitle: "Clear…",
            resetConfirmationMessage: "This deletes every note in profile.md.",
            onReset: { try elfManager.clearProfile() }
        )
        .mainAppCard()
        ElfSkillsSection(elfManager: elfManager)
            .mainAppCard()
        ElfHomeAndExportSection(companionManager: companionManager, elfManager: elfManager)
            .mainAppCard()
            .onAppear { elfManager.reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                elfManager.reload()
            }
    }
}

// MARK: - Identity

private struct ElfIdentitySection: View {
    @ObservedObject var elfManager: ElfManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Identity")
            HStack(spacing: 8) {
                TextField("Emoji", text: identityBinding(\.emoji))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                TextField("Name", text: identityBinding(\.name))
                    .textFieldStyle(.roundedBorder)
            }
            TextField("What this elf is for (optional)", text: identityBinding(\.description))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func identityBinding(_ identityKeyPath: WritableKeyPath<ElfConfiguration.Identity, String>) -> Binding<String> {
        Binding(
            get: { elfManager.configuration.identity[keyPath: identityKeyPath] },
            set: { newValue in elfManager.updateConfiguration { $0.identity[keyPath: identityKeyPath] = newValue } }
        )
    }
}

// MARK: - Behaviour

private struct ElfBehaviourSection: View {
    @ObservedObject var elfManager: ElfManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "How it answers")
            HStack {
                Text("Reply length")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { elfManager.configuration.behaviour.replyLength },
                    set: { newReplyLength in elfManager.updateConfiguration { $0.behaviour.replyLength = newReplyLength } }
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
            TextField("Tone, for example \"calm and encouraging\" (optional)", text: behaviourBinding(\.tone))
                .textFieldStyle(.roundedBorder)
            TextField("Always reply in… (optional, for example \"British English\")", text: behaviourBinding(\.language))
                .textFieldStyle(.roundedBorder)

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

    private func behaviourBinding(_ behaviourKeyPath: WritableKeyPath<ElfConfiguration.Behaviour, String>) -> Binding<String> {
        Binding(
            get: { elfManager.configuration.behaviour[keyPath: behaviourKeyPath] },
            set: { newValue in elfManager.updateConfiguration { $0.behaviour[keyPath: behaviourKeyPath] = newValue } }
        )
    }

    private func behaviourToggleBinding(_ behaviourKeyPath: WritableKeyPath<ElfConfiguration.Behaviour, Bool>) -> Binding<Bool> {
        Binding(
            get: { elfManager.configuration.behaviour[keyPath: behaviourKeyPath] },
            set: { newValue in elfManager.updateConfiguration { $0.behaviour[keyPath: behaviourKeyPath] = newValue } }
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
    @ObservedObject var elfManager: ElfManager
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
                    skillBeingEdited = ElfSkillEditorRequest(skill: ElfSkill(title: "", description: "", body: ""), isNew: true)
                }
                .pointerCursor()
            }
            Text("Working knowledge your elf learned — how things are done at work, your tools, your conventions. Shared in exports.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if elfManager.skills.isEmpty {
                Text("No skills yet.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            }
            ForEach(elfManager.skills) { skill in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.title)
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
            ElfSkillEditorSheet(elfManager: elfManager, skillEditorRequest: skillEditorRequest)
        }
    }
}

private struct ElfSkillEditorRequest: Identifiable {
    let id = UUID()
    let skill: ElfSkill
    let isNew: Bool
}

private struct ElfSkillEditorSheet: View {
    @ObservedObject var elfManager: ElfManager
    let skillEditorRequest: ElfSkillEditorRequest

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var bodyText: String
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    init(elfManager: ElfManager, skillEditorRequest: ElfSkillEditorRequest) {
        self.elfManager = elfManager
        self.skillEditorRequest = skillEditorRequest
        _title = State(initialValue: skillEditorRequest.skill.title)
        _description = State(initialValue: skillEditorRequest.skill.description)
        _bodyText = State(initialValue: skillEditorRequest.skill.body)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(skillEditorRequest.isNew ? "New skill" : "Edit skill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            TextField("Title, for example \"Deploying the web app\"", text: $title)
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
                try? elfManager.deleteSkill(skillEditorRequest.skill)
                dismiss()
            }
        }
    }

    private func save() {
        do {
            try elfManager.saveSkill(
                ElfSkill(title: title, description: description, body: bodyText),
                replacingFileName: skillEditorRequest.isNew ? nil : skillEditorRequest.skill.fileName
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
    @ObservedObject var elfManager: ElfManager
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LayerFieldLabel(text: "Home folder")
            HStack(spacing: 8) {
                Text(elfManager.home.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { elfManager.revealHomeInFinder() }
                    .pointerCursor()
            }
            HStack(spacing: 8) {
                Text("Its own files (files/): \(elfManager.elfFileCount) \(elfManager.elfFileCount == 1 ? "file" : "files")")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Open") { elfManager.revealFilesInFinder() }
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
        savePanel.nameFieldStringValue = ElfExporter.packageBaseName(forElfName: elfManager.configuration.identity.name) + ".elf"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "elf") ?? .zip]
        savePanel.canCreateDirectories = true
        let accessoryHostingView = NSHostingView(rootView: ElfExportOptionsView(exportOptionsModel: exportOptionsModel))
        accessoryHostingView.frame.size = accessoryHostingView.fittingSize
        savePanel.accessoryView = accessoryHostingView

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }
        do {
            try elfManager.export(
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
