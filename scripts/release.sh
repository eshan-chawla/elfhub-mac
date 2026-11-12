#!/bin/bash
set -euo pipefail

# Add Homebrew to PATH so create-dmg and gh are available in non-interactive shells
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh — Automates the full release pipeline for elfhub
#
# What it does (in order):
#   1. Auto-detects version + build from the latest GitHub Release
#   2. Archives the app via xcodebuild, always with the published bundle id
#   3. Exports a .app signed with your Developer ID Application certificate
#   4. Wraps it in a DMG (drag-to-Applications) and signs the DMG
#   5. Notarizes the DMG with Apple (so Gatekeeper won't block it)
#   6. Creates a GitHub Release with the DMG attached
#
# elfhub has no auto-update feed (the app never checks for updates on its
# own); users download new versions from GitHub Releases.
#
# Usage:
#   ./scripts/release.sh              Auto-bumps: 1.5 → 1.6, build 6 → 7
#   ./scripts/release.sh 2.0          Sets marketing version to 2.0, auto-bumps build
#   ./scripts/release.sh 2.0 10       Sets both marketing version and build number
#   ./scripts/release.sh --local 1.0  Builds, signs, notarizes and staples the DMG
#                                     but publishes nothing — for testing it first
#
# Prerequisites (one-time setup):
#   - Xcode with your Developer ID Application certificate, selected with
#     `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
#   - `brew install create-dmg gh`
#   - `gh auth login` (GitHub CLI authenticated)
#   - `xcrun notarytool store-credentials "AC_PASSWORD"` (Apple notarization credentials)
#   - Config/Local.xcconfig with your DEVELOPMENT_TEAM and ELFHUB_BUNDLE_IDENTIFIER
#     (see Config/Local.xcconfig.example)
#
# Required environment:
#   ELFHUB_RELEASE_GITHUB_REPO      owner/repo that hosts releases
# Optional environment:
#   ELFHUB_RELEASE_APP_NAME         defaults to "elfhub" (must match PRODUCT_NAME)
#   ELFHUB_NOTARY_KEYCHAIN_PROFILE  defaults to "AC_PASSWORD"
#   ELFHUB_DEVELOPER_ID_IDENTITY    certificate used to sign the DMG; defaults to
#                                  "Developer ID Application" (matches the one
#                                  in your keychain when you have just one)
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

SCHEME="elfhub"
APP_NAME="${ELFHUB_RELEASE_APP_NAME:-elfhub}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_PROJECT_PATH="${PROJECT_DIR}/elfhub.xcodeproj"

# The published app's bundle id — final, keep in sync with Config/Shared.xcconfig.
# Passed on the xcodebuild command line so a developer's Config/Local.xcconfig
# (e.g. com.elfhub.os.dev for Xcode builds) can never leak into a release.
RELEASE_BUNDLE_IDENTIFIER="com.elfhub.os"
DEVELOPER_ID_SIGNING_IDENTITY="${ELFHUB_DEVELOPER_ID_IDENTITY:-Developer ID Application}"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_OUTPUT_DIR="${BUILD_DIR}/dmg"
RELEASES_DIR="${PROJECT_DIR}/releases"  # where finished DMGs are kept
# Window background with the "drag to Applications" arrow. Made by
# scripts/dmg/make-dmg-background.swift for the window size and icon
# positions used in step 4 — regenerate it if you change those.
DMG_BACKGROUND="${PROJECT_DIR}/scripts/dmg/dmg-background.tiff"

GITHUB_REPO="${ELFHUB_RELEASE_GITHUB_REPO:?Set ELFHUB_RELEASE_GITHUB_REPO=owner/repo for the repo that hosts releases}"
NOTARY_KEYCHAIN_PROFILE="${ELFHUB_NOTARY_KEYCHAIN_PROFILE:-AC_PASSWORD}"

