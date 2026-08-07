# PhotoDropMac — critical review

**Date:** 2026-08-06 · **Reviewed at:** `dff7ed0` · **Baseline then:** 132 tests, 0 failures
· **Now:** 153 tests, 0 failures — **Tier 1 fixed**

Every finding below was reproduced by a probe or traced through the source. Each is marked
**CONFIRMED** (a probe demonstrated it), **CONFIRMED (inspection)** (the code path is
unambiguous but no probe was run), or **MITIGATED** (real, but an existing safeguard blunts it).
Nothing is reported as "probably".

Tier 1 has since been fixed, and each entry records what shipped. The probes that demonstrated
those five defects were rewritten as permanent regression tests asserting the corrected
behavior; the remaining probes are preserved outside the repo and can be promoted the same way
as their fixes land.

---

## Verdict

**The data-safety core is excellent, and the quality drops sharply outside it.** That is the
single most useful thing to know about this repo. It is not uneven work — it is a *gradient*,
and the gradient tracks distance from the original copy engine.

What is genuinely good, with evidence:

- **`FileCopier`** puts overwrite-refusal at the syscall — `open(O_WRONLY|O_CREAT|O_EXCL)`
  ([FileCopier.swift:76](Sources/PhotoDropMac/Core/FileCopier.swift:76)) — rather than a prior
  `fileExists` check, and removes its own partial on *any* throw (`:130`). `flushToDisk`
  **throws** on `fsync` failure instead of `try?`-ing it (`:139`). This is the best code here.
- **`IngestEngine.swift:213`** writes `flushed = FileCopier.fullSyncVolume(at: root) && flushed`
  with the call deliberately on the left, so short-circuiting can't skip syncing later roots.
  A real bug avoided on purpose.
- **`ManifestWriter.resolve`** uses *lexical* normalization, not `standardizedFileURL`, because
  the latter is existence-dependent and would silently drop exactly the missing files `heal`
  exists to find ([Manifest.swift:123](Sources/PhotoDropMac/Core/Manifest.swift:123)). The
  reasoning is written down at the definition.
- **`DestinationIndex.swift:78`** reconstructs paths from `dir` because `FileManager` resolves
  `/var → /private/var`, which would make the collision set never string-match a planned
  destination. (My own first probe fell into precisely this trap — the code is right and I was
  wrong.)
- **`HashCache.matches`** fails closed on legacy entries, with a comment identifying that a
  false cache *hit* is the dangerous direction because skipped entries carry no digest.
- **`VerifyEngine.build`** refuses to arbitrate between disagreeing manifests and removes
  conflicted keys from the work set. The reasoning — every ordering signal is attacker-chosen —
  is correct and well argued.
- **The tests state the threat model, not the assertion.** `HashCacheValidatorTests`,
  `ManifestTrustTests`, `JobStampTests`, `AssetDiscoveryTests` all explain the attack or
  regression they encode. `ManifestTrustTests.swift:144` asserts a *structural* invariant rather
  than a golden string. This is rarer than it should be.
- **Not defects, despite suspicion:** the three themes are fully wired; the `@AppStorage` keys
  really are in sync across all three declaration sites; `Copier` is a thin controller, not a
  duplicate pipeline; accessibility on the marks and contact sheet is real;
  `scripts/make-icon.swift` and most of `release.sh` are genuine, including a staple-ordering
  subtlety most release scripts get wrong.

Where the care ran out — and the pattern is consistent — is **anything added after the core
was solid**: the second and third destinations, `heal`, the cancel path, the scheduled agent,
the post-ingest hook. These share a signature: the happy path works, and the failure path was
never exercised. The most telling instance is that `HealEngine` uses the exact
newest-manifest-wins rule that `VerifyEngine`, twenty files away, spends two paragraphs
explaining is unsafe — the *knowledge* is in the repo, it just didn't travel.

**And nothing enforces any of it.** There is no CI. 21 test files, a live GitHub remote, and
the only thing that runs them is a human typing `xcodebuild`. `release.sh` goes from `xcodegen`
straight to a notarized DMG with no test gate.

---

## Tier 1 — Data safety, or the user is told something false

