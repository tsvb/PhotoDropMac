# IMPLEMENTATION.md

Per-file diffs and additions for the PhotoDropMac polish pass. Each section is
independently shippable. Section numbers match the suggested commit order in
`README.md`.

References to your existing code are to `tsvb/PhotoDropMac@main`. Line numbers
are approximate; search by surrounding context.

---

## §1 — xxHash signatures in the log

**Goal.** Surface the already-computed xxHash on every verified log entry as a
12-character signature in monospaced caption. This is the app's "show the
work" moment.

### 1.1 — Extend `LogEntry`

In `Sources/PhotoDropMac/Copier.swift` (where `LogEntry` is declared today),
add an optional `signature` field:

```swift
struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let message: String
    let signature: UInt64?     // NEW — xxHash of the verified file, if any

    enum Kind: Sendable {
        case info, copied, verified, skipped, error
    }
}
```

(`LogEntry+Patch.swift` in this bundle shows the patch as a standalone file
you can reference.)

### 1.2 — Populate it when verification succeeds

In `Copier.swift`, find the spot where a verified entry is logged today. Pass
the computed hash:

```swift
// after a successful verify():
log.append(.init(
    timestamp: .now,
    kind: .verified,
    message: "\(sourceName) → \(destName)",
    signature: verifiedHash      // the UInt64 you computed in xxhash()
))
```

For `.copied` / `.skipped` / `.info` / `.error`, pass `signature: nil`.

### 1.3 — Render the signature in `LogView`

Add `VerifiedSignature.swift` (in this bundle) to the project. Then in
`ProgressPane.swift`'s `LogView`, render the signature on verified rows:

```swift
HStack(spacing: 8) {
    Image(systemName: icon(for: entry.kind))
        .foregroundStyle(color(for: entry.kind))
        .frame(width: 14)

    Text(entry.timestamp, format: .dateTime.hour().minute().second())
        .foregroundStyle(.secondary)
        .monospacedDigit()

    Text(entry.message)
        .lineLimit(1)
        .truncationMode(.middle)

    Spacer(minLength: 8)

    if let sig = entry.signature {
        VerifiedSignature(hash: sig)   // ← from this bundle
    }
}
.font(.system(.caption, design: .monospaced))
```

Icon mapping for `kind`:

| Kind       | systemName                       | foregroundStyle |
| ---------- | -------------------------------- | --------------- |
| `.info`    | `info.circle`                    | `.secondary`    |
| `.copied`  | `arrow.right.doc`                | `.primary`      |
| `.verified`| `checkmark.seal.fill`            | `.green`        |
| `.skipped` | `arrow.uturn.left`               | `.secondary`    |
| `.error`   | `exclamationmark.triangle.fill`  | `.red`          |

### 1.4 — Acceptance

- [ ] Verified rows show `[a3f7…7fa3]` at the right edge in monospaced caption.
- [ ] Skipped / copied / info / error rows do **not** show a signature.
- [ ] The signature column is right-aligned and uses `.tabularNumbers()`-equivalent
      so the column width is stable as rows scroll.
- [ ] Copying a log row to the clipboard includes the signature.

---

## §2 — Custom verification mark (`SealGrid`)

**Goal.** Replace the generic `checkmark.seal.fill` with a mechanical 4×4 grid
that fills as bundles verify. It appears in three places: the progress card
header, the completion sheet, and (small) in the sidebar row of a finished
ingest.

### 2.1 — Drop `SealGrid.swift` into the project

It's in this bundle. No imports beyond `SwiftUI`. Pure `Canvas` drawing — cheap
to animate.

### 2.2 — `ProgressPane.swift` — use it as the header mark

Currently `ProgressPane` shows a circular indeterminate progress + a percent
label. Add the `SealGrid` next to the percent so the user has a *visual*,
not just numeric, sense of how many bundles have been verified:

```swift
HStack(alignment: .center, spacing: 16) {
    SealGrid(progress: progress.fractionVerified)
        .frame(width: 64, height: 64)

    VStack(alignment: .leading, spacing: 4) {
        Text("Ingesting \(Int(progress.fraction * 100))%")
            .font(.title3.weight(.semibold))
            .monospacedDigit()

        Text("Bundle \(progress.bundleIndex) of \(progress.bundleTotal)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
    Spacer()
    ProgressPaneStats(progress: progress)   // MB/s + ETA, right-aligned
}
```

