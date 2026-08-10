# PhotoDropMac — handover to a fresh Ultracode session

Repo: `/Users/tim/claude/PhotoDropMac`. Branch `fix/tier-1-data-safety` at `5d79c22`, working
tree clean, nothing pushed. Read `CLAUDE.md` — it is dense and load-bearing, and accurate except
where §7 says otherwise.

---

## 1. What this is

SwiftUI + Swift 6, macOS 14+, **unsandboxed by design**, plus a headless CLI (`photodrop`)
embedded in the app bundle. It ingests photos off removable cards into a date-organized
library: streaming tee-hash verification, content-based dedup, N-way mirroring, per-file
checksum xattrs, a verification manifest per job, and a report-only `heal`.

~7.6k lines across `Sources/` (24 Core + 22 UI + 1 CLI file), ~10.6k with the 22 test files.

The product **is** the trustworthiness of the verdict line. Every feature exists so someone can
say "these bytes are the bytes that came off the card" and be right. That framing decides ties.

## 2. What you're walking into

A full critical review (`REVIEW.md`) found the codebase splits in two:

- **The original data-safety core** — `FileCopier`, `ManifestWriter.resolve`,
  `DestinationIndex`, `HashCache`, `VerifyEngine.build`, `JobStamp` — states its reasoning at
  the definition site: what breaks without this rule, and the measurement that proved it. **In
  Core, treat the comments as the specification**; read the definition site before changing
  behavior. That does not mean Core is correct — the highest-severity open bug (S-1) is in
  `Core/Hasher.swift`. It means a change there needs an argument, not permission.
- **Everything layered on top** — multi-destination mirrors, `HealEngine`, the cancel path, the
  launchd agent, the post-ingest hook — had a working happy path and an unexercised failure
  path.

Tier 1 (5 data-safety defects) and Tier 2 (8) are fixed and committed (`34a5156`, `cecd69b`).
Suite: **173 tests, 0 failures, ~1.2 s**. Three independent surveys then re-verified the repo
against source rather than against `REVIEW.md`'s markers; §5–§7 are their output.

**The characteristic failure mode here is not a missing mechanism. It is a correct mechanism
applied at some sinks and not others, or calibrated to yesterday's threat.** Worked examples,
all still live:

- `CLIOutput.safe` escapes control characters for the terminal; `JobLogger` writes card
  filenames raw into the log users actually read afterwards.
- `HealEngine.hasControlCharacters` guards the restore script but stops at `0x7F`, so U+202E
  gets a live `cp` line instead of a commented-out one.
- `ManifestWriter.resolve` guards heal's *write* side while its *read* side hashes whatever
  absolute path the manifest names.

When you find a guard, immediately ask: **what are all the sinks this class of input reaches,
and does every one of them have it?**

Second trait: **knowledge does not travel between files here.** `CLAUDE.md` has 13 broken
source links, misattributes a 556-line engine to a 170-line controller, and says `@AppStorage`
keys live in three files when eleven declare them. Doc drift in this repo is not cosmetic — it
is what sends the next agent to the wrong file.

---

## 3. Standing instructions

> **You have complete discretion on decisions.** Priority, approach, scope, sequencing, what to
> build, what to skip — yours. Do not come back for permission on ordinary engineering calls.
> Do not present a menu and wait. Decide, do it, tell me what you decided and why. If you
> disagree with something in this handoff, reject it and say why in one sentence — that is a
> better outcome than compliance.
>
> **You have complete discretion on creativity.** If you see something better to build that is
> on no list — a fuzz harness, a new invariant test, a refactor that makes a class of bug
> unrepresentable — build that instead.
>
> **Maintain a strong security perspective throughout.** Not a final review pass; the lens you
> hold while writing every line. This app is unsandboxed, reads adversary-authored
> filesystems, spawns subprocesses, and emits a shell script for humans to run. Ask of every
> change: what untrusted input reaches this, and what does it do with it? Security work
> outranks feature work when they conflict.
>
> **Ask me first only for:** destructive or irreversible acts (deleting user data, discarding
> uncommitted work); anything leaving the machine (push, PR, publish, notarize, release, mail);
> history rewrite or force-push; changes to my permission settings or CI credentials.
>
> Local commits on a topic branch off `fix/tier-1-data-safety`, branches, worktrees, scratch
> files: go ahead. Commit convention in this repo is Conventional Commits —
> `fix(ingest,cli): …`, `docs(review): …` — with a body that explains the failure, not the diff.