> **STATUS: all five fixed.** Suite is 153 tests / 0 failures (was 132 before this
> work; the 21 added are the regressions below). New coverage:
> `IngestEngineFailureTests` (9 — mirror independence, duplicate roots, the cancel
> receipt, verified-count honesty), `HealEngineTests` +3 (planted manifest,
> agreeing manifests, pooled mirrors), `ArchiveDestinationsTests` +9 (identity
> dedup incl. symlinks). Each fix is described in place below.

### T1-1 · Mirror destinations do not fail independently · CONFIRMED → **FIXED**
[IngestEngine.swift:167](Sources/PhotoDropMac/Core/IngestEngine.swift:167) —
`for d in allRoots.indices { try await copyBundle(...) }` sits inside one `do`, so a throw at
`d=1` never attempts `d=2`.

> **Probe:** primary + unwritable mirror + healthy mirror, 3 bundles. Primary got all 3 files,
> **the healthy third destination got zero**, and the job reported `copied=3 failed=3`
> simultaneously.

Worst case is the 3-2-1 scenario the feature is sold on: a NAS drops offline mid-job and the
external SSD — which is fine — receives nothing at all.

**Shipped:** each destination now has its own `do/catch` inside the bundle loop
([IngestEngine.swift:177](Sources/PhotoDropMac/Core/IngestEngine.swift:177)). `CopyResult` gained
`failuresByDestination`, plus `primaryFailures` / `failedMirrors`; `CompletionSheet` keys its alarm
hero on `primaryFailures` and reports a failed mirror as *"Library complete — a mirror fell
behind"*, naming the mirror. Log lines are prefixed with the destination when there is more than
one. Regression: `testFailingMirrorDoesNotStarveTheNextMirror`,
`testPrimaryFailureIsStillReportedAgainstThePrimary`.

### T1-2 · Primary == archive reports a successful ingest as a total failure · CONFIRMED → **FIXED**
[ArchiveDestinations.swift:20](Sources/PhotoDropMac/Core/ArchiveDestinations.swift:20) dedupes
archives against *each other*, by raw string, and never against the primary.

> **Probe:** archive set to the primary path. All 3 photos landed correctly and verified — and
> the job reported `failed=3` with three "Refused to overwrite" errors. Maximum alarm, zero
> actual problem. A second probe confirmed `/Volumes/Photos/` and `/Volumes/Photos` both
> survive dedup as separate destinations.

Easy user mistake: two folder pickers side by side.

**Shipped:** `ArchiveDestinations.identity(ofPath:)` keys on **dev + inode** when the path exists
and the symlink-resolved, standardized path when it doesn't (archive folders are routinely
configured before they exist). `list` now takes the primary and drops any spelling of it;
`mirrors` gives the CLI's repeatable `--archive` the same protection — it previously bypassed
dedup entirely. `IngestEngine` also calls `dedupedRoots` on `[primary] + archives` so no caller
can reintroduce it, and logs when it drops one. Verified end-to-end: `photodrop ingest --to X
--archive X` now exits 0 with 3 copied, 0 failed.

### T1-3 · `heal` trusts a planted manifest that `verify` correctly rejects · CONFIRMED → **FIXED**
[HealEngine.swift:58](Sources/PhotoDropMac/Core/HealEngine.swift:58) does
`byPath[fileURL.path] = Item(...)` unconditionally after an oldest→newest sort — newest wins.
[VerifyEngine.swift:119](Sources/PhotoDropMac/Core/VerifyEngine.swift:119) refuses to do this,
and explains why at length.

> **Probe:** tamper with a file, drop `ingest-20990101-000000-000.json` recording the tampered
> digest into the library's own manifest folder. `verify` → `conflicts=1` (correct).
> `heal` → `healthy=1, candidates=0` — it declares the corrupted library perfectly fine.

This is the sharpest finding in the review: two engines consume the same untrusted input and
only one applies the trust rule the repo already worked out.

**Shipped:** `HealEngine.run` is now a thin pass over `VerifyEngine.build` — its private merge is
gone. Conflicts surface as a new `HealCandidate.Kind.conflicted`, never recoverable, rendered by
the CLI as *"NOT HEALABLE — two manifests record different checksums."* `VerifyEngine.WorkItem`
gained `mirrors`, unioned across manifests that *agree* (safe: a mirror is only offered after its
bytes hash to the expected digest), so heal lost no recovery ability. Verified end-to-end: the
planted-manifest library now reports CONFLICT and exits 1.

