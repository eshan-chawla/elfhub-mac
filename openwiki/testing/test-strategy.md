---
type: testing-strategy
title: Test Strategy
description: The Swift Testing suites in elfhubTests, the pure seams each one pins down (provider wire formats, guidance decoding, geometry, consent, speech segmentation, the notepad, chat storage, the user's ink, capture selection, navigation), how to run them, and what still needs manual checking.
tags: [testing, swift-testing, unit-tests, coverage, validation, manual-testing]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-08b21f75ac60cac755d66137
    resource: repo://elfhub.xcodeproj/xcshareddata/xcschemes/elfhub-OnlyUnitTest.xcscheme
  - id: openwiki-source-888736c01a215aa6f045cc28
    resource: repo://elfhub/ScreenActionCoordinator.swift
  - id: openwiki-source-a4a5525295afe00eb6cc19c4
    resource: repo://elfhub/ScreenActionSynthesizer.swift
  - id: openwiki-source-6d3e0b655528ad0f1ac9cf0c
    resource: repo://elfhubTests/elfhubTests.swift
  - id: openwiki-source-c5af4805eacab0baec8d9709
    resource: repo://elfhubTests/LanguageModelProviderTests.swift
  - id: openwiki-source-dd05161b0f323fe9174b7a22
    resource: repo://elfhubTests/NotepadTests.swift
  - id: openwiki-source-c398cbe12705f601b002bcf8
    resource: repo://elfhubTests/ScreenActionParsingTests.swift
  - id: openwiki-source-fa2a2d885981a4afacbc8d74
    resource: repo://elfhubUITests/elfhubUITests.swift
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# Test Strategy

Every automated test lives in `elfhubTests/` and uses Swift Testing (`import Testing`, `@Test`, `#expect`). The approach is to pull each decision out into a pure function or value type, and test that. Code that touches TCC, event taps, ScreenCaptureKit, sockets or real windows is checked by hand in a running build.

## Running

- Run tests from Xcode with the `elfhub` scheme, or with `elfhub-OnlyUnitTest`, which runs only `elfhubTests`.
<!-- openwiki: broken internal link [/openwiki/operations/local-development-and-permissions.md] link "/openwiki/operations/local-development-and-permissions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Do not run `xcodebuild` from a terminal**: it invalidates the app's TCC grants ([Local development](/openwiki/operations/local-development-and-permissions.md)).
- Keep complete failure output.
- Leave the known Swift 6 concurrency and deprecated `onChange` warnings alone.

## Suites and what they pin down

| Suite | Seam |
|---|---|
| `LanguageModelProviderTests` | Wire formats with no network. Anthropic bodies (system, tools, tool use and results, raw thinking blocks replayed verbatim), the direct `/v1/messages` path, the server-side-fallback rules, stream assembly, refusal and fallback handling. OpenAI bodies with and without images, plus tool-call stitching. Gemini bodies and parsing. Model lists and local-URL detection. |
| `ProviderConfigurationTests` | Codable round-trips. Configurations saved before the tool-calling flag, the coordinate convention or the preset id existed. The Anthropic vision profile per model generation. |
| `DesktopFirstTests` | Conversation persistence (newest first, fractional-second dates, empty chats not saved), history turns, titles. Catalog presets. Gemini model list. Ollama pull progress, errors and capabilities. Shortcut persistence. Tutorial step selection. |
| `GuidanceToolAndSpeechTests` | Decoding tool calls (malformed calls, numbers sent as strings, one pointer, action cap). The action tool offered only in action mode. Stray tags stripped in tool mode. Sentence segmentation (short-sentence joining, tags split across chunks, decimals). Legacy saved choices. ElevenLabs and OpenAI-compatible speech requests. |
| `NotepadTests` | Tag parsing, the 40-line cap, default title, `[NOTE:]` vs `[NOTEPAD:]`. A trailing `[POINT]` still parses after notepad tags are stripped. Markdown blocks and an unclosed fence. Plain-text and Markdown copies. Each line tied to the sentence after it. No joining across lines. Pacing of lines that arrive together. The prompt text. The notepad saved, reloaded and kept in history. |
| `ScreenActionParsingTests` | Action-tag parsing (CLICK, DOUBLECLICK, TYPE, KEY, SCROLL, labels, `:screenN`), emission order, the action cap, `[POINT]` passthrough, empty `[TYPE:]`, label and key-combo risk tiers. |
| `ConsentPolicyTests` | Password fields and privacy-blocked apps are always the user's own step. A real Send title overrides an innocent model label. Whole-word authorization. Default buttons. Messaging apps and Terminal. Accessibility snapping rules. |
| `ScreenshotGeometryTests` | Capture sizing per model (Claude limits, total pixel cap, aspect ratio, no upscaling, portrait). Conversions from 0–999 and 0–1000 to pixels. The command normalizer. |
| `ScreenAnnotationParsingTests` | Annotation tags: HIGHLIGHT, CIRCLE, ARROW, UNDERLINE, NOTE. |
| `CursorScreenCaptureTests` | Choosing the cursor's screen (top edge, shared edge, gaps, no screens). Reusing or discarding the prefetched capture. Fallback for an out-of-range screen number. |
| `UserScreenInkTests` | Stroke recording, the modifier safety net, CG ↔ AppKit ↔ screenshot mapping, ink drawn into the image, classifying circle, line or spot, and model-coordinate prompt notes. |
| `ChatHistoryTests` | Legacy JSON, the quiet-period split, screenshots off by default, the delete cascade, guidance and ink stored relative to the display, marks only with a saved screenshot, exchange lookup. |
| `MainAppNavigationTests` | The window opens on chat, Settings Back returns where you came from, category titles and icons. |
| `elfhubTests` | Permission routing: system prompt first, then System Settings, plus the persisted Screen Recording hint. |

The UI test target (`elfhubUITests`) is Xcode template scaffolding: a launch test and a launch-performance measure, with no product assertions.

## Manual-only territory

These need a real build and a person watching:

- `ScreenActionCoordinator`'s consent card, timeouts and stop behavior; the events `ScreenActionSynthesizer` posts.
- `UserInterruptionMonitor` and the push-to-talk and drawing event taps.
- Real ScreenCaptureKit captures and how coordinates land on multiple monitors.
- AssemblyAI websocket sessions; Apple speech; voice playback and fallback.
- Overlay timing.
- The notepad window: dragging, growth, copy and close.

When changing one of these, pull any new decision out into a pure helper with its own test, as `shouldReusePrefetchedScreenCaptures`, `ConsentPolicy` and `NotepadPanelModel`'s pacing were.

## Related pages

<!-- openwiki: broken internal link [/openwiki/operations/local-development-and-permissions.md] link "/openwiki/operations/local-development-and-permissions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Local development and permissions](/openwiki/operations/local-development-and-permissions.md)
<!-- openwiki: broken internal link [/openwiki/workflows/screen-targeting-and-actions.md] link "/openwiki/workflows/screen-targeting-and-actions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Screen targeting and actions](/openwiki/workflows/screen-targeting-and-actions.md)
<!-- openwiki: broken internal link [/openwiki/workflows/notepad.md] link "/openwiki/workflows/notepad.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Notepad](/openwiki/workflows/notepad.md)
