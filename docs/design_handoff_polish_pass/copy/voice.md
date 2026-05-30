# Voice — verbatim strings

All user-facing strings, grouped by surface. Lift these verbatim unless flagged
`(propose)`.

## Window title bar

```
{Card label}                        // e.g. "EOS R5 SD"  — bound to selected card
{size} · {N} photos                 // e.g. "64.2 GB · 482 photos"
```

Subtitle morphs by Copier.state:

| State                | Subtitle                                       |
| -------------------- | ---------------------------------------------- |
| `.idle` (no card)    | _empty_                                        |
| `.idle` (scanning)   | `— · Scanning…`                                |
| `.idle` (ready)      | `{size} · {N} photos`                          |
| `.running`           | `{size} · Ingesting {pct}%`                    |
| `.running` (2 dests) | `{size} · Ingesting {pct}% · 2 dests`          |
| `.completed`         | `{size}`                                       |
| `.cancelled`         | `{size} · Cancelled`                           |
| `.failed`            | `{size} · Failed`                              |

## Sidebar

```
Cards                               // section header
{Card label}                        // row primary
{kind} · {capacity}                 // row secondary  ("SDXC · 128 GB")

Recent ingests                      // section header
{Description or date}               // row primary
{N} photos · {date}                 // row secondary
```

Empty section: a `ContentUnavailableView`-style placeholder inside the sidebar
group: `No cards inserted.`

## Inspector

```
Destinations                        // section header
Primary                             // field label
Archive                             // field label
Choose folder…                      // primary placeholder
Second copy (optional)              // archive placeholder

Description                         // section header
e.g. Iceland                        // textfield placeholder

Options                             // section header
Verify copies with xxHash           // toggle label
Eject card when finished            // toggle label

Every file is hash-checked after copy. Recommended.   // footer when Verify is on

Ingest                              // primary button label (.borderedProminent .large)
```

## Toolbar

```
Refresh                             // arrow.clockwise — kicks off another card scan
Toggle Inspector                    // sidebar.right
```

## Idle (no card) — ContentUnavailableView

```
No card selected
Insert a memory card to begin.
```

## Scanning detail

```
Scanning card…
```

Place under a small native NSProgressIndicator-style spinner.

## First-run hint (under Ingest button when destination empty)

```
Pick a destination to enable Ingest. PhotoDrop will remember it for every card.
```

(propose — confirm exact wording with engineering)

## Progress pane

```
Ingesting {pct}%                          // .title3 .semibold .monospacedDigit
Bundle {i} of {N}                         // .subheadline .secondary .monospacedDigit
{speed} MB/s · {eta} left                 // .subheadline .secondary .monospacedDigit
```

Right side of header: stats stack, right-aligned, tabular numbers.

Activity (log) header: `Activity` left, three legend pills right (`verified`,
`skipped`, `error`).

## Log row (caption monospaced)

| Kind        | Format                                                                                |
| ----------- | ------------------------------------------------------------------------------------- |
| `.info`     | `Starting ingest: {N} bundles, {size}`                                                |
| `.info`     | `Indexing destination for duplicates…`                                                |
| `.copied`   | `{srcName} → {destName}`                                                              |
| `.verified` | `{srcName} → {destName}                                                  [a3f7…7fa3]` |
| `.skipped`  | `{srcName} — already present as {existingName}`                                       |
| `.error`    | `Verify mismatch on {name} — destination copy deleted`                                |
| `.error`    | `Halting job on verification mismatch.`                                               |

## Completion sheet — clean success

```
[seal-grid pulse]
Ingest complete
All files copied and verified. Card ejected — safe to remove.

Files     482 copied
Size      24.6 GB
Elapsed   10m 42s
Speed     38.4 MB/s

[Open Log] [Show in Finder] [Done]
```

## Completion sheet — with skips

```
Ingest complete
{N copied} copied, {M skipped} already present. Card ejected — safe to remove.
```

## Completion sheet — only dupes (nothing copied)

```
Ingest complete
Everything was already there — nothing new to copy. Card ejected — safe to remove.
```

## Completion sheet — with errors

```
[orange octagon]
Ingest completed with errors
{N} file{s} failed — see log for details.
```

(No "safe to remove" line — the user needs to retry from the card.)

## Cancelled — ContentUnavailableView

```
[xmark.octagon]
Ingest cancelled
Partial files from the current bundle were rolled back. The {N} already-verified bundles are safe on disk.

[Reset]
```

## Halted (verify mismatch) — ContentUnavailableView

```
[exclamationmark.triangle.fill multicolor]
Ingest failed
Halted: verification mismatch. The {N} already-verified bundles are safe on disk; the failing file is still on the card.

[Reset]
```

## Menu bar dropdown

When a card is mounted:

```
Ingest from {Card label}…                ⌘I
{N} photos · {size}
————————————————————
Preferences…                              ⌘,
————————————————————
About PhotoDrop
Quit PhotoDrop                            ⌘Q
```

When no card is mounted:

```
Open PhotoDrop
No card inserted
————————————————————
Preferences…                              ⌘,
… etc
```

## Settings — General tab

```
Destinations
  Primary library   [path field]
  Archive copy      [path field]                Optional second destination — verified independently
```

## Settings — Ingest tab

```
Defaults                  Applied to every job, overridable per-ingest in the inspector.
  Verify copies with xxHash                          Hash-check every byte after copy — recommended.
  Eject card when finished
  Show completion summary
```

## Settings — Menu Bar tab (proposed, §7)

```
Menu bar status                           Many users live in the menu bar — these controls keep that path one-click.
  Show in menu bar                  [Always | With card | Hidden]
  Auto-open window when a card arrives    [toggle]
  One-click ingest from menu bar          [toggle]   Uses your default destination and verify settings. Still hash-checks every file.
```

## Tone rules

- Lead with what is preserved before what failed.
- Numbers always tabular and monospaced.
- "Card" not "SD card" or "drive" — match the existing codebase's vocabulary.
- "Verify" not "check" — matches `verifyCopies` AppStorage key.
- "xxHash" appears once explicitly (the inspector toggle), then implicitly
  (the signatures in the log) — never as a noun in completion copy.
- Em-dash em-dash em-dash. No semicolons in user-facing strings.