### T1-4 · Cancelling an ingest destroys the integrity record · CONFIRMED → **FIXED**
[IngestEngine.swift:202](Sources/PhotoDropMac/Core/IngestEngine.swift:202) returns `nil` on
cancel — before the manifest write, the log write, and `cache.save()`, and without rolling back.

> **Probe:** cancel after 3 of 8 bundles. **3 files on disk, 0 manifests.** Those photos have
> no integrity record at all. Combine with T2-2 below and re-ingesting cannot repair it: the
> dedup path records `xxhash64: nil`, so `verify` will report success over zero files forever.

Cancelling is a routine user action, not an edge case.

**Shipped:** cancellation falls through to the manifest, log, and cache save instead of returning
early, skipping only the eject. `Manifest.partial` (optional, so old manifests still decode) marks
a job that stopped early. `run()` now always returns a `CopyResult`, with `cancelled` set —
and `Copier`'s completion guard was changed from `!flag.isCancelled` to a *superseded-run* check,
because the old guard discarded the very receipt the engine had stayed alive to write.
`CopierState.cancelled` carries the result so the UI can reach the log and manifest.
Regression: `testCancellationStillWritesAManifestForWhatLanded` asserts the manifest exists, is
marked partial, matches what's on disk, and re-verifies clean.

### T1-5 · `verifiedBundles` counts bundles that were never verified · CONFIRMED → **FIXED**
[IngestEngine.swift:172](Sources/PhotoDropMac/Core/IngestEngine.swift:172) increments
unconditionally; `verify` is never consulted.
[MainView.swift:412](Sources/PhotoDropMac/UI/MainView.swift:412) then renders
*"The N already-verified bundles are safe on disk."*

> **Probe:** ingest with `verify: false`, cancel. `verifiedBundles=3`, and **zero** `.verified`
> log lines — nothing was hash-checked after write.

A false reassurance, in the reassurance string, of a data-integrity tool.

**Shipped:** `if verify && primaryOK { verifiedBundles += 1 }` — also excluding bundles whose
primary copy failed, which were never verified *there* whatever the mirrors did. `Copier` now
tracks `completedBundles` alongside, and `MainView.landedPhrase` says "already-verified … safe on
disk" only when something was actually hash-checked, otherwise "N completed bundles are on disk
(copy verification was off)".

---

## Tier 2 — Advertised but shallow

### T2-1 · Mirror filenames diverge from the primary, silently breaking `heal` · CONFIRMED
[IngestEngine.swift:149](Sources/PhotoDropMac/Core/IngestEngine.swift:149) computes
`existingPaths` and `planBatch` independently per root, so `_1` disambiguation is per-root.

> **Probe:** pre-seed a colliding name in the primary only. Primary wrote
> `…_IMG_0001_1.JPG`, mirror wrote `…_IMG_0001.JPG`. The manifest records only the primary's
> path, so `heal` looks for the primary's name under the mirror root, doesn't find it, and
> reports the file **unrecoverable** with a perfect copy sitting right there.

**Fix:** plan once and reuse the same relative path for every mirror — a mirror should be
name-identical by definition, and `heal` already assumes it. Union the existing-name sets
across roots when disambiguating.

### T2-2 · An all-duplicate re-ingest writes a manifest that attests to nothing · CONFIRMED
`DestinationIndex.findDuplicate` computes the source digest and returns only the URL;
[IngestEngine.swift:320](Sources/PhotoDropMac/Core/IngestEngine.swift:320) then records
`xxhash64: nil`, and `VerifyEngine.build:115` skips nil-digest entries.

> **Probe:** ingest twice. Second manifest: 3 entries, **all 3 with no digest**. `verify` →
> `verified=0` and reports success.

The digest needed to fix this was already computed and thrown away.

**Fix:** return the digest from `findDuplicate` and record it on skipped entries.

### T2-3 · `PostIngestHook` deadlocks on a chatty hook · CONFIRMED
[PostIngestHook.swift:51](Sources/PhotoDropMac/Core/PostIngestHook.swift:51) sets
`standardOutput = Pipe()` and never reads it; stderr drains only inside `terminationHandler`,
which by definition runs after exit.

