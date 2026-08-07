# PhotoDropMac — critical review

**Date:** 2026-08-06 · **Reviewed at:** `dff7ed0` · **Baseline then:** 132 tests, 0 failures
· **Now:** 204 tests, 0 failures — **Tiers 1, 2 and 3 fixed**

Every finding below was reproduced by a probe or traced through the source. Each is marked
**CONFIRMED** (a probe demonstrated it), **CONFIRMED (inspection)** (the code path is
unambiguous but no probe was run), or **MITIGATED** (real, but an existing safeguard blunts it).
Nothing is reported as "probably".

Tiers 1, 2 and 3 have since been fixed, and each entry records what shipped. Every probe that
demonstrated a defect was rewritten as a permanent regression test asserting the corrected
behavior. **Tier 4 (UI dead ends, README drift) remains open**, along with the security
findings in `HANDOFF.md` §5 — `XxHash64.hash(fileAt:)` accepting a character device is the
sharpest of them.

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

**And at review time nothing enforced any of it.** There was no CI: 21 test files, a live
GitHub remote, and the only thing that ran them was a human typing `xcodebuild`; `release.sh`
went from `xcodegen` straight to a notarized DMG with no test gate. Both are now closed (Tier 3),
which is what makes the rest of this document durable rather than a snapshot.

---

## Tier 1 — Data safety, or the user is told something false

> **STATUS: all five fixed.** New coverage: `IngestEngineFailureTests` (mirror
> independence, duplicate roots, the cancel receipt, verified-count honesty),
> `HealEngineTests` +3 (planted manifest, agreeing manifests, pooled mirrors),
> `ArchiveDestinationsTests` +9 (identity dedup incl. symlinks). Each fix is
> described in place below.

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

> **STATUS: all eight fixed.** New coverage: mirror parity and re-ingest digests in
> `IngestEngineFailureTests`, deadlock races in `PostIngestHookTests`, the NAME_MAX
> cases in `CopyPlanTests`, unreadable-target cases in `XattrTests`, exit-code
> branching in `ScheduledVerificationTests`, schema validation in
> `ManifestTrustTests`. The child-process fix is shared:
> [`ChildProcess`](Sources/PhotoDropMac/Core/ChildProcess.swift).

### T2-1 · Mirror filenames diverge from the primary, silently breaking `heal` · CONFIRMED → **FIXED**
[IngestEngine.swift:149](Sources/PhotoDropMac/Core/IngestEngine.swift:149) computes
`existingPaths` and `planBatch` independently per root, so `_1` disambiguation is per-root.

> **Probe:** pre-seed a colliding name in the primary only. Primary wrote
> `…_IMG_0001_1.JPG`, mirror wrote `…_IMG_0001.JPG`. The manifest records only the primary's
> path, so `heal` looks for the primary's name under the mirror root, doesn't find it, and
> reports the file **unrecoverable** with a perfect copy sitting right there.

**Shipped:** the plan is computed once and rebased onto each mirror (`IngestEngine.rebase`), and
collision avoidance unions the existing names across *all* destinations so one name is free
everywhere. Regression: `testMirrorUsesTheSameFilenameAsThePrimary` and
`testHealFindsTheMirrorCopyAfterACollision`, which asserts the actual consequence, not just the names.

### T2-2 · An all-duplicate re-ingest writes a manifest that attests to nothing · CONFIRMED → **FIXED**
`DestinationIndex.findDuplicate` computes the source digest and returns only the URL;
[IngestEngine.swift:320](Sources/PhotoDropMac/Core/IngestEngine.swift:320) then records
`xxhash64: nil`, and `VerifyEngine.build:115` skips nil-digest entries.

> **Probe:** ingest twice. Second manifest: 3 entries, **all 3 with no digest**. `verify` →
> `verified=0` and reports success.

The digest needed to fix this was already computed and thrown away.

**Shipped:** `findDuplicate` returns a `Duplicate { url, hash }` and the skipped manifest entry
records it. Verified end-to-end: a second `photodrop ingest` of the same card now yields
`✓ All 3 files across 2 manifests match`. Regression:
`testSkippedFilesRecordTheDigestTheDedupMatchedOn`.

### T2-3 · `PostIngestHook` deadlocks on a chatty hook · CONFIRMED → **FIXED**
[PostIngestHook.swift:51](Sources/PhotoDropMac/Core/PostIngestHook.swift:51) sets
`standardOutput = Pipe()` and never reads it; stderr drains only inside `terminationHandler`,
which by definition runs after exit.

