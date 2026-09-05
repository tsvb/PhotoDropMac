# Changelog

All notable changes to PhotoDrop are recorded here. Versions follow
[semantic versioning](https://semver.org/), pre-1.0: minor versions may change
behaviour, patch versions fix things.

Release notes previously lived only in GitHub's database, which meant a user on
an older build had no way to learn what a newer one fixed — and no way to diff
it. They live here now, in the repo, and `scripts/release.sh` cuts the GitHub
release from this file.

## [Unreleased]

### Fixed

- **`photodrop sync` stops the way `ingest` stops.** SIGINT, SIGTERM and SIGHUP
  now end a sync at the next file boundary, with the mirror's manifest written
  for what landed and marked partial; a second signal exits at once. It shipped
  without this: a Ctrl-C mid-file killed the process with the file half written
  at the mirror, invisible to the manifest and the checksum attribute, and the
  *next* sync reported it as a CONFLICT it must never overwrite — a permanent
  conflict made out of a file that had merely been cut short. Exit 2 on a cancel,
  as for `ingest`.
- **A clip and a still from the same moment land on the same day.** A movie's
  creation date carries the camera's UTC offset, and it was rendered in the Mac's
  zone — so a clip shot at 08:00 in Tokyo filed under 19:00 the previous day
  when ingested in New York, while the still beside it filed under the 29th.
  Movie timestamps now follow the rule stills always have: the camera's wall
  clock is the capture time. A `Z` timestamp, from a camera that stores a true
  instant and does not know where it was, is kept as an instant.
- Clips shorter than a second get a poster frame in the contact sheet. The
  fallback to the first frame was dead code (the compiler said so), so such a
  clip showed the same "no preview" cell a corrupt file does.
- **`sync` tells you what `heal` will do with the mirror.** `heal <library>`
  searches only the mirrors the library's own manifests record, and a mirror
  brought up to date afterwards is not among them; `sync` now says so and names
  the `--mirror` argument to pass. Also in the `--json` report.
- CI: the appcast check ran `xmllint` on an Ubuntu image that does not ship it,
  so `main` read as failing for a missing tool.

### Added

- **Apple `.aae` adjustment sidecars travel with their still.** Every Photos
  export and Image Capture import writes one beside each edited HEIC or JPEG. It
  was neither a sidecar nor ignorable, so ingesting a folder of iPhone photos
  reported every edited frame as a file PhotoDrop would not take and suppressed
  the eject.
- **A Homebrew cask.** `brew install --cask tsvb/tap/photodropmac` installs the
  same notarized DMG, puts `photodrop` on `PATH`, and defers updates to Sparkle.
  `scripts/release.sh` renders it for every release and publishes it to the tap.
- Tests for `SyncEngine`, which had none: what it copies, what it refuses to
  overwrite, what it does when the library's own copy is missing or no longer
  matches its record, how it stops, and why a no-op run writes no manifest.

### Changed

- **Dependencies are pinned exactly.** `project.yml` pins Sparkle and
  swift-argument-parser with `exactVersion`; the resolved versions live inside
  the gitignored Xcode project, so a `from:` range meant every fresh resolve —
  CI, a new machine, release day — took whatever was newest, and the update
  channel's own in-process code could change under a release unaudited.
- CI builds and tests on both `macos-15` and `macos-26`, so the toolchain that
  gates a release includes the one releases are actually cut with.
- The implemented design handoff moved under `docs/internal/`.

## [0.4.0] — 2026-08-31

### Added

- **In-app updates (Sparkle).** PhotoDrop can now keep itself up to date instead
  of relying on you to notice a new DMG on the Releases page — which, for a
  security fix, meant a fix that reached nobody. **Settings → Updates** holds the
  controls; **Help → Check for Updates…** checks on demand.
  - **Opt-in.** Sparkle asks before its first check and nothing is fetched until
    you answer. The app sets no "check automatically" default on your behalf.
  - **Signed.** Every update is verified against an Ed25519 key compiled into the
    copy you are already running, before anything is unpacked — on top of the
    existing Developer ID signature and Apple notarization.
  - **Never during an ingest.** Sparkle's terminal act is to replace and relaunch
    the app, and a copy's only safe stopping point is a file boundary. Update
    checks are refused while a job runs, and a pending installation is postponed
    until the copy has finished and written its manifest — the same reasoning
    that already routes Quit through the graceful-cancel path.
  - **A build that cannot update says so.** A build from source carries no signing
    key; it starts no updater, makes no network connection at all, and Settings
    states that plainly rather than showing a Check button that does nothing.
  - Privacy: the update check is the app's only outbound connection, sends nothing
    about you or your photos, and Sparkle's system profiling stays off. See
    [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

### Changed

- The app now uses an explicit `Info.plist` instead of Xcode's generated one.
  Xcode's `INFOPLIST_KEY_*` build settings only cover keys it knows about:
  `INFOPLIST_KEY_SUFeedURL` was accepted without a warning and **dropped from the
  built plist**, which would have shipped an app that silently never checks for
  updates. `scripts/release.sh` now reads both Sparkle keys back out of the built
  bundle, and the test suite pins it.
- Sparkle's XCFramework ships ad-hoc signed and embedding it signs only the outer
  bundle, so a post-build phase re-signs the executables nested inside it with the
  build's own identity, hardened runtime and secure timestamp. `codesign --verify
  --deep --strict` reports such a build as perfectly valid; notarization is what
  rejects it, after the archive is already submitted. `release.sh` now fails if
  any ad-hoc signature survives in the finished bundle.
- `scripts/release.sh` refuses to ship a build whose update key is missing or does
  not match the private key in the keychain, and signs each release into
  `appcast.xml` before tagging — a release absent from the feed is a release no
  installed copy will ever see.

## [0.3.0] — 2026-08-31

**Supersedes 0.2.1**, which was tagged but never published — so if you are on
0.2.0, this is the first build you can download since then, and it carries 0.2.1's
release-script fix as well.

Fixes and features from an adversarial review of the whole app. The through-line
is a rule the codebase already held and was not enforcing everywhere: *"couldn't
read it" must never be reported as "nothing there."*

### Fixed — data safety

- **Dedup now reads the file it vouches for.** A skip consulted a persisted
  digest that `stat` still validated, so a file that suffered silent corruption
  after its ingest — bit rot, a bad cable, a partial restore — matched its own
  stale digest, was skipped, and had a *fresh* manifest record that digest for
  it. The match is now confirmed against the candidate's real bytes before the
  copy is skipped, and a disagreeing cache entry is dropped.
- **A failed manifest write is no longer silent.** It could copy and verify every
  file, report `✓ Ingest complete`, exit 0 and eject the card while leaving a
  library nothing can ever verify. It now fails the CLI with exit 1, blocks the
  eject, and is stated plainly in the completion sheet.
- **The card ejects last.** The eject — the one irreversible act in a job — ran
  *before* the manifest and log were written, and the volume flush ran before the
  record it needed to make durable. Order is now: manifest → flush → eject → log.
- **`partial` is read.** The field was written on every job and consulted by
  nothing, so a cancelled 40-of-500 ingest verified green forever. `verify` now
  reports it.
- **`verify` counts what it could not check.** Manifest entries with no digest,
  and entries whose path escapes the library root, were dropped silently.
- **The scan counts what it will not copy**, and no longer ejects over it.
- **Source timestamps are preserved.** Every copied file wore the ingest time,
  which also destroyed the mtime the date logic falls back to.
- **A vanished card halts the job.** A bumped reader at bundle 100 of 2000
  produced 1,900 identical failure lines and no explanation.
- **The Mac stays awake during an ingest.** The default battery idle timer is ten
  minutes; an offload is routinely longer.
- **The GUI refuses a destination folder that doesn't exist**, as the CLI always
  has. A folder renamed in Finder since it was picked became a second, empty
  library: the whole card was re-copied and the job reported success over it.
- **A cull suppresses the auto-eject.** Deselected frames are still on the card.

### Added

- **Video and HEIF ingest.** `mov`, `mp4`, `m4v`, `avi`, `mts`, `m2ts` and others
  are first-class primaries with capture dates and poster frames from
  AVFoundation; `heic`, `heif` and `hif` join the stills. Previously every one of
  these was dropped by the extension filter with no tally.
- **`photodrop sync <library> --to <mirror>`** — brings a mirror that wasn't
  mounted at ingest time up to date. It only ever adds; a file already there with
  different content is reported, never overwritten.
- **Ingest from a folder in the GUI**, not just a card. The CLI always allowed it.
- **`{Sequence}`, `{CameraModel}` and `{BodySerial}` naming tokens.**
  `Wedding_0001, Wedding_0002…` was previously inexpressible, and a two-body
  shoot had no way to tell its cameras apart.
- **MHL** is written alongside the JSON/CSV manifest — the interchange format
  post houses and delivery specs require.
- **Card history.** The sidebar says when a card was last ingested and how many
  files landed, which is the 2am "did I already do this one?" question.
- **Keyboard operation of the contact sheet.** Arrows move, space toggles, return
  reveals. Culling 2,000 frames previously meant 2,000 mouse clicks.
- **A failure list you can read and copy**, in the completion sheet and the
  halted/cancelled panes. The reasons previously existed only in a log the app
  stopped displaying the moment a job ended.
- **Help menu, security policy, privacy statement and contribution guide.** The
  Help menu opened nothing and the app named no way to report a problem.
- Mirrors that aren't mounted are warned about once, before the job, instead of
  failing once per bundle for its length.

### Changed

- **Mirrors copy from the primary instead of re-reading the card.** A
  3-destination job read the whole card three times, serially — the headline
  3-2-1 feature was also the slowest path. This is *more* rigorous, not less: the
  mirror's hash is checked against the card-side digest, so a primary that no
  longer holds what came off the card halts the job.
- `photodrop --version` reads the bundle instead of a literal that had drifted
  two releases behind.
- Settings and the inspector share one editor for extra destinations; the
  scheduled-verify paths get folder pickers and a warning when the path is wrong.
- Notification permission is requested at launch rather than mid-ingest, and a
  post-ingest hook failure is no longer silenced by the completion-banner toggle.

## [0.2.1] — 2026-08-30

### Fixed
- Release script falls back to `hdiutil` when `create-dmg` *fails*, not only when
  it is absent.

## [0.2.0] — 2026-08-11

### Fixed
- **Mounted disk images are no longer offered as cards.** A read/write HFS+ DMG,
  a read-only UDZO DMG, an APFS DMG and a sparsebundle all report
  `isLocal && isEjectable && isRemovable` — the exact signature of a memory card
  — so every disk image you had open was listed, auto-opened the window on mount,
  and was a legal one-click-ingest target.
- The scheduled-verify feature stopped trusting
  `Bundle.url(forAuxiliaryExecutable:)` to find the CLI.
- Several view bodies split so the type checker finishes on CI's toolchain.

### Added
- **Named folder layouts**, and an optional year level — the most obvious layout
  of all, `{root}/2026-05-28/IMG_0001.jpg`, was previously inexpressible.
- The layout picker sits where the destination is chosen.

## [0.1.3] — 2026-08-06

First broadly usable release. Earlier 0.1.x tags are superseded by it.