> **Probe:** a hook writing ~1 MiB to stdout **never returned** (10 s timeout). The child blocks
> writing to a full 64 KiB pipe buffer, the termination handler never fires, and the
> continuation never resumes — a permanently leaked task on every ingest.

Any hook that runs `rsync -v` or `exiftool` trips this.

**Fix:** drain both pipes concurrently (`readabilityHandler`, or read to EOF before
`waitUntilExit`). `DriveEjector.swift:50` and `ScheduledVerification.runLaunchctl:106` have the
same shape — safe today only because `diskutil` and `launchctl` are quiet. Fix the pattern once.

### T2-4 · A long filename exceeds `NAME_MAX` and fails the whole bundle · CONFIRMED
`PathPlanner.sanitize` caps the **stem** at 255 UTF-8 bytes; `CopyPlan.swift:136` then appends
`.{ext}`.

> **Probe:** a 240-char source stem planned a **259-byte** filename → `ENAMETOOLONG` → bundle
> failed and rolled back. Direct check: `sanitize` returns exactly 255 bytes, leaving no room
> for the extension. `CopyPlanTests.swift:93` only asserts the *folder leaf* is ≤ 255, so
> CLAUDE.md listing "the `NAME_MAX` cap" under tested behavior is not accurate for filenames.

**Fix:** cap the stem at `255 - (extension bytes + 1)`. Same for the long-form companion suffix
at `CopyPlan.swift:189`. Add the filename case to `CopyPlanTests`.

### T2-5 · `verify --xattr` exits 0 on an unreadable or nonexistent target · CONFIRMED
[VerifyEngine.swift:149](Sources/PhotoDropMac/Core/VerifyEngine.swift:149) returns an empty
report, indistinguishable from "nothing stamped".

> **Probe:** against a nonexistent path *and* a `chmod 000` directory, both printed
> "No checksummed (xattr) files found" and **exited 0**. A verification tool reporting success
> on a target it could not read. A typo in a script gets a green check forever.

**Fix:** distinguish "target unreadable/absent" from "target readable, nothing stamped" —
return `nil` (or a distinct case) for the former and exit 2, matching the manifest path.

### T2-6 · The nightly agent cries wolf on a missing manifest · CONFIRMED
[ScheduledVerification.swift:55](Sources/PhotoDropMac/Core/ScheduledVerification.swift:55)
builds `… verify … --json || osascript -e 'display notification "Verification found issues"'`.
Measured: `verify` exits **2** when no manifest exists — identical treatment to exit 1
(real corruption).

Point it at a library with no `PhotoDrop Manifests/` and it posts "Verification found issues"
every night, training the user to ignore the one notification that matters. The log at
`StandardOutPath` also has no rotation.

**Fix:** branch on the exit code in the shell command — 1 → "issues found", 2 → "could not
verify (no manifest)". Add `newsyslog`-style rotation or cap the log.

### T2-7 · The scheduled-verify toggle can lie in both directions · CONFIRMED (inspection)
`isInstalled` ([:47](Sources/PhotoDropMac/Core/ScheduledVerification.swift:47)) only stats the
plist and never asks launchd whether the job is loaded. If `bootstrap` throws,
[SettingsView.swift:97](Sources/PhotoDropMac/UI/SettingsView.swift:97) sets `enabled = false`
but never calls `uninstall()` — the orphan plist stays in `~/Library/LaunchAgents` and may load
at next login, running verifications the user believes are off. Separately,
`SettingsView.swift:81` re-applies only on `enabled`/`schedule`, so editing `binaryPath` or
`libraryOverride` leaves the installed agent pointing at the old target while the UI shows the
new one; and `.disabled(effectiveBinaryPath.isEmpty || libraryPath.isEmpty)` can strand the
toggle greyed *on* with no way to remove the agent.

**Fix:** `uninstall()` on bootstrap failure; derive `isInstalled` from `launchctl print`;
`onChange` for the path fields; don't disable the toggle when it is currently on.

