# Security Policy

## Reporting a vulnerability

Report security issues privately through **[GitHub's private vulnerability
reporting](https://github.com/tsvb/PhotoDropMac/security/advisories/new)** rather
than a public issue.

If that is unavailable to you, open a public issue containing only *"I have a
security report, please provide a contact"* — no details — and a contact route
will be posted.

Please include the app or `photodrop --version` string, macOS version, and the
smallest reproduction you can manage. There is no bounty; this is a
one-developer project.

## Supported versions

The **latest release** is the only supported version; there is no back-porting.

There is now an in-app update channel (Sparkle), so a security fix can reach you
without your having to notice a new DMG on the Releases page. It is opt-in: if
you declined automatic checks, or you are on a build made from source, you are
back to checking by hand — **Help → Check for Updates…**. Releases before that
channel existed have no route forward except downloading a new DMG.

## The update channel

An updater is a path by which code from the internet becomes code running with
your account's privileges, so it is worth stating exactly what guards it:

- The appcast is fetched over **HTTPS** from
  `raw.githubusercontent.com/tsvb/PhotoDropMac/main/appcast.xml`. The app refuses
  a non-HTTPS feed outright.
- Every update is **signed with an Ed25519 key** whose public half is compiled
  into the copy of PhotoDrop you are already running. Sparkle verifies that
  signature over the downloaded DMG **before** unpacking it. An unsigned or
  wrongly-signed update is refused — a compromised feed or a hijacked download
  URL is not enough to install anything.
- The DMG is *also* Developer ID-signed and notarized by Apple, so Gatekeeper
  checks it independently.
- A build with no signing key configured (any build from source) **starts no
  updater at all** and makes no connection.
- **An update is never installed while an ingest is running.** Sparkle's terminal
  act is to replace and relaunch the app; PhotoDrop refuses update checks during
  a copy and postpones any pending installation until the job has finished and
  written its manifest.

The private signing key lives in the maintainer's login keychain and is never in
this repository. If you believe an update has been served that PhotoDrop should
not have accepted, that is exactly the kind of report the section above is for.

## Known, accepted risk: ImageIO decodes card bytes in-process

This is documented here because a user is entitled to know it before pointing the
app at an untrusted card, and because a finder should not have to rediscover it.

PhotoDrop is **deliberately unsandboxed** (`com.apple.security.app-sandbox =
false`): it needs unrestricted filesystem access to copy from an arbitrary card
to an arbitrary destination, and it shells out to `/usr/sbin/diskutil` to eject.

The consequence is that `ExifReader.dateTaken` runs for every primary on every
scan, and `ThumbnailLoader` decodes previews — both through ImageIO/AVFoundation,
both on **attacker-authored files**, with the user's full filesystem access and
no containment. A crafted RAW or movie that triggers a decoder bug could, in
principle, write `~/Library/LaunchAgents`, or rewrite the
`photodrop.postIngestScript` preference, which the app then executes.

The hardened runtime is enabled on Release builds. It limits code injection; it
provides **no filesystem containment**.

Properly fixing this needs an XPC decode helper, or the sandbox — and the sandbox
would require rethinking eject and folder access, and would rule out this
distribution model. It is recorded, not fixed. If the sandbox decision is ever
revisited, reconsider this first.

**Practical advice:** treat a memory card the way you would treat any removable
media from someone else. Ingesting your own cards from your own cameras is the
designed use.

## What PhotoDrop does not do

- **No telemetry.** There is no analytics and no crash reporting. The only
  outbound connection the app ever makes is the update check described above,
  which you opt into and which sends nothing about you or your photos. The Help
  menu's links open your browser. See [PRIVACY.md](PRIVACY.md).
- **It never writes to the source.** A card is opened read-only.
- **It never overwrites.** Destination files are created with `O_EXCL`, so a
  collision fails the bundle rather than replacing a photo.
