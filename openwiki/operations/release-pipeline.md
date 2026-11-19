---
type: operations-runbook
title: Release Pipeline
description: How scripts/release.sh ships elfhub. It picks the next version from GitHub Releases, archives and exports with Developer ID, builds a DMG, notarizes and staples it, and publishes a GitHub Release. The app has no update feed.
tags: [release, notarization, dmg, github-releases, signing, operations]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-76478c25db28b99104e23105
    resource: repo://scripts/release.sh
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# Release Pipeline

`scripts/release.sh` is the only sanctioned place to run `xcodebuild` from a terminal, because it does release builds rather than development builds. elfhub has no auto-update feed. The app never checks for updates; users download new versions from GitHub Releases (`scripts/release.sh:7-19`, `scripts/README.md`).

## Prerequisites and environment

- **Signing:** Xcode with a Developer ID certificate, plus `Config/Local.xcconfig` holding `DEVELOPMENT_TEAM` and `ELFHUB_BUNDLE_IDENTIFIER`.
- **Tools:** `brew install create-dmg gh`, then `gh auth login`.
- **Notarization credentials:** `xcrun notarytool store-credentials "AC_PASSWORD"`.
- **`ELFHUB_RELEASE_GITHUB_REPO`** (required): `owner/repo` of the repository that hosts releases. The script exits immediately if it is unset.
- **Optional:** `ELFHUB_RELEASE_APP_NAME` (default `elfhub`, must match `PRODUCT_NAME`) and `ELFHUB_NOTARY_KEYCHAIN_PROFILE` (default `AC_PASSWORD`).

(`scripts/release.sh:26-54`)

## Stages

1. **Version.** The script reads the latest release tag and the release count from GitHub. With no arguments, it bumps the minor version by 0.1 (1.9 → 2.0) and the build number by 1. `release.sh 2.0` sets the version, and `release.sh 2.0 10` sets both. It refuses to continue if the tag already exists, and asks for a y/N confirmation.
2. **Clean.** It removes `build/`, any leftover `releases/rw.*.dmg` files, and the previous `releases/elfhub.dmg` (`scripts/release.sh:137-144`).
3. **Archive.** `xcodebuild archive -scheme elfhub` runs with `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` set.
4. **Export.** `xcodebuild -exportArchive` runs with a generated `developer-id` ExportOptions plist, which signs and notarizes the `.app` (`scripts/release.sh:158-184`).
5. **DMG.** `create-dmg` builds a drag-to-Applications window with `dmg-background.png` as its background (`scripts/release.sh:186-203`).
6. **Notarize the DMG.** `xcrun notarytool submit --wait` with the stored keychain profile, then `xcrun stapler staple` (`scripts/release.sh:205-219`).
7. **Publish.** `gh release create <tag> <dmg> --latest` creates the release on `ELFHUB_RELEASE_GITHUB_REPO`. The script prints a stable download URL: `.../releases/latest/download/elfhub.dmg` (`scripts/release.sh:221-239`).

## Gotchas

- **Missing DMG background.** The script references `dmg-background.png` at the repository root, but that file is not currently tracked, so `create-dmg` needs it restored (or the flag removed) before a release.
- **The clean step deletes the previous DMG.** Move anything you want to keep out of `releases/` first. The directory is gitignored.
- **No appcast or Sparkle step.** The app contains no updater, so publishing the GitHub Release is the whole distribution.

## Related pages

<!-- openwiki: broken internal link [/openwiki/operations/local-development-and-permissions.md] link "/openwiki/operations/local-development-and-permissions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Local development and permissions](/openwiki/operations/local-development-and-permissions.md)
