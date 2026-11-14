//
//  CompanionTurnPipeline.swift
//  elfhub
//
//  One turn of elfhub, shared by voice and text chat:
//
//    capture screens sized for the active model
//      → model request (native guidance tools, or text tags as a fallback)
//      → decode guidance (point / annotate / act) into ScreenGuidanceCommands
//      → convert coordinates to screenshot pixels
//      → hand actions to the consent gate (ScreenActionCoordinator)
//      → place the pointer and annotations on screen (via CompanionEventBus)
//      → record conversation history
//
//  The reply text streams out through `onReplyTextDelta` as it arrives so the
//  caller can show captions and start speaking immediately. Speech, voice
//  state and the status pill stay with CompanionManager.
//

import Foundation

@MainActor
final class CompanionTurnPipeline {

    struct TurnResult {
        /// Reply text with all guidance stripped — safe to speak or show.
        let spokenText: String
        /// True when an action consent card is waiting for the user.
        let consentCardIsPending: Bool
        /// The screenshot the model saw, as captured — without the user's
        /// ink (nil for text-only models). Chat history keeps it, when the
        /// user turned that on, as the "before" image.
        let originalScreenshotJPEGData: Data?
        /// What the user drew on that screenshot, so the chat can redraw it
        /// for the "after" view. Nil when they didn't draw on that display.
        let shownUserInk: SavedUserInk?
        /// The pointer and marks drawn on that screenshot's display, so the
        /// chat can redraw them over it later. Nil when nothing was drawn.
        let shownScreenGuidance: SavedScreenGuidance?
        /// The notepad this reply wrote (the window stays open on screen),
        /// saved on the reply in chat. Nil when it wrote none.
        let shownNotepad: SavedNotepad?
        /// Files the elf changed in its folder this turn, each undoable.
        var elfFileChanges: [ElfChangeLogEntry] = []
    }

    private let providerConfigurationStore: ProviderConfigurationStore
    private let screenActionCoordinator: ScreenActionCoordinator
    private let companionEventBus: CompanionEventBus

    /// Prior exchanges (tag-stripped), trimmed to the most recent ones.
    private var conversationHistory: [LanguageModelHistoryTurn] = []
    static let maximumHistoryTurns = 10

    /// How many model rounds the main elf gets per turn to use its tools
    /// (usually one is enough).
    static let mainElfMaximumModelRounds = 3

    /// The active elf's part of each prompt (soul, profile, skills…), read
    /// at the start of every turn.
    private let elfPromptContextProvider: () async -> ElfPromptContext

    /// The elf whose tools (its notes, files, skills) this turn may use;
    /// nil gives the model no elf tools.
    private let elfForToolsProvider: () -> Elf?
    private let elfToolRegistry = ElfToolRegistry.standard()

    init(
        providerConfigurationStore: ProviderConfigurationStore,
        screenActionCoordinator: ScreenActionCoordinator,
        companionEventBus: CompanionEventBus,
        elfPromptContextProvider: @escaping () async -> ElfPromptContext = { .starter },
        elfForToolsProvider: @escaping () -> Elf? = { nil }
    ) {
        self.providerConfigurationStore = providerConfigurationStore
        self.screenActionCoordinator = screenActionCoordinator
        self.companionEventBus = companionEventBus
        self.elfPromptContextProvider = elfPromptContextProvider
        self.elfForToolsProvider = elfForToolsProvider
    }

    func clearConversationHistory() {
        conversationHistory.removeAll()
    }

    /// Continues from a saved chat: the model sees its recent exchanges as
    /// the conversation so far.
    func replaceConversationHistory(with historyTurns: [LanguageModelHistoryTurn]) {
        conversationHistory = Array(historyTurns.suffix(Self.maximumHistoryTurns))
    }

    /// Captures the display the cursor is on at the size the model that will
    /// answer wants (the ChatGPT plan's fallback while the plan can't).
    /// Called at push-to-talk key-down so the screenshot is ready before the
    /// user finishes speaking.
    func captureCursorScreenForActiveModel() async throws -> [CompanionScreenCapture] {
        let visionProfile = providerConfigurationStore.configurationForNextTurn()?.visionProfile
            ?? .genericVisionModel(coordinateConvention: .imagePixels)
        return try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(visionProfile: visionProfile)
    }

    // MARK: - Turn