> **Probe:** a hook writing ~1 MiB to stdout **never returned** (10 s timeout). The child blocks
> writing to a full 64 KiB pipe buffer, the termination handler never fires, and the
> continuation never resumes — a permanently leaked task on every ingest.

Any hook that runs `rsync -v` or `exiftool` trips this.

**Shipped:** a shared [`ChildProcess`](Sources/PhotoDropMac/Core/ChildProcess.swift) runner starts
both drains *before* `run()` and completes only once both hit EOF; it also closes the write ends
if the spawn fails, so reader threads can't be stranded. `PostIngestHook`, `DriveEjector` and
`ScheduledVerification` all use it. Regression: two tests race a ~1 MiB-of-output hook against a
20 s deadline — they now finish in 0.14 s.

### T2-4 · A long filename exceeds `NAME_MAX` and fails the whole bundle · CONFIRMED → **FIXED**
`PathPlanner.sanitize` caps the **stem** at 255 UTF-8 bytes; `CopyPlan.swift:136` then appends
`.{ext}`.

> **Probe:** a 240-char source stem planned a **259-byte** filename → `ENAMETOOLONG` → bundle
> failed and rolled back. Direct check: `sanitize` returns exactly 255 bytes, leaving no room
> for the extension. `CopyPlanTests.swift:93` only asserts the *folder leaf* is ≤ 255, so
> CLAUDE.md listing "the `NAME_MAX` cap" under tested behavior is not accurate for filenames.

**Shipped:** `PathPlanner.fileName(stem:extension:)` composes the whole name under the cap and
never truncates the extension; `CopyPlan` also subtracts the `_1` disambiguator's own length
before trimming, and both companion forms go through it. Regression: four tests in
`CopyPlanTests`, including the disambiguated case.

### T2-5 · `verify --xattr` exits 0 on an unreadable or nonexistent target · CONFIRMED → **FIXED**
[VerifyEngine.swift:149](Sources/PhotoDropMac/Core/VerifyEngine.swift:149) returns an empty
report, indistinguishable from "nothing stamped".

> **Probe:** against a nonexistent path *and* a `chmod 000` directory, both printed
> "No checksummed (xattr) files found" and **exited 0**. A verification tool reporting success
> on a target it could not read. A typo in a script gets a green check forever.

**Shipped:** `runXattr` returns a `XattrOutcome` — `.report`, `.unreadableTarget`, `.cancelled` —
decided up front, because `FileManager`'s enumerator is lazy and swallows its own errors. The CLI
exits 2 with a specific message. Verified end-to-end: nonexistent → 2, `chmod 000` → 2,
readable-but-unstamped → 0. Regression: four tests in `XattrTests`.

### T2-6 · The nightly agent cries wolf on a missing manifest · CONFIRMED → **FIXED**
[ScheduledVerification.swift:55](Sources/PhotoDropMac/Core/ScheduledVerification.swift:55)
builds `… verify … --json || osascript -e 'display notification "Verification found issues"'`.
Measured: `verify` exits **2** when no manifest exists — identical treatment to exit 1
(real corruption).

Point it at a library with no `PhotoDrop Manifests/` and it posts "Verification found issues"
every night, training the user to ignore the one notification that matters. The log at
`StandardOutPath` also has no rotation.

**Shipped:** the command captures `RC` and branches — exit 1 says "found issues", exit 2 says
"could not verify … no manifest found". Instead of log rotation, output is echoed *only* on a
non-zero exit, so a healthy library adds nothing to the log at all. Regression: two tests in
`ScheduledVerificationTests`, one asserting the old `--json ||` shape is gone.

### T2-7 · The scheduled-verify toggle can lie in both directions · CONFIRMED (inspection) → **FIXED**
`isInstalled` ([:47](Sources/PhotoDropMac/Core/ScheduledVerification.swift:47)) only stats the
plist and never asks launchd whether the job is loaded. If `bootstrap` throws,
[SettingsView.swift:97](Sources/PhotoDropMac/UI/SettingsView.swift:97) sets `enabled = false`
but never calls `uninstall()` — the orphan plist stays in `~/Library/LaunchAgents` and may load
at next login, running verifications the user believes are off. Separately,
`SettingsView.swift:81` re-applies only on `enabled`/`schedule`, so editing `binaryPath` or
`libraryOverride` leaves the installed agent pointing at the old target while the UI shows the
new one; and `.disabled(effectiveBinaryPath.isEmpty || libraryPath.isEmpty)` can strand the
toggle greyed *on* with no way to remove the agent.

