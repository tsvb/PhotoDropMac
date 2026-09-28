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
  signature over the downloaded DMG **before** mounting it. An unsigned or
  wrongly-signed update is refused — a compromised feed or a hijacked download
  URL is not enough to install anything. (0.5.0 and earlier mounted the DMG
  first and checked the signature before installing anything from it.)
- The **feed is signed** with the same key, and the app refuses a feed whose
  signature does not verify, so the versions and download links it offers are
  the ones the maintainer published: an older signed build cannot be relabeled
  as the newest. 0.5.0 and earlier do not check the feed's signature.
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

## Known, accepted risk: the post-ingest hook is a preference

The post-ingest hook is a path stored in PhotoDrop's preferences, and PhotoDrop
runs it. macOS treats a program PhotoDrop starts as PhotoDrop for privacy
purposes, so the hook inherits whatever Files & Folders, removable-volume or Full
Disk Access you have granted PhotoDrop. Any process running as your account can
rewrite that preference (`defaults write com.tsvb.PhotoDropMac
photodrop.postIngestScript …`) — including one you have *not* granted that access
— and so borrow PhotoDrop's.

What PhotoDrop does about it:

- The ingest screen names the hook before every ingest, so a path you did not set
  is visible before you press Ingest.
- The hook is refused if the script, or any folder above it, can be written by
  another user, and if it is on a removable volume (a card mounted under the same
  name as the drive your script lives on would otherwise supply its own).
  Settings shows why a configured hook would be refused.
- It runs only after an ingest that took everything on the card.

What it does not do is stop a process already running as you from changing the
preference. Closing that needs the hook configuration kept somewhere only
PhotoDrop can write, or the hook run without PhotoDrop's privacy grants (which
would make hooks that touch an external library prompt for access themselves).
If you do not use a hook, leave the setting empty; nothing runs.

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