# --local makes the exact DMG a release would ship (signed, notarized, stapled)
# without creating a GitHub Release, so it can be tested on this Mac first.
# The version and build arguments that follow it work as usual.
IS_LOCAL_ONLY_BUILD=false
if [ "${1:-}" = "--local" ]; then
    IS_LOCAL_ONLY_BUILD=true
    shift
fi

# ── Auto-detect version from latest GitHub Release ──────────────────────────
# Fetches the latest release tag (e.g. "v1.5") and build number from GitHub.
# If no arguments are provided, bumps the minor version by 0.1 and build by 1.
# You can override either or both by passing arguments.

echo "🔍 Checking latest release on GitHub..."

LATEST_TAG=$(gh release view --repo "${GITHUB_REPO}" --json tagName --jq '.tagName' 2>/dev/null || echo "")

if [ -n "$LATEST_TAG" ]; then
    # Strip the "v" prefix to get the version number (e.g. "v1.5" → "1.5")
    LATEST_VERSION="${LATEST_TAG#v}"

    # Get the build number from the latest release's app bundle inside the DMG.
    # We download just the release metadata (not the DMG) and parse the body/notes,
    # but the simplest reliable approach is to track it from the GitHub release title
    # or from a known incrementing sequence. We use the GitHub API to get asset info
    # and derive the build number from the release list count.
    LATEST_BUILD=$(gh release list --repo "${GITHUB_REPO}" --json tagName --jq 'length' 2>/dev/null || echo "0")

    echo "   Latest release: ${LATEST_TAG} (build ${LATEST_BUILD})"
else
    LATEST_VERSION="0.0"
    LATEST_BUILD=0
    echo "   No previous releases found — starting from scratch"
fi

