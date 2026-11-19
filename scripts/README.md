# Release Scripts

## `icon/make-app-icon.swift` — Rebuild the app icon

```bash
swift -O scripts/icon/make-app-icon.swift
```

Builds every size in `elfhub/Assets.xcassets/AppIcon.appiconset` (16–1024 px) from `brand/source/elfhub-icon-source.jpg`. It removes the dark background, resizes the igloo inside the square (`iglooScaleWithinRoundedSquare`, now 0.85, using the cut-out in `brand/source/elfhub-igloo-cutout-source.png`), fits the rounded square to Apple's macOS icon grid (824 px on a 1024 px canvas, with a soft shadow), and writes `brand/elfhub-icon-1024.png` and `brand/elfhub-icon.svg`. It also writes `brand/elfhub-igloo-1024.png` and `brand/elfhub-igloo.svg` from the igloo cut-out. Run it after changing the source artwork.

## `icon/make-menu-bar-icon.swift` — Rebuild the menu bar icon

```bash
swift scripts/icon/make-menu-bar-icon.swift [preview.png]
```

Draws the one-colour igloo glyph (22 × 22 pt, the tallest that fits the menu bar) that matches the app icon. It writes the glyph as a single SVG path to `elfhub/Assets.xcassets/MenuBarIcon.imageset/` (a vector template image, so macOS tints it for light and dark menu bars) and to `brand/elfhub-menu-bar-igloo.svg`. Pass a path to also get a large preview PNG.

The icon artwork is all rights reserved, not AGPL — see `brand/LICENSE.md`.

## `release.sh` — Ship a new version of elfhub

Automates the full release pipeline: build → sign → DMG → notarize → Sparkle signature + appcast → GitHub Release.

The published app updates itself with [Sparkle](https://sparkle-project.org): once a day it reads
`https://github.com/<repo>/releases/latest/download/appcast.xml`, so a release published as
**latest** with its `appcast.xml` is offered to everyone. Users see the notes with Install / Remind me
later / Skip; nothing installs without a click unless they switch on automatic installs. Xcode and
contributor builds (other bundle ids) never update themselves.

### Quick start

```bash
# The repo that hosts your releases
export ELFHUB_RELEASE_GITHUB_REPO=your-org/elfhub-releases

# Markdown notes for the GitHub Release and the app's update window (optional)
export ELFHUB_RELEASE_NOTES_FILE=~/release-notes/1.1.md

# Auto-bumps version and build number from the latest GitHub Release
./scripts/release.sh
```

The signing team comes from `Config/Local.xcconfig` (see `Config/Local.xcconfig.example`).
The bundle id is always the published `com.elfhub.os` — the script passes it on the
`xcodebuild` command line, so the id your Xcode builds use (e.g. `com.elfhub.os.dev`
in `Local.xcconfig`) never ends up in a release. Optional: `ELFHUB_RELEASE_APP_NAME`
(default `elfhub`), `ELFHUB_NOTARY_KEYCHAIN_PROFILE` (default `AC_PASSWORD`) and
`ELFHUB_DEVELOPER_ID_IDENTITY` (default `Developer ID Application`, used to sign the DMG).

The script checks GitHub for the latest release (e.g. `v1.5`, build 6 — read from its `appcast.xml`, because Sparkle only installs a higher build number) and automatically bumps to `v1.6`, build 7. You'll see a confirmation prompt before anything runs.

### Test the DMG before publishing

```bash
# Builds, signs, notarizes and staples releases/elfhub.dmg, signs it for Sparkle and
# writes releases/appcast.xml — publishes nothing
./scripts/release.sh --local 1.0
```

When you're happy with it, the script prints the `gh release create …` command that
publishes that exact DMG and appcast, so what you tested is what people download.

To test an update end to end before publishing, serve a newer DMG and an appcast pointing
at it from this Mac, and point the installed app at it (it still checks the EdDSA signature
and the Developer ID):

```bash
swift scripts/sparkle/make-appcast.swift --version 1.0.1 --build 2 \
    --download-url http://127.0.0.1:8000/elfhub.dmg \
    --ed-signature "$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update -p <test>/elfhub.dmg)" \
    --length "$(stat -f%z <test>/elfhub.dmg)" --minimum-system-version 14.2.0 \
    --notes-file <test>/release-notes.md --output <test>/appcast.xml
(cd <test> && python3 -m http.server --bind 127.0.0.1 8000)
defaults write com.elfhub.os ElfhubUpdateFeedURL http://127.0.0.1:8000/appcast.xml
# …Check for Updates… in the installed app, then:
defaults delete com.elfhub.os ElfhubUpdateFeedURL
```

### Override version or build

```bash
# Set a specific marketing version (auto-bumps build)
./scripts/release.sh 2.0

# Set both marketing version and build number
./scripts/release.sh 2.0 10
```

### Safety

- **Duplicate detection**: If the tag already exists on GitHub, the script exits with an error and suggests what to do.
- **Signing key check**: Stops before building if the Sparkle key in your Keychain doesn't match `SUPublicEDKey` in `elfhub/Info.plist` — a mismatch would publish an update no installed copy can accept.
- **Build numbers only go up**: An explicit build number at or below the latest release's is refused.
- **Confirmation prompt**: Shows the version, build, and previous release before proceeding. Press `y` to continue.

### What it does

1. Fetches the latest release from GitHub to determine version + build
2. Archives the app via `xcodebuild` as `com.elfhub.os`
3. Exports a signed `.app` with Developer ID
4. Creates a drag-to-Applications DMG and signs it. Its window shows an arrow from the app to Applications (`scripts/dmg/dmg-background.tiff`; after changing the window size or icon positions, regenerate it with `swift scripts/dmg/make-dmg-background.swift`)
5. Notarizes the DMG with Apple (Gatekeeper compliance)
6. Signs the stapled DMG with Sparkle's `sign_update` (EdDSA) and writes `appcast.xml` (`scripts/sparkle/make-appcast.swift`: version, build, minimum macOS, markdown notes, download URL for this tag)
7. Creates a GitHub Release with the DMG and `appcast.xml` attached

### One-time setup (prerequisites)

1. **Xcode** with your Developer ID Application certificate, selected as the developer directory:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```
3. **GitHub CLI auth**:
   ```bash
   gh auth login
   ```
4. **Apple notarization credentials** (stored in Keychain):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID \
       --team-id YOUR_TEAM_ID
   ```
   You'll be prompted for an app-specific password (generate one at [appleid.apple.com](https://appleid.apple.com)).
5. **Sparkle update-signing key** (EdDSA; one key for the life of the app). Sparkle's tools
   are in `build/SourcePackages/artifacts/sparkle/Sparkle/bin/` after the first release run
   or `xcodebuild -resolvePackageDependencies -project elfhub.xcodeproj -scheme elfhub -clonedSourcePackagesDirPath build/SourcePackages`:
   ```bash
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys      # creates it in your login Keychain, prints the public key
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/elfhub-sparkle-private-key   # backup — store offline, then delete
   ```
   Put the printed public key in `SUPublicEDKey` in `elfhub/Info.plist` (already done for the
   published app). **Never lose the private key**: installed copies only accept updates signed
   with it. On a new Mac, import the backup with `generate_keys -f <backup file>`.
   Forks that publish their own builds need their own key, feed URL and bundle id.
