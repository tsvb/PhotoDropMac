# Rendered by scripts/homebrew-cask.sh — do not edit by hand. The tap repo
# (tsvb/homebrew-tap) receives a copy of this file on every published release.
cask "photodropmac" do
  version "0.4.0"
  sha256 "dc4816c287dfa96a3e8264d790e015b5b8f66f6d12aeb9be27e379c223ccfcef"

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

  depends_on macos: ">= :sonoma"

  app "PhotoDropMac.app"
  # The headless CLI ships inside the bundle, signed and notarized with it;
  # this puts it on PATH as `photodrop`.
  binary "#{appdir}/PhotoDropMac.app/Contents/MacOS/photodrop"

  # Scheduled verification installs a launchd agent that points into the bundle.
  uninstall launchctl: "com.tsvb.photodrop.verify"

  zap trash: [
    "~/Library/Application Support/PhotoDropMac",
    "~/Library/Logs/PhotoDrop",
    "~/Library/Preferences/com.tsvb.PhotoDropMac.plist",
  ]
end
