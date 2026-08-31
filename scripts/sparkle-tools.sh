#!/usr/bin/env bash
#
# sparkle-tools.sh — locate Sparkle's command-line tools.
#
# Sourced by sparkle-keys.sh and appcast.sh; not executable on its own.
#
# Sparkle is an SPM dependency, so its tools (generate_keys, sign_update,
# generate_appcast, BinaryDelta) ship inside the resolved artifact bundle rather
# than anywhere on PATH. The path contains a DerivedData hash, so it is found by
# search rather than construction — and the search is written down here once,
# because two scripts and a release depend on it and a silent "tool not found"
# at release time is the worst moment to debug it.

# sparkle_tool <name> → absolute path on stdout, or a diagnostic + exit 2.
sparkle_tool() {
  local name="$1" candidate

  # 1. Explicit override, for a Homebrew install or a vendored copy.
  if [[ -n "${SPARKLE_BIN:-}" ]]; then
    if [[ -x "$SPARKLE_BIN/$name" ]]; then echo "$SPARKLE_BIN/$name"; return 0; fi
    echo "✗ SPARKLE_BIN is set to '$SPARKLE_BIN' but does not contain an executable '$name'." >&2
    return 2
  fi

  # 2. The resolved SPM artifact. Newest first, so a stale DerivedData directory
  #    for the same project does not win over the current one.
  while IFS= read -r candidate; do
    [[ -x "$candidate/$name" ]] && { echo "$candidate/$name"; return 0; }
  #    This project's own DerivedData first, so another project's older Sparkle
  #    cannot win a tie on mtime.
  done < <({ ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/PhotoDropMac-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null
             ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null; })

  # 3. Anything the user already has on PATH.
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi

  echo "✗ Could not find Sparkle's '$name' tool." >&2
  echo "  Resolve the package first:" >&2
  echo "      xcodegen generate && xcodebuild -project PhotoDropMac.xcodeproj -resolvePackageDependencies" >&2
  echo "  Or point SPARKLE_BIN at a directory containing it." >&2
  return 2
}
