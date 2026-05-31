#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package PhotoDropMac for distribution.
#
# Produces a signed + notarized + stapled DMG that opens cleanly (no Gatekeeper
# prompt) on any Mac. The embedded `photodrop` CLI is signed as part of the
# app's signature and covered by the same notarization.
#
# Prerequisites (one-time — see RELEASING.md):
#   • Paid Apple Developer Program membership.
#   • A "Developer ID Application" certificate in your login keychain.
#   • A notarytool credential profile:
#       xcrun notarytool store-credentials "PhotoDropNotary" \
#             --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 ./scripts/release.sh [version]
#
# Environment:
#   DEVELOPMENT_TEAM   10-char Team ID (required unless set in project.yml).
#   NOTARY_PROFILE     notarytool keychain profile name (default: PhotoDropNotary).
#
# No credentials are read from or written to the repo.

set -euo pipefail

cd "$(dirname "$0")/.."          # repo root

# ── Inputs ──────────────────────────────────────────────────────────────────
SCHEME="PhotoDropMac"
APP_NAME="PhotoDropMac"
PROJECT="PhotoDropMac.xcodeproj"
NOTARY_PROFILE="${NOTARY_PROFILE:-PhotoDropNotary}"

# Version: first arg, else the committed MARKETING_VERSION in project.yml.
VERSION="${1:-$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
# Build number: monotonic commit count (overrides project.yml at build time).
BUILD="$(git rev-list --count HEAD)"

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "▸ Releasing $APP_NAME $VERSION (build $BUILD)"

# ── Preflight: fail early with a clear message if signing can't succeed ──────
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "✗ No 'Developer ID Application' certificate in the keychain." >&2
  echo "  Enroll in the Apple Developer Program and create the certificate first." >&2
  echo "  See RELEASING.md → Prerequisites." >&2
  exit 1
fi

TEAM_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  TEAM_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

# ── 1. Regenerate the Xcode project from project.yml ────────────────────────
echo "▸ xcodegen generate"
xcodegen generate

# ── 2. Archive (Release): app + embedded photodrop, both hardened + timestamped
echo "▸ xcodebuild archive (Release)"
rm -rf "$ARCHIVE"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  "${TEAM_ARGS[@]}" \
  archive

[[ -d "$APP" ]] || { echo "✗ Archive did not produce $APP" >&2; exit 1; }

# ── 3. Package into a DMG ────────────────────────────────────────────────────
echo "▸ Building DMG"
rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --app-drop-link 450 150 \
    --icon "$APP_NAME.app" 150 150 \
    "$DMG" "$APP"
else
  # Zero-dependency fallback: stage the app + an Applications symlink, compress.
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi

# ── 4. Notarize the DMG and wait for the verdict ────────────────────────────
echo "▸ notarytool submit (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

# ── 5. Staple the ticket so it validates offline ────────────────────────────
echo "▸ stapler staple"
xcrun stapler staple "$DMG"

# ── 6. Verify ────────────────────────────────────────────────────────────────
echo "▸ Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -t exec -vvv "$APP" || true          # informational
xcrun stapler validate "$DMG"

echo ""
echo "✓ Done: $DMG"
echo "  Spot-check the embedded CLI is hardened:"
echo "    codesign -dvvv '$APP/Contents/MacOS/photodrop' 2>&1 | grep -E 'Authority|flags'"
echo "  Simulate a clean download (should open with no Gatekeeper dialog):"
echo "    cp -R '$APP' /tmp/$APP_NAME.app && xattr -w com.apple.quarantine '0081;0;Safari;' /tmp/$APP_NAME.app && open /tmp/$APP_NAME.app"