`fractionVerified` should be `Double(verifiedBundles) / Double(totalBundles)`.
If you don't track verified separately from copied, use `fraction`.

### 2.3 — `CompletionSheet.swift` — use it as the hero glyph

Currently the sheet leads with `Image(systemName: "checkmark.seal.fill")`.
Replace with:

```swift
SealGrid(progress: 1, pulse: true)
    .frame(width: 56, height: 56)
    .padding(.bottom, 4)
```

Pass `pulse: true` only on completion — it triggers a single scale animation
on the last cell (~350ms). Re-mount, don't toggle.

For the failure case, **keep** `Image(systemName: "exclamationmark.octagon.fill")`
at 48pt with `.foregroundStyle(.orange)`. The seal-grid is reserved for
success.

### 2.4 — Acceptance

- [ ] During ingest, the seal grid fills cell-by-cell in row-major order as
      bundles verify.
- [ ] On completion, the last cell pulses once (no loop).
- [ ] The grid honors `Color.accentColor`.
- [ ] Resizes cleanly from 24pt to 96pt without sub-pixel artifacts.

---

## §3 — Completion sheet: lead with "safe to remove"

**Goal.** The completion sheet today leads with stats. The brief leads with
the emotional payoff (the card is ejected, the work is done), then provides
stats below.

### 3.1 — `CompletionSheet.swift` body order

```swift
VStack(spacing: 0) {
    // 1. Hero mark
    if result.failed > 0 {
        Image(systemName: "exclamationmark.octagon.fill")
            .font(.system(size: 48))
            .foregroundStyle(.orange)
    } else {
        SealGrid(progress: 1, pulse: true)
            .frame(width: 56, height: 56)
    }

    // 2. Title — semantic, not "Ingest complete"
    Text(titleString(for: result))
        .font(.title3.weight(.semibold))
        .padding(.top, 12)

    // 3. Subtitle — leads with "safe to remove" if ejected
    Text(subtitleString(for: result))
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 6)
        .frame(maxWidth: 360)

    // 4. Stats grid
    CompletionStatsGrid(result: result)
        .padding(.top, 22)
        .padding(.bottom, 22)

    // 5. Actions
    HStack(spacing: 10) {
        Button("Open Log") { /* … */ }
        Button("Show in Finder") { /* … */ }
        Button("Done") { onDismiss() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }
}
.padding(28)
.frame(width: 480)
```

### 3.2 — Title / subtitle strings

```swift
func titleString(for result: CopyResult) -> String {
    if result.failed > 0 {
        return "Ingest completed with errors"
    }
    return "Ingest complete"
}

func subtitleString(for result: CopyResult) -> String {
    let parts: [String] = {
        if result.failed > 0 {
            return ["\(result.failed) file\(result.failed == 1 ? "" : "s") failed — see log for details."]
        }
        if result.copied == 0 && result.skipped > 0 {
            return ["Everything was already there — nothing new to copy."]
        }
        if result.skipped > 0 {
            return ["\(result.copied) copied, \(result.skipped) already present."]
        }
        return ["All files copied and verified."]
    }()

    var out = parts.joined(separator: " ")
    if result.wasEjected {
        out += " Card ejected — safe to remove."
    }
    return out
}
```

The "Card ejected — safe to remove." is **appended** in all success cases.
For failure, omit it — the user will need to retry from the card.

### 3.3 — Stats grid

Replace any custom layout with a `Grid` (already in your CompletionSheet,
double-check the columns):

```swift
Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
    GridRow {
        Text("Files").foregroundStyle(.secondary)
        Text(filesLine(result)).monospacedDigit()
    }
    GridRow {
        Text("Size").foregroundStyle(.secondary)
        Text(result.copiedSize, format: .byteCount(style: .file))
            .monospacedDigit()
    }
    GridRow {
        Text("Elapsed").foregroundStyle(.secondary)
        Text(result.elapsed, format: .units(width: .abbreviated))
            .monospacedDigit()
    }
    GridRow {
        Text("Speed").foregroundStyle(.secondary)
        Text(result.averageBytesPerSecond, format: .byteCount(style: .file))
            .monospacedDigit()
        + Text("/s").foregroundStyle(.secondary)
    }
}
.font(.callout)

func filesLine(_ r: CopyResult) -> String {
    var parts: [String] = ["\(r.copied) copied"]
    if r.skipped > 0 { parts.append("\(r.skipped) skipped") }
    if r.failed  > 0 { parts.append("\(r.failed) failed") }
    return parts.joined(separator: ", ")
}
```

