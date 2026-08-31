# Privacy

PhotoDrop collects nothing, sends nothing, and has no servers.

## No network access

The app makes **no outbound network connections**. There is no telemetry, no
analytics, no crash reporting, and no update check. The only URLs in the source
are the Help menu's links, which open in your browser when you click them, and a
test fixture.

This is a deliberate trade. It means the developer has no signal at all when a
user hits a failure — no error counts, no crash traces, nothing. For a tool that
reads photo libraries and filesystem paths, that is the right side of the trade:
a crash report from a photographer's card is exactly the payload you least want
leaving the machine.

If you want to report a problem, the app writes everything needed to do so
locally — see below — and the completion sheet has a **Copy Details** button for
the failure list.

## What stays on your Mac

| What | Where |
|---|---|
| Job logs | `~/Library/Logs/PhotoDrop/` |
| Verification manifests (JSON, CSV, MHL) | `<destination>/PhotoDrop Manifests/` |
| Hash cache | `~/Library/Application Support/PhotoDropMac/hash-cache.json` |
| Preferences, including recently ingested cards | the app's `UserDefaults` domain |
| Scheduled-verify agent (if enabled) | `~/Library/LaunchAgents/` |

All of it is yours, in plain formats, and can be deleted at any time. Deleting
the hash cache costs only a re-hash. Deleting a manifest costs the ability to
verify that job's files against it — the per-file checksum attributes survive, so
`photodrop verify --xattr` still works.

## Things that run other programs

Two features execute code on your behalf, both off by default and both
configured only by you:

- **Post-ingest hook** (`photodrop.postIngestScript`) — an executable you nominate,
  run after a clean ingest with job details in `PHOTODROP_*` environment
  variables.
- **Scheduled verification** — installs a `launchd` agent that runs `photodrop
  verify` on a cadence you choose and posts a notification. Report-only; it never
  changes your library.

Eject uses `/usr/sbin/diskutil`. That is the only other program the app runs on
its own initiative.