### T2-8 · Smaller confirmed items
- **`heal --script` overwrites its output path** with `write(toFile:atomically:)`
  ([PhotoDropCLI.swift:51](Sources/PhotoDropCLI/PhotoDropCLI.swift:51)) — the exact behavior
  `JobStamp.claimUniqueName` exists to prevent everywhere else. Use the claim.
- **`schemaID` is write-only.** `ManifestWriter.decode` never checks `schema`, so any
  structurally-valid JSON is accepted as a PhotoDrop manifest. Versioning that isn't.
- **CLI ingest has no cancellation path and skips the post-ingest hook.**
  `PhotoDropCLI.swift:138` never supplies `isCancelled` and there is no SIGINT handler, so
  Ctrl-C leaves a partial file with no manifest entry; `:151` never runs the hook the app runs.
- **`heal` restoring from a manifest-named root · MITIGATED.** A planted manifest can point
  `destinations[1]` anywhere and `heal` will emit a `cp` from it — but the generated script
  *does* list every source root in an up-front "confirm you recognize every one of them"
  comment block, and the control-character refusal works. The safeguard functions as designed;
  the residual risk is only that a disclosed path may look plausible. Worth keeping in mind,
  not worth code changes.
- **`AssetBundle.photoCount`** returns a fixed `1` and has zero call sites. Dead.
- **`PreflightCheck.spaceWarning`** iterates a `Dictionary` and returns on the first
  over-capacity volume, so with two full destinations the one reported is nondeterministic.
- **`TemplateRenderer.resolve`** allocates a `DateFormatter` per token per bundle per root, and
  `destinationDirectory` is called three times per bundle. Thousands of the most expensive
  object in Foundation on a large card.

---

## Tier 3 — Process (highest leverage per hour)

1. **There is no CI.** No `.github/`, no workflow, no pre-commit, despite a live remote. This
   is the single highest-value item in the review: 132 passing tests that nothing runs
   automatically. A `macos-latest` workflow running `xcodegen generate && xcodebuild … test`
   is an afternoon's work and would have caught several Tier-1 items as they were introduced.
   Note the hosted test bundle needs a GUI session — GitHub's macOS runners provide one.
2. **`release.sh` never runs the tests** — [:67](scripts/release.sh:67) `xcodegen` →
   [:74](scripts/release.sh:74) `archive`, straight through to a notarized DMG. Add a test gate
   before the archive step.
3. **`XCTSkip` on a poll-loop timeout** ([CopierManifestTests.swift:66](Tests/PhotoDropMacTests/CopierManifestTests.swift:66),
   [VerifierTests.swift:63](Tests/PhotoDropMacTests/VerifierTests.swift:63)) converts a real
   failure into a green skip on a loaded machine. The §1.2 rollback regression — the most
   important test in the suite — can stop running and nothing reports it. Replace with
   `XCTFail`, or an `XCTestExpectation` with a generous timeout.
4. **The test suite has side effects on the developer's machine.** Measured: one run of
   `CopierManifestTests` added **5 files to the real `~/Library/Logs/PhotoDrop/`** (133 → 138)
   and never cleans up. The same path calls `UNUserNotificationCenter.requestAuthorization`
   (a real system prompt) and reads
   `UserDefaults.standard[photodrop.postIngestScript]` — **so on a machine with a hook
   configured, running the tests executes the developer's script.** The cache and index stores
   are already injectable; make the log directory, notifier, and hook injectable the same way.
5. **Coverage gaps in data-safety code.** No test at all: `DriveEjector`, `JobLogger`,
   `PreflightCheck`, and `Hasher` (346 LOC — README:245 sells the Debug-only `assert` as
   coverage, but nothing calls `xxHash64SelfCheck()`). Partially tested but missing the branches
   that matter: `IngestEngine`'s halt / cancel / archive-failure paths, `DestinationIndex.build`
   and `buildIncremental`, the `HashCache` actor itself (only `matches` is tested), and
   `ScheduledVerification`'s install/uninstall. The CLI (365 LOC) is **structurally untestable**
   — [project.yml:76](project.yml:76) binds the test target to the app only — so the documented
   exit-code contract is unverified. The probes written for this review cover several of these
   and can be promoted.