# Determine the next marketing version: bump minor by 0.1
# e.g. "1.5" → "1.6", "2.9" → "3.0" (carries over)
if [ $# -ge 1 ]; then
    MARKETING_VERSION="$1"
else
    MAJOR=$(echo "$LATEST_VERSION" | cut -d. -f1)
    MINOR=$(echo "$LATEST_VERSION" | cut -d. -f2)
    NEXT_MINOR=$((MINOR + 1))
    if [ "$NEXT_MINOR" -ge 10 ]; then
        MAJOR=$((MAJOR + 1))
        NEXT_MINOR=0
    fi
    MARKETING_VERSION="${MAJOR}.${NEXT_MINOR}"
fi

# Determine the next build number: always increment by 1
if [ $# -ge 2 ]; then
    BUILD_NUMBER="$2"
else
    BUILD_NUMBER=$((LATEST_BUILD + 1))
fi

DMG_FILENAME="${APP_NAME}.dmg"
TAG="v${MARKETING_VERSION}"

# ── Safety checks ────────────────────────────────────────────────────────────

# Check if this tag already exists on GitHub to prevent accidental duplicates
if gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
    echo ""
    echo "❌ Release ${TAG} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo "   To release a new version, either:"
    echo "     • Run without arguments to auto-bump: ./scripts/release.sh"
    echo "     • Specify a higher version: ./scripts/release.sh $(echo "${MARKETING_VERSION} + 0.1" | bc)"
    echo "     • Delete the existing release first: gh release delete ${TAG} --repo ${GITHUB_REPO} --yes"
    exit 1
fi

echo ""
if [ "${IS_LOCAL_ONLY_BUILD}" = true ]; then
    echo "🧪 Building ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER}) for local testing — nothing will be published"
else
    echo "🚀 Releasing ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER})"
fi
echo "   Previous: ${LATEST_TAG:-none}"
echo ""

# Confirm with the user before proceeding
read -p "   Proceed? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   Aborted."
    exit 0
fi
echo ""

# ── Step 1: Clean build directory ────────────────────────────────────────────

echo "🧹 Cleaning build directory and stale DMGs..."
rm -rf "${BUILD_DIR}"
# Remove any leftover temp DMGs from create-dmg (rw.*.dmg) and the previous
# same-named DMG so create-dmg doesn't choke on duplicates.
rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}" "${RELEASES_DIR}"

# ── Step 2: Archive ──────────────────────────────────────────────────────────

echo "📦 Archiving ${RELEASE_BUNDLE_IDENTIFIER}..."
# -allowProvisioningUpdates lets xcodebuild use the Xcode account to register
# the bundle id and fetch signing assets, as Xcode does for builds in the IDE.
xcodebuild archive \
    -project "${XCODE_PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    ELFHUB_BUNDLE_IDENTIFIER="${RELEASE_BUNDLE_IDENTIFIER}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    2>&1 | tail -5

echo "✅ Archive created"

# ── Step 3: Export (signed with Developer ID) ────────────────────────────────

# Create an export options plist for Developer ID distribution.
# This tells xcodebuild to sign with your Developer ID Application certificate.
# It does not notarize — "destination: export" only writes the signed .app.
# Notarization happens in step 5, on the DMG, and covers the app inside it.
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "📤 Exporting (signing with Developer ID)..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates \
    2>&1 | tail -5

echo "✅ Export complete (signed with Developer ID)"

# ── Step 4: Create and sign the DMG ──────────────────────────────────────────

DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"

# Finder opens the DMG's window when people open the file. If the background
# image is missing, the window still works, just without the arrow and caption.
# (The ${array[@]+...} form keeps an empty array safe under `set -u` in the
# bash 3.2 that ships with macOS.)
CREATE_DMG_BACKGROUND_ARGUMENTS=()
if [ -f "${DMG_BACKGROUND}" ]; then
    CREATE_DMG_BACKGROUND_ARGUMENTS=(--background "${DMG_BACKGROUND}")
else
    echo "   ⚠️  ${DMG_BACKGROUND} not found — the DMG window will have no arrow"
fi

echo "💿 Creating DMG (signed with \"${DEVELOPER_ID_SIGNING_IDENTITY}\")..."
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --text-size 13 \
    --icon "${APP_NAME}.app" 160 195 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 500 195 \
    ${CREATE_DMG_BACKGROUND_ARGUMENTS[@]+"${CREATE_DMG_BACKGROUND_ARGUMENTS[@]}"} \
    --codesign "${DEVELOPER_ID_SIGNING_IDENTITY}" \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | tail -3

echo "✅ DMG created and signed: ${DMG_PATH}"

# ── Step 5: Notarize the DMG ─────────────────────────────────────────────────
# The .app inside the DMG is already signed with Developer ID, but the DMG
# itself needs to be submitted to Apple for notarization so Gatekeeper
# allows users to open it without the "Apple could not verify" warning.
# Requires stored credentials: xcrun notarytool store-credentials "${NOTARY_KEYCHAIN_PROFILE}"

echo "🔏 Notarizing DMG with Apple (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    --wait

echo "📎 Stapling notarization ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"

echo "✅ DMG notarized and stapled"

# ── Step 6: Create GitHub Release ────────────────────────────────────────────

if [ "${IS_LOCAL_ONLY_BUILD}" = true ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "🧪 Local build v${MARKETING_VERSION} (build ${BUILD_NUMBER}) ready — nothing was published"
    echo ""
    echo "   DMG:  ${DMG_PATH}"
    echo ""
    echo "   Test it, then publish this exact DMG with:"
    echo "   gh release create ${TAG} \"${DMG_PATH}\" --repo ${GITHUB_REPO} --title v${MARKETING_VERSION} --notes \"${APP_NAME} v${MARKETING_VERSION}\" --latest"
    echo "═══════════════════════════════════════════════════════════════"
    exit 0
fi

echo "🏷️  Creating GitHub Release ${TAG}..."
gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "v${MARKETING_VERSION}" \
    --notes "${APP_NAME} v${MARKETING_VERSION}" \
    --latest

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Release v${MARKETING_VERSION} (build ${BUILD_NUMBER}) complete!"
echo ""
echo "   DMG:      ${DMG_PATH}"
echo "   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "   Download URL (always latest):"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo "═══════════════════════════════════════════════════════════════"