    /// - Parameter onLanguageModelSwitched: called when the ChatGPT plan
    ///   can't answer and the turn starts over on the fallback model (the
    ///   caller drops what streamed so far), and when the plan answers again
    ///   after a stretch on the fallback.
    func runTurn(
        userText: String,
        prefetchedScreenCaptures: [CompanionScreenCapture]?,
        userInkStrokes: [UserInkStroke] = [],
        isSpokenTurn: Bool = false,
        onReplyTextDelta: @escaping @MainActor @Sendable (String) -> Void,
        onModelRoundEnded: @escaping @MainActor () -> Void = {},
        onLanguageModelSwitched: @escaping @MainActor (LanguageModelSwitchNotice) -> Void = { _ in }
    ) async throws -> TurnResult {
        // Kept across the fallback restart below, so a file the first try
        // already saved isn't saved twice.
        let turnEffectLedger = ElfTurnEffectLedger()
        let elfForTools = elfForToolsProvider()
        // This turn replaces whatever the previous one was doing on screen,
        // and only this turn's actions may run from now on.
        let screenActionTurnToken = screenActionCoordinator.beginTurn()

        guard let turnConfiguration = providerConfigurationStore.configurationForNextTurn() else {
            throw LanguageModelProviderError.missingConfiguration("add a model in Settings, under Models")
        }

        var screenCaptures: [CompanionScreenCapture]
        if let prefetchedScreenCaptures, !prefetchedScreenCaptures.isEmpty {
            screenCaptures = prefetchedScreenCaptures
        } else {
            screenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(
                visionProfile: turnConfiguration.visionProfile
            )
        }
        try Task.checkCancellation()

        do {
            let turnResult = try await runModelPartOfTurn(
                languageModelProvider: try providerConfigurationStore.makeProvider(for: turnConfiguration),
                userText: userText,
                screenCaptures: screenCaptures,
                userInkStrokes: userInkStrokes,
                isSpokenTurn: isSpokenTurn,
                screenActionTurnToken: screenActionTurnToken,
                elfToolContextForTurn: elfForTools,
                turnEffectLedger: turnEffectLedger,
                onReplyTextDelta: onReplyTextDelta,
                onModelRoundEnded: onModelRoundEnded
            )
            if turnConfiguration.kind == .chatGPTPlan, providerConfigurationStore.chatGPTPlanUnavailableSince != nil {
                providerConfigurationStore.clearChatGPTPlanUnavailable()
                onLanguageModelSwitched(.returnedToChatGPTPlan)
            }
            return turnResult
        } catch {
            let fallbackConfiguration = providerConfigurationStore.fallbackConfiguration
            guard let fallbackConfigurationForThisTurn = Self.fallbackConfiguration(
                afterFailure: error,
                of: turnConfiguration,
                fallbackConfiguration: fallbackConfiguration,
                isFallbackReady: fallbackConfiguration.map(providerConfigurationStore.isReady) ?? false
            ), let planUsageError = error as? ChatGPTPlanUsageError else {
                throw error
            }
            try Task.checkCancellation()
            if let pauseReason = Self.chatGPTPlanPauseReason(afterFailure: planUsageError) {
                // Later turns go to the fallback too; the plan is tried
                // again on a new turn an hour from now.
                providerConfigurationStore.recordChatGPTPlanUnavailable(reason: pauseReason)
            }
            onLanguageModelSwitched(.switchedToFallback(
                fallbackModelName: fallbackConfigurationForThisTurn.displayName,
                reason: planUsageError
            ))

            // Same screenshot when it's within the fallback's image limits;
            // otherwise a new one sized for it (an oversized image would be
            // shrunk by the provider and the coordinates would drift).
            let fallbackVisionProfile = fallbackConfigurationForThisTurn.visionProfile
            let screenCapturesFitTheFallback = screenCaptures.allSatisfy { screenCapture in
                ScreenshotGeometry.imageFits(
                    widthInPixels: screenCapture.screenshotWidthInPixels,
                    heightInPixels: screenCapture.screenshotHeightInPixels,
                    profile: fallbackVisionProfile
                )
            }
            if !screenCapturesFitTheFallback {
                screenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(visionProfile: fallbackVisionProfile)
                try Task.checkCancellation()
            }
            return try await runModelPartOfTurn(
                languageModelProvider: try providerConfigurationStore.makeProvider(for: fallbackConfigurationForThisTurn),
                userText: userText,
                screenCaptures: screenCaptures,
                userInkStrokes: userInkStrokes,
                isSpokenTurn: isSpokenTurn,
                screenActionTurnToken: screenActionTurnToken,
                elfToolContextForTurn: elfForTools,
                turnEffectLedger: turnEffectLedger,
                onReplyTextDelta: onReplyTextDelta,
                onModelRoundEnded: onModelRoundEnded
            )
        }
    }

