#!/bin/bash
set -euo pipefail

# Add Homebrew to PATH so create-dmg and gh are available in non-interactive shells
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh — Automates the full release pipeline for elfhub
#
# What it does (in order):
#   1. Auto-detects version + build from the latest GitHub Release (the build
#      number comes from its appcast.xml, so it only ever goes up)
#   2. Archives the app via xcodebuild, always with the published bundle id
#   3. Exports a .app signed with your Developer ID Application certificate
#   4. Wraps it in a DMG (drag-to-Applications) and signs the DMG
#   5. Notarizes the DMG with Apple (so Gatekeeper won't block it)
#   6. Signs the stapled DMG for Sparkle (EdDSA) and writes appcast.xml
#   7. Creates a GitHub Release with the DMG and appcast.xml attached
#
# Updates: the app (Sparkle) reads
#   https://github.com/<repo>/releases/latest/download/appcast.xml
# once a day, so publishing a release as "latest" offers it to everyone.
# The Sparkle private key lives in your login Keychain (made once with
# Sparkle's generate_keys); the script stops if it doesn't match
# SUPublicEDKey in elfhub/Info.plist, since a mismatch would ship updates
# no installed app can accept.
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
#   ELFHUB_RELEASE_NOTES_FILE       markdown release notes, shown on the GitHub
#                                  Release and in the app's update window;
#                                  defaults to a one-line note
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
# Swift packages are checked out here (kept between runs) so Sparkle's tools
# have a fixed path: generate_keys and sign_update.
SOURCE_PACKAGES_DIR="${BUILD_DIR}/SourcePackages"
SPARKLE_TOOLS_DIR="${SOURCE_PACKAGES_DIR}/artifacts/sparkle/Sparkle/bin"
MAKE_APPCAST_SCRIPT="${PROJECT_DIR}/scripts/sparkle/make-appcast.swift"
APP_INFO_PLIST="${PROJECT_DIR}/elfhub/Info.plist"
APPCAST_FILENAME="appcast.xml"

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

    # The build number is the latest release's sparkle:version, read from its
    # appcast.xml. Sparkle compares build numbers, so they must only ever go
    # up — counting releases could go backwards after one is deleted. A
    # release without an appcast falls back to that count.
    PREVIOUS_APPCAST_DIR="$(mktemp -d)"
    LATEST_BUILD=""
    if gh release download "${LATEST_TAG}" --repo "${GITHUB_REPO}" --pattern "${APPCAST_FILENAME}" --dir "${PREVIOUS_APPCAST_DIR}" &>/dev/null; then
        LATEST_BUILD=$(sed -n 's:.*<sparkle\:version>\([0-9][0-9]*\)</sparkle\:version>.*:\1:p' "${PREVIOUS_APPCAST_DIR}/${APPCAST_FILENAME}" | sort -n | tail -1)
    fi
    rm -rf "${PREVIOUS_APPCAST_DIR}"
    if [ -z "${LATEST_BUILD}" ]; then
        LATEST_BUILD=$(gh release list --repo "${GITHUB_REPO}" --json tagName --jq 'length' 2>/dev/null || echo "0")
    fi

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

# Installed apps only take an update whose build number is higher than theirs.
if ! [[ "${BUILD_NUMBER}" =~ ^[0-9]+$ ]] || [ "${BUILD_NUMBER}" -le "${LATEST_BUILD}" ]; then
    echo "❌ Build number ${BUILD_NUMBER} must be a whole number above the latest release's build (${LATEST_BUILD})."
    exit 1
fi

# Release notes go on the GitHub Release and into the app's update window.
if [ -n "${ELFHUB_RELEASE_NOTES_FILE:-}" ]; then
    if [ ! -s "${ELFHUB_RELEASE_NOTES_FILE}" ]; then
        echo "❌ ELFHUB_RELEASE_NOTES_FILE=${ELFHUB_RELEASE_NOTES_FILE} is missing or empty."
        exit 1
    fi
    RELEASE_NOTES_SOURCE="${ELFHUB_RELEASE_NOTES_FILE}"