### 3.4 — Acceptance

- [ ] On clean success with eject, subtitle ends with `Card ejected — safe to remove.`
- [ ] On dupes-only success, subtitle reads `Everything was already there — nothing new to copy.`
- [ ] On failure, subtitle leads with `<N> file(s) failed — see log for details.` (no ejected line).
- [ ] Stats use a 2-column `Grid` with leading label / trailing value, all
      monospaced digit.

---

## §4 — `ContentUnavailableView` polish

**Goal.** Make `.cancelled` and `.failed` states informative without growing
the component. Lead with what was preserved, then the next step.

### 4.1 — `MainView.swift` — `.cancelled` branch

```swift
ContentUnavailableView {
    Label("Ingest cancelled", systemImage: "xmark.octagon")
} description: {
    Text("Partial files from the current bundle were rolled back. The \(progress.verifiedBundles) already-verified bundles are safe on disk.")
} actions: {
    Button("Reset") { copier.reset() }
        .buttonStyle(.borderedProminent)
}
```

### 4.2 — `MainView.swift` — `.failed(let message)` branch

```swift
ContentUnavailableView {
    Label("Ingest failed", systemImage: "exclamationmark.triangle.fill")
        .symbolRenderingMode(.multicolor)
} description: {
    Text("\(message). The \(progress.verifiedBundles) already-verified bundles are safe on disk; the failing file is still on the card.")
} actions: {
    Button("Reset") { copier.reset() }
        .buttonStyle(.borderedProminent)
}
```

Wire `progress.verifiedBundles` from `Copier`. If that field doesn't exist
yet, add it as a `@Published` (or `@Observable`-tracked) `Int` and increment
it on each successful verify.

### 4.3 — `.idle` (no card) branch

Tighten the description:

```swift
ContentUnavailableView(
    "No card selected",
    systemImage: "sdcard",
    description: Text("Insert a memory card to begin.")
)
```

### 4.4 — Acceptance

- [ ] Cancelled view names how many bundles were preserved.
- [ ] Failed view names how many were preserved **and** that the failing file
      is still on the card.
- [ ] Both views show a single primary Reset button (no destructive secondary).

---

## §5 — `InspectorPane.swift` — small refinements

**Goal.** Existing form is right; tighten grouping and re-order options so the
trust setting (verify) sits with the destinations, and the action defaults
(eject) sit on their own line.

```swift
Form {
    Section("Destinations") {
        DestinationField(
            label: "Primary",
            urlBinding: $primaryDestination,
            placeholder: "Choose folder…"
        )
        DestinationField(
            label: "Archive",
            urlBinding: $archiveDestination,
            placeholder: "Second copy (optional)"
        )
    }

    Section("Description") {
        TextField("e.g. Iceland", text: $description)
            .textFieldStyle(.plain)
    }

    Section {
        Toggle("Verify copies with xxHash", isOn: $verifyCopies)
        Toggle("Eject card when finished", isOn: $ejectWhenDone)
    } header: {
        Text("Options")
    } footer: {
        if verifyCopies {
            Text("Every file is hash-checked after copy. Recommended.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    Section {
        Button {
            ingestPlanner.start()
        } label: {
            Label("Ingest", systemImage: "arrow.right.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canStartIngest)
    }
}
.formStyle(.grouped)
```

### 5.1 — Acceptance

- [ ] Verify + Eject share a section, with a contextual footer when Verify is on.
- [ ] Ingest button is `.large` and fills the section row.
- [ ] When `canStartIngest` is false, the button is disabled but still visible.

---

## §6 — `MenuBarMenu.swift` polish

**Goal.** Make the menu bar item read at a glance. Two improvements: subtitle
under the primary action, and a status-icon glyph that switches on card
presence.

### 6.1 — Menu structure

