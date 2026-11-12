---
type: operations-guide
title: Local Development, Build Configuration, and Permissions
description: How to build and run elfhub locally (Xcode only, never terminal xcodebuild), the xcconfig setup that keeps permissions stable, entitlements, the four macOS permissions and how they gate features, known warnings, and the project's code conventions.
tags: [development, build, xcode, xcconfig, permissions, tcc, entitlements, conventions]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-56fb497c9b52a1a156d96e71
    resource: repo://Config/Local.xcconfig.example
  - id: openwiki-source-7e733f97e9b3d78d80467d7e
    resource: repo://Config/Shared.xcconfig
  - id: openwiki-source-54e04c2748da0b7e95dc7809
    resource: repo://elfhub.xcodeproj/project.pbxproj
  - id: openwiki-source-e2c892c223ac06c0fa85911d
    resource: repo://elfhub/CompanionManager.swift
  - id: openwiki-source-586451881b2cf04d299a4eb6
    resource: repo://elfhub/elfhub.entitlements
  - id: openwiki-source-1187d48823c52140b427552b
    resource: repo://elfhub/WindowPositionManager.swift
  - id: openwiki-source-23775c3de52f3ab95a13cb8b
    resource: repo://README.md
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# Local Development, Build Configuration, and Permissions

## Build and run

Prerequisites: macOS 14.2+ (the deployment target, needed for ScreenCaptureKit) and Xcode 16+ (`README.md:33-45`, `elfhub.xcodeproj/project.pbxproj:336`).

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, which is gitignored. Set `DEVELOPMENT_TEAM`; a free Personal Team works. Set `ELFHUB_BUNDLE_IDENTIFIER` to a bundle id you own.
2. Open `elfhub.xcodeproj`, select the `elfhub` scheme, and press Cmd+R.

`Config/Shared.xcconfig` is committed. It is the base configuration of every build, leaves the team empty, defaults the bundle id to `com.example.elfhub`, and ends with `#include? "Local.xcconfig"` (`Config/Shared.xcconfig:15-22`). There are no third-party Swift packages, server or keys to set up. Model, speech and voice keys are entered in the app and stored in the Keychain.

**Keep the bundle id stable.** macOS ties Screen Recording, Accessibility and Microphone grants to the bundle id and signing identity. Changing either means granting everything again.

<!-- openwiki: broken internal link [/openwiki/operations/release-pipeline.md] link "/openwiki/operations/release-pipeline.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
**Never run `xcodebuild` from the terminal for development or tests.** A terminal build invalidates the app's TCC grants, and the app then has to ask for Screen Recording, Accessibility and the rest again. Build and test from Xcode. `scripts/release.sh` is release-only tooling ([Release pipeline](/openwiki/operations/release-pipeline.md)).

Known, non-blocking warnings (Swift 6 concurrency, and the deprecated `onChange` in `TextChatView.swift`) are left alone on purpose.

## Entitlements

The app is not sandboxed. Its entitlements are network client, audio input, and a mach-lookup exception for the ScreenCaptureKit picker (`elfhub/elfhub.entitlements`). Running outside the sandbox is what allows the global event taps, synthetic input events and arbitrary user-chosen endpoints. `Info.plist` only carries the screen-capture usage description.

## Permissions

| Permission | Needed for | How it's checked |
|---|---|---|
| Accessibility | The push-to-talk tap, drawing while talking, Esc monitoring, Accessibility snapping, screen actions | `AXIsProcessTrusted()` |
| Screen Recording | Screenshots | `CGPreflightScreenCaptureAccess()`, with a persisted "previously confirmed" hint to cover false negatives |
| Microphone | Push-to-talk (not needed in text-only mode) | `AVCaptureDevice.authorizationStatus(for: .audio)` |
| Screen content | ScreenCaptureKit access | A one-time 320×240 test capture. A real image counts as granted, and the result is persisted. |

Sources: `elfhub/WindowPositionManager.swift:35-107`, `elfhub/CompanionManager.swift:538-610`.

- **Polling.** `CompanionManager` re-checks every 1.5 s, so grants made in System Settings show up without a relaunch. Screen Recording is the exception, because macOS needs an app restart for it.
- **Prompting.** A request shows the system prompt on the first attempt in a launch, and opens System Settings on later attempts. The user never gets both at once (`elfhub/WindowPositionManager.swift:138-151`).
<!-- openwiki: broken internal link [/openwiki/architecture/macos-runtime.md] link "/openwiki/architecture/macos-runtime.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **What the permissions gate.** The overlay is mounted only when onboarding is complete and the active input mode's permissions are held. In text-only mode the microphone isn't required. The push-to-talk tap needs voice mode and Accessibility. See [macOS runtime](/openwiki/architecture/macos-runtime.md).

## Conventions

These are from root `AGENTS.md`, which `CLAUDE.md` links to.

- The project is named `elfhub` everywhere: directory, scheme, targets, module `elfhub` and `PRODUCT_NAME`.
- Names are long and explicit, and clarity beats concision. Comments explain why.
- SwiftUI is the default. AppKit is used only for panels, the overlay and event taps. UI state lives on `@MainActor`; that is the default isolation, and pure types are marked `nonisolated`.
- Every button shows a pointer cursor and has deliberate hover feedback.
- Don't add unrequested features or refactors. Update `AGENTS.md` when the architecture changes.
- New source files are picked up automatically, because the project uses a file-system-synchronized group.

## Related pages

<!-- openwiki: broken internal link [/openwiki/testing/test-strategy.md] link "/openwiki/testing/test-strategy.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Test strategy](/openwiki/testing/test-strategy.md)
<!-- openwiki: broken internal link [/openwiki/architecture/macos-runtime.md] link "/openwiki/architecture/macos-runtime.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [macOS runtime](/openwiki/architecture/macos-runtime.md)
<!-- openwiki: broken internal link [/openwiki/operations/release-pipeline.md] link "/openwiki/operations/release-pipeline.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Release pipeline](/openwiki/operations/release-pipeline.md)