---

## 4. Working method that produced the results here

1. **Reproduce before you fix.** Every high-value finding below came from a probe, not from
   reading. If you cannot reproduce it you do not yet understand it — and you may be about to
   "fix" something that isn't broken (see T3-6, a suspected defect that reproduction
   *disproved*). **Build hostile fixtures in the scratchpad and point probes at synthetic
   paths**: a fake mirror root you created, a `/dev/zero` symlink inside your own fixture tree,
   a dummy 600-mode file. Never aim a probe at your real `~/.ssh`, and don't re-run the
   memory-exhaustion measurement — the numbers in §5 exist so you don't have to.
2. **Convert the probe into a regression test** whose doc comment states (a) the threat model
   in one sentence and (b) the **measured before-state**. In-repo exemplars:
   `HashCacheValidatorTests`, `ManifestTrustTests`, `JobStampTests`. A test that says only
   `// checks heal` is half a test.
3. **Verify end-to-end, not just at the unit.** The cautionary tale is S-4 below: a Tier-2 fix
   that was entirely inert in production while its unit tests passed green, because they
   asserted the message strings appeared *in the command* and never that they reached
   `osascript`. Where a unit test can pass over a dead feature, add an execution-level check —
   `ScheduledVerificationTests.notificationText(forExitCode:)` is the pattern: run the real
   shell with the side-effecting binary stubbed, and assert on what it actually emitted.
4. **Never claim a fix without running it.** Run the suite, run the CLI, paste real output.
5. **Report honestly, including what you left undone and why.** Under-claiming is free.
6. **When you change load-bearing behavior, write the reason at the definition site** in the
   voice Core already uses — what breaks without this, and the measurement. That is the only
   mechanism by which this repo's knowledge survives.

---

## 5. Findings dossier — security

**This is verified evidence so you don't have to rediscover it. It is not a work order.**
Ignoring or reordering an item is a legitimate decision; say so in one sentence. Every finding
below was reproduced against the built binaries.

**S-1 · `XxHash64.hash(fileAt:)` has no regular-file check and no autorelease drain** — **FIXED (`3a6080a`).**
`Core/Hasher.swift:213-234`. HIGH. Both a security bug and a plain reliability bug:
- Adversarial: a planted manifest with `"destinations": ["<lib>", "/dev"]` and an entry `zero`
  makes `heal` hash `/dev/zero`. Containment *passes* — `/dev` is the recorded root. Measured:
  still running at 12 s, 1,896 MB RSS, needed SIGKILL.
- Benign, no attacker: verifying a 3 GiB file peaked at 1,876 MiB RSS; ingesting one 2 GiB file
  peaked at 664 MiB. A library of large video/RAW can hit memory pressure during a normal verify.
- Fix is at the primitive — `stat` and refuse non-regular files, wrap the read loop in
  `autoreleasepool` — so all five call sites inherit it: `HealEngine.swift:147`,
  `VerifyEngine.swift:204` (the `--xattr` walk) and `:233`, `FileCopier.swift:164` (post-copy
  verify), `HashCache.swift:164`. Regression-test at least the verify and xattr paths; testing
  only heal leaves the paths the benign memory numbers actually came from.

**S-2 · `heal` is a hash-equality oracle over arbitrary readable files.** MEDIUM. **FIXED (`56c93fd`).** Both halves: non-regular files are refused at the primitive, and a recorded mirror root is searched only if it carries a `PhotoDrop Manifests/` folder or the user named it (`heal --mirror`). Refused roots are reported.
`VerifyEngine.swift:116-118` takes mirror roots verbatim from the manifest;
`HealEngine.swift:74-76` stats and hashes the resolved path. Anyone who can drop one JSON into
`<lib>/PhotoDrop Manifests/` (shared NAS, synced folder, a library handed over on a drive) can
name any directory as a mirror and get content confirmed by guess. Reproduced with a synthetic
attacker root and a 600-mode dummy file: heal hashed it, reported it as the restore source, and
`--script` emitted a `cp` from it. Both existing mitigations fire after the fact — the hash
check only makes the answer *correct*, and the source-root header only helps if a human reads
it. Worth considering: refuse non-regular files (also fixes S-1), and gate mirror roots that
aren't under a destination the *user* configured.