    /// The model that should answer this turn after `failure`, or nil to let
    /// the failure stand. Only a ChatGPT-plan problem (its usage limit,
    /// eligibility, availability or sign-in) moves the turn, and only to a
    /// ready fallback that isn't the plan itself.
    nonisolated static func fallbackConfiguration(
        afterFailure failure: Error,
        of failedConfiguration: ProviderConfiguration,
        fallbackConfiguration: ProviderConfiguration?,
        isFallbackReady: Bool
    ) -> ProviderConfiguration? {
        guard failedConfiguration.kind == .chatGPTPlan,
              let planUsageError = failure as? ChatGPTPlanUsageError,
              planUsageError.switchesToFallbackModel,
              let fallbackConfiguration,
              isFallbackReady,
              fallbackConfiguration.kind != .chatGPTPlan else {
            return nil
        }
        return fallbackConfiguration
    }

    /// Whether a ChatGPT-plan failure pauses the plan for an hour. Only the
    /// usage limit and an ineligible plan do: they won't clear in a moment.
    /// A brief outage or a sign-in problem moves just this turn.
    nonisolated static func chatGPTPlanPauseReason(afterFailure failure: Error) -> ChatGPTPlanUnavailableReason? {
        switch failure as? ChatGPTPlanUsageError {
        case .usageLimitReached: return .usageLimitReached
        case .notEligible: return .notEligible
        default: return nil
        }
    }

