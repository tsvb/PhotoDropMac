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

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ No usable notarytool credential profile named '$NOTARY_PROFILE'." >&2
  echo "  Run 'xcrun notarytool store-credentials \"$NOTARY_PROFILE\" ...' first." >&2
  echo "  See RELEASING.md → Prerequisites." >&2
  exit 1
fi

# The update channel is a code-execution path into every user's Mac, so the two
# halves of its key are checked before anything expensive happens. This half —
# "is there a public key at all?" — needs nothing but PlistBuddy. The other half,
# "does the private key in the keychain match it?", needs Sparkle's tools and so
# runs after the package is resolved, below.
PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist 2>/dev/null || echo "")"
if [[ -z "$PUBLIC_ED_KEY" ]]; then
  if [[ "${ALLOW_UNSIGNED_UPDATES:-0}" == "1" ]]; then
    echo "⚠ ALLOW_UNSIGNED_UPDATES=1 — shipping a build that can never update itself."
  else
    echo "✗ Info.plist carries no SUPublicEDKey, so this build could never update itself." >&2
    echo "  Every copy you hand out would be stranded on this version forever — a" >&2
    echo "  security fix would reach nobody who did not happen to revisit the" >&2
    echo "  Releases page." >&2
    echo "  Create the key once:   ./scripts/sparkle-keys.sh" >&2
    echo "  Or ship without one:   ALLOW_UNSIGNED_UPDATES=1 $0 ${1:-}" >&2
    exit 1
  fi
fi

TEAM_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  TEAM_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

# ── 0. Refuse to ship from a dirty tree ─────────────────────────────────────
# The build number below is a commit count, and the tag written at the end names
# a commit. Both are lies if uncommitted work went into the binary — you would
# have a notarized DMG that corresponds to no revision anyone can check out.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Working tree is dirty. Commit or stash before releasing." >&2
  git status --short >&2
  exit 1
fi

# ── 1. Regenerate the Xcode project from project.yml ────────────────────────
echo "▸ xcodegen generate"
xcodegen generate

# Resolve packages explicitly so a network failure reads as a network failure —
# and so Sparkle's signing tools exist for the key check immediately below.
echo "▸ xcodebuild -resolvePackageDependencies"
xcodebuild -project "$PROJECT" -resolvePackageDependencies >/dev/null