**S-3 · The ingest log contains card filenames verbatim.** MEDIUM. **FIXED (`3b43537`).** `JobLogger.swift:66` builds
`lineText` raw and `:70` writes it; text assembled at `IngestEngine.swift:478`. Confirmed
against a real log: `IMG\x1B[2K\x1B[1A0002.CR2` erases the preceding VERIFY line when the user
`cat`s the log, and a raw newline forges an entire fabricated log record. Same threat
`CLIOutput.safe` and `HealEngine.comment` exist for; this is the sink that was missed, and it
is the one users read after the fact.

**S-4 · The nightly notification never rendered — ALREADY FIXED (`5d79c22`). Nothing to do.**
`$MSG` sat inside a single-quoted `osascript -e` argument, so the shell never expanded it and
both banners would have read a literal `$MSG` — the exit-1/exit-2 distinction the Tier-2 fix
added never reached the user. Now each branch emits its own complete `osascript` call with the
message inline, plus `issuesMessage` / `cannotVerifyMessage` constants and three
execution-level tests. **Read that commit before writing anything else** — it is the clearest
example of the failure mode this codebase produces and of the test standard that catches it.

**S-5 · Terminal/script filters cover C0+DEL only, not Unicode bidi.** MEDIUM. **FIXED (`3b43537`).** One definition in `Core/SafeText.swift`, used by all three sinks. `PathPlanner.sanitize` is deliberately unchanged: storage must record the name the file actually has.
`PhotoDropCLI.swift:313` and `HealEngine.swift:158` both test `< 0x20 || == 0x7F`;
`PathPlanner.sanitize` (`PathPlanner.swift:104`) trims ends only, so U+202E survives into the
destination filename, manifest, CSV and reports. Confirmed: a bidi filename produced a **live**
`mkdir -p … && cp -p …` line in the restore script rather than a commented one. The quoting is
correct so the command is inert — but the script's entire safety model is "a human reviews
every executable line," and this defeats the review rather than the shell.

**S-6 · ImageIO decodes card bytes in-process, unsandboxed.** MEDIUM — threat model, not a bug **RECORDED, not fixed (`f1243f1`)** — see the sandbox section of `CLAUDE.md`.
list item. `ExifReader.dateTaken` runs for every primary on every scan; `ThumbnailLoader`
decodes previews. A crafted RAW hitting a CoreGraphics decoder bug gets the user's full
filesystem access, can write `~/Library/LaunchAgents`, and can rewrite
`photodrop.postIngestScript`. Hardened runtime limits code injection but gives no filesystem
containment. This is the accepted price of the sandbox exemption; it needs an XPC decode helper
to fix. Record it; reconsider first if the sandbox decision is ever revisited.

**S-7 · `ChildProcess` has no timeout, no output cap, and inherits stdin.** LOW. **FIXED (`775cdd0`).**
`ChildProcess.swift:42-90`. A hook that blocks on stdin or a dead mount never returns (leaks a
detached task per ingest via `Copier.swift:160-166`); a hook streaming gigabytes is drained but
accumulated unbounded in memory. The Tier-2 fix removed the deadlock; it did not bound the
resource.

**S-8 · `verify` names a path it never checked.** LOW. **FIXED (`09c7454`).** `VerifyEngine.swift:73-75` builds issues
from `item.relPath` (the manifest's recorded string) rather than `item.url` (what was actually
resolved and checked). A manifest entry `"path": "/etc/hosts"` is correctly re-rooted under the
library, then reported as `MISSING /etc/hosts` — reproduced exactly. For a tool whose product is
a trustworthy verdict line, printing a system path it did not inspect is a reporting-integrity
flaw. Printing the resolved URL through `safe` costs nothing.

**S-9 · None of the CLI's security-relevant code is tested.** LOW but structural. **FIXED (`3b43537`, `e50423b`).** `CLIOutput.safe`'s rule moved into `Core/SafeText.swift` (tested directly), and `CLIBlackBoxTests` drives the embedded binary for the exit codes, the JSON shape and the terminal guard.
`CLIOutput.safe` — the guard keeping card text from driving the terminal — has zero tests, as
does every exit-code path the launchd agent branches on. `project.yml:71-81` gives the test
target only `Tests/PhotoDropMacTests` + a dependency on the app; `:85-95` gives `photodrop` sole
ownership of `Sources/PhotoDropCLI`. Either make the CLI sources a library both consume, or move
`CLIOutput` into `Core/`. Cheaper interim: drive the embedded binary with `Process` from the
existing hosted target (`Contents/MacOS/photodrop`) and assert exit codes and JSON shape.

