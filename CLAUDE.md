# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS (SwiftUI, Swift 6) app that ingests photos from removable memory cards into a date-organized library. It scans a card, previews a year/day folder tree, then copies each photo bundle with streaming hash verification, content-based deduplication, optional multi-destination archival (primary + any number of mirror copies), and optional card eject.

The discovery, dedup, companion-classification, and path-planning rules are **deliberate and load-bearing** — data safety depends on them, and several encode non-obvious decisions (same-directory-only companion matching, content-based dedup across the whole destination root, all-or-nothing bundles). Each such rule is documented at its definition; change those behaviors carefully and on purpose, not as a drive-by "fix." They stand on their own merits — judge a proposed change against what it does to data safety here, not against how any other tool behaves.

## Build & run

The `.xcodeproj` is **gitignored and generated** — it is not in version control. You must regenerate it before building a fresh checkout, and after any change to `project.yml` or after adding/removing/renaming source files:

```bash
xcodegen generate                                                      # regenerate PhotoDropMac.xcodeproj from project.yml
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' build    # build
```

`xcodegen` is installed via Homebrew (`brew install xcodegen`). Deployment target is macOS 14.0. There are two targets: the `PhotoDropMac` app (scheme `PhotoDropMac`), and `photodrop`, a headless command-line tool (scheme `photodrop`).

### The `photodrop` CLI

`photodrop` is a `tool` target that compiles the shared `Core/` sources (the engines + pure logic) plus `Sources/PhotoDropCLI/`, and links **swift-argument-parser** (declared under `packages:` in `project.yml`). It never compiles the SwiftUI `UI/`. Build it with a **scheme** (a `-target` build mishandles the SPM module under Swift 6 explicit modules):

```bash
xcodegen generate
xcodebuild -project PhotoDropMac.xcodeproj -scheme photodrop \
           -configuration Debug -destination 'platform=macOS' build
```

`photodrop verify <library|manifest.json> [--json] [--xattr]` re-verifies a library (exit `0` all-verified, `1` issues found, `2` no manifest / unreadable target / error), driving the same `VerifyEngine` the app uses. `--xattr` verifies by each file's embedded checksum attribute instead of the manifest (see below), so it works on any folder even after a reorg; it returns a `XattrOutcome` rather than a bare report because **"couldn't read the target" must never be reported as "nothing stamped"** — collapsing the two made a typo'd path exit `0` with a reassuring message forever. `photodrop ingest --from <card> --to <primary> [--archive …] [--preset …] [--[no-]verify] [--[no-]eject] [--description …] [--folder-template …] [--file-template …] [--post-ingest-hook <path>]` drives `IngestEngine` headlessly; **Ctrl-C is a graceful cancel** (SIGINT stops it at the next file boundary so the manifest still gets written — see the copy engine), and the hook is an explicit option because a CLI's `UserDefaults` domain isn't the app's. `photodrop heal <library> [--json] [--script <path>]` ([HealEngine.swift](Sources/PhotoDropMac/Core/HealEngine.swift)) is **report-only**: it verifies the library and, for every damaged/missing file, reports whether a healthy copy exists in a recorded mirror — and where. It **never writes to the library**; `--script` emits a reviewable restore script the user runs themselves, created with `O_EXCL` so it can't clobber an existing file (the one write the command makes — it refuses rather than silently choosing another path). Mirror lookup uses the manifest's `destinations` array (all roots written that job; falls back to `[primaryDestination] + archiveDestination` for older manifests).

### Tests

There is a `PhotoDropMacTests` XCTest target (declared in `project.yml`, sources in `Tests/PhotoDropMacTests/`, wired into the `PhotoDropMac` scheme). Run it with:

```bash
xcodegen generate
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' test
```