```swift
Menu {
    if let card = watcher.primary {
        Button {
            ingestPlanner.startFromMenuBar()
        } label: {
            Text("Ingest from \(card.label)…")
        }
        .keyboardShortcut("i")
        .disabled(!canStartIngest)

        if let summary = card.previewSummary {
            Text(summary)                      // "482 photos · 24.6 GB"
                .foregroundStyle(.secondary)
        }
    } else {
        Text("No card inserted")
            .foregroundStyle(.secondary)
    }

    Divider()
    SettingsLink {
        Text("Preferences…")
    }
    .keyboardShortcut(",")

    Divider()
    Button("About PhotoDrop") { /* open about */ }
    Button("Quit PhotoDrop") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
} label: {
    // Status icon: filled when a card is mounted
    Image(systemName: watcher.primary != nil ? "sdcard.fill" : "sdcard")
}
```

### 6.2 — Acceptance

- [ ] Status icon switches between `sdcard` and `sdcard.fill` based on
      `watcher.primary`.
- [ ] When a card is present, the primary item is `Ingest from <label>…`
      with ⌘I shortcut, and a secondary line shows the preview summary.
- [ ] `Preferences…` uses `SettingsLink` (avoids spinning up a window).

---

## §7 — (Optional) Menu Bar tab in Settings

**Goal.** If you decide to ship the one-click-from-menu-bar path, expose it
as a setting rather than just being implicit. This is a NEW tab in the
existing `TabView` in `SettingsView.swift`.

### 7.1 — New `@AppStorage` keys

In a shared place (e.g. `Settings.swift` or top of `SettingsView.swift`):

```swift
@AppStorage("photodrop.menuBar.visibility") private var menuBarVisibility: MenuBarVisibility = .always
@AppStorage("photodrop.menuBar.autoOpenWindow") private var menuBarAutoOpen: Bool = true
@AppStorage("photodrop.menuBar.oneClickIngest") private var menuBarOneClick: Bool = false

enum MenuBarVisibility: String, CaseIterable, Identifiable {
    case always, withCard, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always:   return "Always"
        case .withCard: return "With card"
        case .hidden:   return "Hidden"
        }
    }
}
```

### 7.2 — New tab body

```swift
Form {
    Section("Menu bar status") {
        Picker("Show in menu bar", selection: $menuBarVisibility) {
            ForEach(MenuBarVisibility.allCases) { v in
                Text(v.label).tag(v)
            }
        }
        .pickerStyle(.segmented)

        Toggle("Auto-open window when a card arrives", isOn: $menuBarAutoOpen)
    }

    Section {
        Toggle("One-click ingest from menu bar", isOn: $menuBarOneClick)
    } footer: {
        Text("Uses your default destination and verify settings. Still hash-checks every file.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
.formStyle(.grouped)
.tabItem { Label("Menu Bar", systemImage: "sdcard.fill") }
```

### 7.3 — Wire `menuBarOneClick` into `MenuBarMenu.swift`

If `menuBarOneClick` is true and a card is present, on `Ingest from <label>…`
selection skip the inspector confirmation and call `ingestPlanner.start()`
directly with the stored defaults.

### 7.4 — Acceptance

- [ ] All three settings persist across app restarts.
- [ ] Toggling `menuBarVisibility` to `.hidden` removes the MenuBarExtra.
- [ ] One-click ingest succeeds on a clean card with primary destination set.
- [ ] One-click ingest is **disabled** (greyed out) when primary destination
      is empty.

---

## QA pass

Once everything is shipped, run through every state listed in
`design-files/index.html`:

1. **Idle (no card)** — sidebar empty section, detail = ContentUnavailableView.
2. **Scanning** — spinner + "Scanning card…" label.
3. **Preview ready** — list of years with day rows; inspector enabled.
4. **First run (no destination)** — same preview, Ingest disabled, hint
   text under the Ingest button.
5. **Ingesting** — `ProgressPane` with `SealGrid`, log streaming with
   xxHash signatures.
6. **Ingesting with skips** — same view; log alternates verified / skipped.
7. **Dual destination** — destination tiles below the progress bar.
8. **Done (clean)** — completion sheet leads with `Card ejected — safe to remove.`
9. **Done with skips** — completion sheet shows `N copied, M already present.`
10. **Done with errors** — orange octagon hero; subtitle leads with failed count.
11. **Cancelled** — `ContentUnavailableView` with bundle-count description.
12. **Halted (verify mismatch)** — `ContentUnavailableView` with bundle-count.
13. **Menu bar dropdown** — `Ingest from <label>…` + summary subtitle.

If any of these don't read like the HTML, open the corresponding artboard in
`design-files/index.html` for comparison.
