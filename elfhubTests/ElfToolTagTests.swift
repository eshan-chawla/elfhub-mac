//
//  ElfToolTagTests.swift
//  elfhubTests
//
//  Models without tool calling save and delete their files (and save a
//  skill when asked) with silent tags. The tags become the same tool calls,
//  are never spoken — a half-written block holds speech back — and such
//  models see their newest notes in the prompt instead of reading them.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfToolTagTests {

    @Test func fileBlocksBecomeWrites() {
        let responseText = "noted. [FILE:files/trip.md]lisbon\nin may[/FILE] anything else? [DELETE_FILE:files/old.md]"
        #expect(ElfToolTags.invocations(fromResponseText: responseText, userAskedToSaveSkill: false) == [
            .writeFile(path: "files/trip.md", content: "lisbon\nin may"),
            .deleteFile(path: "files/old.md"),
        ])
        #expect(ElfToolTags.textWithoutElfTags(responseText) == "noted.  anything else? ")
    }

    @Test func aDeleteTagInsideASavedFileIsTextNotAnAction() {
        let responseText = "saved the how-to. [FILE:files/howto.md]write [DELETE_FILE:files/x.md] to delete x[/FILE]"
        #expect(ElfToolTags.invocations(fromResponseText: responseText, userAskedToSaveSkill: false) == [
            .writeFile(path: "files/howto.md", content: "write [DELETE_FILE:files/x.md] to delete x"),
        ])
    }

    @Test func skillTagsAreIgnoredUnlessAsked() {
        let responseText = "here's the skill. [SKILL:Deploying]run make deploy[/SKILL]"
        #expect(ElfToolTags.invocations(fromResponseText: responseText, userAskedToSaveSkill: false).isEmpty)
        #expect(ElfToolTags.invocations(fromResponseText: responseText, userAskedToSaveSkill: true) == [
            .saveSkill(name: "Deploying", body: "run make deploy"),
        ])
        #expect(!ElfToolTags.textWithoutElfTags(responseText).contains("make deploy"))
    }

    @Test func anUnclosedBlockIsDroppedFromTheText() {
        #expect(ElfToolTags.textWithoutElfTags("saving. [FILE:files/a.md]half written") == "saving. ")
        #expect(ElfToolTags.invocations(fromResponseText: "saving. [FILE:files/a.md]half written", userAskedToSaveSkill: false).isEmpty)
    }

    @Test func tagsInsideNotepadLinesAreNotTools() {
        let responseText = "here's how. [NOTEPAD:Tags][NOTEPAD_LINE:write [DELETE_FILE:files/a.md] to delete] that's it."
        #expect(ElfToolTags.invocations(fromResponseText: responseText, userAskedToSaveSkill: false).isEmpty)
    }

    @Test func silentBlocksAreNeverSpoken() {
        var sentenceSegmenter = SpokenSentenceSegmenter()
        var spokenSentences = sentenceSegmenter.append("i'm saving that for you now. [FILE:files/a.md]secret text here. more secret.[/FILE] all done, it's in your files.")
        spokenSentences += sentenceSegmenter.finish()
        let spokenText = spokenSentences.map(\.text).joined(separator: " ")
        #expect(!spokenText.contains("secret"))
        #expect(spokenText.contains("all done"))
        #expect(!spokenText.contains("[FILE"))
    }

    @Test func anUnclosedBlockHoldsBackSpeechAndIsDroppedAtTheEnd() {
        var sentenceSegmenter = SpokenSentenceSegmenter()
        let spokenWhileOpen = sentenceSegmenter.append("okay, here goes the note now. [FILE:files/a.md]a partial sentence. and another one. ")
        #expect(!spokenWhileOpen.map(\.text).joined().contains("partial"))
        #expect(!sentenceSegmenter.finish().map(\.text).joined().contains("partial"))
        #expect(!SpokenSentenceSegmenter.speakableText(fromPartialResponse: "ok [DELETE_FILE:files/a.md] done").contains("DELETE"))
        #expect(SpokenSentenceSegmenter.speakableText(fromPartialResponse: "ok [FI") == "ok ")
    }

    @Test func tagOnlyModelsSeeTheirNewestNotesWithinTheBudget() throws {
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let home = ElfHome(directory: homeDirectory)
        try home.createIfNeeded()
        let olderNoteURL = home.filesDirectory.appendingPathComponent("older.md")
        try Data(String(repeating: "o", count: ElfPromptBudget.preloadedNotesCharacterLimit).utf8).write(to: olderNoteURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: olderNoteURL.path)
        try Data("lisbon in may".utf8).write(to: home.filesDirectory.appendingPathComponent("trip.md"))
        let preloadedNotes = ElfPromptBudget.preloadedNotes(home: home)
        #expect(preloadedNotes.map(\.path) == ["files/trip.md"])

        var elfPromptContext = ElfPromptContext.starter
        elfPromptContext.ownNotePaths = ["files/trip.md", "files/older.md"]
        elfPromptContext.preloadedNotes = preloadedNotes
        let promptText = elfPromptContext.promptSections.joined(separator: "\n\n")
        #expect(promptText.contains("## files/trip.md\nlisbon in may"))
    }

    @Test func tagOnlyModelsAreToldHowToSaveFiles() {
        let tagSystemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels,
            guidanceEncoding: .textTags,
            includesScreenActions: false,
            includesElfFileTags: true
        )
        #expect(tagSystemPrompt.contains("[FILE:files/"))
        #expect(tagSystemPrompt.contains("[DELETE_FILE:"))
        let toolSystemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: .imagePixels,
            guidanceEncoding: .nativeTools,
            includesScreenActions: false,
            includesElfFileTags: false
        )
        #expect(!toolSystemPrompt.contains("[FILE:"))
    }
}
