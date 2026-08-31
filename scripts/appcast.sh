#!/usr/bin/env bash
#
# appcast.sh — sign a released DMG and add it to appcast.xml.
#
#   ./scripts/appcast.sh build/PhotoDropMac-0.4.0.dmg --version 0.4.0 --build 123
#
# Options:
#   --version <v>    marketing version (CFBundleShortVersionString)
#   --build <n>      build number (CFBundleVersion) — what Sparkle actually
#                    compares, so it must increase with every release
#   --url <url>      download URL (default: the GitHub release asset for v<version>)
#   --feed <path>    appcast to edit (default: appcast.xml)
#   --changelog <p>  file to cut release notes from (default: CHANGELOG.md)
#   --force          replace an existing item for this version
#
# Environment:
#   SPARKLE_PRIVATE_KEY_FILE  sign with an exported private key instead of the
#                             login keychain (for CI or a second machine).
#
# Called by scripts/release.sh after the DMG is notarized and uploaded. Usable on
# its own to repair a feed.
#
# The signature is produced by Sparkle's sign_update using the private key in
# your login keychain. **A release that is not in this file has not shipped**:
# users on an older build will never be offered it, no matter that the GitHub
# release exists — which is the same failure mode as the unpushed tag that
# release.sh's PUBLISH gate exists to prevent.

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/sparkle-tools.sh
source "scripts/sparkle-tools.sh"

DMG=""; VERSION=""; BUILD=""; URL=""; FEED="appcast.xml"; CHANGELOG="CHANGELOG.md"; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --build)     BUILD="$2";   shift 2 ;;
    --url)       URL="$2";     shift 2 ;;
    --feed)      FEED="$2";    shift 2 ;;
    --changelog) CHANGELOG="$2"; shift 2 ;;
    --force)     FORCE=1;      shift ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    -*)          echo "✗ Unknown option: $1" >&2; exit 64 ;;
    *)           DMG="$1";     shift ;;
  esac
done

[[ -n "$DMG"     ]] || { echo "✗ No DMG given. Usage: $0 <dmg> --version <v> --build <n>" >&2; exit 64; }
[[ -f "$DMG"     ]] || { echo "✗ No such file: $DMG" >&2; exit 2; }
[[ -n "$VERSION" ]] || { echo "✗ --version is required." >&2; exit 64; }
[[ -n "$BUILD"   ]] || { echo "✗ --build is required — it is the number Sparkle compares." >&2; exit 64; }
[[ -f "$FEED"    ]] || { echo "✗ No such feed: $FEED" >&2; exit 2; }

# The public key in the plist and the private key in the keychain are two halves
# of one thing. Signing with no key configured in the app produces an item every
# client ignores.
PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist 2>/dev/null || echo "")"
if [[ -z "$PUBKEY" ]]; then
  echo "✗ Info.plist carries no SUPublicEDKey, so no build can verify this item." >&2
  echo "  Run ./scripts/sparkle-keys.sh first." >&2
  exit 2
fi

if grep -q "sparkle:shortVersionString>$VERSION<" "$FEED"; then
  if [[ "$FORCE" != "1" ]]; then
    echo "✗ $FEED already has an item for $VERSION. Use --force to replace it." >&2
    exit 2
  fi
  echo "▸ Removing the existing item for $VERSION (--force)"
  awk -v v="<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" '
    /<item>/ { buf = $0 "\n"; inside = 1; hit = 0; next }
    inside   { buf = buf $0 "\n"; if (index($0, v)) hit = 1
               if ($0 ~ /<\/item>/) { if (!hit) printf "%s", buf; inside = 0 }
               next }
    { print }
  ' "$FEED" > "$FEED.tmp" && mv "$FEED.tmp" "$FEED"
fi

DOWNLOAD_URL="${URL:-https://github.com/tsvb/PhotoDropMac/releases/download/v$VERSION/$(basename "$DMG")}"

# Deployment target, read from the one place that sets it, so the feed can never
# offer an update to a Mac that cannot run it.
MIN_OS="$(awk '/deploymentTarget:/{found=1} found && /macOS:/{gsub(/[^0-9.]/,"",$2); print $2; exit}' project.yml)"
MIN_OS="${MIN_OS:-14.0}"

SIGN_UPDATE="$(sparkle_tool sign_update)"
# By default the private key is read from the login keychain. SPARKLE_PRIVATE_KEY_FILE
# points at an exported key instead (`generate_keys -x`), which is how a CI runner
# or a second machine signs without the developer's keychain.
KEY_ARGS=()
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  [[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]] || { echo "✗ SPARKLE_PRIVATE_KEY_FILE does not exist: $SPARKLE_PRIVATE_KEY_FILE" >&2; exit 2; }
  KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi
echo "▸ Signing $DMG"
# Prints, verbatim: sparkle:edSignature="…" length="…" — embedded as-is rather
# than parsed and reassembled, so there is nothing to get subtly wrong.
ENCLOSURE_ATTRS="$("$SIGN_UPDATE" "${KEY_ARGS[@]+"${KEY_ARGS[@]}"}" "$DMG")"
[[ "$ENCLOSURE_ATTRS" == *edSignature=* ]] || {
  echo "✗ sign_update produced no signature: $ENCLOSURE_ATTRS" >&2; exit 2; }

