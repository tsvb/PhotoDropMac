# Contributing

## Before you start

Read [CLAUDE.md](CLAUDE.md). It is written for coding agents but it is the real
architecture document, and it explains *why* the load-bearing rules are what they
are — the same-directory-only companion matching, content-based dedup across the
whole destination root, all-or-nothing bundles, the manifest trust boundary.

Those rules are deliberate. Several of them look like bugs until you read the
reasoning. Change them carefully and on purpose, not as a drive-by fix, and judge
a proposed change against what it does to **data safety here** rather than
against how another tool behaves.

## Build

The `.xcodeproj` is generated and gitignored:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' build
```

Regenerate after any change to `project.yml` or after adding, removing or
renaming a source file.

## Tests

```bash
xcodebuild -project PhotoDropMac.xcodeproj -scheme PhotoDropMac \
           -configuration Debug -destination 'platform=macOS' test
```

**The suite is hermetic and must stay that way.** It must not write to
`~/Library/Logs/PhotoDrop`, must not install a launch agent, and must not touch
`UserDefaults.standard`. CI fails the build if it does. `Copier.hermetic(in:)` is
the factory that injects the cache, index, log directory and defaults suite; if
you add a new side effect, add an injection point with it.

Timeouts must **fail**, never `XCTSkip` — `xcodebuild` prints `TEST SUCCEEDED`
over a skip, which is how a regression stops running silently.

## What a good change looks like

- A data-safety change comes with a test that fails without it.
- A comment explains the *reasoning*, not the mechanics. The convention here is
  to record the failure that motivated the rule, with measurements where they
  exist, so the next reader can tell a deliberate constraint from an accident.
- If you add or rename an `@AppStorage` key, `grep` for it — there is no central
  store and every reader re-declares it. Missing one silently desyncs the views.

## Scope

This is a one-developer tool with an opinionated design. Non-goals are recorded
in CLAUDE.md and are choices, not oversights. If you want to propose something
large, open an issue first rather than a surprise PR.
