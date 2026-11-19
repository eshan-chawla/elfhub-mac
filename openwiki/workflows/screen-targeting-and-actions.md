---
type: workflow
title: Screen Capture, Pointing, Annotations, Drawing, and Actions
description: How elfhub sees the screen and acts on it. Covers capturing the display under the cursor at a size each model can handle, the coordinate spaces and conversions between them, decoding guidance from tags or tools, placement refined with Accessibility, how long things stay on screen, the user's own drawing, and consent-gated clicks, typing, scrolling and keys.
tags: [screen-capture, coordinates, pointing, annotations, overlay, accessibility, actions, consent, safety, ink]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-22eafd95fa9e1b66b4ca2427
    resource: repo://elfhub/CompanionEventBus.swift
  - id: openwiki-source-0c14c5df686ece124d7a440b
    resource: repo://elfhub/CompanionScreenCaptureUtility.swift
  - id: openwiki-source-be20e05db90b17df4a71ae3d
    resource: repo://elfhub/CompanionTurnPipeline.swift
  - id: openwiki-source-807fb5b99135073cf3297352
    resource: repo://elfhub/ConsentPolicy.swift
  - id: openwiki-source-888736c01a215aa6f045cc28
    resource: repo://elfhub/ScreenActionCoordinator.swift
  - id: openwiki-source-7f1f5f016219ef7255e1fb8f
    resource: repo://elfhub/ScreenActionParsing.swift
  - id: openwiki-source-a4a5525295afe00eb6cc19c4
    resource: repo://elfhub/ScreenActionSynthesizer.swift
  - id: openwiki-source-7198f6c0ddc73ec50d830a07
    resource: repo://elfhub/ScreenAnnotationParsing.swift
  - id: openwiki-source-e6fbcc84bf6122aa778162e7
    resource: repo://elfhub/ScreenshotGeometry.swift
  - id: openwiki-source-fe318fda0c7c7bf5cb212158
    resource: repo://elfhub/UserScreenInk.swift
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# Screen Capture, Pointing, Annotations, Drawing, and Actions

## Capturing the screen the user means

`CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(visionProfile:)` captures only the display under the mouse. On a multi-monitor setup that is the screen the user is focused on, so the model gets one clear image and is never asked for a screen number (`elfhub/CompanionScreenCaptureUtility.swift:152-242`).

- **Choosing the display.** `indexOfScreenFrame(containingCursorLocation:in:)` uses AppKit screen frames. A shared edge belongs to the screen the cursor just entered. A cursor exactly on the top edge, or in a gap between monitors, falls to the nearest screen (`elfhub/CompanionScreenCaptureUtility.swift:130-150`).
- **What's excluded.** Windows owned by elfhub (overlay, panels, notepad) and by apps on `ScreenCapturePrivacyBlocklist` (password managers, Keychain, Passwords; editable in Settings › Privacy) are removed from the ScreenCaptureKit filter, so their pixels are never captured.
- **Size.** `ScreenshotGeometry.targetCaptureSize` sizes the image to the model's `ModelVisionProfile`: Claude's known limits, or a conservative generic size. It never exceeds those limits and never upscales. An oversized image would be resized by the provider without telling elfhub, and every coordinate would drift (`elfhub/ScreenshotGeometry.swift:5-20`).
- **Format.** JPEG at 0.8 quality.
- **Prefetch.** A push-to-talk screenshot is taken at key-down. It is reused only if the cursor is still on the same display when the turn is sent (`elfhub/CompanionScreenCaptureUtility.swift:254-265`).

## Coordinate spaces

| Space | Origin | Used by |
|---|---|---|
| Model convention | Image pixels, or a normalized 0–999 / 0–1000 grid | What the model writes. The image label tells it which one to use. |
| Sent-screenshot pixels | Top-left | After `ScreenGuidanceCoordinateNormalizer.convertToScreenshotPixels`. |
| AppKit global points | Bottom-left | Overlay drawing, saved guidance, the user's ink. |
| Core Graphics global points | Top-left | `CGEvent` clicks and Accessibility hit-tests. |

`CompanionScreenCapture` clamps a screenshot pixel, scales it to display points, then produces either origin from that one step:

- **AppKit:** flip Y and add the display's AppKit frame origin.
- **Core Graphics:** add the display's `CGDisplayBounds` origin.

This avoids "flip against the primary screen" math, which breaks on mixed-resolution layouts. The inverse mapping turns the user's ink into screenshot pixels (`elfhub/CompanionScreenCaptureUtility.swift:27-89`).

## Decoding guidance

There are two encodings, and both produce `ScreenGuidanceCommand`s (`elfhub/GuidanceDecoders.swift`):

- **Text tags** (`TagGuidanceDecoder`):
  - `[POINT:x,y:label]` or `[POINT:none]`, at the very end of the reply;
  - annotations `[HIGHLIGHT|CIRCLE|ARROW|UNDERLINE|NOTE:…]`, anywhere in the reply;
  - in action mode, `[CLICK|DOUBLECLICK|SCROLL|TYPE|KEY:…]`.
- **Native tools** (`GuidanceToolDefinitions` / `ToolCallGuidanceDecoder`): `point_at`, `annotate`, and, only in action mode, `perform_screen_action`. In tool mode, stray tags are still decoded and stripped, and the tool's pointer wins.

