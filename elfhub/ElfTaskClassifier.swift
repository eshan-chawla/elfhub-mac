//
//  ElfTaskClassifier.swift
//  elfhub
//
//  When the user calls a side elf by name, what kind of request it is:
//
//    quick   answer now, in the foreground (and point if it helps)
//    long    say "on it" and do it in the background as a task
//    screen  take the screen and do it there
//
//  Clear phrases decide on their own; anything else is one small model call
//  asked for {"kind": "quick|long|screen"} with about a second to answer.
//  A timeout, an error or an answer that can't be read counts as quick —
//  the user gets an answer either way.
//

import Foundation

nonisolated enum ElfTaskKind: String, Equatable, Sendable {
    case quick
    case long
    case screen
}

enum ElfTaskClassifier {
    /// How long the model gets to answer. A setting only so tests can be
    /// sure an instant answer wins on a busy machine.
    nonisolated(unsafe) static var modelAnswerTimeoutInSeconds: Double = 1.2

    /// Long work, when the request starts with it ("research …", "can you
    /// draft …") — not when it's a word in a question ("explain this draft").
    private static let longWorkLeadingPhrases = [
        "research", "look into", "write up", "draft", "find out", "dig into", "put together", "compile", "write",
    ]
    private static let politeOpenings = ["please", "can you", "could you", "would you", "will you", "i need you to", "go"]
    private static let screenWorkPhrases = [
        "do it", "click", "go to", "fill in", "fill out", "on my screen", "open the", "type it", "press",
    ]
    private static let quickQuestionPhrases = [
        "what's this", "what is this", "what's that", "what is that", "explain", "what does", "where is", "where's",
    ]
    /// Words that point at the screen: a request with them needs the
    /// screenshot, so it's never sent to the background by a shortcut.
    private static let screenPointingWords: Set<String> = ["this", "that", "these", "those", "here"]

    /// The kind decided by clear phrases alone, or nil when a model should
    /// decide. Quick questions come first; long work only when the request
    /// starts with it (or says "in the background") and isn't about
    /// something on screen.
    static func shortcutKind(for requestText: String) -> ElfTaskKind? {
        let requestWords = UtteranceWords.words(in: requestText)
        func containsPhrase(_ phrase: String) -> Bool {
            UtteranceWords.firstIndex(ofPhrase: phrase, in: requestWords) != nil
        }
        if quickQuestionPhrases.contains(where: containsPhrase) { return .quick }
        if containsPhrase("in the background") { return .long }
        let pointsAtTheScreen = requestWords.contains { screenPointingWords.contains($0) }
        let isAQuestion = requestText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        if !pointsAtTheScreen, !isAQuestion, startsWithLongWork(requestWords) { return .long }
        if screenWorkPhrases.contains(where: containsPhrase) { return .screen }
        return nil
    }

    private static func startsWithLongWork(_ requestWords: [String]) -> Bool {
        var remainingWords = requestWords[...]
        var droppedAnOpening = true
        while droppedAnOpening {
            droppedAnOpening = false
            for politeOpening in politeOpenings {
                let openingWords = UtteranceWords.words(in: politeOpening)
                if remainingWords.starts(with: openingWords) {
                    remainingWords = remainingWords.dropFirst(openingWords.count)
                    droppedAnOpening = true
                }
            }
        }
        return longWorkLeadingPhrases.contains { remainingWords.starts(with: UtteranceWords.words(in: $0)) }
    }

    /// The kind in a model's answer, read leniently; quick when unclear.
    static func kind(fromModelAnswer modelAnswer: String) -> ElfTaskKind {
        let loweredAnswer = modelAnswer.lowercased()
        if let kindRange = loweredAnswer.range(of: #""kind"\s*:\s*"(quick|long|screen)""#, options: .regularExpression) {
            let kindText = loweredAnswer[kindRange]
            if kindText.contains("long") { return .long }
            if kindText.contains("screen") { return .screen }
            return .quick
        }
        return .quick
    }

    static let classificationInstruction = """
    you sort requests for an assistant. reply with only json: {"kind": "quick"} if it can be answered right away in a sentence or two (a question, an explanation, pointing at something), {"kind": "long"} if it needs research, writing or several steps that take a while, or {"kind": "screen"} if the user wants something done on their screen (clicking, typing, filling in).
    """

    /// Finishes (with no answer) when the classifier's time is up.
    @concurrent
    nonisolated private static func classifierTimeLimitPassed() async -> ElfTaskKind? {
        try? await Task.sleep(nanoseconds: UInt64(modelAnswerTimeoutInSeconds * 1_000_000_000))
        return nil
    }

    /// Shortcuts first, else one small model call with a short time limit.
    static func classify(requestText: String, languageModelProvider: LanguageModelProvider) async -> ElfTaskKind {
        if let shortcutKind = shortcutKind(for: requestText) { return shortcutKind }
        let classificationRequest = LanguageModelRequest(
            systemPrompt: classificationInstruction,
            userText: requestText,
            maxOutputTokens: 64,
            reasoningEffort: .low
        )
        return await withTaskGroup(of: ElfTaskKind?.self) { taskGroup in
            taskGroup.addTask { @MainActor in
                guard let classificationResponse = try? await languageModelProvider.streamResponse(classificationRequest, onStreamEvent: { _ in }) else {
                    return .quick
                }
                return kind(fromModelAnswer: classificationResponse.text)
            }
            // The time limit runs off the main thread, so a busy main thread
            // can't let a slow answer win the race.
            taskGroup.addTask(operation: classifierTimeLimitPassed)
            let firstResult = await taskGroup.next() ?? nil
            taskGroup.cancelAll()
            return firstResult ?? .quick
        }
    }
}
