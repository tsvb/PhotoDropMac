#!/usr/bin/env bash
#
# sign-sparkle-helpers.sh — re-sign the executables nested inside
# Sparkle.framework with this build's identity.
#
# Run as a post-build phase of the PhotoDropMac target (see project.yml), not by
# hand: it must happen after the framework is embedded and before Xcode seals the
# app around it.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# Sparkle's XCFramework ships **ad-hoc signed** (`flags=0x10002(adhoc,runtime)` —
# check it with `codesign -dvvv` on the artifact in SourcePackages). Xcode signs
# the framework bundle when it embeds it, but signing a bundle does not re-sign
# the nested code inside it, so the four helpers below stayed ad-hoc in a full
# Developer ID Release build. Measured on this project.
#
# Nothing local catches that: `codesign --verify --deep --strict` reports the app
# as *valid* and satisfying its designated requirement, because ad-hoc signatures
# are structurally fine. Notarization is where it bites — Apple requires every
# executable in the bundle to carry a Developer ID signature and a secure
# timestamp, and an ad-hoc one has neither. The failure would arrive from Apple's
# service after the archive, at the most expensive point in the release.
#
# Signing is innermost-first, and the framework is re-signed last because
# changing nested code breaks the seal above it.
set -euo pipefail

FRAMEWORK="${CODESIGNING_FOLDER_PATH:?must run from an Xcode build phase}/Contents/Frameworks/Sparkle.framework"

if [[ ! -d "$FRAMEWORK" ]]; then
  # A silent skip here would ship exactly the ad-hoc helpers this exists to
  # prevent, so an absent framework is an error rather than a no-op.
  echo "error: $FRAMEWORK not found. Sparkle is a dependency of this target; if the embed step moved, this phase must move with it." >&2
  exit 1
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no code-signing identity in this build; Sparkle's helpers would stay ad-hoc." >&2
  exit 1
fi

ARGS=(--force --sign "$IDENTITY")
# Mirror the configuration rather than hard-coding: Debug is ad-hoc with the
# hardened runtime off, and demanding a secure timestamp there would put a
# network round-trip in every local build.
[[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]] && ARGS+=(--options runtime)
if [[ "${OTHER_CODE_SIGN_FLAGS:-}" == *--timestamp* ]]; then
  ARGS+=(--timestamp)
else
  ARGS+=(--timestamp=none)
fi

V="$FRAMEWORK/Versions/B"
# Innermost first. The entitlements Sparkle ad-hoc signed these with are dropped
# deliberately: they name org.sparkle-project identifiers, and an unsandboxed
# host needs none of them (the XPC services are only used by sandboxed apps).
for helper in \
  "$V/XPCServices/Downloader.xpc" \
  "$V/XPCServices/Installer.xpc" \
  "$V/Updater.app" \
  "$V/Autoupdate"
do
  [[ -e "$helper" ]] || continue
  codesign "${ARGS[@]}" "$helper"
done

codesign "${ARGS[@]}" "$V"

# Prove it, rather than assume it: an ad-hoc flag surviving here is the whole
# defect, and it is invisible to every other check in the build.
if codesign -dvvv "$V/Autoupdate" 2>&1 | grep -q "adhoc"; then
  if [[ "$IDENTITY" != "-" ]]; then
    echo "error: Sparkle's helpers are still ad-hoc signed after re-signing. Notarization would reject this build." >&2
    exit 1
  fi
fi