# ── 1a. The other half of the update-key check ──────────────────────────────
# The public key is committed in Info.plist; the private key is in the login
# keychain. They can disagree silently, and the symptom is not an error — it is
# every installed copy quietly refusing every update, forever. Caught here, while
# the only thing lost is a few seconds.
if [[ -n "$PUBLIC_ED_KEY" ]]; then
  if KEYCHAIN_PUB="$("$(dirname "$0")/sparkle-keys.sh" --print 2>/dev/null | awk '/Public key:/ {print $NF}')" \
     && [[ -n "$KEYCHAIN_PUB" ]]; then
    if [[ "$KEYCHAIN_PUB" != "$PUBLIC_ED_KEY" ]]; then
      echo "✗ The signing key in your keychain is not the one this app trusts." >&2
      echo "    Info.plist : $PUBLIC_ED_KEY" >&2
      echo "    keychain   : $KEYCHAIN_PUB" >&2
      echo "  An update signed with the keychain key would be refused by every" >&2
      echo "  installed copy. Import the right private key, or see" >&2
      echo "  scripts/sparkle-keys.sh about rotating." >&2
      exit 1
    fi
  elif [[ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    echo "✗ No Sparkle private key available to sign the update with." >&2
    echo "  Info.plist expects updates signed by $PUBLIC_ED_KEY." >&2
    echo "  Import the private key into this keychain:" >&2
    echo "      generate_keys -f <exported-key-file>" >&2
    echo "  or point SPARKLE_PRIVATE_KEY_FILE at an exported copy." >&2
    exit 1
  fi
fi

# ── 1b. The test gate ───────────────────────────────────────────────────────
# Nothing else in this project runs the suite automatically, and a release is
# the worst possible moment to find out. It takes a couple of seconds; a
# notarized DMG built from untested code is forever.
if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
  echo "⚠ SKIP_TESTS=1 — shipping without running the suite. You are on your own."
else
  echo "▸ xcodebuild test (Debug)"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
             -configuration Debug -destination 'platform=macOS' test
  echo "▸ xcodebuild build (photodrop CLI)"
  xcodebuild -project "$PROJECT" -scheme photodrop \
             -configuration Debug -destination 'platform=macOS' build
fi

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
  "${TEAM_ARGS[@]+"${TEAM_ARGS[@]}"}" \
  archive

[[ -d "$APP" ]] || { echo "✗ Archive did not produce $APP" >&2; exit 1; }

# ── 3. Notarize and staple the .app itself ───────────────────────────────────
# Order matters: the app is stapled BEFORE it goes into the DMG, so the copy the
# user drags to /Applications carries its own ticket.
#
# Stapling only the DMG is not enough. A ticket is bound to a specific cdhash,
# and the DMG's ticket covers the DMG — once the user copies the app out and
# discards the disk image, nothing on disk proves the app was notarized.
# Gatekeeper then has to ask Apple at first launch, which fails closed when the
# machine is offline: "PhotoDropMac cannot be opened because Apple cannot check
# it for malicious software." Stapling the app first makes that check work
# offline, which is the whole point of stapling.
#
# notarytool only accepts .zip/.dmg/.pkg, so the app ships to Apple as a zip
# built with ditto (preserves symlinks and extended attributes; `zip` does not).
echo "▸ notarytool submit — app (profile: $NOTARY_PROFILE)"
APP_ZIP="$BUILD_DIR/$APP_NAME-app.zip"
rm -f "$APP_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$APP_ZIP"

echo "▸ stapler staple — app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"   # fail the release if the app didn't get a ticket

# ── 4. Package the stapled app into a DMG ────────────────────────────────────
echo "▸ Building DMG"
rm -f "$DMG"
# Always stage a *copy*. create-dmg does `rm "$SRC_FOLDER/.DS_Store"`, and at
# this point the app is already notarized and stapled — deleting anything inside
# the bundle would invalidate the signature after the ticket was attached. `ditto`
# rather than `cp -R` so extended attributes (the stapled ticket among them)
# survive the copy.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"

# The fallback is reached when create-dmg is missing *or* when it fails. It
# drives Finder over AppleEvents to place the icons, which needs a Finder that
# will answer: from a background shell, an ssh session or CI it returns
# `Finder got an error: AppleEvent timed out. (-1712)` and exits non-zero.
# Under `set -e` that used to abort the release *after* the app was already
# notarized and stapled — the expensive, irreversible half — over icon
# placement. A plain disk image is a complete, shippable artifact; prettiness is
# not worth losing the release for.
#
# create-dmg leaves its scratch `rw.*.dmg` and a half-built $DMG behind when it
# dies, so both are cleared before the retry. $STAGE survives a failed attempt
# intact: the only thing create-dmg writes there is the removal of .DS_Store.
dmg_fallback() {
  echo "▸ Building DMG with hdiutil (no Finder required)"
  rm -f "$BUILD_DIR"/rw.*.dmg "$DMG"
  ln -sf /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
}

if command -v create-dmg >/dev/null 2>&1; then
  if ! create-dmg \
        --volname "$APP_NAME" \
        --app-drop-link 450 150 \
        --icon "$APP_NAME.app" 150 150 \
        "$DMG" "$STAGE"; then
    echo "⚠ create-dmg failed (commonly a Finder AppleEvent timeout when not run" >&2
    echo "  from a foreground GUI session). Falling back to a plain disk image." >&2
    dmg_fallback
  fi
else
  dmg_fallback
fi

# ── 5. Notarize the DMG and wait for the verdict ────────────────────────────
echo "▸ notarytool submit — dmg (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

# ── 6. Staple the DMG too, so the disk image itself validates offline ───────
echo "▸ stapler staple — dmg"
xcrun stapler staple "$DMG"

# ── 7. Verify ────────────────────────────────────────────────────────────────
echo "▸ Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -t exec -vvv "$APP" || true          # informational
xcrun stapler validate "$APP"                 # the copy the user keeps
xcrun stapler validate "$DMG"                 # the download itself

# The update keys have to survive the build, not just the repo. They were first
# declared as INFOPLIST_KEY_* build settings, which Xcode accepted without a
# warning and then dropped from the built plist — an app that silently never
# updates. Read them back out of the bundle that is about to ship.
# Nothing in a local build catches an ad-hoc signature: `codesign --verify --deep
# --strict` above reports the app as valid and satisfying its designated
# requirement, because ad-hoc signatures are structurally fine. Notarization is
# where it bites, and by then the archive is built and submitted. Sparkle's
# XCFramework arrives ad-hoc signed and Xcode's embed step signs only the outer
# framework, so scripts/sign-sparkle-helpers.sh re-signs what is inside it — this
# is the assertion that the phase actually ran.
ADHOC=0
while IFS= read -r nested; do
  if codesign -dvvv "$nested" 2>&1 | grep -q "flags=0x[0-9a-f]*(.*adhoc"; then
    echo "✗ Ad-hoc signed, and notarization requires a Developer ID: $nested" >&2
    ADHOC=1
  fi
done < <(find "$APP/Contents" \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" \) -mindepth 1 -maxdepth 4 -type d
         find "$APP/Contents/Frameworks" "$APP/Contents/MacOS" -type f -perm +111 2>/dev/null)
[[ "$ADHOC" == "0" ]] || { echo "  See scripts/sign-sparkle-helpers.sh." >&2; exit 1; }

BUILT_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
BUILT_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
[[ "$BUILT_FEED" == https://* ]] || { echo "✗ The built app has no https SUFeedURL (got '\''$BUILT_FEED'\''). It could never update." >&2; exit 1; }
if [[ "${ALLOW_UNSIGNED_UPDATES:-0}" != "1" && "$BUILT_KEY" != "$PUBLIC_ED_KEY" ]]; then
  echo "✗ The built app's SUPublicEDKey does not match Info.plist. Updates would be refused." >&2
  exit 1
fi

# ── 8. Record the release in the repo ───────────────────────────────────────
# Until now `./release.sh 0.2.0` shipped 0.2.0 while project.yml still said
# 0.1.3 and git recorded nothing, so the committed spec drifted from every
# artifact ever handed out and no tag named the code inside a DMG.
COMMITTED_VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ "$COMMITTED_VERSION" != "$VERSION" ]]; then
  echo "▸ Writing MARKETING_VERSION $COMMITTED_VERSION → $VERSION in project.yml"
  # Only the MARKETING_VERSION line; -i '' is the BSD sed in-place form.
  sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]+\"/\1\"$VERSION\"/" project.yml
  git add project.yml
  git commit -m "chore(release): $VERSION"
fi

# ── 8b. Put the release in the appcast ──────────────────────────────────────
# A GitHub release nobody is told about updates nobody: every installed copy
# learns about new versions from this file and this file only. It is generated
# before the tag so the tag names a commit whose feed already describes the
# build — and pushed by step 9 along with everything else, so there is one
# publish gate rather than two.
if [[ -n "$PUBLIC_ED_KEY" ]]; then
  echo "▸ Signing $DMG into appcast.xml"
  ./scripts/appcast.sh "$DMG" --version "$VERSION" --build "$BUILD"
  if [[ -n "$(git status --porcelain appcast.xml)" ]]; then
    git add appcast.xml
    git commit -m "chore(release): appcast for $VERSION"
  fi
else
  echo "⚠ No signing key — appcast.xml not updated. No installed copy will learn about $VERSION."
fi

TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "⚠ Tag $TAG already exists — leaving it alone."
else
  echo "▸ git tag $TAG"
  git tag -a "$TAG" -m "$APP_NAME $VERSION (build $BUILD)"
fi

# ── 9. Publish, or say loudly that nothing is published ─────────────────────
# The manual "push it yourself" step below was missed once already: v0.2.1 was
# built, committed and tagged locally while GitHub still showed 0.2.0 as the
# latest release, so the fix in it shipped to nobody. A release that no user can
# download is the same as no release, and a script that ends by printing a
# reminder is not a mechanism.
#
# PUBLISH=1 does the whole thing; otherwise the state is reported rather than
# implied, and the exit is non-zero so a CI or wrapper invocation cannot mistake
# "built but unpublished" for "released".
if [[ "${PUBLISH:-0}" == "1" ]]; then
  echo "▸ Pushing $TAG and publishing the release"
  git push origin HEAD --follow-tags
  NOTES_ARG=(--generate-notes)
  if [[ -f CHANGELOG.md ]]; then
    # Cut the section for this version out of the changelog, so the published
    # notes and the repo's record are the same text rather than two accounts.
    if NOTES="$(awk -v v="## [$VERSION]" '
          index($0, v) == 1 { grabbing = 1; next }
          grabbing && /^## \[/ { exit }
          grabbing { print }' CHANGELOG.md)" && [[ -n "${NOTES// /}" ]]; then
      NOTES_ARG=(--notes "$NOTES")
    fi
  fi
  gh release create "$TAG" "$DMG" --title "$APP_NAME $VERSION" "${NOTES_ARG[@]}"
  echo "✓ Published: $(gh release view "$TAG" --json url -q .url)"
else
  echo ""
  echo "⚠ NOT PUBLISHED. The DMG exists, $TAG is tagged locally and appcast.xml is"
  echo "  committed locally — so no user can download it and no installed copy can"
  echo "  see it."
  echo "  Publish with:   PUBLISH=1 $0 $VERSION"
  echo "  Or by hand:     git push origin HEAD --follow-tags \\"
  echo "                  && gh release create $TAG '$DMG' --title '$APP_NAME $VERSION' --notes-file CHANGELOG.md"
fi

echo ""
echo "✓ Done: $DMG"
echo "  Spot-check the embedded CLI is hardened:"
echo "    codesign -dvvv '$APP/Contents/MacOS/photodrop' 2>&1 | grep -E 'Authority|flags'"
echo "  Simulate a clean download (should open with NO Gatekeeper dialog at all —"
echo "  a prompt here means the staple did not take):"
echo "    SPOT=\"\$(mktemp -d)\"; cp -R '$APP' \"\$SPOT/\"; xattr -w com.apple.quarantine '0081;0;Safari;' \"\$SPOT/$APP_NAME.app\"; open \"\$SPOT/$APP_NAME.app\""
