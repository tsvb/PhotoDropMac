# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS (SwiftUI, Swift 6) app that ingests photos from removable memory cards into a date-organized library. It scans a card, previews a year/day folder tree, then copies each photo bundle with streaming hash verification, content-based deduplication, optional multi-destination archival (primary + any number of mirror copies), and optional card eject.

This is a port of a Windows app (`PhotoDrop`, .NET/WPF). The Windows `PhotoDrop.Core` is the **behavioral source of truth** — much of the discovery, dedup, companion-classification, and path-planning logic deliberately mirrors it (comments say "matches the Windows ..."). When changing that behavior, treat the Windows reference as authoritative rather than "fixing" it locally. See [HANDOFF_FROM_WINDOWS.md](HANDOFF_FROM_WINDOWS.md) for context (note: the Avalonia recipe there is explicitly *not* the path taken).

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

`photodrop verify <library|manifest.json> [--json] [--xattr]` re-verifies a library (exit `0` all-verified, `1` issues found, `2` no manifest / error), driving the same `VerifyEngine` the app uses. `--xattr` verifies by each file's embedded checksum attribute instead of the manifest (see below), so it works on any folder even after a reorg. `photodrop ingest --from <card> --to <primary> [--archive …] [--preset …] [--[no-]verify] [--[no-]eject] [--description …] [--folder-template …] [--file-template …]` drives `IngestEngine` headlessly.

### Tests

There is a `PhotoDropMacTests` XCTest target (declared in `project.yml`, sources in `Tests/PhotoDropMacTests/`, wired into the `PhotoDropMac` scheme). Run it with:

```bash
xcodegen generate
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' test
```

The suites cover the data-safety paths and pure transforms: the copy engine's overwrite-refusal (`O_EXCL`) and mid-file cancellation (`FileCopierTests`); naming/sanitization incl. the `NAME_MAX` cap and traversal/hidden guards (`NamingTemplateTests`); collision-safe planning (`CopyPlanTests`); dedup semantics incl. the zero-byte exemption (`DestinationIndexTests`); discovery/companion matching (`AssetDiscoveryTests`); EXIF parsing (`ExifReaderTests`); manifest round-trip + CSV, the rollback-accuracy / unique-byte accounting, and re-verification (`ManifestTests`, `CopierManifestTests`, `VerifierTests`); the completion-summary gate (`CompletionSummaryGateTests`); and the thumbnail LRU (`LRUCacheTests`). `Copier` takes injectable cache/index store URLs so its integration tests stay hermetic. Tests are **hosted** (the bundle loads into the app), so a headless CI runner still needs a GUI session to launch the host.

The DEBUG-only hash self-check also remains: `XxHash64Vectors.validated` (entry point `xxHash64SelfCheck()`) in [Hasher.swift](Sources/PhotoDropMac/Hasher.swift) asserts XXH64 reference vectors and streaming-split correctness in Debug builds.

### Signing / sandbox

Unsandboxed (`com.apple.security.app-sandbox = false`), ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), hardened runtime off. This is deliberate: the app needs unrestricted filesystem access (arbitrary card → arbitrary destination) and shells out to `/usr/sbin/diskutil` via `Process` to eject cards — no entitlements required because of the unsandboxed/ad-hoc setup. Don't add the sandbox entitlement without rethinking eject and folder access.

## The ingest pipeline (big picture)

Data flows through a chain of mostly-pure value-type transforms, driven by three `@MainActor @Observable` controllers. End to end:

1. **`DriveWatcher`** — observes `NSWorkspace` mount/unmount and exposes `[DetectedDrive]` (removable/ejectable local volumes; built-in SD readers report "internal" so that flag is intentionally *not* filtered on). It is injected via `.environment` and, crucially, is hosted by the `MenuBarExtra` label so it stays alive in the scene graph even when the main window is closed — that's what lets a card insertion auto-open the window ([PhotoDropMacApp.swift](Sources/PhotoDropMac/PhotoDropMacApp.swift)).
2. **`AssetDiscovery.scan(root:)`** — two-pass directory walk producing `[AssetBundle]`. Pass 1: RAW primaries + their same-directory companions; pass 2: standalone JPEGs not already claimed as a RAW's JPEG-pair. Extension sets (RAW list, sidecar `.xmp`/`.dop`/`.pp3`/`.wav`, JPEG) and the companion-classification rules (cases A/B in `classifyCompanion`) mirror the Windows reference. Companion matching is **same-directory only** by design.
3. **`ExifReader`** — `DateTimeOriginal` (or `Digitized`) via ImageIO, parsed in the *local* timezone; falls back to file mtime. This date drives all folder grouping.
4. **`PathPlanner.plan`** — groups bundles into `[YearGroup] → [DestinationFolder]` by capture date, for the preview tree. **`CopyPlan.plan`** — computes the actual destination path/filename per bundle.
   - The preview has two modes (toolbar Tree/Grid toggle, `PreviewMode`): the `PreviewTree`, and the **`ContactSheet`** culling grid. The contact sheet shows a thumbnail per bundle (`ThumbnailLoader`, an `actor` over ImageIO embedded-preview extraction with an in-memory cache) and lets the user deselect shots/days before ingest. Selection is tracked as `deselectedIDs: Set<AssetBundle.ID>` in `MainView` (empty = all selected; reset when the card changes); `startIngest` filters `yearGroups` to the selected bundles via `selectedYearGroups()`, and `canStartIngest` requires ≥1 selected.
5. **`IngestPlanner`** — orchestrates the scan (off-main via `Task.detached`) and holds `yearGroups` for the UI.
6. **`Copier`** — the copy engine (details below).

### The `AssetBundle` is the atomic unit

A bundle is one primary photo + its companions (`.xmp`/`.dop`/`.pp3` sidecars, JPEG pair, `.wav` audio note). Copy, verify, rollback, and dedup all operate on whole bundles: a RAW without its `.dop` has lost its edits, so they must move or fail together. `CompanionKind` is a deliberately closed set ([AssetBundle.swift](Sources/PhotoDropMac/AssetBundle.swift)).

### Destination layout

`CopyPlan` writes to: `{root}/{yyyy}/{day-folder}/{filename}.{ext}`, where the **day-folder** and **filename** are user-configurable templates ([NamingTemplate.swift](Sources/PhotoDropMac/NamingTemplate.swift)). The year is always the fixed top level; the original extension is always re-appended. Defaults reproduce the historical Windows pattern `{yyyy-MM-dd}[_{Description}]` / `{yyyyMMdd_HHmmss}_{OriginalStem}`. Template syntax: `{…}` tokens (a named token — `Description`, `OriginalName`, `OriginalStem`, `CardLabel` — or otherwise a Unicode date-format pattern applied to the capture date) and `[…]` optional groups (dropped when a named token inside renders empty). A literal `/` in the **folder** template nests subfolders below the year (e.g. `{MM}/{yyyy-MM-dd}` → `{root}/{yyyy}/05/2026-05-28`); the rendered output is split into components by `PathPlanner.sanitizedComponents`, each sanitized independently. User data (description/card label) is slash-stripped by `sanitize` *before* interpolation, so only the template author can nest. `TemplateRenderer` is pure; **`PathPlanner.plan` groups the preview by the rendered day-folder path and `CopyPlan.destinationDirectory` renders the same components — they must agree.** Companions are renamed to track the primary's new name so the stem relationship survives (long-form `IMG.DNG.xmp` → `{newName}.xmp`; short-form shared-stem → `{newStem}.{ext}`). Folder/description/template-output sanitization is in `PathPlanner.sanitize` (single component) / `PathPlanner.sanitizedComponents` (nested folder path).

### The copy engine (`Copier`)

`Copier.start(...)` spawns a `Task` running `run(...)`, which:
- Builds a **`DestinationIndex`** per destination root (size-bucketed snapshot; hashes only on a size collision) for dedup.
- Per bundle, per file: dedup-check → copy+tee-hash → optional verify → record hash. Skipped (duplicate) bytes still count toward progress so the bar fills smoothly.
- **Rollback:** if any file in a bundle fails, already-written files from *that bundle* are deleted (the bundle is all-or-nothing).
- **Halt vs. continue:** a verification mismatch halts the entire job; any other per-bundle error is logged, counted as failed, and the job continues.
- Optionally ejects the card (`DriveEjector` → `diskutil eject`), writes a log file (`JobLogger` → `~/Library/Logs/PhotoDrop/ingest-<ts>.log`), writes a **verification manifest** (`ManifestWriter` → `<primaryRoot>/PhotoDrop Manifests/ingest-<ts>.{json,csv}`), and persists the hash cache.