---

## 6. Findings dossier — process and tests

**T3-1 · No CI at all.** **FIXED (`07a5810`).** `.github/workflows/ci.yml` — xcodegen, the suite, the `photodrop` scheme, the log-directory assertion, and the doc-link check. A second assertion (`9a7a62f`) fails the build if a test run leaves a launch agent behind. No `.github/`, no workflow, no pre-commit, no lint/format config,
despite a live GitHub remote. 173 tests that nothing runs automatically. A workflow needs:
`brew install xcodegen`, `xcodegen generate`, then both schemes. Tests are **hosted** — the host
app must launch, so the runner needs a GUI session (GitHub's macOS runners provide one). A doc
link-check would catch §7's whole first category mechanically.

**T3-2 · `release.sh` notarizes and ships without running tests.** **FIXED (`07a5810`).** Dirty-tree refusal, the suite + CLI build before archiving (`SKIP_TESTS=1` overrides loudly), `MARKETING_VERSION` write-back, annotated `v<version>` tag. No test gate, no `git tag`,
no clean-tree check, no version write-back: `:36` takes a version and `:80` passes it as a build
setting only, so `./release.sh 0.2.0` ships 0.2.0 while `project.yml:58` still says `0.1.3` and
git records nothing. `BUILD="$(git rev-list --count HEAD)"` (`:38`) stamps a count a dirty tree
doesn't correspond to. Three lines close the worst-consequence hole: a notarized DMG built from
untested code.

**T3-3 · Two `XCTSkip` sites turn a timeout into a green skip** **FIXED (`07a5810`).** Both now fail. The remaining `XCTSkip`s are the deliberate `getuid() == 0` and no-capacity guards. —
`CopierManifestTests.swift:67` and `VerifierTests.swift:64` (REVIEW.md cites `:66`/`:63`; those
are the guards, not the throws). Both sit behind a hard 5 s poll budget, and
`CopierManifestTests` carries the §1.2 rollback regression at `:148`. `xcodebuild` prints
`** TEST SUCCEEDED **` over a skip. Leave the other two alone: `XattrTests.swift:56` follows an
already-recorded `XCTFail`, and `:128`'s `XCTSkipIf(getuid() == 0, …)` is a deliberate guard.

**T3-4 · The suite writes into the developer's real home.** **FIXED (`07a5810`).** `Copier.hermetic(in:)` injects the cache, index store, log directory, an isolated `UserDefaults` suite, and disables notifications; CI asserts the log folder stays empty. `Notifier.notifyHookFailure` keeps its missing frontmost check **on purpose** — there is no in-app surface for a hook failure, and that is now stated at the definition. Measured:
`~/Library/Logs/PhotoDrop` went 329 → 347 files (**+18**) in one run, never cleaned.
`JobLogger.swift:28-31` derives the directory from `.libraryDirectory` with no injection point,
while `IngestEngine.init` already injects `cache:` and `indexStoreURL:` — follow that pattern.
Also `Copier.swift:132/:135` reach `UNUserNotificationCenter.requestAuthorization`, and
`Copier.swift:157` reads the developer's real `UserDefaults` for a post-ingest script it would
then *execute* (latent only because no key is set today). `notifyHookFailure`
(`Notifier.swift:36-39`) has `guard enabled` but lacks the frontmost check the other two have.
**Do not delete the accumulated files in `~/Library/Logs/PhotoDrop`** — that is the user's audit
trail and it is on the ask-first list. Fix the injection, not the symptom.

**T3-5 · Untested data-safety code, in risk order.** **FIXED (`07a5810`, `9a7a62f`).** `DestinationIndexBuildTests` covers `build`/`buildIncremental` including the stale-entry false-duplicate; `JobLoggerTests`, `PreflightCheckTests` and `ChildProcessTests` exist; `ScheduledVerificationInstallTests` closes install/uninstall/`isLoaded` behind an injected agent. `DestinationIndex.build` /
`buildIncremental` (`DestinationIndex.swift:99`, `:145`) — tests hand-construct
`DestinationIndex(bySize:)` and only exercise `findDuplicate`; **a stale incremental index
yields a false duplicate, and a false duplicate silently skips a photo.** That is the riskiest
untested path in Core. Then `JobLogger` (free once T3-4 lands), `PreflightCheck`,
`ChildProcess` (only indirect coverage), and `ScheduledVerification` install/uninstall/isLoaded.

**T3-6 · STRUCK — not a defect. Do not "fix" it.** **RESIDUAL FIXED (`07a5810`).** `release.sh` stages a `ditto` copy for `create-dmg`, so nothing deletes inside the stapled bundle. REVIEW.md's suspicion about the `create-dmg`
branch was disproved by reproduction: create-dmg 1.2.3 is installed and the exact
`release.sh:115-120` invocation produces a DMG whose root holds the intact `.app` plus the
`Applications` symlink — `hdiutil` special-cases a bundle at `-srcfolder`. One real residual:
`create-dmg:361-363` does `rm "$SRC_FOLDER/.DS_Store"`, and at `release.sh:120` `$SRC_FOLDER` is
the already-stapled app; deleting inside the bundle would invalidate the signature after the
ticket was attached. Stage a copy first — one line.

---

## 7. Findings dossier — UI and docs

**T4-1 · The halt path dead-ends, and the payload already exists.** `Copier.swift:130-132`
collapses a halted `CopyResult` to a bare string, discarding `logURL` and `manifestURL` — but
the engine *did* write a `partial: true` manifest and a log and *did* return their URLs
(`IngestEngine.swift:318-335`). `MainView.swift:396-405` offers one sentence and a Reset button;
Open Log / Export Manifest live only in `CompletionSheet`, shown solely for `.completed`.
Meanwhile `Notifier.swift:29` tells the user to "see the app for details" — there are none. Same
story on cancel: `CopierState.cancelled(CopyResult?)` carries the receipt and nothing in `UI/`
binds it. A `JobArtifactButtons(result:)` shared by all three terminal states closes it.

**T4-2 · No `applicationShouldTerminate` anywhere, and this one loses integrity coverage.**
`PhotoDropMacApp.swift:123-125` wires Quit straight to `NSApp.terminate(nil)`. `FileCopier`'s
partial cleanup is a Swift `catch` that process death skips, and the orphan is then invisible
forever: not in the manifest (written after the loop), not xattr-stamped, and on re-ingest its
size differs so dedup misses and `CopyPlan` disambiguates the *real* file to `…_1`. Neither
`verify` nor `verify --xattr` can ever see it. Window-close half: no `deinit`, no
`.onDisappear`, so the detached engine runs on while `[weak self]` fails (skipping notifier and
hook), and a reopened window mints a fresh `Copier()` at `.idle` reporting no ingest while one
runs.

**ProgressPane shows "VERIFIED" when verification is off.** `ProgressPane.swift:74-92` drives
the mark from `progress.percent` (bytes copied) and hard-codes the caption at `:88`; the verify
flag is never passed. This is exactly the dishonesty T1-5 just fixed in the completion text,
left standing in the more prominent surface. Three lines.

**One-click ingest can auto-start an ingest nobody requested.** `tryAutoIngest`
(`MainView.swift:257-267`) returns without clearing `autoIngestPending` or
`coordinator.pendingOneClickCardID` on any guard failure, and its only retry trigger is
`.onChange(of: planner.isScanning)`. One-click a card with no recognized photos → flag stays
armed → insert a different card later → it ingests with no user action. Secondary: the
uncleared coordinator field means re-clicking for the same card sets an identical value, so
`onChange` doesn't fire and the second click silently does nothing.

**T4-3 · Culling is invisible outside the grid.** `MainView.swift:304` and
`PreviewTree.swift:27-31` report all discovered bundles while `MainView.swift:197` ingests
`selectedYearGroups()` (`:233-246`). Deselect 400 of 500, switch to tree, read "500 files"
beside a button that will copy 100. `selectedBundleCount` is already computed at `:188-193`.

**T4-4 · "Auto-open window" is inert in `.withCard` mode.** `PhotoDropMacApp.swift:61-71` puts
the `onChange` on the MenuBarExtra *label*, which in `.withCard` is created by the very
drives-empty→non-empty transition it needs to observe; without `initial: true` it never fires,
so the first card of a session never auto-opens. It's also inert in `.hidden`, and
`SettingsView.swift:316` shows the toggle plainly enabled in all three modes.

**T4-5 · Silent `try?` cluster:** failed preset save (`IngestPreset.swift:127-130` — appears to
succeed, gone next launch), denied notification authorization (`Notifier.swift:47`, `:55` —
toggle reads checked forever, and authorization is first requested at the worst possible moment,
deliberately while the app is *not* frontmost), failed sidebar eject (`MainView.swift:359`,
reports neither outcome — contrast `IngestEngine.swift:300-307`, which logs it).

**T4-6 · Accessibility:** five image-only controls carry `.help()` but no `accessibilityLabel`
(different AX attributes) — `MainView.swift:357-365`, `InspectorPane.swift:186-192` and
`:255-262`, `SettingsView.swift:211` and `:353` — plus the preview-mode Picker's two bare
`Image` tags. No `.commands` block, so no menu items for Refresh / Verify Library / Toggle
Inspector / Cancel. (Correction to REVIEW.md: keyboard shortcuts *do* exist — seven.) No
localization and no `@SceneStorage`; both are defensible scope choices for a one-developer tool,
but say so somewhere rather than leaving it implicit.

**T4-7 (low):** `IngestPlanner.replan` is synchronous on the main actor per keystroke
(`:54-57`, `:64-66`), O(bundles) per character. `ThumbnailLoader` uses `Task.detached` (`:61-68`)
which doesn't inherit cancellation, so scrolled-away decodes run to completion; the claimed
concurrency bound is prose only (`:42-43` — no semaphore exists); a nil decode (`:79`) is never
cached, so `ContactSheet.swift:164-172` spins a `ProgressView` forever and retries on every
reappearance.

**Docs — mechanical but load-bearing:**
- `CLAUDE.md` has **13 broken links across 11 unique paths**, all flat
  `Sources/PhotoDropMac/X.swift` predating the `Core/`/`UI/` split: lines 47, 65, 75, 79, 129,
  144 (×3), 152, 153, 161 (×2), 169.
- `CLAUDE.md:82-94` titles the copy-engine section "`Copier`" and attributes `DestinationIndex`,
  rollback and manifest writing to it. All of that is `Core/IngestEngine.swift` (556 lines);
  `Copier` is 170 lines of state plumbing. The Tier-1/2 notes were written *into* that section,
  deepening the misattribution, and `IngestEngine.swift` is never linked in the document.
- `CLAUDE.md:45` names 14 test suites; there are 22 files / 23 `XCTestCase` classes
  (`XattrTests.swift` declares two). Most of the undocumented ones are long-standing — only
  `IngestEngineFailureTests.swift` came from the Tier-1/2 work.
- `CLAUDE.md:144` says `@AppStorage` keys live in three files and warns to update "**every**
  declaration site." Eleven files declare them; `photodrop.verificationStyle` alone has nine
  sites across eight files. The doc undercuts the invariant it is stating.
- `README.md:202-222`'s layout tree is wholesale stale (no `Core/`/`UI/`, no CLI/Tests/scripts,
  12 files missing). `:245` asserts the dead Debug self-check runs — nothing calls
  `xxHash64SelfCheck()`. The settings table (`:140-152`) omits six shipped keys. The CLI's
  `verify`/`ingest`/`heal` verbs appear nowhere — `heal` is a data-recovery feature with zero
  user documentation. Highlights still sell "dual-destination" when the app writes N mirrors.
