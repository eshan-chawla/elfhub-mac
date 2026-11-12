# Release Scripts

## `release.sh` — Ship a new version of elfhub

Automates the full release pipeline: build → sign → DMG → notarize → GitHub Release.

elfhub has no auto-update feed — the app never checks for updates on its own; users download new versions from GitHub Releases.

### Quick start

```bash
# The repo that hosts your releases
export ELFHUB_RELEASE_GITHUB_REPO=your-org/elfhub-releases

# Auto-bumps version and build number from the latest GitHub Release
./scripts/release.sh
```

The signing team comes from `Config/Local.xcconfig` (see `Config/Local.xcconfig.example`).
The bundle id is always the published `com.elfhub.os` — the script passes it on the
`xcodebuild` command line, so the id your Xcode builds use (e.g. `com.elfhub.os.dev`
in `Local.xcconfig`) never ends up in a release. Optional: `ELFHUB_RELEASE_APP_NAME`
(default `elfhub`), `ELFHUB_NOTARY_KEYCHAIN_PROFILE` (default `AC_PASSWORD`) and
`ELFHUB_DEVELOPER_ID_IDENTITY` (default `Developer ID Application`, used to sign the DMG).

The script checks GitHub for the latest release (e.g. `v1.5`, build 6) and automatically bumps to `v1.6`, build 7. You'll see a confirmation prompt before anything runs.

### Test the DMG before publishing

```bash
# Builds, signs, notarizes and staples releases/elfhub.dmg — publishes nothing
./scripts/release.sh --local 1.0
```

When you're happy with it, the script prints the `gh release create …` command that
publishes that exact DMG, so what you tested is what people download.

### Override version or build

```bash
# Set a specific marketing version (auto-bumps build)
./scripts/release.sh 2.0

# Set both marketing version and build number
./scripts/release.sh 2.0 10
```

### Safety

- **Duplicate detection**: If the tag already exists on GitHub, the script exits with an error and suggests what to do.
- **Confirmation prompt**: Shows the version, build, and previous release before proceeding. Press `y` to continue.

### What it does

1. Fetches the latest release from GitHub to determine version + build
2. Archives the app via `xcodebuild` as `com.elfhub.os`
3. Exports a signed `.app` with Developer ID
4. Creates a drag-to-Applications DMG and signs it. Its window shows an arrow from the app to Applications (`scripts/dmg/dmg-background.tiff`; after changing the window size or icon positions, regenerate it with `swift scripts/dmg/make-dmg-background.swift`)
5. Notarizes the DMG with Apple (Gatekeeper compliance)
6. Creates a GitHub Release with the DMG attached

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