    /// Everything after the screenshot: ink, prompt, model, guidance,
    /// actions and history. Runs once, or twice when the ChatGPT plan hands
    /// the turn to the fallback model.
    private func runModelPartOfTurn(
        languageModelProvider: LanguageModelProvider,
        userText: String,
        screenCaptures capturedScreenCaptures: [CompanionScreenCapture],
        userInkStrokes: [UserInkStroke],
        isSpokenTurn: Bool,
        screenActionTurnToken: ScreenActionTurnToken,
        elfToolContextForTurn: Elf?,
        turnEffectLedger: ElfTurnEffectLedger,
        onReplyTextDelta: @escaping @MainActor @Sendable (String) -> Void,
        onModelRoundEnded: @escaping @MainActor () -> Void
    ) async throws -> TurnResult {
        let capabilities = languageModelProvider.capabilities
        let coordinateConvention = capabilities.visionProfile.coordinateConvention
        var screenCaptures = capturedScreenCaptures

        // What the user drew while talking goes into the screenshot itself
        // (the only copy kept) and into words, so "this" can be resolved.
        // The screenshot was taken without elfhub's overlay, so the live
        // trail isn't in it — the ink is drawn in here instead.
        var userTextForModel = userText
        let originalScreenshotJPEGData = capabilities.supportsVision ? screenCaptures.first?.imageData : nil
        var shownUserInk: SavedUserInk?
        if capabilities.supportsVision, !userInkStrokes.isEmpty, let cursorScreenCapture = screenCaptures.first {
            let strokesInScreenshotPixels = UserInkScreenshotRenderer.strokesInScreenshotPixels(userInkStrokes, on: cursorScreenCapture)
            let pixelsPerPoint = CGFloat(cursorScreenCapture.screenshotWidthInPixels) / CGFloat(max(cursorScreenCapture.displayWidthInPoints, 1))
            if !strokesInScreenshotPixels.isEmpty,
               let inkedScreenshotJPEGData = UserInkScreenshotRenderer.drawing(
                strokesInScreenshotPixels,
                ontoScreenshotJPEG: cursorScreenCapture.imageData,
                lineWidthInPixels: max(3, UserInkAppearance.inkLineWidthInPoints * pixelsPerPoint)
               ) {
                screenCaptures[0] = cursorScreenCapture.replacingImageData(inkedScreenshotJPEGData)
                shownUserInk = SavedUserInk(userInkStrokes: userInkStrokes, displayFrame: cursorScreenCapture.displayFrame)
                if let userInkPromptNote = UserInkDescriber.promptNote(
                    forStrokesInScreenshotPixels: strokesInScreenshotPixels,
                    convention: coordinateConvention,
                    sentImageSize: cursorScreenCapture.sentImageSize
                ) {
                    userTextForModel += "\n\n" + userInkPromptNote
                }
            }
        }

        // Label each image with its coordinate space so the model answers in
        // the same space we convert back from. Text-only models get no images.
        let imagesForModel: [LanguageModelImage] = capabilities.supportsVision
            ? screenCaptures.map { capture in
                LanguageModelImage(
                    data: capture.imageData,
                    label: capture.label + coordinateConvention.screenshotLabelSuffix(
                        sentImageWidthInPixels: capture.screenshotWidthInPixels,
                        sentImageHeightInPixels: capture.screenshotHeightInPixels
                    )
                )
            }
            : []

        let usesNativeGuidanceTools = capabilities.supportsToolCalling
        let isActionModeEnabled = screenActionCoordinator.isActionModeEnabled
        let guidanceTools = usesNativeGuidanceTools
            ? GuidanceToolDefinitions.toolDefinitions(includingScreenActions: isActionModeEnabled)
            : []
        let elfToolDefinitions = usesNativeGuidanceTools
            ? elfToolContextForTurn.map { elfRegistryElf in
                elfToolRegistry.toolDefinitions(for: .mainForeground, configuration: elfRegistryElf.configuration)
            } ?? []
            : []
        let systemPrompt = CompanionPromptBuilder.systemPrompt(
            coordinateConvention: coordinateConvention,
            guidanceEncoding: usesNativeGuidanceTools ? .nativeTools : .textTags,
            includesScreenActions: isActionModeEnabled,
            elfPromptContext: await elfPromptContextProvider()
        )

        let initialRequest = LanguageModelRequest(
            systemPrompt: systemPrompt,
            history: conversationHistory,
            userText: userTextForModel,
            images: imagesForModel,
            tools: guidanceTools + elfToolDefinitions,
            reasoningEffort: Self.reasoningEffort(isActionModeEnabled: isActionModeEnabled, isSpokenTurn: isSpokenTurn)
        )
        // The model may use its tools (its notes, files and skills) over a
        // few rounds; guidance calls from every round are drawn once below.
        let elfToolContext = elfToolContextForTurn.map { elfToolSetup in
            ElfToolContext(
                elf: elfToolSetup,
                changeLog: ElfChangeLog(home: elfToolSetup.home),
                origin: .turn(conversationIdentifier: nil),
                userUtterance: userText,
                // The screenshot is the user's own view, sent every turn with
                // them watching, so it isn't counted; files and web pages the
                // elf reads are (see the tools).
                influencedBy: [],
                turnEffectLedger: turnEffectLedger
            )
        }
        let agentLoopResult = try await ElfAgentLoop.run(
            initialRequest: initialRequest,
            languageModelProvider: languageModelProvider,
            toolRegistry: elfToolRegistry,
            toolContext: elfToolContext,
            guidanceToolNames: GuidanceToolDefinitions.toolNames,
            maximumRounds: usesNativeGuidanceTools ? Self.mainElfMaximumModelRounds : 1,
            onReplyTextDelta: onReplyTextDelta,
            onModelRoundEnded: onModelRoundEnded
        )
        try Task.checkCancellation()

        let replyText = agentLoopResult.replyText
        let toolCalls = agentLoopResult.guidanceToolCalls

        let guidanceDecodeResult = Self.decodeGuidance(
            replyText: replyText,
            toolCalls: toolCalls,
            usesNativeGuidanceTools: usesNativeGuidanceTools
        )
        let spokenText = guidanceDecodeResult.spokenText
        let shownNotepad = NotepadTagParser.notepad(fromResponseText: replyText)

        // Bring every coordinate into the sent screenshot's pixel space.
        let screenshotPixelDecodeResult = GuidanceDecodeResult(
            spokenText: spokenText,
            commands: guidanceDecodeResult.commands.map { command in
                ScreenGuidanceCoordinateNormalizer.convertToScreenshotPixels(
                    command,
                    convention: coordinateConvention,
                    sentImageSizeForScreenNumber: { screenNumber in
                        CompanionScreenCapture.targetCapture(screenNumber: screenNumber, in: screenCaptures)?.sentImageSize
                    }
                )
            },
            pointLabel: guidanceDecodeResult.pointLabel
        )

        // Actions go through the consent gate (only if action mode is on). It
        // owns the pointer when it shows an action target.
        let coordinatorTookOverActions = await screenActionCoordinator.handleParsedActions(
            screenshotPixelDecodeResult.actions,
            screenCaptures: screenCaptures,
            userUtterance: userText,
            turnToken: screenActionTurnToken
        )

        let placedGuidance = await placeGuidance(
            from: screenshotPixelDecodeResult,
            screenCaptures: screenCaptures,
            includePointer: !coordinatorTookOverActions
        )

        // The notepad window isn't in screenshots, so the model remembers
        // what it wrote there through its history.
        let assistantTextForHistory = Self.assistantTextForHistory(
            spokenText: spokenText,
            notepad: shownNotepad,
            toolOutcomes: agentLoopResult.toolOutcomes
        )
        conversationHistory.append(LanguageModelHistoryTurn(userText: userText, assistantText: assistantTextForHistory))
        if conversationHistory.count > Self.maximumHistoryTurns {
            conversationHistory.removeFirst(conversationHistory.count - Self.maximumHistoryTurns)
        }

        return TurnResult(
            spokenText: spokenText,
            consentCardIsPending: screenActionCoordinator.pendingConsent != nil,
            originalScreenshotJPEGData: originalScreenshotJPEGData,
            shownUserInk: shownUserInk,
            shownScreenGuidance: capabilities.supportsVision
                ? screenCaptures.first.flatMap { sentCapture in
                    SavedScreenGuidance(
                        pointer: placedGuidance.pointer,
                        annotations: placedGuidance.annotations,
                        displayFrame: sentCapture.displayFrame
                    )
                }
                : nil,
            shownNotepad: shownNotepad,
            elfFileChanges: agentLoopResult.toolOutcomes.flatMap(\.fileChanges)
        )
    }