### Verification manifest (`Manifest` / `ManifestWriter`)

Every ingest writes a receipt of what landed and its checksums, as JSON + CSV, into a `PhotoDrop Manifests/` folder at the primary destination root (filename stamp matches the job's log). Entries are accumulated during the **primary** copy pass only (`recordManifest:` in `copyBundle`) — the archive is a byte-identical mirror — and cover copied/verified files (with their `xxhash64`) and skipped duplicates (matched path, no re-hash). The manifest URL flows back in `CopyResult.manifestURL`; the completion sheet's **Export Manifest…** saves a copy elsewhere. This surfaces the hashes the copy engine already computes rather than discarding them after the verify step.

**Per-file checksum xattr.** In addition to the manifest, `IngestEngine` stamps each copied file's `xxhash64` into an extended attribute (`com.tsvb.photodrop.xxh64`, [FileChecksumXattr.swift](Sources/PhotoDropMac/Core/FileChecksumXattr.swift)) so the file carries its own checksum. `VerifyEngine.runXattr` (CLI `verify --xattr`) walks a folder and re-checks every stamped file — manifest-free, so it survives a library reorg or a lost manifest. **Secondary and best-effort**: xattrs are stripped by exFAT/FAT, some cloud sync, and `cp -X`, so the manifest stays authoritative; an absent attribute means "unstamped", never "changed".

**Re-verification** (`Verifier` / `VerifySheet`, launched from the toolbar's *Verify Library* button): pick a library folder (or a manifest `.json`) and it re-hashes every file recorded in the manifest(s) under `<folder>/PhotoDrop Manifests/`, reporting matches / changed (silent corruption) / missing. The manifest is the source of truth — each file resolves relative to its own manifest's location (two levels up), so a moved library still verifies. Hashing reuses `XxHash64.hash(fileAt:)` and runs off-main with throttled progress, mirroring the copy engine.

State is exposed as a `CopierState` enum (`idle`/`running`/`completed`/`cancelled`/`failed`) that the UI switches on.

### Hashing & dedup performance model

- **`XxHash64`** ([Hasher.swift](Sources/PhotoDropMac/Hasher.swift)) — a pure-Swift, value-type (trivially `Sendable`) streaming XXH64. Non-cryptographic; used only for copy verification and dedup equality.
- **Tee-hashing** (`FileCopier.copyAndHash`) — streams source→dest in 1 MiB chunks while hashing the bytes in flight, so a multi-GB file is read exactly once for both the copy and its digest.
- **`HashCache`** (an `actor`, persisted as JSON at `~/Library/Application Support/PhotoDropMac/hash-cache.json`) — caches digests keyed by `volumeUUID|path` (source) / `path` (dest), validated by `(size, mtime)`. A warm cache turns a re-ingest of the same card against the same destination from a file-read-bound operation into a stat-bound one (the SD read, the bottleneck, is skipped entirely). After a copy+verify, the just-computed digest is written back via `recordDestination` so the next run doesn't re-hash it.
- **Dedup semantics** (`DestinationIndex.findDuplicate`) match Windows: a file is a duplicate if size+hash match **anywhere under the destination root**, not just at the same path — so a renamed earlier import is still detected.

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
- `photodrop.extraArchiveDestinations` (String, newline-separated extra archive folder paths) — additional mirror destinations beyond Primary + Archive (3-2-1 backups). Assembled with the primary archive into the ordered list via [ArchiveDestinations.swift](Sources/PhotoDropMac/ArchiveDestinations.swift); each gets its own verified copy. Edited in Settings → General
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

The enum-typed keys (`VerificationStyle`, `MenuBarVisibility`) get their `String`-backed type from [AppCoordinator.swift](Sources/PhotoDropMac/AppCoordinator.swift), which is the one definition site shared by every `@AppStorage` declaration.