PUB_DATE="$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")"

# Release notes, cut from the changelog and converted to the small subset of
# HTML Sparkle's update window renders. Embedded rather than linked: a user
# deciding whether to install should not need a second network fetch to read
# what changed, and the notes then match the repo's record exactly.
NOTES_HTML=""
if [[ -f "$CHANGELOG" ]]; then
  NOTES_HTML="$(awk -v v="## [$VERSION]" '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    # Turn a paired delimiter into open/close tags. An odd count is left alone —
    # a lone asterisk in prose must not open a tag that never closes.
    function pair(s, d, o, c,   n, t, p, open, out) {
      t = s; n = 0
      while ((p = index(t, d)) > 0) { n++; t = substr(t, p + length(d)) }
      if (n == 0 || n % 2) return s
      out = ""; open = 1
      while ((p = index(s, d)) > 0) {
        out = out substr(s, 1, p - 1) (open ? o : c)
        s = substr(s, p + length(d)); open = !open
      }
      return out s
    }
    # [text](target) → a real link for an absolute URL, plain text for a relative
    # one. A repo-relative path means nothing in Sparkle'"'"'s update window, and
    # leaving the markdown raw put a literal "[PRIVACY.md](PRIVACY.md)" in front
    # of the user at the moment they are deciding whether to install.
    function links(s,   out, m, text, target, inner) {
      out = ""
      while (match(s, /\[[^][]*\]\([^()]*\)/)) {
        inner = substr(s, RSTART, RLENGTH)
        text   = substr(inner, 2, index(inner, "](") - 2)
        target = substr(inner, index(inner, "](") + 2, length(inner) - index(inner, "](") - 2)
        m = (target ~ /^https?:\/\//) ? "<a href=\"" target "\">" text "</a>" : text
        out = out substr(s, 1, RSTART - 1) m
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    function inline(s) {
      s = esc(s)
      s = links(s)
      s = pair(s, "`",  "<code>", "</code>")
      s = pair(s, "**", "<strong>", "</strong>")
      return pair(s, "*", "<em>", "</em>")
    }
    # Blocks are buffered rather than emitted per line: the changelog is hard
    # wrapped, so a line-at-a-time conversion put every continuation line outside
    # the <li> or <p> it belonged to, and split each paragraph into one <p> per
    # line. Measured on the 0.3.0 notes.
    function flush(  text) {
      if (mode == "") return
      text = inline(buf)
      if (mode == "li") print "<li>" text "</li>"; else print "<p>" text "</p>"
      mode = ""; buf = ""
    }
    function closelist() { flush(); if (inlist) { print "</ul>"; inlist = 0 } }
    function append(line) { sub(/^[[:space:]]+/, "", line); buf = (buf == "") ? line : buf " " line }
    index($0, v) == 1 { grabbing = 1; next }
    grabbing && /^## \[/ { exit }
    !grabbing { next }
    /^#{3,} / { closelist(); sub(/^#+ +/, ""); print "<h3>" inline($0) "</h3>"; next }
    /^[[:space:]]*[-*] / {
      flush()
      if (!inlist) { print "<ul>"; inlist = 1 }
      sub(/^[[:space:]]*[-*] +/, "")
      mode = "li"; buf = $0
      next
    }
    /^[[:space:]]*$/ { closelist(); next }
    { if (mode == "") mode = "para"; append($0); next }
    END { closelist() }
  ' "$CHANGELOG")"
fi
if [[ -z "${NOTES_HTML// /}" ]]; then
  echo "⚠ No $CHANGELOG section found for $VERSION — the item will carry no release notes." >&2
  NOTES_HTML="<p>See the release page for details.</p>"
fi
# CDATA is the wrapper, so the only sequence that can break out is "]]>".
NOTES_HTML="${NOTES_HTML//]]>/]]&gt;}"

ITEM_FILE="$(mktemp)"
trap 'rm -f "$ITEM_FILE"' EXIT
cat > "$ITEM_FILE" <<ITEM
        <item>
            <title>PhotoDrop $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <link>https://github.com/tsvb/PhotoDropMac/releases/tag/v$VERSION</link>
            <description><![CDATA[
$NOTES_HTML
]]></description>
            <enclosure url="$DOWNLOAD_URL"
                       type="application/octet-stream"
                       $ENCLOSURE_ATTRS />
        </item>
ITEM

MARKER="NEW ITEMS ARE INSERTED DIRECTLY BELOW THIS LINE"
grep -q "$MARKER" "$FEED" || { echo "✗ $FEED has lost its insertion marker." >&2; exit 2; }
awk -v marker="$MARKER" -v itemfile="$ITEM_FILE" '
  { print }
  index($0, marker) { while ((getline line < itemfile) > 0) print line; close(itemfile) }
' "$FEED" > "$FEED.tmp" && mv "$FEED.tmp" "$FEED"

# A feed that does not parse is a feed nobody can update from, and the failure is
# invisible from the app: Sparkle just reports no update, forever.
xmllint --noout "$FEED" 2>/dev/null || {
  echo "✗ $FEED is no longer well-formed XML. Not committing this." >&2; exit 2; }

echo "✓ Added $VERSION (build $BUILD) to $FEED"
echo "  Download URL: $DOWNLOAD_URL"
echo "  Commit and push it, or no existing installation will ever see this release."