else
    RELEASE_NOTES_SOURCE=""
    echo "   ⚠️  No ELFHUB_RELEASE_NOTES_FILE — the release notes will be one line."
fi

# Sparkle's tools come from the Sparkle package, checked out into
# ${SOURCE_PACKAGES_DIR}; resolving is quick once it's there.
echo "🔑 Checking the Sparkle signing key..."
xcodebuild -resolvePackageDependencies \
    -project "${XCODE_PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR}" \
    >/dev/null
if [ ! -x "${SPARKLE_TOOLS_DIR}/sign_update" ] || [ ! -x "${SPARKLE_TOOLS_DIR}/generate_keys" ]; then
    echo "❌ Sparkle's sign_update / generate_keys weren't found in ${SPARKLE_TOOLS_DIR}."
    exit 1
fi
# generate_keys -p prints the public key of the private key in the Keychain
# (or an error line, still exiting 0), so compare its output, not its status.
KEYCHAIN_PUBLIC_ED_KEY=$("${SPARKLE_TOOLS_DIR}/generate_keys" -p 2>/dev/null | tail -1 || true)
APP_PUBLIC_ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP_INFO_PLIST}" 2>/dev/null || true)
if [ -z "${APP_PUBLIC_ED_KEY}" ] || [ "${KEYCHAIN_PUBLIC_ED_KEY}" != "${APP_PUBLIC_ED_KEY}" ]; then
    echo "❌ The Sparkle key in your Keychain doesn't match SUPublicEDKey in elfhub/Info.plist."
    echo "   Keychain: ${KEYCHAIN_PUBLIC_ED_KEY:-none}"
    echo "   App:      ${APP_PUBLIC_ED_KEY:-none}"
    echo "   Import the backed-up key with: ${SPARKLE_TOOLS_DIR}/generate_keys -f <backup file>"
    echo "   (Changing SUPublicEDKey instead would stop every installed copy from updating.)"
    exit 1
fi
echo "   ✅ Keychain key matches the app"

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
# Everything in build/ except the package checkouts (Sparkle's tools live there).
find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 ! -name "$(basename "${SOURCE_PACKAGES_DIR}")" -exec rm -rf {} + 2>/dev/null || true
# Remove any leftover temp DMGs from create-dmg (rw.*.dmg), the previous
# same-named DMG so create-dmg doesn't choke on duplicates, and the previous
# appcast and notes.
rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}" "${RELEASES_DIR}/${APPCAST_FILENAME}" "${RELEASES_DIR}/release-notes.md"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}" "${RELEASES_DIR}"

# ── Step 2: Archive ──────────────────────────────────────────────────────────

echo "📦 Archiving ${RELEASE_BUNDLE_IDENTIFIER}..."
# -allowProvisioningUpdates lets xcodebuild use the Xcode account to register
# the bundle id and fetch signing assets, as Xcode does for builds in the IDE.
xcodebuild archive \
    -project "${XCODE_PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR}" \
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

# The update settings must be in the shipped app, and Sparkle's helpers
# (Autoupdate, Updater.app, its XPC services) must carry the same Developer ID
# signature as the app, or updates fail to install.
EXPORTED_APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
EXPORTED_APP_INFO_PLIST="${EXPORTED_APP_PATH}/Contents/Info.plist"
for REQUIRED_SPARKLE_KEY in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
    if ! /usr/libexec/PlistBuddy -c "Print :${REQUIRED_SPARKLE_KEY}" "${EXPORTED_APP_INFO_PLIST}" &>/dev/null; then
        echo "❌ ${REQUIRED_SPARKLE_KEY} is missing from the exported app's Info.plist."
        exit 1
    fi
done
if [ ! -d "${EXPORTED_APP_PATH}/Contents/Frameworks/Sparkle.framework" ]; then
    echo "❌ Sparkle.framework isn't embedded in the exported app."
    exit 1
