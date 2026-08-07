#!/usr/bin/env bash
#
# Verify that every relative markdown link in the repo's docs points at a file
# that exists.
#
# CLAUDE.md accumulated 13 broken links across 11 unique paths simply by
# surviving the Core/ + UI/ reorganisation — flat `Sources/PhotoDropMac/X.swift`
# paths that no longer resolve. Each one silently sends a reader to a file that
# isn't there, and in a repo whose whole problem is that knowledge fails to
# travel between files, that is not cosmetic.
#
# Handles `[text](path)` and `[text](path:123)` — a trailing `:line` is a
# clickable line anchor, not part of the filename. Skips http(s), mailto and
# in-page `#anchor` links.
#
# Usage: scripts/check-doc-links.sh [file ...]   (defaults to the repo's docs)

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.md')
fi

broken=0
checked=0

for doc in "${files[@]}"; do
  [[ -f "$doc" ]] || continue
  # One link target per line.
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in
      http://*|https://*|mailto:*|'#'*) continue ;;
    esac
    # Strip a :line / :line:col suffix and any #fragment.
    path="${target%%#*}"
    path="$(printf '%s' "$path" | sed -E 's/:[0-9]+(:[0-9]+)?$//')"
    [[ -n "$path" ]] || continue

    checked=$((checked + 1))
    # Links are relative to the file that contains them.
    base="$(dirname "$doc")"
    if [[ ! -e "$base/$path" ]]; then
      line="$(grep -n -F "($target)" "$doc" | head -1 | cut -d: -f1)"
      echo "::error file=$doc,line=${line:-1}::broken link → $path"
      printf '  %s:%s  →  %s\n' "$doc" "${line:-?}" "$path" >&2
      broken=$((broken + 1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$doc" | sed -E 's/^\]\(//; s/\)$//')
done

if [[ $broken -gt 0 ]]; then
  echo "" >&2
  echo "✗ $broken broken link(s) out of $checked checked." >&2
  exit 1
fi

echo "✓ All $checked relative links resolve."
