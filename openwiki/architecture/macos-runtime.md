---
type: runtime-architecture
title: macOS Runtime, State Coordinator, and UI Surfaces
description: How elfhub launches, how CompanionManager.shared coordinates every surface, and how the chat-first main window, menu bar panel, overlay windows, notepad panel, permissions, onboarding, tutorial and input modes fit together.
tags: [macos, runtime, appkit, swiftui, lifecycle, permissions, overlay, onboarding, windows]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-e2c892c223ac06c0fa85911d
    resource: repo://elfhub/CompanionManager.swift
  - id: openwiki-source-6814a464778b8e176207a031
    resource: repo://elfhub/elfhubApp.swift
  - id: openwiki-source-7f2fd2bad7287687bf029001
    resource: repo://elfhub/GuidedTutorialController.swift
  - id: openwiki-source-a7e5103a75feaefc49465a2f
    resource: repo://elfhub/MainAppView.swift
  - id: openwiki-source-55ce83d9cd4299d274c2c91e
    resource: repo://elfhub/MenuBarPanelManager.swift
  - id: openwiki-source-c5d1aaca31b9e985118fcf66
    resource: repo://elfhub/OverlayWindow.swift
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# macOS Runtime, State Coordinator, and UI Surfaces

elfhub is one SwiftUI app with AppKit bridges for every surface that has to float, ignore clicks, or avoid normal window chrome. There is one long-lived coordinator, `CompanionManager.shared`, and a small set of managers that each own one kind of AppKit window.

## Launch and shutdown

`elfhubApp` declares a `WindowGroup("elfhub")` that hosts `MainAppView`. The window has a fixed starting size (1000 × 700) and `.contentMinSize` resizability, so moving between pages never resizes it. An empty `Settings` scene exists only because SwiftUI requires at least one scene (`elfhub/elfhubApp.swift:21-41`).

`CompanionAppDelegate.applicationDidFinishLaunching` does only three things (`elfhub/elfhubApp.swift:49-61`):

1. registers a zero tooltip delay;
2. creates `MenuBarPanelManager`, which makes the status item right away;
3. calls `CompanionManager.start()`.

`applicationWillTerminate` calls `CompanionManager.stop()`.

There is no analytics, no update check and no automatic login item. Launch at login is opt-in, through `LaunchAtLoginSetting` (`SMAppService.mainApp`), toggled from Settings › General.

`MainWindowPresenter.showMainWindow()` brings the main window forward from AppKit code. If the user closed the window, it asks macOS to reopen the running app, which makes SwiftUI create a fresh window (`elfhub/elfhubApp.swift:68-83`).

## CompanionManager: the coordinator

`CompanionManager` is a `@MainActor ObservableObject` singleton. It owns, among other things:

- the dictation manager and the global shortcut monitor;
- the overlay window manager and the notepad panel manager;
- `ScreenActionCoordinator`;
- the model, chat and on-device-model stores;
- the tutorial controller;
- the turn pipeline (`elfhub/CompanionManager.swift:26-97`).

<!-- openwiki: broken internal link [/openwiki/workflows/screen-targeting-and-actions.md] link "/openwiki/workflows/screen-targeting-and-actions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
Surfaces observe it, but on-screen guidance does not read its state. Pointer, annotations, status pill and notepad are all driven through `CompanionEventBus` events (see [Screen targeting](/openwiki/workflows/screen-targeting-and-actions.md)).

`start()` wires everything in order (`elfhub/CompanionManager.swift:416-435`):

1. permissions refresh and 1.5 s polling;
2. the voice-state, audio-level and shortcut bindings;
3. the screen-action side-effect closures;
4. Esc dismissal of guidance;
5. the notepad's event subscription;
6. the model-store change forwarding;
7. the speech-to-text provider;
8. an Ollama refresh;
9. finally, overlay mounting.

`stop()` tears all of these down. It also closes the notepad and stops any running screen actions (`elfhub/CompanionManager.swift:519-536`).

### Voice state

`CompanionVoiceState` is `idle / listening / processing / responding`. Setting it to `listening` or `processing` emits `.listeningStarted` / `.processingStarted` on the bus (`elfhub/CompanionManager.swift:31-40`). Two sources drive it:

- **Dictation.** A Combine sink over the dictation manager's recording, finalizing and preparing flags maps them to listening or processing. It never overwrites `.responding`. When dictation ends with no response in flight, it emits `.turnFinished`, so a press-and-release with no speech doesn't leave the pill stuck (`elfhub/CompanionManager.swift:644-675`).
- **Speech.** `StreamingSpeechPlayer`'s start and finish callbacks move the state to `.responding` and back to `.idle` (`elfhub/CompanionManager.swift:207-222`).

### Interaction input modes

`InteractionInputMode` is Voice, Text or Both. It is persisted under `interactionInputMode` and defaults to Both.

Text-only mode turns voice off at the root:

- it removes the push-to-talk event tap entirely;
- it cancels any dictation in progress;
- it drops the microphone from the permissions the app needs.