fi
codesign --verify --deep --strict "${EXPORTED_APP_PATH}"
echo "✅ Update settings present and every nested signature checks out"

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

# ── Step 6: Sign the update for Sparkle and write the appcast ────────────────
# Stapling changed the DMG, so the EdDSA signature is made only now, on the
# exact file people download. Installed apps check it against SUPublicEDKey.

echo "✍️  Signing the DMG for Sparkle and writing ${APPCAST_FILENAME}..."
DMG_ED_SIGNATURE=$("${SPARKLE_TOOLS_DIR}/sign_update" -p "${DMG_PATH}")
DMG_LENGTH_IN_BYTES=$(stat -f%z "${DMG_PATH}")
# Sparkle wants a three-part version ("14.2" → "14.2.0").
APP_MINIMUM_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${EXPORTED_APP_INFO_PLIST}")
while [ "$(echo "${APP_MINIMUM_SYSTEM_VERSION}" | tr -cd '.' | wc -c | tr -d ' ')" -lt 2 ]; do
    APP_MINIMUM_SYSTEM_VERSION="${APP_MINIMUM_SYSTEM_VERSION}.0"
done

RELEASE_NOTES_PATH="${RELEASES_DIR}/release-notes.md"
if [ -n "${RELEASE_NOTES_SOURCE}" ]; then
    cp "${RELEASE_NOTES_SOURCE}" "${RELEASE_NOTES_PATH}"
else
    echo "${APP_NAME} v${MARKETING_VERSION}" > "${RELEASE_NOTES_PATH}"
fi

APPCAST_PATH="${RELEASES_DIR}/${APPCAST_FILENAME}"
swift "${MAKE_APPCAST_SCRIPT}" \
    --version "${MARKETING_VERSION}" \
    --build "${BUILD_NUMBER}" \
    --download-url "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${DMG_FILENAME}" \
    --ed-signature "${DMG_ED_SIGNATURE}" \
    --length "${DMG_LENGTH_IN_BYTES}" \
    --minimum-system-version "${APP_MINIMUM_SYSTEM_VERSION}" \
    --notes-file "${RELEASE_NOTES_PATH}" \
    --output "${APPCAST_PATH}"

# Prove the signature verifies with the key the app ships with.
"${SPARKLE_TOOLS_DIR}/sign_update" --verify "${DMG_PATH}" "${DMG_ED_SIGNATURE}"
echo "✅ Update signed and appcast written"

# ── Step 7: Create GitHub Release ────────────────────────────────────────────
# Publishing as --latest moves releases/latest/download/appcast.xml, which is
# what every installed copy checks — that's the moment the update goes out.

if [ "${IS_LOCAL_ONLY_BUILD}" = true ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "🧪 Local build v${MARKETING_VERSION} (build ${BUILD_NUMBER}) ready — nothing was published"
    echo ""
    echo "   DMG:      ${DMG_PATH}"
    echo "   Appcast:  ${APPCAST_PATH}"
    echo "   Notes:    ${RELEASE_NOTES_PATH}"
    echo ""
    echo "   Test it, then publish these exact files with:"
    echo "   gh release create ${TAG} \"${DMG_PATH}\" \"${APPCAST_PATH}\" --repo ${GITHUB_REPO} --title v${MARKETING_VERSION} --notes-file \"${RELEASE_NOTES_PATH}\" --latest"
    echo "═══════════════════════════════════════════════════════════════"
    exit 0
fi

echo "🏷️  Creating GitHub Release ${TAG}..."
gh release create "${TAG}" "${DMG_PATH}" "${APPCAST_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "v${MARKETING_VERSION}" \
    --notes-file "${RELEASE_NOTES_PATH}" \
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
echo "   Update feed the app reads:"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${APPCAST_FILENAME}"
echo "═══════════════════════════════════════════════════════════════"
