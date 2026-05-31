# Releasing PhotoDropMac

PhotoDropMac is distributed as a **Developer ID-signed, notarized DMG** — the
recognized way to ship a Mac app outside the App Store so it opens with no
Gatekeeper warning. (The Mac App Store is not an option: the app is deliberately
unsandboxed for arbitrary card→destination access and to eject cards via
`diskutil`.)

The whole pipeline is `scripts/release.sh`. This document covers the one-time
prerequisites and the per-release steps.

## Prerequisites (one-time)

1. **Apple Developer Program membership (paid, $99/yr).** A free Apple ID
   *cannot* issue Developer ID certificates or notarize. Enroll at
   <https://developer.apple.com> (approval can take a day or two).

2. **A "Developer ID Application" certificate** in your login keychain. Create
   it in Xcode → **Settings → Accounts → Manage Certificates → + → Developer ID
   Application**, or via the Developer portal. Verify:

   ```sh
   security find-identity -v -p codesigning
   ```

   You should see a line like `… "Developer ID Application: Your Name (TEAMID)"`.

3. **Your 10-char Team ID** (developer.apple.com → Membership). Either set it in
   `project.yml` under the `Release` config's `DEVELOPMENT_TEAM`, or pass it as
   `DEVELOPMENT_TEAM=…` when running the release script (preferred — keeps it out
   of the committed file if you'd rather not publish it).

4. **A notarytool credential profile.** Create an app-specific password at
   <https://appleid.apple.com> (Sign-In and Security → App-Specific Passwords),
   then store it once in the keychain:

   ```sh
   xcrun notarytool store-credentials "PhotoDropNotary" \
     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
   ```

   The profile name (`PhotoDropNotary`) is what the script's `NOTARY_PROFILE`
   refers to. **Credentials live in the keychain, never in the repo.**

5. **(Optional) `create-dmg`** for a nicer DMG layout: `brew install create-dmg`.
   Without it the script falls back to `hdiutil`.

## Cutting a release

```sh
DEVELOPMENT_TEAM=ABCDE12345 ./scripts/release.sh 1.0.0
```

- The argument is the marketing **version** (`1.0.0`). If omitted, the script
  reads `MARKETING_VERSION` from `project.yml`.
- The **build number** is set automatically to the commit count
  (`git rev-list --count HEAD`), so it always increases.
- `NOTARY_PROFILE` defaults to `PhotoDropNotary`; override via env if you named
  your profile differently.

The script runs, in order:

1. `xcodegen generate` — regenerate the project from `project.yml`.
2. `xcodebuild … -configuration Release … archive` — builds and signs the app
   **and** the embedded `photodrop` CLI with Developer ID + hardened runtime +
   secure timestamp. (Xcode signs the nested CLI before sealing the app wrapper,
   so the signing order is correct automatically — do **not** hand-sign with
   `codesign --deep`.)
3. Package the `.app` into `build/PhotoDropMac-<version>.dmg`.
4. `xcrun notarytool submit … --wait` — upload to Apple and block until the
   verdict.
5. `xcrun stapler staple` — attach the notarization ticket so the DMG validates
   offline.
6. Verify (`codesign --verify`, `spctl`, `stapler validate`).

Then upload the DMG to a **GitHub Release**.

## Verifying a build by hand

```sh
APP="build/PhotoDropMac.xcarchive/Products/Applications/PhotoDropMac.app"

# Signature valid, including the embedded CLI:
codesign --verify --deep --strict --verbose=2 "$APP"

# The embedded photodrop is hardened (flags must include "runtime"):
codesign -dvvv "$APP/Contents/MacOS/photodrop" 2>&1 | grep -E 'Authority|flags'

# Gatekeeper accepts it as notarized:
spctl -a -t exec -vvv "$APP"          # → accepted, source=Notarized Developer ID
xcrun stapler validate build/PhotoDropMac-*.dmg

# The real test — simulate a downloaded, quarantined copy. Should open with no dialog:
cp -R "$APP" /tmp/PhotoDropMac.app
xattr -w com.apple.quarantine "0081;0;Safari;" /tmp/PhotoDropMac.app
open /tmp/PhotoDropMac.app
```

## Troubleshooting

- **Notarization came back `Invalid`.** Read the per-binary log — it names the
  offending file and reason:

  ```sh
  xcrun notarytool log <submission-id> --keychain-profile "PhotoDropNotary"
  ```

  The usual causes (a missing secure timestamp, or a non-hardened nested binary)
  are already prevented by the `Release` config in `project.yml`.

- **`No 'Developer ID Application' certificate`** from the script's preflight:
  prerequisite #2 isn't done. Until it is, only Debug (ad-hoc) builds work.

- **The scheduled-verification launchd job stops working after moving the app.**
  Its plist points at `…/PhotoDropMac.app/Contents/MacOS/photodrop`; if the app
  is moved or deleted, the job degrades to a benign "verification found issues"
  notification. Re-toggle scheduled verification in **Settings → Maintenance** to
  rewrite the path.

## Notes

- **Versioning.** Bump the committed `MARKETING_VERSION` in `project.yml` at real
  milestones; the precise build number is supplied per-build by the script, so
  routine releases don't need a `project.yml` edit. The CLI's own `--version`
  string in `Sources/PhotoDropCLI/PhotoDropCLI.swift` is separate — keep it in
  sync.
- **Future channels.** A Homebrew cask (`brew install --cask`) and in-app Sparkle
  auto-updates both build on top of this notarized DMG; neither is set up yet.
