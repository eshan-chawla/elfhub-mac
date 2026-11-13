# AGENTS.md - elfhub (Main App Target)

Single app target. Guidance for this target lives in the root `AGENTS.md` at the repo
top level (which `CLAUDE.md` symlinks to) — that file is the source of truth for the
architecture, key files, conventions, and build instructions.

## Target Layout

All source files live flat in this directory; see the root `AGENTS.md` "Key Files"
table for a per-file map. Highlights:

- `elfhubApp.swift` — entry point; AppKit main window (`MainWindowPresenter`) + `CompanionAppDelegate`
- `CompanionManager.swift` — central state machine for the voice pipeline
- `CompanionPanelView.swift` — SwiftUI content shared by the main window and the menu bar panel
- `MenuBarPanelManager.swift` — NSStatusItem + floating NSPanel
- `OverlayWindow.swift` — click-through per-screen guidance overlay (pointer at target, annotations, status pill)

Supporting assets (`Info.plist`, `Assets.xcassets`, entitlements) also live here.
Build-time values come from `../Config/Shared.xcconfig` + gitignored `../Config/Local.xcconfig`.

## Tests

`../elfhubTests/` — unit tests for `LanguageModelProvider`,
`ProviderConfiguration`, and `ScreenActionParsing`.