    /// What the model remembers of its reply: what it said, the notepad it
    /// wrote (the window isn't in screenshots), and a footnote of what it
    /// changed ("(you saved files/trip.md)") — so the history stays one
    /// plain exchange per turn, without the tool calls.
    static func assistantTextForHistory(
        spokenText: String,
        notepad: SavedNotepad?,
        toolOutcomes: [ElfToolOutcome]
    ) -> String {
        var assistantTextForHistory = notepad.map { spokenText + "\n\n" + $0.textForConversationHistory } ?? spokenText
        let chatNotes = toolOutcomes.flatMap(\.chatNotes)
        if !chatNotes.isEmpty {
            assistantTextForHistory += "\n\n(you " + chatNotes.joined(separator: "; ") + ")"
        }
        return assistantTextForHistory
    }

    /// Speed versus depth for this turn, on models that support it. A spoken
    /// question wants a quick answer, so it thinks less. When the reply may
    /// act on the screen, the balanced default is asked for explicitly so it
    /// never drops below it. Typed chat keeps the model's own default.
    nonisolated static func reasoningEffort(isActionModeEnabled: Bool, isSpokenTurn: Bool) -> LanguageModelReasoningEffort? {
        if isActionModeEnabled { return .medium }
        if isSpokenTurn { return .low }
        return nil
    }

    /// Tool calls are the primary channel when enabled, but a model may still
    /// write a tag in its text; both are decoded and merged (the tool's pointer
    /// wins), and tags never reach speech either way. Notepad tags are
    /// removed first, so a [POINT] at the very end still counts as the end.
    nonisolated static func decodeGuidance(
        replyText: String,
        toolCalls: [LanguageModelToolCall],
        usesNativeGuidanceTools: Bool
    ) -> GuidanceDecodeResult {
        let replyTextWithoutNotepad = NotepadTagParser.removingNotepadTags(from: replyText)
        let tagDecodeResult = TagGuidanceDecoder.decode(responseText: replyTextWithoutNotepad)
        guard usesNativeGuidanceTools else { return tagDecodeResult }

        let toolDecodeResult = ToolCallGuidanceDecoder.decode(responseText: tagDecodeResult.spokenText, toolCalls: toolCalls)
        let toolProvidedPointer = toolDecodeResult.pointCommand != nil
        let tagCommandsToKeep = tagDecodeResult.commands.filter { command in
            if case .point = command { return !toolProvidedPointer }
            return true
        }
        return GuidanceDecodeResult(
            spokenText: tagDecodeResult.spokenText,
            commands: toolDecodeResult.commands + tagCommandsToKeep,
            pointLabel: toolDecodeResult.pointLabel ?? tagDecodeResult.pointLabel
        )
    }

