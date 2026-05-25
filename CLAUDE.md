# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS (SwiftUI, Swift 6) app that ingests photos from removable memory cards into a date-organized library. It scans a card, previews a year/day folder tree, then copies each photo bundle with streaming hash verification, content-based deduplication, optional dual-destination archival, and optional card eject.

This is a port of a Windows app (`PhotoDrop`, .NET/WPF). The Windows `PhotoDrop.Core` is the **behavioral source of truth** — much of the discovery, dedup, companion-classification, and path-planning logic deliberately mirrors it (comments say "matches the Windows ..."). When changing that behavior, treat the Windows reference as authoritative rather than "fixing" it locally. See [HANDOFF_FROM_WINDOWS.md](HANDOFF_FROM_WINDOWS.md) for context (note: the Avalonia recipe there is explicitly *not* the path taken).

## Build & run

The `.xcodeproj` is **gitignored and generated** — it is not in version control. You must regenerate it before building a fresh checkout, and after any change to `project.yml` or after adding/removing/renaming source files:

```bash
xcodegen generate                                                      # regenerate PhotoDropMac.xcodeproj from project.yml
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' build    # build
```

`xcodegen` is installed via Homebrew (`brew install xcodegen`). There is a single application target/scheme, `PhotoDropMac`. Deployment target is macOS 14.0.

### Tests

There is **no XCTest target**. The only automated test is a DEBUG-only self-check of the hash implementation: `XxHash64Vectors.validated` (entry point `xxHash64SelfCheck()`) in [Hasher.swift](Sources/PhotoDropMac/Hasher.swift). It asserts XXH64 reference vectors and streaming-split correctness; assertions fire only in Debug builds. To exercise it, call `xxHash64SelfCheck()` early in launch, or build/run a Debug configuration.

### Signing / sandbox

Unsandboxed (`com.apple.security.app-sandbox = false`), ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), hardened runtime off. This is deliberate: the app needs unrestricted filesystem access (arbitrary card → arbitrary destination) and shells out to `/usr/sbin/diskutil` via `Process` to eject cards — no entitlements required because of the unsandboxed/ad-hoc setup. Don't add the sandbox entitlement without rethinking eject and folder access.

## The ingest pipeline (big picture)

Data flows through a chain of mostly-pure value-type transforms, driven by three `@MainActor @Observable` controllers. End to end:

1. **`DriveWatcher`** — observes `NSWorkspace` mount/unmount and exposes `[DetectedDrive]` (removable/ejectable local volumes; built-in SD readers report "internal" so that flag is intentionally *not* filtered on). It is injected via `.environment` and, crucially, is hosted by the `MenuBarExtra` label so it stays alive in the scene graph even when the main window is closed — that's what lets a card insertion auto-open the window ([PhotoDropMacApp.swift](Sources/PhotoDropMac/PhotoDropMacApp.swift)).
2. **`AssetDiscovery.scan(root:)`** — two-pass directory walk producing `[AssetBundle]`. Pass 1: RAW primaries + their same-directory companions; pass 2: standalone JPEGs not already claimed as a RAW's JPEG-pair. Extension sets (RAW list, sidecar `.xmp`/`.dop`/`.pp3`/`.wav`, JPEG) and the companion-classification rules (cases A/B in `classifyCompanion`) mirror the Windows reference. Companion matching is **same-directory only** by design.
3. **`ExifReader`** — `DateTimeOriginal` (or `Digitized`) via ImageIO, parsed in the *local* timezone; falls back to file mtime. This date drives all folder grouping.
4. **`PathPlanner.plan`** — groups bundles into `[YearGroup] → [DestinationFolder]` by capture date, for the preview tree. **`CopyPlan.plan`** — computes the actual destination path/filename per bundle.
5. **`IngestPlanner`** — orchestrates the scan (off-main via `Task.detached`) and holds `yearGroups` for the UI.
6. **`Copier`** — the copy engine (details below).

### The `AssetBundle` is the atomic unit

A bundle is one primary photo + its companions (`.xmp`/`.dop`/`.pp3` sidecars, JPEG pair, `.wav` audio note). Copy, verify, rollback, and dedup all operate on whole bundles: a RAW without its `.dop` has lost its edits, so they must move or fail together. `CompanionKind` is a deliberately closed set ([AssetBundle.swift](Sources/PhotoDropMac/AssetBundle.swift)).

### Destination layout

`CopyPlan` writes to: `{root}/{yyyy}/{yyyy-MM-dd}[_{Description}]/{yyyyMMdd_HHmmss}_{OriginalName}`. Companions are renamed to track the primary's new name so the stem relationship survives (long-form `IMG.DNG.xmp` → `{newName}.xmp`; short-form shared-stem → `{newStem}.{ext}`). Folder/description sanitization is in `PathPlanner.sanitize`.

### The copy engine (`Copier`)

`Copier.start(...)` spawns a `Task` running `run(...)`, which:
- Builds a **`DestinationIndex`** per destination root (size-bucketed snapshot; hashes only on a size collision) for dedup.
- Per bundle, per file: dedup-check → copy+tee-hash → optional verify → record hash. Skipped (duplicate) bytes still count toward progress so the bar fills smoothly.
- **Rollback:** if any file in a bundle fails, already-written files from *that bundle* are deleted (the bundle is all-or-nothing).
- **Halt vs. continue:** a verification mismatch halts the entire job; any other per-bundle error is logged, counted as failed, and the job continues.
- Optionally ejects the card (`DriveEjector` → `diskutil eject`), writes a log file (`JobLogger` → `~/Library/Logs/PhotoDrop/ingest-<ts>.log`), and persists the hash cache.

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
- `photodrop.verifyCopies` (Bool, default `true`)
- `photodrop.ejectAfterIngest` (Bool, default `false`)
- `photodrop.showCompletionSheet` (Bool, default `true`)