Limits:

- one pointer;
- at most 6 annotations;
- at most 4 actions per reply.

(`elfhub/ScreenAnnotationParsing.swift:35`, `elfhub/ScreenActionParsing.swift:132`)

## Placement and the overlay

`ScreenGuidancePlacement` maps commands to real screen points and refines them with `AccessibilityElementLocator`:

- **Pointer.** It gets a ring around the real element it landed in.
- **Highlight.** A box that roughly covers one control snaps to that control's frame.

Containers and huge elements are never snapped. Accessibility lookups run off the main thread with a 50 ms timeout.

The placed result is emitted as `.guidancePlaced` (`elfhub/CompanionTurnPipeline.swift:299-331`).

`ScreenGuidanceOverlayModel` owns every display-timing rule (`elfhub/CompanionEventBus.swift:98-311`):

| Item | Rule |
|---|---|
| Pointer | Stays at least 3 s, and until speech ends plus 1 s. |
| Annotations | Linger 8 s after speech. |
| User's ink | Fades with the annotations, or after 20 s if no reply comes. |
| Status pill | Hides 2.5 s after the turn goes idle. Hints show for 8 s. |
| Clearing | `.turnStarted` and `.allGuidanceDismissed` (Esc) clear the pointer, marks and ink immediately. |

While anything is visible and Accessibility is granted, a listen-only Esc tap is active. The user's app still receives the Esc (`elfhub/CompanionManager.swift:495-517`).

<!-- openwiki: broken internal link [/openwiki/workflows/notepad.md] link "/openwiki/workflows/notepad.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
The overlay ignores notepad events. The notepad has its own window ([Notepad](/openwiki/workflows/notepad.md)).

## Drawing while talking

While push-to-talk is held, `UserScreenInkRecorder` installs an active mouse tap. It swallows press, drag and release, and records `UserInkStroke`s, which the overlay draws live as an orange trailing line.

- **Safety net.** A mouse event that arrives without the shortcut's modifiers ends drawing and passes through to the app.
- **On send.** `UserInkScreenshotRenderer` burns the strokes into the screenshot, and `UserInkDescriber` adds a note in the model's coordinates: a circled area, a line, or a clicked spot.
- **In chat.** The ink is saved as vector data on the question (`elfhub/UserScreenInk.swift`, `elfhub/CompanionTurnPipeline.swift:108-134`).

## Acting on the screen

Action mode is off by default. With it off, the model is never told it can act (`elfhub/ScreenActionCoordinator.swift:101-126`).

### Resolving each action

`ScreenActionCoordinator.handleParsedActions` resolves every action against the real UI:

- the Accessibility facts at the target (title, role, password field, default button);
- the frontmost app;
- the privacy blocklist.

`ConsentPolicy.evaluate` then decides how much consent the action needs. The model's own label can only add caution (`elfhub/ConsentPolicy.swift:8-127`):

- **The user's own step:** password fields and privacy-blocked apps.
- **Needs an explicit yes:**
  - a send, delete, purchase, submit or close/quit effect (judged from the real title or key combo) that the user's own words didn't ask for;
  - a dialog's default button the user didn't name;
  - any action in a sensitive frontmost app (Terminal, iTerm, Warp, Mail, Messages, Slack, Discord, Telegram, WhatsApp, Outlook).
- **Proceed with a preview:** everything else.

### Arming and firing

`elfhub/ScreenActionCoordinator.swift:150-299`:

- **A user's step blocks the whole batch.** elfhub speaks the reason and shows the target.
- **Auto-fire** (a standing per-session grant) fires at once when nothing needs an explicit yes.
- **Otherwise** a consent card is armed. elfhub says "say go or hit confirm". The card cancels itself silently after 20 s, and only if it is still the same card.
- **Firing.** Each targeted action is previewed with the pointer for 350 ms, then performed, with 150 ms between actions.
- **Stopping.** `UserInterruptionMonitor` runs an active tap. Esc is consumed ("stopped."), and any untagged physical input means the user is taking over ("okay, you've got it."). Either way the chain halts before its next event.

`ScreenActionSynthesizer` posts events from a `.hidSystemState` source, so macOS attributes Accessibility to elfhub itself (`elfhub/ScreenActionSynthesizer.swift:33-245`):

- clicks move the pointer first;
- double-clicks use rising click states;
- scrolling uses line units;
- typing posts Unicode key pairs per character and yields between them;
- key combos resolve to virtual key codes.

Every event is tagged with `syntheticEventMarker` in `eventSourceUserData`. That tag is how elfhub tells its own events apart from the user's.

## Related pages

<!-- openwiki: broken internal link [/openwiki/workflows/conversation-turn.md] link "/openwiki/workflows/conversation-turn.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [A conversation turn](/openwiki/workflows/conversation-turn.md)
<!-- openwiki: broken internal link [/openwiki/architecture/macos-runtime.md] link "/openwiki/architecture/macos-runtime.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [macOS runtime](/openwiki/architecture/macos-runtime.md)
<!-- openwiki: broken internal link [/openwiki/testing/test-strategy.md] link "/openwiki/testing/test-strategy.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Test strategy](/openwiki/testing/test-strategy.md)
