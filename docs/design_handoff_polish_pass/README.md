# Handoff: PhotoDropMac · Steady polish pass

This package describes a design pass on the existing **`tsvb/PhotoDropMac`** SwiftUI
codebase. It is a *polish* pass, not a rewrite: every change names a specific
existing file and either adds a small view, adjusts strings, or extends an
existing model field. Two new SwiftUI views are introduced. Nothing here changes
your architecture (`@Observable` Copier, AppStorage settings, NavigationSplitView
+ `.inspector`, `.sheet` completion).

Two visual directions are bundled. Pick A unless you explicitly want B's tone:

- **A · Steady** — what the current app could look like with three additions:
  a custom **seal-grid verification mark**, an **xxHash signature** rendered
  on every verified log line, and better empty-state copy on the
  cancelled / failed states. Default.
- **B · Ledger** — same scaffolding, swaps the seal grid for a **stamp ring**
  and the completion headline to **Instrument Serif**. One ornamental moment.
  Optional. Ships behind a setting or just used for the completion sheet.

## About the design files

The `design-files/` folder in this bundle contains an **HTML + React prototype**
that visualizes every state of the app. Treat it as a **visual reference**, not
a port target — it is hand-built in JSX to look like SwiftUI, but the
implementation work is in the SwiftUI codebase itself.

The HTML uses `Geist` + `Geist Mono` as proxies for SF Pro / SF Mono. On the
real Mac app, use the system font; do **not** ship Geist.

## Fidelity

**High-fidelity.** Every typography size, color token, spacing value, and SF
Symbol name in `IMPLEMENTATION.md` is implementable verbatim. Strings in
`copy/voice.md` are the final copy unless flagged "(propose)".

## What's in this bundle

| File | What it is |
| --- | --- |
| `README.md` | This file. |
| `IMPLEMENTATION.md` | The meaty one — per-file diffs against your current Swift files. Read this top-to-bottom. |
| `swift/SealGrid.swift` | New SwiftUI view — the Steady verification mark. Drop in `Sources/PhotoDropMac/`. |
| `swift/StampMark.swift` | New SwiftUI view — the Ledger verification mark. Optional. |
| `swift/VerifiedSignature.swift` | Helper to format a `UInt64` xxHash as `[a3f7…7fa3]` in monospaced caption. |
| `swift/LogEntry+Patch.swift` | Suggested addition to `LogEntry` so the verified hash flows to the log row. |
| `copy/voice.md` | All new strings, organised by state. |
| `design-files/` | The HTML prototype. Open `index.html` for an interactive view of every state. |

## Suggested commit order

The brief is intentionally chunked into small commits — each one ships value on
its own. Land them in this order:

1. **xxHash signatures in the log.** Extend `LogEntry`, format the hash, render
   it in `LogView`. Tiny diff, biggest perceived "polish" lift. See
   `IMPLEMENTATION.md §1`.
2. **`SealGrid` verification mark.** Add the new view, swap the
   `checkmark.seal.fill` in `ProgressPane` and `CompletionSheet` for it. §2.
3. **Completion sheet copy + ordering.** Lead with "safe to remove". §3.
4. **`ContentUnavailableView` descriptions** on `.cancelled` and `.failed`. §4.
5. **Inspector spacing + grouping** tweaks (5 minutes). §5.
6. **Menu bar polish** — add subtitle when card present. §6.
7. **(Optional) Settings · Menu Bar tab** — new `@AppStorage` keys for
   one-click ingest from menu bar. §7. Land only if you've decided to ship that
   path.

Each section in `IMPLEMENTATION.md` carries a checklist and the exact code to
paste. The bundle does not change `Copier.swift`, `IngestPlanner.swift`, or any
of the asset/discovery files — work is confined to the view layer.

## Design tokens (quick reference)

```
Window:           1020 × 700              // matches current PhotoDropMacApp
Sidebar:          232pt                   // a touch wider than current
Inspector:        308pt
Sheet width:      480pt, radius 10
Accent:           Color.accentColor       // user-controlled, system blue default
                  (design used #120A8F — Apple Ultramarine — as the reference)
Verified tone:    .green
Skipped tone:     .secondary
Failed tone:      .red
Toolbar:          .windowToolbarStyle(.unified)
Caption mono:     .font(.system(.caption, design: .monospaced))
                   + .monospacedDigit()
```

## A note on the accent

The design was rendered using `#120A8F` (Apple Ultramarine) but the **actual
implementation should not hardcode this**. Read the user's `Color.accentColor`
and let System Settings drive it. The verification mark and primary button
both bind to `.tint(.accentColor)`.

## Open questions to confirm before shipping

1. **Hash display.** xxHash is computed today but discarded after the verify
   step. This brief surfaces it as a 12-character signature in the log
   (`[a3f7…7fa3]`). Confirm you want it visible — it is the strongest "show
   the work" signal in the app.
2. **Menu bar one-click ingest.** Currently no such command exists. Section 7
   proposes adding it as an opt-in setting. Confirm or skip.
3. **Direction B inclusion.** If Steady ships well, you may not want Ledger at
   all. Easy to drop — Ledger is two files (`StampMark.swift` and a wrapped
   `CompletionSheet` variant) and changes nothing else.