**Shipped:** all four. `install` removes the plist again when `bootstrap` throws; `isLoaded()`
asks `launchctl print` (the old `isInstalled` is now honestly named `hasPlist`); Settings
re-applies on `binaryPath`, `libraryOverride` and `primary` changes; and the toggle is disabled
only when it is *off*, so it can always be turned back off. `apply()` is async now — it used to
block the main thread on two `waitUntilExit()` calls.

### T2-8 · Smaller confirmed items · **FIXED**
**Shipped:** every item below, except the one already marked MITIGATED, which needed no change.

- **`heal --script` overwrites its output path** with `write(toFile:atomically:)`
  ([PhotoDropCLI.swift:51](Sources/PhotoDropCLI/PhotoDropCLI.swift:51)) — the exact behavior
  `JobStamp.claimUniqueName` exists to prevent everywhere else. **Fixed** with `O_EXCL` and a clear refusal rather than the claim's rename-and-continue: the path is the user's explicit choice, so quietly writing somewhere else would be the greater surprise.
- **`schemaID` is write-only.** `ManifestWriter.decode` never checks `schema`, so any
  structurally-valid JSON is accepted as a PhotoDrop manifest. Versioning that isn't. **Fixed** — `decode` rejects an unrecognized schema, so a future format is ignored rather than misread.
- **CLI ingest has no cancellation path and skips the post-ingest hook.**
  `PhotoDropCLI.swift:138` never supplies `isCancelled` and there is no SIGINT handler, so
  Ctrl-C leaves a partial file with no manifest entry; `:151` never runs the hook the app runs. **Fixed** — a `DispatchSource` SIGINT handler drives the engine's existing cancellation, and `--post-ingest-hook` runs it explicitly. Verified end-to-end: Ctrl-C at 33 of 40 files wrote a `partial: true` manifest covering exactly those 33, which then verified clean.
- **`heal` restoring from a manifest-named root · MITIGATED.** A planted manifest can point
  `destinations[1]` anywhere and `heal` will emit a `cp` from it — but the generated script
  *does* list every source root in an up-front "confirm you recognize every one of them"
  comment block, and the control-character refusal works. The safeguard functions as designed;
  the residual risk is only that a disclosed path may look plausible. Worth keeping in mind,
  not worth code changes.
- **`AssetBundle.photoCount`** returned a fixed `1` and had zero call sites. **Deleted.**
- **`PreflightCheck.spaceWarning`** iterates a `Dictionary` and returns on the first
  over-capacity volume, so with two full destinations the one reported is nondeterministic.
  **Fixed** — it now reports the volume furthest short, ties broken by path.
- **`TemplateRenderer.resolve`** allocates a `DateFormatter` per token per bundle per root, and
  `destinationDirectory` is called three times per bundle. Thousands of the most expensive
  object in Foundation on a large card. **Fixed** — formatters are cached by (time zone,
  pattern), with the formatting done inside the lock since `DateFormatter` isn't thread-safe.
  The redundant `destinationDirectory` calls remain.

---

## Tier 3 — Process (highest leverage per hour) · **ALL FIXED**

> **Shipped:** CI on every push and PR ([.github/workflows/ci.yml](.github/workflows/ci.yml)) —
> full suite, both schemes, a hermeticity assertion, and a doc-link check
> ([scripts/check-doc-links.sh](scripts/check-doc-links.sh), which reproduced all 13 broken
> CLAUDE.md links on its first run; they are now fixed). `release.sh` gained a test gate, a
> clean-tree refusal, version write-back and an annotated tag, plus a staged copy for
> `create-dmg`. The suite is hermetic via `Copier.hermetic(in:)` — measured 0 files added to
> `~/Library/Logs/PhotoDrop`, down from +18 per run. Skip-on-timeout is now a failure. 31 new
> tests across `DestinationIndexBuildTests`, `JobLoggerTests`, `ChildProcessTests`,
> `PreflightCheckTests` and the hermeticity cases. **Nothing in `~/Library/Logs/PhotoDrop` was
> deleted** — that is the user's audit trail.

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

---

# Third pass — topology, mirrors, and reporting (2026-08-07)

Run after Tiers 1–3 closed, aimed only at what the earlier passes missed. Three
disjoint sweeps (pure transforms, filesystem topology, lifecycle/CLI), every claim
re-verified against source. `HANDOFF.md` §5–§7 items are unaffected and remain open.

The pass named a second characteristic failure mode, alongside §2's *a correct
mechanism applied at some sinks and not others*:

> **Every guard protects one destination tree in isolation. Nothing validated the
> relationship *between* the trees — source vs destination, or destination vs
> destination — and nothing could verify a mirror at all.**

## Tier A — data safety · **fixed**

- **A1 · A destination may contain the source, and the card is then ejected.** No
  check anywhere. `findDuplicate` matches content anywhere under a root, so every
  file matched itself: 0 copied, 0 failed, no halt, a manifest pointing at the
  *source* files, CLI exit 0, card ejected. → `DestinationTopology`, refused.
- **A2 · Nested destination roots silently defeat mirroring.** `dedupedRoots`
  compares dev+inode, so `/Vol/X` and `/Vol/X/Lib` are "different folders" but not
  independent trees. Mirror-as-parent: the mirror stays empty forever, reporting
  success. Mirror-as-child: the primary write is skipped in favour of the backup
  copy and the manifest re-points the photo into it. → refused.
- **A3 · Case-only collisions escaped `_1`.** APFS is case-insensitive;
  `taken` compared exact strings. `IMG_0001.JPG` + `img_0001.jpg` → `O_EXCL`
  refuses, bundle fails and rolls back on every run, forever. Intra-bundle
  collisions were structurally invisible (`taken.insert` runs after `plan`
  returns), and could not be fixed inside the `_n` loop without hanging it.
  → `CopyPlan.collisionKey` + `separateInternalCollisions`.
- **A4 · Mirrors had no integrity record and the manifest attested to them
  anyway.** `partial` ignored `filesFailed`; entries were primary-only; mirrors
  had no manifest folder, so `verify <mirror>` exited 2 and `verify --xattr`
  cannot detect absence. → one manifest per root, `partial` on per-root failure,
  xattr-stamp failure logged once per root.
- **A5 · `photodrop ingest` exited 0 when the card was never read**, and a typo'd
  `--to` minted a whole library tree. → `ScanOutcome`; `--to` must exist.
- **A6 · Only SIGINT was a graceful stop.** SIGTERM/SIGHUP/logout/launchd-timeout
  all left an orphan partial invisible to both verify modes. → all three handled.

## Tier B — reporting integrity · **fixed**

B1 xattr walk had no `errorHandler` (unreadable subtree → `✓ All N match`, exit 0) ·
B2 unstamped files never counted (a stripped library read as a pass; a fully
unstamped exFAT/SMB mirror read as "nothing to check", exit 0) ·
B3 a directory-read failure was persisted as an *empty* snapshot **with the real
mtime**, so one transient EIO hid a day-folder from dedup forever ·
B4 unknown `{Token}`s went to `DateFormatter` (`{Descripton}` → `14854052026`,
`{Wedding}` → `5528`) and never dropped their optional group ·
B5 `ExifReader.parse` returned nil for the DST spring-forward hour, filing an hour
of shooting under the mtime date ·
B6 `sanitize` passed `? * < > | "` and trailing dots, which every SMB/exFAT mirror
rejects ·
B7 `Copier`'s progress/log hops had no generation guard and `reset()` didn't retire
the flag, so a superseded job's lines landed in the next job's log and the panel
reverted on its own ·
B8 a card yanked mid-scan produced a silently truncated plan.

242 tests, 0 failures (was 204). Each fix carries a regression test stating its
threat model and measured before-state.

## Tier C — **fixed** (follow-up pass)

All ten, plus one defect the work uncovered.

- **C1 · The hash was pinned by nothing.** `xxHash64SelfCheck()` had zero callers
  and used `assert` (a no-op in Release), while every other test in the suite used
  the hasher as a *self-consistent oracle* — hash source, hash destination,
  compare — which passes identically if the algorithm is wrong. → `HasherTests`:
  known-answer vectors from `xxh64sum`, every split offset of a multi-stripe
  message, many chunk sizes, a zero-length mid-stream update, single-bit
  sensitivity at every offset, and `hash(fileAt:)` vs in-memory either side of the
  1 MiB read boundary. The dead entry point is gone; README's claim that it was
  coverage is corrected. **The new tests immediately caught a wrong vector** — one
  reference digest had been generated from UTF-8-encoded text rather than raw
  bytes. The implementation was right; the table was not.
- **C2 · `dateSource` was computed on every scan and read nowhere.** → the ingest
  log states how many photos have no capture date and are filed by file date,
  which is the case most likely to land in the wrong day folder.