The suites cover the data-safety paths and pure transforms: the copy engine's overwrite-refusal (`O_EXCL`) and mid-file cancellation (`FileCopierTests`); naming/sanitization incl. the `NAME_MAX` cap and traversal/hidden guards (`NamingTemplateTests`); collision-safe planning (`CopyPlanTests`); dedup semantics incl. the zero-byte exemption (`DestinationIndexTests`); discovery/companion matching incl. the symlink guard (`AssetDiscoveryTests`); EXIF parsing (`ExifReaderTests`); manifest round-trip + CSV, the rollback-accuracy / unique-byte accounting, and re-verification (`ManifestTests`, `CopierManifestTests`, `VerifierTests`); the manifest trust boundary — path containment, conflict reporting, restore-script safety, CSV escaping (`ManifestTrustTests`); job-stamp uniqueness and manifest/log pairing (`JobStampTests`); hash-cache reuse (`HashCacheValidatorTests`); the completion-summary gate (`CompletionSummaryGateTests`); and the thumbnail LRU (`LRUCacheTests`). `Copier` takes injectable cache/index store URLs so its integration tests stay hermetic. Tests are **hosted** (the bundle loads into the app), so a headless CI runner still needs a GUI session to launch the host.

The DEBUG-only hash self-check also remains: `XxHash64Vectors.validated` (entry point `xxHash64SelfCheck()`) in [Hasher.swift](Sources/PhotoDropMac/Hasher.swift) asserts XXH64 reference vectors and streaming-split correctness in Debug builds.

### App icon

