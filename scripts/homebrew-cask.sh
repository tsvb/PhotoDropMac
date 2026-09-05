#!/usr/bin/env bash
#
# homebrew-cask.sh — render (and optionally publish) the Homebrew cask for a release.
#
#   ./scripts/homebrew-cask.sh build/PhotoDropMac-0.4.0.dmg --version 0.4.0
#   ./scripts/homebrew-cask.sh --version 0.4.0 --sha256 <hex>        # from the release asset's digest; no file needed
#   ./scripts/homebrew-cask.sh … --publish-to tsvb/homebrew-tap      # also push Casks/photodropmac.rb to the tap
#
# Renders homebrew/Casks/photodropmac.rb (override with --out). The cask is
# committed here so it is versioned with the release it describes, and mirrored
# into the tap repo on publish, which is what makes
#     brew install --cask tsvb/tap/photodropmac
# work. Homebrew will not install a cask from a URL, so the tap repo has to
# exist; it is created once, and never touched by hand again:
#     gh repo create tsvb/homebrew-tap --public --description "Homebrew tap for tsvb's apps"
#
# The cask says `auto_updates true`: the app updates itself through Sparkle, and
# without that flag `brew upgrade` would reinstall over a copy Sparkle had
# already moved past. `livecheck` reads the same appcast the app does.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG=""; VERSION=""; SHA=""; OUT="homebrew/Casks/photodropmac.rb"; PUBLISH_TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VERSION="$2";    shift 2 ;;
    --sha256)     SHA="$2";        shift 2 ;;
    --out)        OUT="$2";        shift 2 ;;
    --publish-to) PUBLISH_TO="$2"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    -*)           echo "✗ Unknown option: $1" >&2; exit 64 ;;
    *)            DMG="$1";        shift ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "✗ --version is required." >&2; exit 64; }
if [[ -z "$SHA" ]]; then
  [[ -n "$DMG" && -f "$DMG" ]] || { echo "✗ Give the DMG, or --sha256 from the release asset's digest." >&2; exit 64; }
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "✗ '$SHA' is not a sha256 hex digest." >&2; exit 2; }

# The minimum macOS the cask declares is the deployment target the app is built
# for, read from the one place it is defined rather than restated here.
MIN_OS="$(awk '/deploymentTarget:/{found=1} found && /macOS:/{gsub(/[^0-9.]/,"",$2); print $2; exit}' project.yml)"
case "${MIN_OS%%.*}" in
  14) MACOS_SYMBOL=":sonoma" ;;
  15) MACOS_SYMBOL=":sequoia" ;;
  26) MACOS_SYMBOL=":tahoe" ;;
  *)  echo "✗ No Homebrew symbol known for macOS $MIN_OS — add it to $0." >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$OUT")"
# `#{version}` and `#{appdir}` are Ruby interpolations and must survive the
# heredoc verbatim; bash only expands `$…` and backticks here, so they do.
cat > "$OUT" <<CASK
# Rendered by scripts/homebrew-cask.sh — do not edit by hand. The tap repo
# (tsvb/homebrew-tap) receives a copy of this file on every published release.
cask "photodropmac" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/tsvb/PhotoDropMac/releases/download/v#{version}/PhotoDropMac-#{version}.dmg"
  name "PhotoDrop"
  desc "Verified photo ingest from memory cards into a date-organized library"
  homepage "https://github.com/tsvb/PhotoDropMac"

  # The app updates itself (Sparkle); brew upgrade must not fight it.
  auto_updates true
  livecheck do
    url "https://raw.githubusercontent.com/tsvb/PhotoDropMac/main/appcast.xml"
    strategy :sparkle
  end

  depends_on macos: ">= $MACOS_SYMBOL"

  app "PhotoDropMac.app"
  # The headless CLI ships inside the bundle, signed and notarized with it;
  # this puts it on PATH as \`photodrop\`.
  binary "#{appdir}/PhotoDropMac.app/Contents/MacOS/photodrop"

  # Scheduled verification installs a launchd agent that points into the bundle.
  uninstall launchctl: "com.tsvb.photodrop.verify"

  zap trash: [
    "~/Library/Application Support/PhotoDropMac",
    "~/Library/Logs/PhotoDrop",
    "~/Library/Preferences/com.tsvb.PhotoDropMac.plist",
  ]
end
CASK

# A cask that does not parse is a tap that fails for every brew user at once.
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$OUT" >/dev/null || { echo "✗ $OUT is not valid Ruby." >&2; exit 2; }
fi
echo "✓ Wrote $OUT ($VERSION, sha256 $SHA)"

if [[ -n "$PUBLISH_TO" ]]; then
  TAP_PATH="Casks/photodropmac.rb"
  # The contents API needs the current blob's sha to update an existing file,
  # and no sha to create one.
  EXISTING_SHA="$(gh api "repos/$PUBLISH_TO/contents/$TAP_PATH" --jq .sha 2>/dev/null || true)"
  ARGS=(-X PUT "repos/$PUBLISH_TO/contents/$TAP_PATH"
        -f message="photodropmac $VERSION"
        -f content="$(base64 < "$OUT" | tr -d '\n')")
  [[ -n "$EXISTING_SHA" ]] && ARGS+=(-f sha="$EXISTING_SHA")
  gh api "${ARGS[@]}" --jq '.content.html_url'
  echo "✓ Published to $PUBLISH_TO/$TAP_PATH — brew install --cask ${PUBLISH_TO%/homebrew-*}/${PUBLISH_TO#*/homebrew-}/photodropmac"
fi
