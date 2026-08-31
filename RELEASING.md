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

5. **A Sparkle update-signing key.** Run it once and commit the result:

   ```sh
   ./scripts/sparkle-keys.sh
   ```

   It creates an Ed25519 keypair (or reuses the one already in your keychain —
   Sparkle deliberately uses **one key per user account**, not one per app),
   stores the private half in the login keychain, and writes the public half into
   `Info.plist` as `SUPublicEDKey`. Commit that: it is public by design, and it is
   the trust anchor every shipped copy of the app carries.

   **Back the private key up now**, somewhere you would keep a certificate. The
   script prints the exact `generate_keys -x …` command to run, with the full path
   to the tool (it lives inside the resolved Sparkle package, not on `PATH`).
   Export it to somewhere **outside this repo** — `.gitignore` covers the obvious
   filenames, but that is a net, not a plan.

   Losing it is close to unrecoverable: every installed copy refuses an update
   signed by any other key, so the whole userbase would be stranded on whatever
   version they have with no in-app route forward. `sparkle-keys.sh` refuses to
   overwrite a different committed key for that reason (`FORCE_KEY_ROTATION=1`
   overrides, and means telling users to download the next release by hand).

6. **(Optional) `create-dmg`** for a nicer DMG layout: `brew install create-dmg`.
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

0. Preflight — Developer ID certificate, notarytool profile, and **both halves of
   the update-signing key**: `Info.plist` must carry a public key, and the private
   key in your keychain must be the matching one. A mismatch there is invisible
   until the feed is live and every installed copy silently refuses every update,
   so it is caught before anything expensive runs. (`ALLOW_UNSIGNED_UPDATES=1`
   ships a build that can never update itself — loudly.)
1. `xcodegen generate` — regenerate the project from `project.yml`.
2. `xcodebuild … -configuration Release … archive` — builds and signs the app
   **and** the embedded `photodrop` CLI with Developer ID + hardened runtime +
   secure timestamp. (Xcode signs the nested CLI before sealing the app wrapper,
   so the signing order is correct automatically — do **not** hand-sign with
   `codesign --deep`.)
3. `xcrun notarytool submit` the `.app` (zipped with `ditto`) and `stapler
   staple` it. This happens **before** the DMG is built, so the copy the user
   drags to /Applications carries its own ticket — see "Why the app is stapled
   too" below.
4. Package the stapled `.app` into `build/PhotoDropMac-<version>.dmg`.
5. `xcrun notarytool submit … --wait` — upload the DMG and block until the
   verdict.
6. `xcrun stapler staple` — attach the ticket so the DMG validates offline too.
7. Verify (`codesign --verify`, `spctl`, `stapler validate` on **both** the app
   and the DMG) — and read `SUFeedURL` / `SUPublicEDKey` back out of the **built**
   bundle, because a key that is right in the repo and missing from the product is
   an app that silently never updates (see the header comment in `Info.plist`).
8. `scripts/appcast.sh` — sign the DMG with the private key and add an `<item>` to
   `appcast.xml`, with release notes cut from `CHANGELOG.md`. Committed before the
   tag, so the tag names a commit whose feed already describes the build.
9. Tag, and — with `PUBLISH=1` — push and create the GitHub release.

### Why the app is stapled too

A notarization ticket is bound to a specific cdhash, so a ticket stapled to the
DMG covers *the DMG*. Once the user copies the app out and throws the disk image
away, nothing on disk proves the app was notarized — Gatekeeper has to ask Apple
at first launch, and that check fails closed when the machine is offline:
*"PhotoDropMac cannot be opened because Apple cannot check it for malicious
software."* Stapling the app before it is packaged makes first launch work with
no network, which is the entire point of stapling. The two `stapler validate`
calls in step 7 are what stop this regressing.

Then upload the DMG to a **GitHub Release** (`PUBLISH=1` does this for you).

## The update feed

`appcast.xml` at the repo root **is** the update channel. Every copy of PhotoDrop
ever shipped polls exactly one URL:

```
https://raw.githubusercontent.com/tsvb/PhotoDropMac/main/appcast.xml
```

That address is compiled into every build, so it cannot be changed without
stranding every copy already in the wild. Three things follow:

- **A release that is not in `appcast.xml` has not shipped.** The GitHub release
  can exist, be notarized and be downloadable, and no installed copy will ever
  hear about it. This is the same failure as the unpushed tag that the `PUBLISH`
  gate exists to prevent — `release.sh` therefore updates the feed itself, and
  pushes it in the same step as the tag.
- **The file is append-only in practice.** Deleting an item does not recall a
  release; it only hides it from anyone still on an older build.
- **Never hand-edit an enclosure's signature or length.** Sparkle silently ignores
  an item it cannot verify, which from the app looks exactly like "there is no
  update". Use `scripts/appcast.sh` — it signs, inserts, and then checks the file
  still parses.

To repair or backfill a feed by hand:

```sh
./scripts/appcast.sh build/PhotoDropMac-0.4.0.dmg --version 0.4.0 --build 123
# --url to override the download URL, --force to replace an existing item,
# SPARKLE_PRIVATE_KEY_FILE=<exported key> to sign without the login keychain.
```

Release notes come from the matching `## [<version>]` section of `CHANGELOG.md`,
converted to the small subset of HTML Sparkle renders, and are **embedded** in the
item — so a user deciding whether to install does not need a second network fetch
to read what changed.

## Verifying a build by hand

```sh
APP="build/PhotoDropMac.xcarchive/Products/Applications/PhotoDropMac.app"

# Signature valid, including the embedded CLI:
codesign --verify --deep --strict --verbose=2 "$APP"

# The embedded photodrop is hardened (flags must include "runtime"):
codesign -dvvv "$APP/Contents/MacOS/photodrop" 2>&1 | grep -E 'Authority|flags'

# Gatekeeper accepts it as notarized:
spctl -a -t exec -vvv "$APP"          # → accepted, source=Notarized Developer ID

# Both must report "The validate action worked!" — the app's own ticket is what
# makes an offline first launch succeed after the DMG is discarded:
xcrun stapler validate "$APP"
xcrun stapler validate build/PhotoDropMac-*.dmg

# The real test — simulate a downloaded, quarantined copy. Should open with no dialog:
SPOT="$(mktemp -d)"
cp -R "$APP" "$SPOT/"
xattr -w com.apple.quarantine "0081;0;Safari;" "$SPOT/PhotoDropMac.app"
open "$SPOT/PhotoDropMac.app"
```

## Troubleshooting

- **Notarization came back `Invalid`.** Read the per-binary log — it names the
  offending file and reason:

  ```sh
  xcrun notarytool log <submission-id> --keychain-profile "PhotoDropNotary"
  ```

  The usual causes (a missing secure timestamp, or a non-hardened nested binary)
  are already prevented by the `Release` config in `project.yml` — and the one
  that config does *not* cover, Sparkle's ad-hoc signed nested helpers, is handled
  by the `Sign Sparkle's nested helpers` build phase and asserted again in step 7.
  If a notarization log ever names `Autoupdate`, `Updater.app`, `Installer.xpc` or
  `Downloader.xpc`, that phase is what stopped running.

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
- **In-app updates** are set up — see "The update feed" above. A Homebrew cask
  (`brew install --cask`) still is not; it would build on the same notarized DMG.