    /// Places the pointer and annotations on their screens, hands them to
    /// the overlay, and returns them so chat history can redraw them later.
    @discardableResult
    private func placeGuidance(
        from guidanceDecodeResult: GuidanceDecodeResult,
        screenCaptures: [CompanionScreenCapture],
        includePointer: Bool
    ) async -> (pointer: PlacedPointer?, annotations: [PlacedAnnotation]) {
        var placedPointer: PlacedPointer?
        if includePointer,
           let pointCommand = guidanceDecodeResult.pointCommand,
           let targetCapture = CompanionScreenCapture.targetCapture(screenNumber: pointCommand.screenNumber, in: screenCaptures) {
            placedPointer = await ScreenGuidancePlacement.placePointer(
                atScreenshotPixel: pointCommand.point,
                label: pointCommand.label,
                on: targetCapture
            )
        }

        var placedAnnotations: [PlacedAnnotation] = []
        for annotation in guidanceDecodeResult.annotations {
            guard let targetCapture = CompanionScreenCapture.targetCapture(screenNumber: annotation.screenNumber, in: screenCaptures) else {
                continue
            }
            placedAnnotations.append(await ScreenGuidancePlacement.placeAnnotation(annotation, on: targetCapture))
        }

        print("🎯 Guidance: pointer \(placedPointer == nil ? "none" : "\"\(guidanceDecodeResult.pointLabel ?? "element")\""), \(placedAnnotations.count) annotation(s)")

        guard placedPointer != nil || !placedAnnotations.isEmpty else { return (nil, []) }
        companionEventBus.emit(.guidancePlaced(pointer: placedPointer, annotations: placedAnnotations))
        return (placedPointer, placedAnnotations)
    }
}

// MARK: - Prompt

enum CompanionPromptBuilder {

    enum GuidanceEncoding {
        /// Guidance via point_at / annotate / perform_screen_action tool calls.
        case nativeTools
        /// Guidance via [POINT:...] style tags written in the reply.
        case textTags
    }

    static func systemPrompt(
        coordinateConvention: ModelCoordinateConvention,
        guidanceEncoding: GuidanceEncoding,
        includesScreenActions: Bool,
        elfPromptContext: ElfPromptContext = .starter
    ) -> String {
        // Who the elf is (its name, soul.md, settings, profile.md, skills)
        // comes first; the mechanics below are the app's and stay fixed.
        var promptSections = elfPromptContext.promptSections
        promptSections.append("coordinates:\n" + coordinateConvention.systemPromptCoordinateDescription)
        switch guidanceEncoding {
        case .nativeTools:
            promptSections.append(toolGuidanceInstructions)
            if includesScreenActions {
                promptSections.append(toolActionInstructions)
            }
        case .textTags:
            promptSections.append(tagGuidanceInstructions)
            if includesScreenActions {
                promptSections.append(tagActionInstructions)
            }
        }
        // Tags for every model: tool calls arrive only after the reply has
        // streamed, and notepad lines must appear while elfhub is talking.
        promptSections.append(notepadInstructions)
        return promptSections.joined(separator: "\n\n")
    }

    private static let whenToPointAndAnnotate = """
    pointing: you can point at things on screen — a pointer appears right on the element with a short label. point whenever it genuinely helps — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app. err on the side of pointing when there's a specific relevant element; don't point for general knowledge questions or at something obvious they're already looking at.

    annotating: you can also draw on the screen to make an explanation concrete — box a region, circle something, draw an arrow, underline text, or write a short handwritten note. use these when they genuinely help: comparing two things, marking several spots, showing where to look in a dense area, or leaving a short reminder next to something. one to three marks is usually plenty. put notes in empty space near what they describe, not on top of it, and keep them under about six words.
    """

    private static let toolGuidanceInstructions = """
    \(whenToPointAndAnnotate)

    how: always write your full spoken reply as normal text first, then use the tools. call point_at at most once, for the single most relevant element. call annotate once per mark. never call a tool without also replying in words, and never describe the tool calls out loud — they're silent.
    """

