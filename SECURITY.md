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

The **latest release** is the only supported version. There is no back-porting,
and — until an update channel exists — no in-app update prompt either, so a fix
reaches you only when you download a new DMG. That is a known gap, tracked
publicly, and it is the reason this file names it rather than implying otherwise.

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

- **No network access.** The app makes no outbound connections of any kind. The
  Help menu's links open your browser; nothing phones home, and there is no
  telemetry, crash reporting, or update check. See [PRIVACY.md](PRIVACY.md).
- **It never writes to the source.** A card is opened read-only.
- **It never overwrites.** Destination files are created with `O_EXCL`, so a
  collision fails the bundle rather than replacing a photo.
