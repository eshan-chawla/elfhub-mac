//
//  VisualSnapshotTests.swift
//  elfhubTests
//
//  Renders screens offscreen to PNG files so a change to the look can be
//  checked without running the app or granting Screen Recording: AppKit
//  draws the view hierarchy (real text fields, toggles and pickers) into a
//  bitmap. Skipped unless ELFHUB_SNAPSHOT_DIR is set — pass it to the test
//  runner as TEST_RUNNER_ELFHUB_SNAPSHOT_DIR=/some/folder with xcodebuild.
//

import AppKit
import SwiftUI
import Testing
@testable import elfhub

@MainActor
struct VisualSnapshotTests {

    nonisolated private static var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["ELFHUB_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Hosts `view` in an offscreen window with the given appearance, lets
    /// SwiftUI lay it out and settle, and writes it as a PNG.
    private func writeSnapshot<Content: View>(
        of view: Content,
        named snapshotName: String,
        size: NSSize = NSSize(width: 1000, height: 760),
        appearanceName: NSAppearance.Name
    ) async throws {
        guard let snapshotDirectory = Self.snapshotDirectory else { return }
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        let offscreenWindow = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.appearance = NSAppearance(named: appearanceName)
        offscreenWindow.contentView = hostingView
        offscreenWindow.orderFrontRegardless()
        // Let SwiftUI lay out, load images and run its entrance animation.
        try await Task.sleep(for: .milliseconds(700))
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let appearanceSuffix = appearanceName == .darkAqua ? "dark" : "light"
        try pngData.write(to: snapshotDirectory.appendingPathComponent("\(snapshotName)-\(appearanceSuffix).png"))
        offscreenWindow.orderOut(nil)
    }

    @Test(.enabled(if: VisualSnapshotTests.snapshotDirectory != nil))
    func onboardingSteps() async throws {
        for onboardingStep in OnboardingPane.OnboardingStep.allCases {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                try await writeSnapshot(
                    of: OnboardingPane(companionManager: CompanionManager.shared, initialStep: onboardingStep),
                    named: "onboarding-\(onboardingStep.rawValue)-\(onboardingStep.title.replacingOccurrences(of: " ", with: "-").lowercased())",
                    appearanceName: appearanceName
                )
            }
        }
    }