`Sources/PhotoDropMac/Assets.xcassets/AppIcon.appiconset` is **generated** by [scripts/make-icon.swift](scripts/make-icon.swift) — edit that script and re-run `swift scripts/make-icon.swift`, don't hand-patch the PNGs. It draws to Apple's macOS grid (824×824 body inside a 1024×1024 canvas, 185.4pt continuous corner, rendered from a `CALayer` with `cornerCurve = .continuous` so the curve is Apple's actual squircle). The 100pt margin is reserved for the shadow and for optical parity with other apps — don't fill it. Artwork differs by size on purpose: card + stripes at ≥64px, arrow alone at ≤32px, because detail that reads at 512px turns to mush at 16px.

### Signing / sandbox

Always **unsandboxed** (`com.apple.security.app-sandbox = false`): the app needs unrestricted filesystem access (arbitrary card → arbitrary destination) and shells out to `/usr/sbin/diskutil` via `Process` to eject cards. Don't add the sandbox entitlement without rethinking eject and folder access — and note it would also rule out the Mac App Store, so distribution is Developer ID + notarization instead.

Signing is **per-config** ([project.yml](project.yml)): **Debug** is ad-hoc (`CODE_SIGN_IDENTITY = "-"`), hardened runtime off — fast local builds, no certificate. **Release** is **Developer ID Application**, hardened runtime **on**, `OTHER_CODE_SIGN_FLAGS = --timestamp` (what notarization requires). Hardened runtime is orthogonal to the sandbox: every runtime behavior (diskutil eject, the `launchctl` scheduled-verify agent, `PostIngestHook`, `UNUserNotificationCenter`, `setxattr`) works under it with **no extra entitlements** — `PhotoDropMac.entitlements` stays sandbox-false and unchanged.

The `photodrop` CLI is **embedded in the app** at `Contents/MacOS/photodrop` (xcodegen `dependencies: [{target: photodrop, link: false, embed: true}]`), signed on copy as part of the app's signature and covered by the same notarization. `EmbeddedCLI` ([EmbeddedCLI.swift](Sources/PhotoDropMac/UI/EmbeddedCLI.swift)) locates it via `Bundle.main`, and `MaintenancePreferences` defaults the scheduled-verify `binaryPath` to it (typed path still overrides). Releases are cut by [scripts/release.sh](scripts/release.sh) (archive → notarize + staple the **app** → DMG → notarize + staple the **DMG**); see [RELEASING.md](RELEASING.md) for prerequisites (paid Apple Developer Program + Developer ID cert + notarytool keychain profile).

## The ingest pipeline (big picture)

Data flows through a chain of mostly-pure value-type transforms, driven by three `@MainActor @Observable` controllers. End to end:

1. **`DriveWatcher`** — observes `NSWorkspace` mount/unmount and exposes `[DetectedDrive]` (removable/ejectable local volumes; built-in SD readers report "internal" so that flag is intentionally *not* filtered on). It is injected via `.environment` and, crucially, is hosted by the `MenuBarExtra` label so it stays alive in the scene graph even when the main window is closed — that's what lets a card insertion auto-open the window ([PhotoDropMacApp.swift](Sources/PhotoDropMac/PhotoDropMacApp.swift)).
2. **`AssetDiscovery.scan(root:)`** — two-pass directory walk producing `[AssetBundle]`. Pass 1: RAW primaries + their same-directory companions; pass 2: standalone JPEGs not already claimed as a RAW's JPEG-pair. Extension sets (RAW list, sidecar `.xmp`/`.dop`/`.pp3`/`.wav`, JPEG) and the companion-classification rules (cases A/B in `classifyCompanion`) are a deliberate, fixed set. Companion matching is **same-directory only** by design.
3. **`ExifReader`** — `DateTimeOriginal` (or `Digitized`) via ImageIO, parsed in the *local* timezone; falls back to file mtime. This date drives all folder grouping.
4. **`PathPlanner.plan`** — groups bundles into `[YearGroup] → [DestinationFolder]` by capture date, for the preview tree. **`CopyPlan.plan`** — computes the actual destination path/filename per bundle.
   - The preview has two modes (toolbar Tree/Grid toggle, `PreviewMode`): the `PreviewTree`, and the **`ContactSheet`** culling grid. The contact sheet shows a thumbnail per bundle (`ThumbnailLoader`, an `actor` over ImageIO embedded-preview extraction with an in-memory cache) and lets the user deselect shots/days before ingest. Selection is tracked as `deselectedIDs: Set<AssetBundle.ID>` in `MainView` (empty = all selected; reset when the card changes); `startIngest` filters `yearGroups` to the selected bundles via `selectedYearGroups()`, and `canStartIngest` requires ≥1 selected.
5. **`IngestPlanner`** — orchestrates the scan (off-main via `Task.detached`) and holds `yearGroups` for the UI.
6. **`Copier`** — the copy engine (details below).

### The `AssetBundle` is the atomic unit

A bundle is one primary photo + its companions (`.xmp`/`.dop`/`.pp3` sidecars, JPEG pair, `.wav` audio note). Copy, verify, rollback, and dedup all operate on whole bundles: a RAW without its `.dop` has lost its edits, so they must move or fail together. `CompanionKind` is a deliberately closed set ([AssetBundle.swift](Sources/PhotoDropMac/AssetBundle.swift)).

### Destination layout

`CopyPlan` writes to: `{root}/{yyyy}/{day-folder}/{filename}.{ext}`, where the **day-folder** and **filename** are user-configurable templates ([NamingTemplate.swift](Sources/PhotoDropMac/NamingTemplate.swift)). The year is always the fixed top level; the original extension is always re-appended. Defaults reproduce PhotoDrop's established pattern `{yyyy-MM-dd}[_{Description}]` / `{yyyyMMdd_HHmmss}_{OriginalStem}`. Template syntax: `{…}` tokens (a named token — `Description`, `OriginalName`, `OriginalStem`, `CardLabel` — or otherwise a Unicode date-format pattern applied to the capture date) and `[…]` optional groups (dropped when a named token inside renders empty). A literal `/` in the **folder** template nests subfolders below the year (e.g. `{MM}/{yyyy-MM-dd}` → `{root}/{yyyy}/05/2026-05-28`); the rendered output is split into components by `PathPlanner.sanitizedComponents`, each sanitized independently. User data (description/card label) is slash-stripped by `sanitize` *before* interpolation, so only the template author can nest. `TemplateRenderer` is pure; **`PathPlanner.plan` groups the preview by the rendered day-folder path and `CopyPlan.destinationDirectory` renders the same components — they must agree.** Companions are renamed to track the primary's new name so the stem relationship survives (long-form `IMG.DNG.xmp` → `{newName}.xmp`; short-form shared-stem → `{newStem}.{ext}`). Folder/description/template-output sanitization is in `PathPlanner.sanitize` (single component) / `PathPlanner.sanitizedComponents` (nested folder path). Composing a *filename* goes through **`PathPlanner.fileName(stem:extension:)`**, which caps stem+`.`+ext together: `sanitize` caps the stem alone, and a 255-byte stem plus `.CR2` is 259 bytes, which `open()` answers with `ENAMETOOLONG` — failing the copy and rolling back the bundle over a name.

**The plan is computed once and rebased onto every mirror** (`IngestEngine.rebase`), so a file has the same relative path at every destination. Planning per root let the `_1` disambiguator be chosen independently, and since the manifest records only the primary's path, `heal` would look for that name under a mirror root, miss, and call a file unrecoverable with a perfect copy present. Collision avoidance therefore unions the existing names across *all* destinations — a name is only free if it is free everywhere.

### The copy engine (`Copier`)

`Copier.start(...)` spawns a `Task` running `run(...)`, which:
- Builds a **`DestinationIndex`** per destination root (size-bucketed snapshot; hashes only on a size collision) for dedup.
- Per bundle, per file: dedup-check → copy+tee-hash → optional verify → record hash. Skipped (duplicate) bytes still count toward progress so the bar fills smoothly.
- **Rollback:** if any file in a bundle fails, already-written files from *that bundle* are deleted (the bundle is all-or-nothing).
- **Halt vs. continue:** a verification mismatch halts the entire job; any other per-bundle error is logged, counted as failed, and the job continues.
- **Destinations fail independently.** Each root gets its own `do/catch` inside the bundle loop, so a mirror that fails neither skips the mirrors after it nor voids the primary copy that already landed. `CopyResult.failuresByDestination` breaks the count down per root; `primaryFailures` / `failedMirrors` are what the UI keys on, so "the NAS was offline" no longer renders as a failed job. Do not re-wrap the destination loop in a single `do`.
- **Destination roots are deduped by filesystem identity** (`ArchiveDestinations.dedupedRoots`, dev+inode). One folder listed twice means pass 2 collides with pass 1's own file, `O_EXCL` correctly refuses, and a *successful* ingest reports every bundle failed. The settings and CLI layers dedupe too; the engine does it again because it takes roots from any caller.
- **Child processes are run through [`ChildProcess`](Sources/PhotoDropMac/Core/ChildProcess.swift), which drains stdout and stderr *while* the child runs.** A pipe holds ~64 KiB; read it only after the child exits and any child that prints more than that blocks in `write()` and never exits. `PostIngestHook` did exactly that and deadlocked forever on a hook running `rsync -v` — measured: ~1 MiB of stdout never returned. `DriveEjector` and `ScheduledVerification` share the runner (they were safe only because `diskutil` and `launchctl` are quiet). Don't hand-roll a `Process` with an undrained `Pipe`.
- **Cancelling still writes the manifest and log** for the bundles that completed, marked `partial: true`. Those files are on disk and are deliberately *not* rolled back, so returning early left them with no integrity record — and a later re-ingest dedup-skips them without a digest (`xxhash64: nil`), so `verify` would then report success over zero files. `run()` therefore always returns a `CopyResult`; `cancelled` distinguishes it. A cancelled job skips the eject.
- Optionally ejects the card (`DriveEjector` → `diskutil eject`), writes a log file (`JobLogger` → `~/Library/Logs/PhotoDrop/ingest-<ts>.log`), writes a **verification manifest** (`ManifestWriter` → `<primaryRoot>/PhotoDrop Manifests/ingest-<ts>.{json,csv}`), and persists the hash cache.

### Verification manifest (`Manifest` / `ManifestWriter`)

Every ingest writes a receipt of what landed and its checksums, as JSON + CSV, into a `PhotoDrop Manifests/` folder at the primary destination root (filename stamp matches the job's log). Entries are accumulated during the **primary** copy pass only (`recordManifest:` in `copyBundle`) — the archive is a byte-identical mirror — and cover copied/verified files and skipped duplicates alike, each with its `xxhash64`. A skipped entry records the digest the dedup match was *made* on — it costs nothing, since `DestinationIndex.findDuplicate` computed it to decide the match, and recording `nil` there meant `VerifyEngine` skipped the entry, so a re-ingest of an already-complete card wrote a manifest that attested to nothing and `verify` reported success over zero files. `ManifestWriter.decode` also **validates `schema`**; it was written and never read, so any structurally-valid JSON was accepted as a manifest. The manifest URL flows back in `CopyResult.manifestURL`; the completion sheet's **Export Manifest…** saves a copy elsewhere. This surfaces the hashes the copy engine already computes rather than discarding them after the verify step.

**The job stamp is shared and sub-second** ([JobStamp.swift](Sources/PhotoDropMac/Core/JobStamp.swift)). A job's two artifacts — the manifest and the log — are named `ingest-<stamp>` and are paired by that name, so the format lives in `JobStamp.fileStamp` rather than being written out at both call sites, where it had already been duplicated and could drift apart unnoticed. Use it for anything else named per-job; don't re-declare the format.

**Names are claimed, not just stamped.** Every per-job artifact goes through `JobStamp.claimUniqueName`, which creates the file with `O_CREAT | O_EXCL` and appends `-2`, `-3`, … only on an actual collision. This is the part that makes overwriting *impossible*; the timestamp precision only makes collisions rarer. Do not replace it with a `fileExists` check — that is a TOCTOU, and `.atomic` writes replace the loser.

Why it matters: `ManifestWriter` writes `.atomic`, so two jobs sharing a name means the second silently destroys the first's manifest — and a lost manifest doesn't fail loudly. `verify` reports success over whatever records remain, printing `✓ All 1 file …` for a two-file library and exiting 0. Measured before the claim existed: ten concurrent `photodrop ingest` processes into one library copied all ten files but left **two** manifests. Process launches cluster inside a millisecond, so precision alone bought almost nothing there.

The precision (`yyyyMMdd-HHmmss-SSS`) still earns its place — it keeps ordinary runs collision-free and therefore suffix-free, so filenames stay clean and sort chronologically. Milliseconds are separated with `-`, not `.`, so the stamp can never be read as a file extension.

The CSV takes the JSON's *resolved* base and the log takes the manifest's, so a suffixed manifest is never paired with an unsuffixed sibling. Pairing is nonetheless best-effort: manifests live per-destination while logs share one global folder, so concurrent jobs to *different* libraries can collide in the log folder and not the manifest folder.

**Per-file checksum xattr.** In addition to the manifest, `IngestEngine` stamps each copied file's `xxhash64` into an extended attribute (`com.tsvb.photodrop.xxh64`, [FileChecksumXattr.swift](Sources/PhotoDropMac/Core/FileChecksumXattr.swift)) so the file carries its own checksum. `VerifyEngine.runXattr` (CLI `verify --xattr`) walks a folder and re-checks every stamped file — manifest-free, so it survives a library reorg or a lost manifest. **Secondary and best-effort**: xattrs are stripped by exFAT/FAT, some cloud sync, and `cp -X`, so the manifest stays authoritative; an absent attribute means "unstamped", never "changed".

**Re-verification** (`Verifier` / `VerifySheet`, launched from the toolbar's *Verify Library* button): pick a library folder (or a manifest `.json`) and it re-hashes every file recorded in the manifest(s) under `<folder>/PhotoDrop Manifests/`, reporting matches / changed (silent corruption) / missing / conflicting. The manifest is the source of truth for *what to check* — each file resolves relative to its own manifest's location (two levels up), so a moved library still verifies. Hashing reuses `XxHash64.hash(fileAt:)` and runs off-main with throttled progress, mirroring the copy engine.

### The manifest is untrusted input

A manifest is unauthenticated data sitting inside the tree it attests to, and `verify`/`heal` accept a target the user did not necessarily produce — a shared or downloaded library, a folder on the card, or a `.json` handed straight to the CLI (whose library root is then taken as two levels up from that file). Three rules follow, and each is load-bearing:

- **Every manifest-derived path goes through `ManifestWriter.resolve(entryPath:under:)`**, which drops anything resolving outside the library root. Without it a `../../..` entry makes verify hash arbitrary files (an existence/content oracle) and makes `heal --script` emit a `cp` that overwrites them. The check is **lexical** on purpose: `standardizedFileURL` consults the filesystem and so returns a different shape for paths that exist than for ones that don't, which would silently drop every missing file — exactly what `heal` looks for.
- **Manifests that disagree are reported, never reconciled.** Two manifests recording the same digest for a path dedupe quietly (a re-ingest re-records what it skipped); two recording *different* digests produce a `.conflict` issue. There is no trustworthy tiebreak — `createdAt`, the `ingest-<stamp>` filename, and the file's mtime are all chosen by whoever wrote the file, so a "newest wins" rule let a planted manifest relabel a tampered file as verified.
- **`heal` derives what to expect of a file from `VerifyEngine.build`, never its own merge.** Both engines read the same unauthenticated manifests, so they must apply the same trust rule — and `build` is where that rule is stated and argued. `HealEngine` used to keep a private oldest→newest merge in which the newest manifest won; planting one JSON dated 2099 that recorded a tampered file's *current* digest made `heal` call the corrupted library healthy while `verify` correctly reported the conflict. Conflicted files surface as `HealCandidate.Kind.conflicted` and are never recoverable — offering a restore would mean picking a winner among disagreeing records. Extend `build` if heal needs more; don't reintroduce a second merge.
- **`heal` stays report-only, and the script it emits must stay reviewable.** `restoreScript` lists the source roots it will copy *from* (they come from the manifest's `destinations`, which can name anywhere) and refuses to emit an executable line for a path containing control characters — such a path is quoted correctly but renders across several lines, so an embedded `rm -rf $HOME` reads like a command to whoever is reviewing. Interior control characters survive `PathPlanner.sanitize`, which trims only the ends, so they are reachable from a card filename.

Relatedly, `AssetDiscovery`'s `isRegularFile` guard is a security boundary, not a directory filter: it has lstat semantics, so it is what stops a symlink on the card from pulling `/etc` or `~/.ssh` into the library. `HashCacheEntry.matches` is likewise strict (exact nanosecond mtime + birth time) because a false cache *hit* silently skips a photo as a duplicate, and skipped entries carry no digest for a later verify to catch.

State is exposed as a `CopierState` enum (`idle`/`running`/`completed`/`cancelled`/`failed`) that the UI switches on.

### Hashing & dedup performance model

- **`XxHash64`** ([Hasher.swift](Sources/PhotoDropMac/Hasher.swift)) — a pure-Swift, value-type (trivially `Sendable`) streaming XXH64. Non-cryptographic; used only for copy verification and dedup equality.
- **Tee-hashing** (`FileCopier.copyAndHash`) — streams source→dest in 1 MiB chunks while hashing the bytes in flight, so a multi-GB file is read exactly once for both the copy and its digest.
- **`HashCache`** (an `actor`, persisted as JSON at `~/Library/Application Support/PhotoDropMac/hash-cache.json`) — caches digests keyed by `volumeUUID|path` (source) / `path` (dest), validated by `(size, mtime)`. A warm cache turns a re-ingest of the same card against the same destination from a file-read-bound operation into a stat-bound one (the SD read, the bottleneck, is skipped entirely). After a copy+verify, the just-computed digest is written back via `recordDestination` so the next run doesn't re-hash it.
- **Dedup semantics** (`DestinationIndex.findDuplicate`) are content-based: a file is a duplicate if size+hash match **anywhere under the destination root**, not just at the same path — so a renamed earlier import is still detected.

## Concurrency conventions

Swift 6 strict concurrency is on. Follow the existing split:
- UI-facing state lives in `@MainActor @Observable final class` controllers (`DriveWatcher`, `IngestPlanner`, `Copier`). `@ObservationIgnored` marks internal bookkeeping that shouldn't trigger view updates.
- Heavy/blocking work (directory scans, hashing, copying, `DestinationIndex.build`) runs on `Task.detached(priority: .userInitiated)`; results hop back to the main actor.
- Progress from the detached copy is throttled (~0.1 s) and marshalled back via `MainActor` hops (`addBytesCopied`) to avoid flooding the UI.
- Shared mutable cross-task state uses an `actor` (`HashCache`). Domain models are value types and therefore `Sendable`.

## Settings contract (`@AppStorage`)

Preferences are plain `@AppStorage` keys with **no central store** — the same keys are declared independently in [MainView.swift](Sources/PhotoDropMac/MainView.swift), [InspectorPane.swift](Sources/PhotoDropMac/InspectorPane.swift), and [SettingsView.swift](Sources/PhotoDropMac/SettingsView.swift). If you add or rename one, update **every** declaration site or the views silently desync:

- `photodrop.primaryDestination` (String)
- `photodrop.archiveDestination` (String, optional second copy)
- `photodrop.extraArchiveDestinations` (String, newline-separated extra archive folder paths) — additional mirror destinations beyond Primary + Archive (3-2-1 backups). Assembled with the primary archive into the ordered list via [ArchiveDestinations.swift](Sources/PhotoDropMac/Core/ArchiveDestinations.swift); each gets its own verified copy, and each fails independently of the others. `list` takes the **primary** so it can drop any spelling of it — see the dedup note under the copy engine. Edited in Settings → General
- `photodrop.verifyCopies` (Bool, default `true`)
- `photodrop.ejectAfterIngest` (Bool, default `false`)
- `photodrop.showCompletionSheet` (Bool, default `true`)
- `photodrop.notifyOnCompletion` (Bool, default `true`) — posts a Notification Center banner on finish when the app isn't frontmost ([Notifier.swift](Sources/PhotoDropMac/Notifier.swift), read via `UserDefaults`; toggled in `SettingsView`)
- `photodrop.postIngestScript` (String, default empty) — path to an executable run after a clean (non-halted) ingest ([PostIngestHook.swift](Sources/PhotoDropMac/PostIngestHook.swift)); argv[1] is the primary destination, job details are in `PHOTODROP_*` env vars. Best-effort (a failure posts a banner, never affects the copy). Read via `UserDefaults` in `Copier`, set in `SettingsView`
- `photodrop.template.folder` (String, default `{yyyy-MM-dd}[_{Description}]`) — day-folder name template
- `photodrop.template.filename` (String, default `{yyyyMMdd_HHmmss}_{OriginalStem}`) — primary file stem template (extension auto-appended). Both edited in Settings → Naming (`NamingPreferences`), read in `MainView` (threaded to `IngestPlanner`/`Copier`)
- `photodrop.verificationStyle` (`VerificationStyle` rawValue, default `.steady`) — the app **theme**, a committed identity per option (not just an accent):
  - `.steady` — the system look: your accent, your light/dark, SF Pro. The no-transformation default.
  - `.ledger` — editorial: forced **light**, **serif** type, **ultramarine** ink (`#120A8F`), wax-seal `StampMark`.
  - `.pressroom` — wire desk: forced **dark**, **monospaced** type, **marigold** accent, aperture-iris mark.

  Each theme's `accent` / `fontDesign` / `colorScheme` live in [VerificationStyle+Theme.swift](Sources/PhotoDropMac/VerificationStyle+Theme.swift) and are applied together via `.tint()` / `.fontDesign()` / `.preferredColorScheme()` at the app root ([PhotoDropMacApp.swift](Sources/PhotoDropMac/PhotoDropMacApp.swift)). `resolvedAccent` recolours the explicit-accent icons (`SidebarRow`, `FolderRow`) and the verification marks (`SealGrid`/`StampMark`/`ApertureMark` take an `accent:` param) that `.tint` doesn't reach. Mark/headline switches are inline in `ProgressPane`/`CompletionSheet`.
- `photodrop.menuBar.visibility` (`MenuBarVisibility` rawValue, default `.always`)
- `photodrop.menuBar.autoOpenWindow` (Bool, default `true`)
- `photodrop.menuBar.oneClickIngest` (Bool, default `false`)
- `photodrop.scheduledVerify.enabled` / `.schedule` (`VerifySchedule` rawValue: daily/weekly/monthly) / `.binaryPath` (path to the built `photodrop` CLI) / `.library` (override; defaults to the primary destination) — Settings → Maintenance. Toggling installs/removes a `launchd` user agent ([ScheduledVerification.swift](Sources/PhotoDropMac/Core/ScheduledVerification.swift)) that runs `photodrop verify --json` at 03:00 on the chosen cadence and posts a notification (via `osascript`). Report-only; the unsandboxed app manages `~/Library/LaunchAgents` directly.

  **Exit 1 and exit 2 get different notifications** — "found issues" vs "could not verify (no manifest)". The old `verify … || osascript "found issues"` fired the same alarm for both, so an agent pointed at a library with no manifest cried wolf nightly, which is how a user learns to ignore it. Output is echoed only on a non-zero exit, so the log doesn't grow by a JSON report a night. `install` removes the plist again if `bootstrap` fails (an orphan plist left the toggle reading *off* while launchd could still load the job at next login), `isLoaded()` asks launchd rather than stat-ing the plist, and Settings re-applies when the binary or library path changes — the installed agent bakes those in, so editing them silently pointed the job at the old library

The enum-typed keys (`VerificationStyle`, `MenuBarVisibility`) get their `String`-backed type from [AppCoordinator.swift](Sources/PhotoDropMac/AppCoordinator.swift), which is the one definition site shared by every `@AppStorage` declaration.
