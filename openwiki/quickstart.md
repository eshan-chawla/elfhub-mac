---
type: repository-quickstart
title: elfhub Repository Quickstart
description: Orientation for coding agents. Covers what elfhub is (a desktop-first, bring-your-own-key macOS companion with no server), the rules that must win before any deeper reading, the setup path, and which wiki page owns each kind of change.
tags: [quickstart, onboarding, routing, conventions, macos, desktop-first, byok]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-7e733f97e9b3d78d80467d7e
    resource: repo://Config/Shared.xcconfig
  - id: openwiki-source-23775c3de52f3ab95a13cb8b
    resource: repo://README.md
  - id: openwiki-source-76478c25db28b99104e23105
    resource: repo://scripts/release.sh
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# elfhub Repository Quickstart

elfhub is a macOS desktop companion. The user holds a push-to-talk shortcut (ctrl+option by default) or types in chat. elfhub sends their words, plus a screenshot of the display under the mouse when the model can see images, to the language model the user configured. The reply comes back as streamed text, and elfhub speaks it sentence by sentence. Along the way elfhub can:

- point at UI elements;
- draw annotations;
- write a notepad of steps or code beside the screen;
- when the user asks and consents, click, type, scroll and press keys.

It is desktop-first and bring-your-own-key. There is no elfhub server, account, analytics or update feed. Keys live in the Keychain and chats are saved only on the Mac.

## Non-negotiable rules

1. **Never run `xcodebuild` from a terminal for development or testing.** It invalidates the app's TCC permission grants (Screen Recording, Accessibility…), and the user has to grant them again. Build and test in Xcode with the `elfhub` scheme. `scripts/release.sh` is the only release-time exception.
2. **Don't fix the known warnings.** The Swift 6 concurrency warnings and the deprecated `onChange` warning are left alone on purpose. Keep failure output complete.
3. **Keep the `elfhub` name everywhere:** directory, scheme, targets, module `elfhub`, `PRODUCT_NAME`.
4. **Follow `AGENTS.md`** (`CLAUDE.md` links to it). Use very clear, long names. Don't add unrequested features or refactors. Every button gets a pointer cursor and deliberate hover behavior. Update `AGENTS.md` when the architecture changes.

## Setup path

1. Install macOS 14.2+ and Xcode 16+.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team and a stable bundle id.
3. Open `elfhub.xcodeproj` and press Cmd+R.
4. In the app, onboarding sets up the three model layers (speech-to-text, language model, voice), then shortcuts and permissions.

<!-- openwiki: broken internal link [/openwiki/operations/local-development-and-permissions.md] link "/openwiki/operations/local-development-and-permissions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
There is nothing to deploy and no keys to put in the code. Details: [Local development and permissions](/openwiki/operations/local-development-and-permissions.md).

## Task → wiki routing

| You are… | Read |
|---|---|
<!-- openwiki: broken internal link [/openwiki/architecture/system-overview.md] link "/openwiki/architecture/system-overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Getting the big picture: ownership, the event bus, the network boundary | [System overview](/openwiki/architecture/system-overview.md) |
<!-- openwiki: broken internal link [/openwiki/architecture/macos-runtime.md] link "/openwiki/architecture/macos-runtime.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Touching launch, `CompanionManager`, windows and panels, overlay mounting, permissions, onboarding or the tutorial | [macOS runtime](/openwiki/architecture/macos-runtime.md) |
<!-- openwiki: broken internal link [/openwiki/workflows/conversation-turn.md] link "/openwiki/workflows/conversation-turn.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Changing how a voice or chat turn runs: prompt, tools or tags, streaming, speech, errors | [A conversation turn](/openwiki/workflows/conversation-turn.md) |
<!-- openwiki: broken internal link [/openwiki/workflows/screen-targeting-and-actions.md] link "/openwiki/workflows/screen-targeting-and-actions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Touching screenshots, coordinates, pointing, annotations, overlay timing, the user's drawing, or screen actions and consent | [Screen targeting and actions](/openwiki/workflows/screen-targeting-and-actions.md) |
<!-- openwiki: broken internal link [/openwiki/workflows/notepad.md] link "/openwiki/workflows/notepad.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Changing the notepad: tags, lines in step with speech, window, copy, saving | [Notepad](/openwiki/workflows/notepad.md) |
<!-- openwiki: broken internal link [/openwiki/concepts/providers-configuration-and-persistence.md] link "/openwiki/concepts/providers-configuration-and-persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Adding or changing a model, speech or voice provider, keys or preferences | [Model layers and secrets](/openwiki/concepts/providers-configuration-and-persistence.md) |
<!-- openwiki: broken internal link [/openwiki/integrations/external-services.md] link "/openwiki/integrations/external-services.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Changing what talks to the network | [External services](/openwiki/integrations/external-services.md) |
<!-- openwiki: broken internal link [/openwiki/concepts/chat-history.md] link "/openwiki/concepts/chat-history.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Touching saved chats, screenshots in chat, or history sent back to the model | [Chat history](/openwiki/concepts/chat-history.md) |
<!-- openwiki: broken internal link [/openwiki/testing/test-strategy.md] link "/openwiki/testing/test-strategy.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Writing or running tests | [Test strategy](/openwiki/testing/test-strategy.md) |
<!-- openwiki: broken internal link [/openwiki/operations/release-pipeline.md] link "/openwiki/operations/release-pipeline.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Shipping a release | [Release pipeline](/openwiki/operations/release-pipeline.md) |

## Where the seams are

Decisions live in pure, unit-tested types:

- provider wire formats;
- guidance and action parsing;
- `ScreenshotGeometry`;
- `ConsentPolicy`;
- `SpokenSentenceSegmenter`;
- `NotepadTagParser` and `NotepadPanelModel` pacing;
- `ChatConversation`;
- cursor-screen selection;
- ink mapping.

Event taps, ScreenCaptureKit, synthetic events, overlays and sound need checking by hand in a running build. When you change one of those, pull the decision out into a pure helper and test it.