    @Test(.enabled(if: VisualSnapshotTests.snapshotDirectory != nil))
    func mainWindowPages() async throws {
        let companionManager = CompanionManager.shared
        let pages: [(String, MainAppSection)] = [
            ("chat", .chat),
            ("elf-main", .elf(ElfManager.mainElfIdentifier)),
            ("settings-general", .settings(.general)),
            ("settings-models", .settings(.models)),
            ("settings-tools", .settings(.tools)),
            ("settings-controls", .settings(.controls)),
            ("settings-privacy", .settings(.privacy)),
        ]
        for (pageName, section) in pages {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                try await writeSnapshot(
                    of: MainAppView(companionManager: companionManager, initialSection: section, showsPagesBeforeSetupForSnapshots: true),
                    named: "main-\(pageName)",
                    size: NSSize(width: 1100, height: 760),
                    appearanceName: appearanceName
                )
            }
        }
    }

    @Test(.enabled(if: VisualSnapshotTests.snapshotDirectory != nil))
    func floatingSurfaces() async throws {
        let notepadPanelModel = NotepadPanelModel(secondsBetweenLines: 0)
        notepadPanelModel.open(title: "Rename every file in a folder")
        for markdownLine in ["## In Finder", "1. Select the files", "2. Right-click and choose **Rename…**", "```", "mv old.txt new.txt", "```"] {
            notepadPanelModel.append(markdownLine: markdownLine)
        }
        let approvalClick = ResolvedScreenAction(
            action: .click(screenshotPixel: CGPoint(x: 100, y: 100), label: "Export", screenNumber: nil),
            coreGraphicsTargetPoint: nil,
            appKitTargetPoint: nil,
            displayFrame: nil,
            targetElementFacts: nil,
            frontmostApplicationBundleIdentifier: "com.apple.Numbers",
            consentDecision: .proceedWithPreview,
            consequentialEffect: nil
        )
        let ordinaryApproval = PendingScreenActionConsent(
            resolvedActions: [approvalClick],
            summary: "click “Export” in Numbers",
            includesHighRiskAction: false,
            screenCaptures: [],
            userUtterance: "export this as a pdf"
        )
        let sendApproval = PendingScreenActionConsent(
            resolvedActions: [ResolvedScreenAction(
                action: .click(screenshotPixel: CGPoint(x: 100, y: 100), label: "Send", screenNumber: nil),
                coreGraphicsTargetPoint: nil,
                appKitTargetPoint: nil,
                displayFrame: nil,
                targetElementFacts: nil,
                frontmostApplicationBundleIdentifier: "com.apple.mail",
                consentDecision: .requiresExplicitConfirmation(reason: "this would send something"),
                consequentialEffect: .send
            )],
            summary: "click “Send”",
            includesHighRiskAction: true,
            screenCaptures: [],
            userUtterance: "reply to sam"
        )
        // Action mode on, so the picker shows; put back afterwards (this is
        // the test app's own settings, never the real app's).
        let screenActionCoordinatorForSnapshots = ScreenActionCoordinator()
        let actionModeWasEnabled = screenActionCoordinatorForSnapshots.isActionModeEnabled
        screenActionCoordinatorForSnapshots.setActionModeEnabled(true)
        defer { screenActionCoordinatorForSnapshots.setActionModeEnabled(actionModeWasEnabled) }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            try await writeSnapshot(
                of: VStack(spacing: 0) {
                    ScreenActionApprovalPopupView(
                        pendingConsent: ordinaryApproval,
                        askingElf: CompanionManager.shared.elfManager.mainElf,
                        onGoAhead: {},
                        onCancel: {}
                    )
                    ScreenActionApprovalPopupView(
                        pendingConsent: sendApproval,
                        askingElf: CompanionManager.shared.elfManager.mainElf,
                        onGoAhead: {},
                        onCancel: {}
                    )
                }
                .padding(20)
                .background(Color.gray.opacity(0.35)),
                named: "approval-popup",
                size: NSSize(width: 500, height: 440),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: VStack(alignment: .leading, spacing: 16) {
                    ForEach(ScreenActionExecutionMode.allCases, id: \.self) { executionMode in
                        Text(ScreenActionModeControls.explanation(for: executionMode))
                            .font(DS.Typography.small)
                    }
                    ScreenActionModeControls(coordinator: screenActionCoordinatorForSnapshots, isAccessibilityGranted: true)
                    ComputerUseStepLimitSettingsRow()
                }
                .frame(width: 320)
                .padding(20)
                .background(DS.Colors.background),
                named: "action-mode-controls",
                size: NSSize(width: 360, height: 470),
                appearanceName: appearanceName
            )
            // Settings › Tools & capabilities explains every "Before acting" mode at once.
            try await writeSnapshot(
                of: VStack(alignment: .leading, spacing: 16) {
                    ScreenActionModeControls(
                        coordinator: screenActionCoordinatorForSnapshots,
                        isAccessibilityGranted: true,
                        explainsEveryMode: true
                    )
                }
                .frame(width: 560)
                .padding(20)
                .background(DS.Colors.background),
                named: "action-mode-controls-settings",
                size: NSSize(width: 600, height: 240),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: VStack(alignment: .leading, spacing: 18) {
                    ElevenLabsVoicePicker(
                        voiceDirectory: ElevenLabsVoiceDirectory.shared,
                        selectedVoiceIdentifier: nil,
                        automaticVoiceIdentifier: ElevenLabsVoicePresetCatalog.bundled.mainElfVoice,
                        automaticExplanation: "a natural, helpful voice for elf. Your other Elfs each get a different one",
                        onSelect: { _ in }
                    )
                    ElevenLabsVoicePicker(
                        voiceDirectory: ElevenLabsVoiceDirectory.shared,
                        selectedVoiceIdentifier: "EXAVITQu4vr4xnSDxMaL",
                        automaticVoiceIdentifier: "OZ0L6eISlOejga3XjDFt",
                        onSelect: { _ in },
                        onPreview: { _ in }
                    )
                }
                .padding(20)
                .frame(width: 460)
                .background(DS.Colors.background),
                named: "elevenlabs-voice-picker",
                size: NSSize(width: 460, height: 220),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: ErrorReportView(
                    initialReport: ErrorReportComposer.compose(
                        ErrorReportContext(
                            errorDescription: #"Model API error (400): {"type":"error","error":{"type":"invalid_request_error","message":"messages.16.content.3.tool_result: all content must be type `text` if `is_error` is true"},"request_id":"req_011Ch97VbtYa6aopJvqL9K7L"}"#,
                            errorTypeName: "LanguageModelProviderError.httpError",
                            origin: .voiceTurn,
                            modelDescription: "anthropic · claude-opus-5-5",
                            screenActionsDescription: "on (Ask first)",
                            stackFrames: [
                                "elfhub.CompanionManager.(sendTranscriptToClaudeWithScreenshot in _A1B2)(transcript: Swift.String) -> () + 1840",
                                "elfhub.CompanionManager.handleFinalTranscript(Swift.String) -> () + 412",
                            ],
                            recentLogLines: [
                                "12:14:02.881 [companion] Computer use step 3: 2 calls, acting 412 ms, settling and looking 380 ms, whole step 1204 ms",
                                "12:14:03.120 [companion] loading /Users/[user]/Library/Application Support/elfhub with token=[REDACTED]",
                            ],
                            supportDiagnostics: SupportDiagnostics(appVersion: "0.0.2", appBuildNumber: "14", macOSVersion: "26.1.0")
                        )
                    ),
                    onOpenOnGitHub: { _ in },
                    onDismiss: {}
                ),
                named: "error-report",
                size: NSSize(width: ErrorReportView.width, height: ErrorReportView.height),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: CompanionPanelView(companionManager: CompanionManager.shared),
                named: "menu-bar-panel",
                size: NSSize(width: 360, height: 560),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: FloatingNotepadView(
                    notepadPanelModel: notepadPanelModel,
                    maximumContentHeight: 400,
                    onClose: {},
                    onPreferredHeightChange: { _ in },
                    onHeaderDragChanged: { _ in },
                    onHeaderDragEnded: {}
                ),
                named: "notepad",
                size: NSSize(width: 420, height: 360),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: VStack(spacing: 20) {
                    CompanionStatusPillView(statusPillPhase: .listening, audioPowerLevel: 0.5)
                    CompanionStatusPillView(statusPillPhase: .thinking, audioPowerLevel: 0)
                    LiveCaptionPanel(transcript: {
                        var transcript = LiveCaptionTranscript()
                        transcript.advance(sentence: "Open the Share menu in the top right of the window.", revealedCharacterCount: 52)
                        transcript.advance(sentence: "Then pick Copy link, and paste it into your message to the team.", revealedCharacterCount: 24)
                        return transcript
                    }())
                    LiveCaptionPanel(transcript: {
                        var transcript = LiveCaptionTranscript()
                        for sentence in [
                            "Open the Share menu in the top right of the window.",
                            "Then pick Copy link, and paste it into your message to the team.",
                            "If the menu isn't there, the document may still be saving, so give it a moment and look again.",
                            "When the link is in your message, press Return to send it.",
                        ] {
                            transcript.advance(sentence: sentence, revealedCharacterCount: sentence.count)
                        }
                        return transcript
                    }())
                    CompanionStatusPillView(statusPillPhase: .acting(summary: "step 2 of 15 · clicking Share"), audioPowerLevel: 0)
                }
                .padding(30),
                named: "status-pill",
                size: NSSize(width: 760, height: 560),
                appearanceName: appearanceName
            )
        }
    }

    /// The Elf's pen over a white page, a dark page and an orange one: every
    /// mark must stay readable on all three.
    @Test(.enabled(if: VisualSnapshotTests.snapshotDirectory != nil))
    func elfPenOnDifferentBackgrounds() async throws {
        // AppKit global coordinates, y up: a 700 × 420 "screen" at the origin.
        let screenFrame = CGRect(x: 0, y: 0, width: 700, height: 420)
        let pointer = PlacedPointer(
            appKitGlobalPoint: CGPoint(x: 120, y: 330),
            displayFrame: screenFrame,
            label: "Share",
            highlightedElementFrame: CGRect(x: 90, y: 315, width: 70, height: 26)
        )
        let annotations = [
            PlacedAnnotation(shape: .circle(center: CGPoint(x: 420, y: 320), radius: 40), label: "this one", displayFrame: screenFrame),
            PlacedAnnotation(shape: .highlight(frame: CGRect(x: 80, y: 170, width: 220, height: 50)), label: nil, displayFrame: screenFrame),
            PlacedAnnotation(shape: .arrow(tail: CGPoint(x: 560, y: 120), head: CGPoint(x: 460, y: 200)), label: nil, displayFrame: screenFrame),
            PlacedAnnotation(shape: .underline(start: CGPoint(x: 80, y: 120), end: CGPoint(x: 300, y: 120)), label: nil, displayFrame: screenFrame),
            PlacedAnnotation(shape: .note(anchor: CGPoint(x: 380, y: 100), text: "Pick Copy link, then paste it in the chat."), label: nil, displayFrame: screenFrame),
        ]
        let backgrounds: [(String, Color)] = [("white", .white), ("dark", Color(hex: "#111418")), ("orange", Color(hex: "#F97316"))]
        for (backgroundName, backgroundColor) in backgrounds {
            try await writeSnapshot(
                of: ZStack(alignment: .topLeading) {
                    backgroundColor
                    ForEach(annotations) { annotation in
                        ScreenAnnotationShapeView(placedAnnotation: annotation, screenFrame: screenFrame, animatesAppearance: false)
                    }
                    PointerAtTargetView(placedPointer: pointer, screenFrame: screenFrame, animatesAppearance: false)
                },
                named: "elf-pen-on-\(backgroundName)",
                size: NSSize(width: 700, height: 420),
                appearanceName: .aqua
            )
        }
    }

    /// The main Elf's page, a side Elf's Work view (with its files) and the
    /// settings sheet, with a side Elf and a few files set up in the test
    /// host's throwaway roster.
    /// The real window, title bar included: the window buttons over the
    /// sidebar's top band, no grey strip, the chat title beside them.
    @Test(.enabled(if: VisualSnapshotTests.snapshotDirectory != nil))
    func mainWindowTitleBar() async throws {
        guard let snapshotDirectory = Self.snapshotDirectory else { return }
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let windowSize = NSSize(width: 1100, height: 420)
            let titledWindow = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            MainWindowPresenter.applyContentTitleBar(to: titledWindow)
            titledWindow.appearance = NSAppearance(named: appearanceName)
            let hostingView = NSHostingView(rootView: MainAppView(
                companionManager: CompanionManager.shared,
                initialSection: .chat,
                showsPagesBeforeSetupForSnapshots: true
            ))
            hostingView.safeAreaRegions = []
            titledWindow.contentView = hostingView
            titledWindow.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(700))
            // The theme frame holds the title bar's buttons as well as the content.
            let windowFrameView = try #require(titledWindow.contentView?.superview)
            windowFrameView.layoutSubtreeIfNeeded()
            let bitmap = try #require(windowFrameView.bitmapImageRepForCachingDisplay(in: windowFrameView.bounds))
            windowFrameView.cacheDisplay(in: windowFrameView.bounds, to: bitmap)
            let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
            let appearanceSuffix = appearanceName == .darkAqua ? "dark" : "light"
            try pngData.write(to: snapshotDirectory.appendingPathComponent("main-window-title-bar-\(appearanceSuffix).png"))
            titledWindow.orderOut(nil)
        }
    }

    @Test(.enabled(if: VisualSnapshotTests.snapshotDirectory != nil))
    func elfPages() async throws {
        let companionManager = CompanionManager.shared
        let elfManager = companionManager.elfManager
        let sideElf = try elfManager.elf(withIdentifier: "wren")
            ?? elfManager.createElf(identity: .init(name: "Wren", description: "Looks things up and comes back with sources."))
        try FileManager.default.createDirectory(at: sideElf.home.filesDirectory.appendingPathComponent("research"), withIntermediateDirectories: true)
        try Data("# Flights to Lisbon\n".utf8).write(to: sideElf.home.filesDirectory.appendingPathComponent("research/lisbon-flights.md"))
        try Data("notes".utf8).write(to: sideElf.home.filesDirectory.appendingPathComponent("notes.md"))
        try elfManager.mainElf.home.writeUserNotes("""
        # user
        ## About you
        - builds a Mac app called elfhub
        - prefers short answers
        ## What we've talked about
        - 2026-11-16: renaming files in Finder
        """)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            try await writeSnapshot(
                of: MainAppView(companionManager: companionManager, initialSection: .elf(ElfManager.mainElfIdentifier), showsPagesBeforeSetupForSnapshots: true),
                named: "main-elf-captain",
                size: NSSize(width: 1100, height: 900),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: ElfHubPage(
                    companionManager: companionManager,
                    elfIdentifier: sideElf.id,
                    selectedTab: .constant(.work),
                    onOpenElf: { _ in },
                    onOpenSettings: {},
                    onStartNewChat: {}
                ),
                named: "side-elf-work",
                size: NSSize(width: 860, height: 760),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: ElfSettingsSheet(
                    companionManager: companionManager,
                    elfIdentifier: sideElf.id,
                    onOpenModelSettings: {},
                    onElfDeleted: {}
                ),
                named: "elf-settings-sheet",
                size: NSSize(width: 760, height: 680),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: LanguageModelUsageSettingsSection(usageLedger: Self.sampleUsageLedger())
                    .padding(20)
                    .frame(width: 640, alignment: .topLeading)
                    .background(DS.Colors.surface1),
                named: "usage-and-cost",
                size: NSSize(width: 640, height: 560),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: SupportSheet(),
                named: "support-sheet-shipped",
                size: NSSize(width: 520, height: 760),
                appearanceName: appearanceName
            )
            try await writeSnapshot(
                of: SupportSheet(
                    supportLinks: SupportLinks(
                        gitHubNewIssueURL: SupportLinks.published.gitHubNewIssueURL,
                        websiteReportURL: URL(string: "https://example.com/report"),
                        discordInviteURL: SupportLinks.published.discordInviteURL,
                        supportEmailAddress: SupportLinks.published.supportEmailAddress
                    ),
                    supportDiagnostics: SupportDiagnostics(appVersion: "0.0.2", appBuildNumber: "14", macOSVersion: "26.1.0")
                ),
                named: "support-sheet",
                size: NSSize(width: 520, height: 900),
                appearanceName: appearanceName
            )
        }
    }

    /// A ledger with a month of made-up usage, for the Usage and cost card.
    private static func sampleUsageLedger() -> LanguageModelUsageLedger {
        let usageLedger = LanguageModelUsageLedger(
            storageDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("elfhub-snapshot-usage-\(UUID().uuidString)")
        )
        let claudeConfiguration = ProviderConfiguration(
            kind: .anthropic, displayName: "Claude", baseURL: "https://api.anthropic.com", model: "claude-opus-5-5",
            supportsVision: true, presetIdentifier: "anthropic"
        )
        let groqConfiguration = ProviderConfiguration(
            kind: .openAICompatible, displayName: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-4-scout",
            supportsVision: false, presetIdentifier: "groq"
        )
        let ollamaConfiguration = ProviderConfiguration(
            kind: .openAICompatible, displayName: "Ollama", baseURL: "http://localhost:11434/v1", model: "qwen3-vl:8b",
            supportsVision: true, presetIdentifier: LocalModelServerPreset.ollama.rawValue
        )
        for requestNumber in 0..<40 {
            usageLedger.record(
                usage: LanguageModelUsage(inputTokens: 1_800, outputTokens: 420, cacheReadInputTokens: 14_000, cacheCreationInputTokens: requestNumber % 5 == 0 ? 6_000 : 0),
                webSearchCount: 0,
                configuration: claudeConfiguration,
                category: requestNumber % 4 == 0 ? .screenWork : .chat
            )
        }
        usageLedger.record(usage: LanguageModelUsage(inputTokens: 9_000, outputTokens: 2_200), webSearchCount: 2, configuration: claudeConfiguration, category: .backgroundTask)
        usageLedger.record(usage: LanguageModelUsage(inputTokens: 5_000, outputTokens: 900), webSearchCount: 0, configuration: claudeConfiguration, category: .memory)
        usageLedger.record(usage: LanguageModelUsage(inputTokens: 3_200, outputTokens: 600), webSearchCount: 0, configuration: groqConfiguration, category: .chat)
        usageLedger.record(usage: LanguageModelUsage(inputTokens: 2_400, outputTokens: 500), webSearchCount: 0, configuration: ollamaConfiguration, category: .chat)
        return usageLedger
    }
}
