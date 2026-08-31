#!/usr/bin/env bash
#
# sparkle-keys.sh — create (or look up) the Sparkle update-signing key and write
# its public half into Info.plist.
#
# Run this ONCE per developer machine. The private key lives in your login
# keychain and is never written to the repo; the public key is the trust anchor
# every shipped build carries, so it is committed.
#
#   ./scripts/sparkle-keys.sh            # generate if absent, then write the plist
#   ./scripts/sparkle-keys.sh --print    # just show the public key, change nothing
#
# ── The one thing to get right ───────────────────────────────────────────────
# Once builds carrying this public key are in users' hands, the key can never
# change: an update signed with a different key is refused by every copy already
# out there, and those users are stranded on the version they have with no
# in-app route forward. Back the private key up — `generate_keys -x <file>` exports
# it — and keep that export somewhere you would keep a certificate.

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/sparkle-tools.sh
source "scripts/sparkle-tools.sh"

PLIST="Info.plist"
PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

GENERATE_KEYS="$(sparkle_tool generate_keys)"

# -p prints the existing public key and exits non-zero if there isn't one, which
# is exactly the "do I already have a key?" question — asked without the risk of
# creating a second one by accident.
if PUBKEY="$("$GENERATE_KEYS" -p 2>/dev/null)" && [[ -n "$PUBKEY" ]]; then
  echo "▸ Using the existing signing key from your keychain."
else
  if [[ "$PRINT_ONLY" == "1" ]]; then
    echo "✗ No Sparkle signing key in this keychain. Run without --print to create one." >&2
    exit 2
  fi
  echo "▸ No signing key found. Generating one (your keychain will ask permission)."
  "$GENERATE_KEYS"
  PUBKEY="$("$GENERATE_KEYS" -p)"
fi

PUBKEY="$(printf '%s' "$PUBKEY" | tr -d '[:space:]')"
[[ -n "$PUBKEY" ]] || { echo "✗ generate_keys returned no public key." >&2; exit 2; }

echo "▸ Public key: $PUBKEY"

if [[ "$PRINT_ONLY" == "1" ]]; then exit 0; fi

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || echo "")"
if [[ "$CURRENT" == "$PUBKEY" ]]; then
  echo "✓ $PLIST already carries this key. Nothing to do."
  exit 0
fi

# Replacing a *different* non-empty key strands every build already shipped with
# the old one, so it is refused rather than done quietly. Overriding is a
# deliberate act with a flag on it.
if [[ -n "$CURRENT" && "${FORCE_KEY_ROTATION:-0}" != "1" ]]; then
  echo "✗ $PLIST already carries a different public key:" >&2
  echo "    in the plist : $CURRENT" >&2
  echo "    in the keychain: $PUBKEY" >&2
  echo "" >&2
  echo "  Every copy of PhotoDrop already released was built with the plist's key" >&2
  echo "  and will REFUSE an update signed by any other. Changing it strands those" >&2
  echo "  users with no in-app route forward." >&2
  echo "  If the old private key is genuinely lost, that trade is yours to make:" >&2
  echo "      FORCE_KEY_ROTATION=1 $0" >&2
  echo "  …and then tell users to download the next release by hand." >&2
  exit 2
fi

# A targeted in-place replacement of the one <string>, NOT `PlistBuddy -c Set`.
# PlistBuddy rewrites the entire file from its parsed form, which drops every XML
# comment — measured: one run erased the whole rationale block in Info.plist,
# including the paragraph explaining why this key can never change.
awk -v key="$PUBKEY" '
  found && /<string>/ { sub(/<string>[^<]*<\/string>/, "<string>" key "<\/string>"); found = 0 }
  /<key>SUPublicEDKey<\/key>/ { found = 1 }
  { print }
' "$PLIST" > "$PLIST.tmp" && mv "$PLIST.tmp" "$PLIST"

# The plist is what the app is built from; a malformed one fails the build with a
# far less obvious message than this.
plutil -lint "$PLIST" >/dev/null || { echo "✗ $PLIST is no longer a valid plist. Restore it from git." >&2; exit 2; }
WRITTEN="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
[[ "$WRITTEN" == "$PUBKEY" ]] || { echo "✗ Wrote $PLIST but it reads back as '$WRITTEN'." >&2; exit 2; }

echo "✓ Wrote SUPublicEDKey into $PLIST."
echo ""
echo "  Commit it — it is public by design and every build must carry the same one:"
echo "      git add $PLIST && git commit -m 'chore(updates): add the Sparkle signing key'"
echo ""
echo "  Back the PRIVATE key up now, while you still have it:"
echo "      $GENERATE_KEYS -x sparkle-private-key.txt   # then store it somewhere safe, NOT in this repo"
