//
//  NotepadTests.swift
//  elfhubTests
//
//  The notepad: elfhub writes an explanation into a floating window line by
//  line as it speaks ([NOTEPAD:title] + [NOTEPAD_LINE:markdown]), the lines
//  are never spoken, and the whole notepad is saved with the reply.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct NotepadTests {

    // MARK: - Parsing

    @Test func parsesTheTitleAndLinesInOrder() {
        let replyText = """
        here's the setup. [NOTEPAD:python venv][NOTEPAD_LINE:## steps] first make it. \
        [NOTEPAD_LINE:1. `python3 -m venv .venv`] then turn it on. [NOTEPAD_LINE:2. `source .venv/bin/activate`]
        """
        let notepad = NotepadTagParser.notepad(fromResponseText: replyText)
        #expect(notepad?.title == "python venv")
        #expect(notepad?.markdownLines == ["## steps", "1. `python3 -m venv .venv`", "2. `source .venv/bin/activate`"])
    }

    @Test func linesWithoutATitleGetTheDefaultTitle() {
        let notepad = NotepadTagParser.notepad(fromResponseText: "look. [NOTEPAD_LINE:- one thing]")
        #expect(notepad?.title == NotepadTagParser.defaultNotepadTitle)
        #expect(notepad?.markdownLines == ["- one thing"])
    }

    @Test func aReplyWithoutLinesHasNoNotepad() {
        #expect(NotepadTagParser.notepad(fromResponseText: "just talking here.") == nil)
        #expect(NotepadTagParser.notepad(fromResponseText: "a title alone [NOTEPAD:empty]") == nil)
    }

    @Test func linesAreCappedAtTheMaximum() {
        let manyLines = (1...60).map { "[NOTEPAD_LINE:line \($0)]" }.joined()
        let notepad = NotepadTagParser.notepad(fromResponseText: manyLines)
        #expect(notepad?.markdownLines.count == NotepadTagParser.maximumNotepadLines)
        #expect(notepad?.markdownLines.first == "line 1")
    }

    @Test func colonsInsideALineAreKept() {
        let notepad = NotepadTagParser.notepad(fromResponseText: "[NOTEPAD_LINE:step 1: open settings]")
        #expect(notepad?.markdownLines == ["step 1: open settings"])
    }

    @Test func removingTagsLeavesOnlyTheSpokenText() {
        let spokenText = NotepadTagParser.removingNotepadTags(
            from: "first this. [NOTEPAD:steps][NOTEPAD_LINE:- a] then that. [NOTEPAD_LINE:- b]"
        )
        #expect(!spokenText.contains("NOTEPAD"))
        #expect(spokenText.contains("first this."))
        #expect(spokenText.contains("then that."))
    }

    @Test func notepadTagsAndHandwrittenNotesStayApart() {
        // A NOTE annotation is not a notepad line…
        #expect(NotepadTagParser.notepad(fromResponseText: "[NOTE:10,20:off by one]") == nil)
        // …and notepad lines are not NOTE annotations.
        let decodeResult = TagGuidanceDecoder.decode(responseText: "[NOTEPAD_LINE:note this] ok [POINT:none]")
        #expect(decodeResult.annotations.isEmpty)
    }

    @Test func notepadTagsAreRemovedBeforeGuidanceSoATrailingPointStillWorks() {
        let decodeResult = CompanionTurnPipeline.decodeGuidance(
            replyText: "click save. [NOTEPAD_LINE:- press save] [POINT:10,20:save]",
            toolCalls: [],
            usesNativeGuidanceTools: false
        )
        #expect(decodeResult.pointCommand?.label == "save")
        #expect(!decodeResult.spokenText.contains("NOTEPAD"))
    }

    // MARK: - Blocks and copying

    @Test func linesBecomeBlocks() {
        let blocks = NotepadBlock.blocks(fromMarkdownLines: [
            "# Title",
            "### small heading",
            "- a bullet",
            "* another bullet",
            "3. third step",
            "> a quote",
            "---",
            "```",
            "let x = 1",
            "let y = 2",
            "```",
            "plain words",
        ])
        #expect(blocks.map(\.kind) == [
            .heading(level: 1),
            .heading(level: 3),
            .bullet,
            .bullet,
            .numbered(number: "3"),
            .quote,
            .rule,
            .code,
            .paragraph,
        ])
        #expect(blocks[0].text == "Title")
        #expect(blocks[2].text == "a bullet")
        #expect(blocks[4].text == "third step")
        #expect(blocks[7].text == "let x = 1\nlet y = 2")
    }

    @Test func anUnclosedCodeFenceStillShowsItsLines() {
        // While streaming, the closing fence may not have arrived yet.
        let blocks = NotepadBlock.blocks(fromMarkdownLines: ["```", "echo hi"])
        #expect(blocks.map(\.kind) == [.code])
        #expect(blocks.first?.text == "echo hi")
    }

    @Test func plainTextCopyHasNoMarkdownSyntax() {
        let notepad = SavedNotepad(title: "venv", markdownLines: [
            "## steps",
            "1. run **this** command: `python3 -m venv .venv`",
            "- then *activate* it",
            "```",
            "source .venv/bin/activate",
            "```",
        ])
        let plainText = notepad.plainText
        #expect(plainText.hasPrefix("venv"))
        #expect(plainText.contains("1. run this command: python3 -m venv .venv"))
        #expect(plainText.contains("• then activate it"))
        #expect(plainText.contains("source .venv/bin/activate"))
        for markdownSyntax in ["**", "`", "#", "*a"] {
            #expect(!plainText.contains(markdownSyntax))
        }
    }

    @Test func markdownCopyKeepsTheMarkdown() {
        let notepad = SavedNotepad(title: "venv", markdownLines: ["- run **this**"])
        #expect(notepad.markdownText == "# venv\n\n- run **this**")
    }

    // MARK: - In step with speech

    @Test func aLineIsShownWithTheSentenceAfterIt() {
        var segmenter = SpokenSentenceSegmenter()
        let segments = segmenter.append(
            "let's set this up together now. [NOTEPAD:setup][NOTEPAD_LINE:1. make the folder] first you make the folder for it. "
        )
        #expect(segments.map(\.text) == ["let's set this up together now.", "first you make the folder for it."])
        #expect(segments[0].notepadItemsToShowFirst.isEmpty)
        #expect(segments[1].notepadItemsToShowFirst == [.title("setup"), .line("1. make the folder")])
    }

    @Test func notepadTagsAreNeverSpokenEvenWhenSplitAcrossChunks() {
        var segmenter = SpokenSentenceSegmenter()
        var segments = segmenter.append("here is the first step of it all. [NOTEPAD_LI")
        #expect(segments.map(\.text) == ["here is the first step of it all."])
        segments = segmenter.append("NE:- step one] and that's the whole thing done.")
        segments += segmenter.finish()
        #expect(segments.map(\.text) == ["and that's the whole thing done."])
        #expect(segments[0].notepadItemsToShowFirst == [.line("- step one")])
        #expect(SpokenSentenceSegmenter.speakableText(fromPartialResponse: "ok [NOTEPAD_LINE:- half") == "ok ")
    }

    @Test func linesAfterTheLastSentenceComeOutAtTheEnd() {
        var segmenter = SpokenSentenceSegmenter()
        var segments = segmenter.append("i've written the whole list down for you. [NOTEPAD_LINE:- milk][NOTEPAD_LINE:- eggs]")
        segments += segmenter.finish()
        #expect(segments.count == 2)
        #expect(segments[0].text == "i've written the whole list down for you.")
        #expect(segments[1].text.isEmpty)
        #expect(segments[1].notepadItemsToShowFirst == [.line("- milk"), .line("- eggs")])
    }

    @Test func shortSentencesAroundNotepadLinesAreNotJoined() {
        // "text : line : text : line" — each line appears when the sentence
        // before it ends, even when the sentences are short.
        var segmenter = SpokenSentenceSegmenter()
        var segments = segmenter.append("[NOTEPAD:steps]open the app. [NOTEPAD_LINE:- open it] then save. [NOTEPAD_LINE:- save it]")
        segments += segmenter.finish()
        #expect(segments.map(\.text) == ["open the app.", "then save.", ""])
        #expect(segments[0].notepadItemsToShowFirst == [.title("steps")])
        #expect(segments[1].notepadItemsToShowFirst == [.line("- open it")])
        #expect(segments[2].notepadItemsToShowFirst == [.line("- save it")])
    }

    @Test func shortSentencesWithoutALineBetweenThemAreStillJoined() {
        var segmenter = SpokenSentenceSegmenter()
        let segments = segmenter.append("sure. okay. here's the longer one. [NOTEPAD_LINE:- a] next. ")
        #expect(segments.map(\.text) == ["sure. okay. here's the longer one."])
    }

    // MARK: - The window

    @Test func linesThatArriveTogetherAppearOneAtATime() async throws {
        let notepadPanelModel = NotepadPanelModel(secondsBetweenLines: 0.05)
        notepadPanelModel.open(title: "steps")
        notepadPanelModel.append(markdownLine: "- one")
        notepadPanelModel.append(markdownLine: "- two")
        notepadPanelModel.append(markdownLine: "- three")
        #expect(notepadPanelModel.markdownLines == ["- one"])

        try await Task.sleep(for: .milliseconds(500))
        #expect(notepadPanelModel.markdownLines == ["- one", "- two", "- three"])
    }

    @Test func aNewNotepadDropsLinesStillWaitingFromTheOldOne() async throws {
        let notepadPanelModel = NotepadPanelModel(secondsBetweenLines: 0.05)
        notepadPanelModel.open(title: "old")
        notepadPanelModel.append(markdownLine: "- old one")
        notepadPanelModel.append(markdownLine: "- old two")
        notepadPanelModel.open(title: "new")
        notepadPanelModel.append(markdownLine: "- new one")

        try await Task.sleep(for: .milliseconds(300))
        #expect(notepadPanelModel.title == "new")
        #expect(notepadPanelModel.markdownLines == ["- new one"])
    }

    // MARK: - Prompt

    @Test func bothGuidanceEncodingsDescribeTheNotepad() {
        for guidanceEncoding in [CompanionPromptBuilder.GuidanceEncoding.nativeTools, .textTags] {
            let systemPrompt = CompanionPromptBuilder.systemPrompt(
                coordinateConvention: .imagePixels,
                guidanceEncoding: guidanceEncoding,
                includesScreenActions: false
            )
            #expect(systemPrompt.contains("[NOTEPAD:"))
            #expect(systemPrompt.contains("[NOTEPAD_LINE:"))
            #expect(systemPrompt.contains("notepad lines are the exception"))
            #expect(systemPrompt.contains("never write two notepad lines in a row"))
        }
    }

    // MARK: - Chat history

    @Test func theNotepadIsSavedOnTheReply() throws {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "how do i make a venv?", inputSource: .spoken)
        conversation.setText("here's how.", ofMessageWithIdentifier: exchangeIdentifiers.assistantMessageIdentifier)
        let notepad = SavedNotepad(title: "venv", markdownLines: ["1. make it", "2. activate it"])
        conversation.recordNotepad(notepad, assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier)

        let encodedConversation = try ChatConversationStore.makeJSONEncoder().encode(conversation)
        let decodedConversation = try ChatConversationStore.makeJSONDecoder().decode(ChatConversation.self, from: encodedConversation)
        #expect(decodedConversation.messages[1].notepad == notepad)
        #expect(decodedConversation.messages[0].notepad == nil)
    }

    @Test func messagesSavedBeforeNotepadsStillLoad() throws {
        let legacyMessageJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"hi","createdAt":"2026-10-31T10:00:00Z","isError":false}
        """
        let decodedMessage = try ChatConversationStore.makeJSONDecoder()
            .decode(StoredChatMessage.self, from: Data(legacyMessageJSON.utf8))
        #expect(decodedMessage.notepad == nil)
    }

    @Test func theModelRemembersWhatItWroteInTheNotepad() {
        var conversation = ChatConversation()
        let exchangeIdentifiers = conversation.appendExchange(userText: "steps please", inputSource: .typed)
        conversation.setText("here they are.", ofMessageWithIdentifier: exchangeIdentifiers.assistantMessageIdentifier)
        conversation.recordNotepad(
            SavedNotepad(title: "steps", markdownLines: ["1. open it", "2. save it"]),
            assistantMessageIdentifier: exchangeIdentifiers.assistantMessageIdentifier
        )
        let assistantText = conversation.historyTurns(maximumTurnCount: 10).first?.assistantText ?? ""
        #expect(assistantText.hasPrefix("here they are."))
        #expect(assistantText.contains("2. save it"))
        #expect(assistantText.contains("steps"))
    }
}