- Two stale test headers teach the trust rule **backwards**: `VerifyEngineTests.swift:4-6` and
  `VerifierTests.swift:5-8` both advertise "newest-manifest-wins," the exact rule those suites
  exist to prove was replaced by conflict reporting.
- `REVIEW.md:319` still says "132 passing tests" (it's 173) and `:62` says "21 test files"
  (it's 22). `REVIEW.md:3-4` are correctly labelled as the *then* baseline — leave them.

**On `REVIEW.md` generally:** this handoff supersedes it wherever they disagree. Its Tier 1 and
Tier 2 outcome notes are accurate; its Tier 3/4 line numbers were never re-verified and several
are stale. Repo convention (see `git log`) is to record outcomes back into it.

---

## 8. Hard constraints — the security invariants

**What is untrusted:** everything on the card (filenames, directory structure, file bytes,
symlinks); every manifest JSON, *including ones inside your own library*; and any path a
manifest names in `destinations[]`. **Trusted:** settings the user typed. **Sinks that untrusted
text reaches:** destination paths, manifest JSON, the CSV, the on-disk log, terminal output, the
restore script, and `osascript`/`launchd` command strings.

The invariants below are instances of guarding that boundary — **derive new ones the same way**.
Each states the measured failure it prevents, because an agent that doesn't know why will
simplify it away. If you are about to remove one, read the definition site first. (Symbol names,
not line numbers — lines rot on your first edit.)

1. **`AssetDiscovery`'s `isRegularFile` guard is a security boundary, not a directory filter.**
   lstat semantics; it is the only thing stopping a card symlink from pulling `/etc` or
   `~/.ssh` into the library. Never an `isDirectory` check.
2. **`O_CREAT | O_EXCL` at the syscall, never a `fileExists` pre-check** — both for destination
   files (`FileCopier`) and for every per-job artifact (`JobStamp.claimUniqueName`).
   `ManifestWriter` writes `.atomic`, which *replaces*; a pre-check is a TOCTOU whose loser's
   manifest silently vanishes, after which `verify` reports success over whatever remains.
   Measured: ten concurrent ingests, ten files, **two** manifests.
3. **Every manifest-derived path passes `ManifestWriter.resolve`, and that check stays
   lexical.** Without it, `../../..` turns `verify` into a content oracle and makes
   `heal --script` emit a `cp` over arbitrary files. `standardizedFileURL` consults the
   filesystem and returns a different shape for paths that exist — it would silently drop every
   *missing* file, which is exactly what `heal` exists to find, and adds a TOCTOU on the check.
4. **Manifests that disagree are reported, never reconciled — and `HealEngine` derives
   expectations from `VerifyEngine.build`, keeping no merge of its own.** `createdAt`, the
   filename stamp and mtime are all chosen by whoever wrote the file. The private newest-wins
   merge that used to live in heal let one JSON dated 2099 make a corrupted library report
   healthy while `verify` correctly reported the conflict.
5. **`heal` stays report-only, and `restoreScript` keeps all three properties:** POSIX
   single-quote escaping of every path, refusal to emit an executable line for a
   control-character path, and the header listing every source root. Quoting alone is
   insufficient — a multi-line path renders across several lines, so an embedded `rm -rf $HOME`
   reads like a command and destroys the human review the script's safety rests on. (S-5 says
   extend this to bidi; do not weaken it.)
6. **All subprocess execution goes through `ChildProcess.run` with an argv array** — never a
   hand-rolled `Process` with an undrained `Pipe` (a pipe holds ~64 KiB; a hook running
   `rsync -v` deadlocked measurably at ~1 MiB), never a shell string. **The launchd plist is the
   only `/bin/sh -c` in the codebase and both interpolated paths stay wrapped in
   `ScheduledVerification.quote`.** Audited this pass, no injection path found — keep it that
   way. And keep each notification branch's message *inline*: single quotes do not expand.
7. **`ScheduledVerification.install` removes the plist when `bootstrap` fails, and `isLoaded()`
   asks launchd rather than stat-ing the plist.** An orphan plist left the toggle reading *off*
   while launchd could still load the job at next login.
8. **`HashCacheEntry.matches` stays exact on full-precision mtime *and* birth time, failing
   closed on legacy entries.** The source key is `volumeUUID|path`, every component
   card-authored, and cheap cards ship duplicate volume serials. A false cache *hit* silently
   skips a real photo as a duplicate, and skipped entries carry no digest for verify to catch.
9. **`DestinationIndex.findDuplicate` keeps the zero-byte exemption, and collision-safe naming
   keeps scanning target folders fresh rather than trusting the cached index.** That separation
   is the only reason a stale dedup entry can never cause an overwrite.
10. **`PathPlanner.sanitize` strips *all* leading dots** so a component can never become `.`,
    `..`, or hidden — **and filenames are composed through `PathPlanner.fileName`** so
    stem+`.`+ext fits `NAME_MAX` together; a 255-byte stem plus `.CR2` earns `ENAMETOOLONG` and
    rolls back a whole bundle over a name.
11. **Untrusted text is neutralized at every sink it reaches:** `CLIOutput.safe` for the
    terminal (the CLI writes its own `\r\u{1B}[K`, so escapes *are* honored),
    `ManifestWriter.csvField` for spreadsheet formula leaders, and `ManifestWriter.decode`
    validating `schema` so an unrecognized version is ignored rather than reinterpreted. S-3 and
    S-5 are two sinks that were missed — expect more.
12. **Multi-destination rules, all four:** the plan is computed once and rebased onto every
    mirror (per-root planning made `heal` miss a perfect copy under a different name); roots are
    deduped by filesystem identity (one folder twice makes pass 2 collide with pass 1 and a
    *successful* ingest report every bundle failed); each destination gets its own `do/catch`
    inside the bundle loop (never re-wrap it — a failed mirror must not void the primary);
    dedup-skipped entries record the digest the match was made on, and cancelling still writes
    the manifest and log marked `partial: true` (both, because a manifest that omits files on
    disk lets `verify` report success over zero files).

---

## 9. Commands

```bash
cd /Users/tim/claude/PhotoDropMac

# The .xcodeproj is GITIGNORED and GENERATED. Regenerate after any project.yml
# change and after adding/removing/renaming any source file.
xcodegen generate

# App + full suite. Invariant: zero failures, and a count that only rises.
# (173 at handoff — update that number wherever it is asserted, don't restore it.)
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' test

# One suite while iterating
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' test \
           -only-testing:PhotoDropMacTests/HealEngineTests

# The CLI. Use the SCHEME — a -target build mishandles the SPM module
# (swift-argument-parser) under Swift 6 explicit modules.
xcodebuild -project PhotoDropMac.xcodeproj -scheme photodrop \
           -configuration Debug -destination 'platform=macOS' build

# Built CLI: DerivedData/.../Build/Products/Debug/photodrop
#   photodrop verify <library|manifest.json> [--json] [--xattr]
#   photodrop ingest --from <card> --to <primary> [--archive …] [--post-ingest-hook <path>]
#   photodrop heal   <library> [--json] [--script <path>]
# Exit codes: 0 = all verified, 1 = issues found, 2 = no manifest / unreadable / error.
```

Tests are **hosted** — the host app must launch, so a GUI session is required. `xcodegen` is
Homebrew (2.45.4 local); prefer `brew` over `npm` for any tool you add.

---

## 10. Using the budget well on *this* repo

**Fan out on** (genuinely independent, no shared state):
- **Adversarial probe construction** — one agent per input class: hostile filenames (C0 / bidi /
  newline / `NAME_MAX` / Unicode-normalization collisions), planted manifests (traversal,
  schema, conflict, hostile `destinations[]`), hostile card topologies (symlinks, fifos,
  packages, zero-byte, huge files). Each builds a fixture tree in the scratchpad and drives the
  real built binary. This technique produced every high-value finding above.
- **Sink-completeness sweeps.** Pick one guard (`CLIOutput.safe`, `sanitize`, `resolve`,
  `hasControlCharacters`, `csvField`) and enumerate *every* sink its input class reaches, then
  report which have it. Directly targets the codebase's characteristic failure mode.
- **Disjoint test-coverage gaps:** `DestinationIndex.build`/`buildIncremental`, `JobLogger`,
  `PreflightCheck`, `ChildProcess`, CLI black-box exit codes. Five new files, zero conflicts.
- **Doc regeneration:** CLAUDE.md links + the `IngestEngine`/`Copier` retitle + test inventory;
  README tree + settings table + CLI verbs. Two agents, different files.

**Do not fan out on:**
- Anything touching `Copier.swift` / `MainView.swift` / `IngestEngine.swift` at once — T4-1,
  T4-2, the VERIFIED badge, T4-3 and the one-click latch all land in the same two files.
  Sequence those in one agent.
- `project.yml` — one writer; `xcodegen generate` rewrites the whole project.
- The suite run itself. It's ~1.2 s; run it serially and often. Parallel `xcodebuild test`
  invocations fight over DerivedData and over `~/Library/Logs/PhotoDrop` (T3-4).

**Rule of thumb:** spend the budget on *reproduction and verification*, not exploration. The
repo is small and well-commented; understanding is cheap. What pays is building the hostile
fixture that proves a bug exists, then proving it's gone.

---

## 11. What good looks like

Properties, not coverage:

- The suite is green and larger, and nothing you claimed as fixed went unrun.
- No security finding is closed without a regression test stating its threat model and measured
  before-state.
- No doc you touched still points at a moved file.
- Your report says plainly what you decided not to do, and why.