So a voice-averse user can still reach a ready state (`elfhub/CompanionManager.swift:138-199`, `:399-407`).

## Permissions and overlay mounting

Four permissions are tracked: Accessibility, Screen Recording, Microphone, and screen content.

- **Polling.** `refreshAllPermissions()` runs every 1.5 s, so grants made in System Settings show up live (`elfhub/CompanionManager.swift:538-571`, `:628-634`).
- **Screen content.** This one comes from a one-time 320×240 test capture. A capture with real dimensions counts as a grant, which is persisted in UserDefaults (`elfhub/CompanionManager.swift:578-610`).
- **Push-to-talk tap.** It is installed only when voice input is enabled and Accessibility is granted. When it is removed, the drawing tap is stopped too, so clicks are never left swallowed (`elfhub/CompanionManager.swift:189-199`).

The overlay is mounted exactly while the user is onboarded and holds the permissions the active input mode needs. Mounting is re-evaluated on every permission refresh and mode change (`elfhub/CompanionManager.swift:441-448`). A mounted overlay draws nothing until there is guidance.

## Windows and panels

| Surface | Owner | Window behavior |
|---|---|---|
| Main window | SwiftUI `WindowGroup` → `MainAppView` | Normal app window. It is chat-first: the sidebar lists every chat, with a Tutorial row while the tutorial runs. A hover menu at the bottom leads to Settings and Quit. Settings swaps the sidebar to its categories, with Back. Onboarding takes over the detail pane until setup is complete. |
| Menu bar panel | `MenuBarPanelManager` | Borderless, non-activating `KeyablePanel`, sized to fit `CompanionPanelView` and centered below the status item. Dismissed by clicking outside or by `.dismissCompanionPanel`. |
| Overlay | `OverlayWindowManager` | One transparent, click-through `OverlayWindow` per screen at `.screenSaver` level, hidden from Accessibility. It never becomes key, and it is rebuilt when displays change. |
<!-- openwiki: broken internal link [/openwiki/workflows/notepad.md] link "/openwiki/workflows/notepad.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
| Notepad | `NotepadPanelManager` | A non-activating floating panel that can become key. The header is the drag handle, and only its X closes it. See [Notepad](/openwiki/workflows/notepad.md). |
| Compact chat | `TextChatWindowManager` | A titled window that shares the app's single `TextChatViewModel`. |

`OverlayWindow` ignores mouse events and joins all Spaces, including full-screen ones. Its `canBecomeKey` and `canBecomeMain` are false, and it calls `setAccessibilityElement(false)` so Accessibility hit-tests reach the user's real UI underneath (`elfhub/OverlayWindow.swift:19-48`). The manager rebuilds one window per `NSScreen` whenever `didChangeScreenParametersNotification` fires (`elfhub/OverlayWindow.swift:55-116`).

Other surfaces open the main window on a given page with `CompanionManager.showMainWindow(section:)`. It posts `.dismissCompanionPanel`, sets `requestedMainAppSection` (which `MainAppView` consumes and clears), and brings the window forward (`elfhub/CompanionManager.swift:99-115`, `elfhub/MainAppView.swift:112-116`).

## Onboarding and the guided tutorial

Onboarding has two steps:

1. **Models:** the three model layers.
2. **Shortcuts and permissions:** input mode, push-to-talk shortcut, permissions, and a "Start tutorial" checkbox that is checked by default.

`completeOnboarding(startTutorial:)` persists `hasCompletedOnboarding` and re-evaluates overlay mounting. It then either starts the tutorial or shows a getting-started hint in the status pill (`elfhub/CompanionManager.swift:461-491`).

`GuidedTutorialController` steps through push-to-talk, pointing, Esc dismissal, text chat and (optionally) screen actions. Steps the current setup can't do are skipped: the voice step in text-only mode, and the pointing steps for a model that can't see the screen. Each step completes by itself when the matching bus event or voice/chat signal arrives, and every step can be skipped (`elfhub/GuidedTutorialController.swift:15-60`, `:100-181`).

## Related pages

<!-- openwiki: broken internal link [/openwiki/architecture/system-overview.md] link "/openwiki/architecture/system-overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [System overview](/openwiki/architecture/system-overview.md)
<!-- openwiki: broken internal link [/openwiki/workflows/conversation-turn.md] link "/openwiki/workflows/conversation-turn.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [A conversation turn](/openwiki/workflows/conversation-turn.md)
<!-- openwiki: broken internal link [/openwiki/workflows/screen-targeting-and-actions.md] link "/openwiki/workflows/screen-targeting-and-actions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Screen targeting and actions](/openwiki/workflows/screen-targeting-and-actions.md)
<!-- openwiki: broken internal link [/openwiki/workflows/notepad.md] link "/openwiki/workflows/notepad.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Notepad](/openwiki/workflows/notepad.md)
<!-- openwiki: broken internal link [/openwiki/operations/local-development-and-permissions.md] link "/openwiki/operations/local-development-and-permissions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Local development and permissions](/openwiki/operations/local-development-and-permissions.md)
