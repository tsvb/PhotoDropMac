#!/usr/bin/env bash
#
# check-appcast-signature.sh — verify appcast.xml's embedded feed signature
# against the SUPublicEDKey in Info.plist, without Sparkle's tools.
#
#   ./scripts/check-appcast-signature.sh [feed] [plist]
#
# Exit 0 when the feed is signed and the signature verifies — or when it is not
# signed at all and REQUIRE_SIGNED_FEED is not 1. Exit 1 on anything else.
#
# Why this exists. `scripts/appcast.sh` signs the feed with `sign_update` after
# every edit: an EdDSA signature over every byte of the file, appended as a
# trailing `<!-- sparkle-signatures: … -->` comment (the format is Sparkle's own,
# read here exactly as SPUExtractAppcastContent reads it). From the release where
# the app sets SURequireSignedFeed, an installed copy refuses a feed whose
# signature does not match — so a hand edit to appcast.xml after it was signed,
# even to a comment, would stop every one of them from seeing any update, and
# Sparkle reports that to the user as nothing more than a failed check. This
# catches it at push time instead. It runs on Linux CI, where Sparkle's tools do
# not exist, which is why it uses openssl: Sparkle's signature is plain Ed25519
# over the bytes before the signing block.
#
# An unsigned feed passes (with a notice) until the app requires a signed one;
# CI sets REQUIRE_SIGNED_FEED=1 from then on.

set -euo pipefail

# Arguments are relative to where the script is called from; the defaults are
# the repo's own files.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FEED="${1:-$REPO/appcast.xml}"
PLIST="${2:-$REPO/Info.plist}"
REQUIRE="${REQUIRE_SIGNED_FEED:-0}"

[[ -f "$FEED"  ]] || { echo "✗ No such feed: $FEED" >&2; exit 1; }
[[ -f "$PLIST" ]] || { echo "✗ No such plist: $PLIST" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Split the feed exactly as Sparkle does: the LAST "<!-- sparkle-signatures:\n"
# starts the signing block; everything before it is the signed content.
STATUS="$(python3 - "$FEED" "$PLIST" "$WORK" <<'PY'
import base64, plistlib, sys
feed_path, plist_path, work = sys.argv[1:4]
data = open(feed_path, 'rb').read()
prefix = b"<!-- sparkle-signatures:\n"
at = data.rfind(prefix)
if at < 0:
    print("unsigned"); sys.exit(0)
end = data.find(b"-->", at + len(prefix))
if end < 0:
    print("malformed:the signing block is not closed"); sys.exit(0)
if data[end + 3:].strip():
    print("malformed:there is content after the signing block"); sys.exit(0)
content = data[:at]
signature = length = None
for line in data[at + len(prefix):end].decode("utf-8", "replace").splitlines():
    if line.startswith("edSignature:"):
        signature = line[len("edSignature:"):].strip()
    elif line.startswith("length:"):
        length = line[len("length:"):].strip()
if not signature or not length:
    print("malformed:the signing block has no edSignature or no length"); sys.exit(0)
if int(length) != len(content):
    print(f"mismatch:{len(content)} bytes are signed-over, the block says {length}"); sys.exit(0)
try:
    sig = base64.b64decode(signature, validate=True)
    pub = base64.b64decode(plistlib.load(open(plist_path, 'rb'))["SUPublicEDKey"], validate=True)
except Exception as error:
    print(f"malformed:{error}"); sys.exit(0)
if len(sig) != 64 or len(pub) != 32:
    print("malformed:the signature or the public key has the wrong length"); sys.exit(0)
open(f"{work}/content", "wb").write(content)
open(f"{work}/sig", "wb").write(sig)
# SubjectPublicKeyInfo for a raw Ed25519 key: fixed 12-byte DER prefix + 32 bytes.
der = bytes.fromhex("302a300506032b6570032100") + pub
pem = b"-----BEGIN PUBLIC KEY-----\n" + base64.b64encode(der) + b"\n-----END PUBLIC KEY-----\n"
open(f"{work}/pub.pem", "wb").write(pem)
print("signed")
PY
)"

case "$STATUS" in
  unsigned)
    if [[ "$REQUIRE" == "1" ]]; then
      echo "✗ $FEED is not signed, and installed copies require a signed feed." >&2
      echo "  Sign it on the release Mac: ./scripts/appcast.sh --sign-only" >&2
      exit 1
    fi
    echo "ℹ $FEED is not signed yet (allowed until the app sets SURequireSignedFeed)."
    exit 0 ;;
  signed)
    if openssl pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin \
         -in "$WORK/content" -sigfile "$WORK/sig" >/dev/null 2>&1; then
      echo "✓ $FEED's signature verifies against $PLIST's SUPublicEDKey."
      exit 0
    fi
    echo "✗ $FEED's signature does not verify against $PLIST's SUPublicEDKey." >&2 ;;
  *)
    echo "✗ $FEED's signing block is unusable: ${STATUS#*:}." >&2 ;;
esac
echo "  appcast.xml was probably edited after it was signed. Re-sign it on the release Mac:" >&2
echo "      ./scripts/appcast.sh --sign-only" >&2
exit 1