6. **`release.sh` DMG branch is likely broken.** [:116](scripts/release.sh:116) passes the
   `.app` where `create-dmg` expects a source *folder*, which would put `Contents/` at the DMG
   root. The `hdiutil` fallback stages correctly — so the "nicer" branch only fires on machines
   with `create-dmg` installed, i.e. it differs from the path that was actually tested. Worth a
   manual check before the next release. Also no `git tag` and no `MARKETING_VERSION` bump.

---

## Tier 4 — UI and documentation drift

- **The halt path dead-ends.** `Copier.swift:115` collapses a halted run to `.failed(String)`,
  discarding `logURL` and `manifestURL`; `MainView.swift:396` then shows *"Halted: verification
  mismatch. See log."* with no Open Log button and no visible log. A verification mismatch is
  the most important event this app can report, and it leaves the user with a sentence.
- **An in-flight ingest is untethered from the UI.** Close the window mid-copy
  (`Copier.swift:112`) and the detached engine runs to completion — writing files, ejecting the
  card — then `guard let self` fails, so no notification and no hook fire. There is also no
  `applicationShouldTerminate` anywhere, so ⌘Q mid-copy leaves a truncated file with no
  rollback, no manifest entry, and no xattr — invisible to both `verify` modes.
- **Culling is invisible outside the grid.** Deselect 400 of 500 and the nav subtitle and tree
  still say 500 while Ingest copies 100.
- **"With card" menu-bar mode silently disables auto-open** (`PhotoDropMacApp.swift:62`): the
  `MenuBarExtra` is inserted *because* the card arrived, so `onChange` never observes a
  transition. The setting works only in "Always" mode and nothing says so.
- **Per-keystroke re-plan on the main actor** (`IngestPlanner.swift:54`): typing in the
  Description field re-runs `PathPlanner.plan` over every bundle synchronously.
- **Thumbnails that fail to decode spin forever** (`ContactSheet.swift:159`) — no failure
  placeholder.
- **Silent `try?` cluster:** `IngestPreset.swift:127` (a failed preset save is invisible),
  `Notifier.swift:47` (denied notifications leave the toggle checked forever, and authorization
  is requested at the worst moment — the first completion, by design when the app isn't
  frontmost), `MainView.swift:359` (sidebar eject reports neither success nor failure).
- **Zero localization**, no state restoration, no menu commands or keyboard shortcuts, and
  image-only buttons using `.help()` — which sets the AX *help* attribute, not the name, so
  VoiceOver announces them unnamed.
- **CLAUDE.md:** the *"The copy engine (`Copier`)"* section describes indexing, rollback, and
  manifest writing that now live in `IngestEngine`; `Copier` is 156 lines of state plumbing.
  **12 source links are broken** — flat `Sources/PhotoDropMac/X.swift` paths predating the
  `Core/`/`UI/` split. The test inventory names 14 suites; 21 exist (undocumented:
  `HealEngineTests`, `ScheduledVerificationTests`, `PostIngestHookTests`, `IngestPresetTests`,
  `VerifyEngineTests`, `XattrTests`, `ArchiveDestinationsTests`). Every claim it *does* make
  checks out, and the hosted/GUI caveat is accurate.
- **README.md:200–222** project tree is wholesale stale — no `Core/`/`UI/` split, no
  `Sources/PhotoDropCLI/`, `Tests/`, or `scripts/`; a reader will not find one file at its
  stated path. **README:245** presents the Debug-only hash self-check as test coverage.
- **`VerifyEngineTests.swift:5`** header still advertises "newest-manifest-wins", contradicted
  by the test at `:79` that replaced it.

---

## Suggested order

1. **T1-5** and **T1-2** — an hour between them, and both stop the app from lying to the user.
2. **CI** (Tier 3.1) before the structural fixes, so the rest lands against a gate.
3. **T1-3** (`heal` reuses `VerifyEngine.build`) — mostly deletion, closes the sharpest gap.
4. **T1-4** and **T1-1** — the two structural ones; both change `CopyResult`, so do them together.
5. **T2-2**, **T2-3**, **T2-4**, **T2-5** — contained, and each has a probe ready to promote.
6. Tier 4 docs in one pass; the CLAUDE.md link rot and the `Copier` section are actively
   misleading to anyone (or any agent) working from them.