    private static let tagGuidanceInstructions = """
    \(whenToPointAndAnnotate)

    how: guidance is written as silent tags in your reply.
    - to point, append [POINT:x,y:label] at the very end of your reply, AFTER your spoken text. label is a short 1-3 word name like "save button". if pointing wouldn't help, append [POINT:none].
    - annotation tags can go anywhere in the reply:
      [HIGHLIGHT:x1,y1,x2,y2:label] box the region between two opposite corners
      [CIRCLE:x,y,r:label] circle around a point, r is the radius in the same units
      [ARROW:x1,y1,x2,y2:label] arrow from x1,y1 pointing at x2,y2
      [UNDERLINE:x1,y1,x2,y2] underline from left end to right end
      [NOTE:x,y:a few words] handwritten note whose top-left is at x,y

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks why their two totals differ: "this one includes tax and that one doesn't, which is the whole gap. [HIGHLIGHT:220,400,380,430:with tax][HIGHLIGHT:220,520,380,550:no tax][POINT:none]"
    - user asks where the bug is: "line forty two reads the array one past its end. [UNDERLINE:120,610,540,610][NOTE:560,600:off by one][POINT:none]"
    """

    private static let notepadInstructions = """
    notepad: when something is much easier to follow written down — steps to follow, a command or a bit of code, a formula, a short comparison — you can write it in a notepad window that appears on the user's screen and stays until they close it. most replies don't need one; use it only when writing genuinely helps.

    how: the notepad is written with silent tags inside your reply, even if you use tools for pointing.
    - open it with [NOTEPAD:short title] and then write one line per tag with [NOTEPAD_LINE:the line]
    - alternate strictly: a spoken sentence, then the one notepad line it introduces, then the next spoken sentence, then the next line — text, line, text, line. each line appears on screen the moment you finish the sentence before it, so the user watches the notepad fill in as you talk.
    - never write two notepad lines in a row, and never write the notepad all at once at the start or the end. the only exception is a code block: its ``` lines and the code lines inside it may come together.
    - lines are markdown: "# heading", "## smaller heading", "- bullet", "1. numbered step", "> quote", "---", lines of ``` around code, and **bold**, *italic*, `code` inside a line
    - never put a ] inside a line. one notepad per reply, at most \(NotepadTagParser.maximumNotepadLines) lines.
    - don't read the notepad out word for word — talk around it, the way a teacher explains what they're writing on a whiteboard.

    example: "sure, here's how to set up a virtual environment. [NOTEPAD:python venv] first you create it inside your project folder. [NOTEPAD_LINE:1. create it: `python3 -m venv .venv`] then you turn it on, and your prompt will show its name. [NOTEPAD_LINE:2. turn it on: `source .venv/bin/activate`] anything you install from now on stays inside that project. [NOTEPAD_LINE:3. install into it: `pip install requests`]"
    """

    private static let whenToAct = """
    taking action: besides pointing and annotating, you can actually control the screen — click, double-click, type, press shortcuts, and scroll. only do this when the user clearly asks you to DO something ("click that", "type my email", "save this", "scroll down"). if they're only asking how or where, point instead — never act just because something is on screen. context is not consent; the user's words are.

    the user sees a pointer on each target before it fires and can press esc to stop you. never take destructive or outbound actions on your own — deleting, sending, buying, or overwriting something they didn't ask you to touch. never type passwords or other secrets; ask the user to do that part. if they explicitly ask for something risky, say out loud exactly what you're about to do first. prefer pointing over acting when unsure.
    """

    private static let toolActionInstructions = """
    \(whenToAct)

    how: call perform_screen_action once per action, in the order they should happen — for example click the field, then type, then press return. keep your spoken sentence natural; the actions are silent.
    """

    private static let tagActionInstructions = """
    \(whenToAct)

    how: emit action tags anywhere in your reply; they use the same coordinates as POINT.
    - [CLICK:x,y:label] single-click an element
    - [DOUBLECLICK:x,y:label] double-click
    - [SCROLL:x,y:up|down|left|right] scroll at a point
    - [TYPE:the literal text] type into whatever is focused
    - [KEY:cmd+s] press a shortcut (cmd, shift, opt, ctrl + a key; or return/tab/esc/arrows)
    you may chain a few in order: "sure, filling that in [CLICK:640,300:email field][TYPE:me@example.com][KEY:return]"
    """
}