- **C3 · Companion matching was by prefix, and a sidecar could join two bundles.**
  `IMG_1234.v2.xmp` classified as a short-form sidecar of `IMG_1234.CR2` and
  renamed onto the real sidecar's path; and with DNG Converter output
  (`CR2`+`DNG`+`xmp`) the xmp joined both bundles, so one collided with the other
  and the same file was copied, hashed and manifested twice. → exact-stem
  matching, `buildBundle` honours `consumed`, siblings sorted so the winner is
  deterministic.
- **C4 · `heal --script` had no library containment**, and a failed script write
  returned 2 (could-not-verify) over a damaged library instead of 1 (issues
  found), blurring the distinction `ScheduledVerification` branches on. → both
  fixed.
- **C5 · `HashCache` was unbounded and loaded on the main actor** at every window
  open (an actor's `init` runs synchronously on the caller). → lazy load inside
  the actor; pruning on save, dead entries first.
- **C6 · A second Ctrl-C did nothing**, and SIGINT stayed ignored while the
  post-ingest hook ran, so a blocking hook was un-interruptible. → second signal
  exits 130; dispositions restored before the hook.
- **C7 · `presets.json` launders unsigned paths into trusted settings.** LOW and
  unchanged in substance — writing that file already needs user-level access — but
  a preset-supplied destination is now printed, so a headless run can't send
  photos somewhere invisible.
- **C8 · Exit `64`** (ArgumentParser's usage error) is documented alongside 0/1/2.
- **C9 · Planning was O(n²)** when the filename template had no per-file token
  (measured: 800 bundles → 1.95 s), because the disambiguator search restarted at
  zero for every bundle. → `planBatch` carries a per-base-name hint; `plan` still
  verifies every candidate, so a wrong hint costs iterations, never a collision.
  Settings now also says a template with no `{OriginalStem}`/`{OriginalName}`
  will number files `_1, _2, _3…`.
- **C10 · `EmbeddedCLI` and `IngestPlanner` had zero test references.** →
  `EmbeddedCLI.resolve(in:)` is injectable and now checks `isExecutableFile` on
  *both* branches (the primary one returned a constructed path unchecked, and it
  feeds the launchd plist — a wrong path is a nightly verify that silently never
  runs). `IngestPlannerTests` covers the scan state machine, including
  `scanWasComplete`, which gates the auto-eject.

### Uncovered while fixing C4 — a real hole in the Tier A guard

`DestinationTopology.contains` resolved symlinks with `resolvingSymlinksInPath()`,
which **consults the filesystem** and therefore returns a different shape for a
path that exists than for one that does not (`/private/tmp/x` → `/tmp/x` only when
it exists). Comparing the two shapes finds no common prefix. Measured:
`heal --script <lib>/evil.sh` wrote into the library — and, more seriously, a
nested archive root **that had not been created yet** was not detected as nested,
which is precisely the configuration `ArchiveDestinations.identity` documents as
routine (an unplugged drive, a folder the job will create). So the A2 refusal had
a hole from the day it landed. → resolve on the deepest *existing* ancestor and
re-append the missing components; regression tests for both the not-yet-created
and neither-exists cases.

This is the same trap `CLAUDE.md` invariant 3 already states for
`ManifestWriter.resolve` ("`standardizedFileURL` consults the filesystem and
returns a different shape for paths that exist"). It was written down, and the new
code walked into it anyway — worth noting for the next pass: **the invariant list
is a checklist to run *against new code*, not just a description of old code.**

272 tests, 0 failures (was 243).

## Checked and correct — do not re-spend the budget

The XXH64 algorithm and all 11 vectors (verified against `xxh64sum`) ·
NFC/NFD handling in `taken` and `hasPrefix` (correct via Swift's
canonical-equivalence semantics) · `truncatedToByteLimit` never splits a scalar ·
`PreflightCheck` sums per *volume* across mirrors, deterministically ·
`PhotoDrop Manifests/` is walked by the dedup index but can never yield a false
duplicate · `runXattr`'s `isRegularFile` guard has the same lstat semantics as
`AssetDiscovery`, and `.skipsPackageDescendants` is set ·
`HashCache` fails closed on a corrupt store and writes atomically ·
`DestinationIndex` staleness cannot produce a false duplicate (`findDuplicate`
re-hashes the candidate's real bytes) · `--folder-template ../../../etc` collapses
to a single `etc` component · the SIGINT mechanism itself (`SIG_IGN` +
`DispatchSourceSignal` + locked flag) is the correct async-signal-safe shape ·
`DestinationIndex.fullWalk` has no error handler **deliberately** — a missed
directory costs a re-copy, never a false duplicate.
