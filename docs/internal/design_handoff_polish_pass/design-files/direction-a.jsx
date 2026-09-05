// direction-a.jsx — "Steady" direction
// Same SwiftUI bones as the existing PhotoDropMac codebase (List/sidebar,
// DisclosureGroup, .inspector(), Form), with three deliberate design
// improvements layered on top:
//   1. Verification motif = seal grid (4×4), not checkmark.seal.fill —
//      the brief calls the plain seal "too generic"
//   2. Inspector voice — "Verify every file" (not "with xxHash"), plus an
//      explicit "Skip duplicates already in library" row
//   3. Completion is restructured so "card ejected — safe to remove" is the
//      headline, not a tacked-on second sentence
//
// Everything else stays HIG: SF Symbols, system accent (Color.accentColor),
// system grays, .borderedProminent ingest, native log iconography.

// ─── SealGrid — verification motif ──────────────────────────────────────────
// 4×4 grid. Fills cell-by-cell as bundles verify. Last cell pulses briefly
// on completion. Reads as a mechanical seal; better than a generic check.
function SealGrid({ tok, progress = 1, size = 56, pulse = false }) {
  const { accent } = tok;
  const cell = (size - 6) / 4;
  const filled = Math.round(progress * 16);
  return (
    <div style={{
      width: size, height: size,
      display: 'grid',
      gridTemplateColumns: `repeat(4, ${cell}px)`,
      gridTemplateRows:    `repeat(4, ${cell}px)`,
      gap: 2, padding: 2,
      borderRadius: 6,
      background: tok.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.04)',
    }}>
      {Array.from({ length: 16 }).map((_, i) => (
        <div key={i} style={{
          background: i < filled ? accent.hex : (tok.dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.08)'),
          borderRadius: 1.5,
          transform: pulse && i === 15 ? 'scale(1.05)' : 'scale(1)',
          transition: 'background .25s, transform .35s',
        }} />
      ))}
    </div>
  );
}

// ─── DA_Sidebar — List(selection:) .listStyle(.sidebar) ─────────────────────
function DA_Sidebar({ tok, cards = [], selectedId, kind = 'a' }) {
  const { t, type, accent } = tok;
  return (
    <PDSidebar tok={tok}>
      <div style={{ padding: '8px 8px 4px' }}>
        <SidebarSectionHeader tok={tok}>Cards</SidebarSectionHeader>
      </div>
      {cards.length === 0 ? (
        <div style={{
          padding: '6px 12px 14px', color: t.textSec, fontSize: 12, lineHeight: 1.45,
        }}>
          No cards inserted.
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          {cards.map((c) => (
            <PDSidebarRow key={c.id}
              tok={tok}
              icon="sdcard.fill"
              label={c.name}
              secondary={fmt.size(c.usedGB) + ' of ' + fmt.size(c.capGB)}
              selected={c.id === selectedId}
              trailing={
                <span style={{ color: c.id === selectedId ? 'rgba(255,255,255,0.85)' : t.textSec, opacity: 0.85, display: 'flex' }}>
                  <Icon name="eject.fill" size={13} />
                </span>
              }
            />
          ))}
        </div>
      )}

      <div style={{ marginTop: 14, padding: '0 8px 4px' }}>
        <SidebarSectionHeader tok={tok}>Recent</SidebarSectionHeader>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {[
          { d: 'Yesterday', n: '628 photos · 24.6 GB' },
          { d: 'Apr 14',    n: '1,204 photos · 47.1 GB' },
          { d: 'Apr 11',    n: '341 photos · 12.8 GB' },
        ].map((r) => (
          <PDSidebarRow key={r.d} tok={tok} icon="folder.fill" label={r.d} secondary={r.n} />
        ))}
      </div>
    </PDSidebar>
  );
}

function SidebarSectionHeader({ tok, children }) {
  return (
    <div style={{
      fontSize: 11, fontWeight: 600,
      color: tok.t.textSec, letterSpacing: -0.02,
      padding: '0 8px 4px',
    }}>{children}</div>
  );
}

// ─── DA_Preview — PreviewTree.swift shape ───────────────────────────────────
function DA_Preview({ tok, days = [], totals }) {
  const { t, type } = tok;
  const groups = days.reduce((acc, d) => {
    const y = d.date.slice(0, 4);
    (acc[y] = acc[y] || []).push(d);
    return acc;
  }, {});

  const summary = `${fmt.int(totals.files)} files · ${fmt.size(totals.sizeGB)}`;

  return (
    <PDList tok={tok}
      header={(
        <>
          <div style={{ fontSize: 13, fontWeight: 600, color: t.text }}>Preview</div>
          <div style={{ fontSize: 12, color: t.textSec, fontVariantNumeric: 'tabular-nums' }}>{summary}</div>
        </>
      )}
    >
      {Object.entries(groups).map(([year, list]) => (
        <PDDisclosure key={year} tok={tok}
          label={
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ color: t.textSec, display: 'flex' }}><Icon name="folder" size={16} /></span>
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 13, fontWeight: 500, color: t.text }}>{year}</div>
                <div style={{ fontSize: 11, color: t.textSec, marginTop: 1, fontVariantNumeric: 'tabular-nums' }}>
                  {fmt.int(list.reduce((a, d) => a + d.files, 0))} files · {fmt.size(list.reduce((a, d) => a + d.sizeGB, 0))}
                </div>
              </div>
            </div>
          }
        >
          {list.map((d) => <DA_FolderRow key={d.date} tok={tok} day={d} />)}
        </PDDisclosure>
      ))}
    </PDList>
  );
}

function DA_FolderRow({ tok, day }) {
  const { t, type, accent } = tok;
  const folderName = day.description ? `${day.date}_${day.description.replace(/\s+/g, '-')}` : day.date;
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: '5px 8px',
    }}>
      <span style={{ color: accent.hex, display: 'flex' }}><Icon name="folder.fill" size={16} /></span>
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{
          fontSize: 13, fontWeight: 600, color: accent.hex,
          fontFamily: type.body, fontVariantNumeric: 'tabular-nums',
        }}>{folderName}</div>
        <div style={{
          fontSize: 11, color: t.textSec, marginTop: 1,
          fontVariantNumeric: 'tabular-nums',
        }}>
          {fmt.int(day.files)} files · {fmt.size(day.sizeGB)}
          {day.dupes ? <span style={{ marginLeft: 8, color: t.skip }}>· {day.dupes} already in library</span> : null}
        </div>
      </div>
    </div>
  );
}

// ─── DA_Inspector — InspectorPane.swift shape, improved voice ───────────────
function DA_Inspector({ tok,
                        dest = '', archive = '', description = '',
                        verify = true, eject = true, skipDupes = true,
                        canIngest = true, ingestLabel = 'Ingest', hint }) {
  const { t, type } = tok;
  const Label = ({ children, trailing }) => (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 6 }}>
      <span style={{ fontSize: 12, fontWeight: 500, color: t.textSec }}>{children}</span>
      {trailing && <span style={{ fontSize: 11, color: t.textMute }}>{trailing}</span>}
    </div>
  );
  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div style={{ padding: '18px 20px 0', flex: 1, minHeight: 0, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 14 }}>
        {/* Destinations */}
        <div>
          <Label>Destination</Label>
          <PDPathField tok={tok} value={dest} placeholder="Choose folder…" />
        </div>
        <div>
          <Label trailing="optional">Archive</Label>
          <PDPathField tok={tok} value={archive} placeholder="Second copy location" />
        </div>

        <PDDivider tok={tok} />

        {/* Description */}
        <div>
          <Label>Description</Label>
          <PDTextField tok={tok} value={description} placeholder="e.g. Wedding, Iceland trip" />
        </div>

        <PDDivider tok={tok} />

        {/* Options — improved copy. No "xxHash" jargon. */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <PDCheckbox tok={tok} checked={verify}    label="Verify every file" />
          <PDCheckbox tok={tok} checked={skipDupes} label="Skip duplicates already in library" />
          <PDCheckbox tok={tok} checked={eject}     label="Eject card when finished" />
        </div>

        {hint && (
          <div style={{
            display: 'flex', gap: 8, alignItems: 'flex-start',
            background: t.warnSoft, color: t.warn,
            padding: '10px 12px', borderRadius: 6, fontSize: 12, lineHeight: 1.4,
            marginTop: 4,
          }}>
            <Icon name="info.circle" size={14} style={{ marginTop: 1, flexShrink: 0 }} />
            <span>{hint}</span>
          </div>
        )}
      </div>

      {/* sticky Ingest CTA at the bottom — borderedProminent + large */}
      <div style={{ padding: '12px 20px 18px', borderTop: `0.5px solid ${t.border}`, background: t.panel }}>
        <PDButton tok={tok} variant="borderedProminent" size="large" full disabled={!canIngest}>
          {ingestLabel}
        </PDButton>
      </div>
    </div>
  );
}

// ─── DA_Progress — ProgressPane.swift shape, with seal-grid added ──────────
function DA_Progress({ tok, job }) {
  const { t, type, accent } = tok;
  const pct = job.pct;
  const dual = !!job.archive;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* progressCard — matches ProgressPane.swift, plus a seal-grid badge */}
      <div style={{ padding: '20px 24px 18px', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <div style={{ fontSize: 16, fontWeight: 600, color: t.text, fontVariantNumeric: 'tabular-nums' }}>
                Ingesting… {Math.round(pct * 100)}%
              </div>
              <PDButton tok={tok} size="small" role="destructive" variant="bordered">Cancel</PDButton>
            </div>

            <div style={{ marginTop: 12 }}><PDProgressBar tok={tok} value={pct} /></div>

            <div style={{
              marginTop: 10,
              fontSize: 12, color: t.textSec,
              fontVariantNumeric: 'tabular-nums',
              display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap',
            }}>
              <span>Bundle <span style={{ color: t.text }}>{fmt.int(job.bundleI)}</span> of <span style={{ color: t.text }}>{fmt.int(job.bundleN)}</span></span>
              <span style={{ color: t.textFaint }}>·</span>
              <span>{job.mbs != null ? fmt.mbs(job.mbs) : '— MB/s'}</span>
              <span style={{ color: t.textFaint }}>·</span>
              <span>{job.eta != null ? fmt.eta(job.eta) + ' left' : '—'}</span>
              {job.skippedI > 0 && (
                <>
                  <span style={{ color: t.textFaint }}>·</span>
                  <span style={{ color: t.skip }}>{fmt.int(job.skippedI)} already in library</span>
                </>
              )}
            </div>

            {job.currentFile && (
              <div style={{
                marginTop: 6, fontSize: 11.5, color: t.textMute,
                fontFamily: type.mono, fontVariantNumeric: 'tabular-nums',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              }}>{job.currentFile}</div>
            )}
          </div>

          {/* seal grid badge — the trust signal */}
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, flexShrink: 0 }}>
            <SealGrid tok={tok} progress={pct} size={52} />
            <div style={{ fontSize: 10, color: t.textMute, letterSpacing: '0.05em', textTransform: 'uppercase' }}>verified</div>
          </div>
        </div>

        {dual && (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 6 }}>
            <DA_DestTile tok={tok} icon="externaldrive.fill" name={job.destName}    pct={job.destPct}    label="Primary" />
            <DA_DestTile tok={tok} icon="shippingbox"        name={job.archiveName} pct={job.archivePct} label="Archive" />
          </div>
        )}
      </div>

      <PDDivider tok={tok} />

      <DA_LogView tok={tok} entries={job.log || []} />
    </div>
  );
}

function DA_DestTile({ tok, icon, name, pct, label }) {
  const { t, type, accent } = tok;
  return (
    <div style={{
      padding: '8px 12px', borderRadius: 6,
      background: tok.dark ? 'rgba(255,255,255,0.03)' : 'rgba(0,0,0,0.025)',
      border: `0.5px solid ${t.border}`,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 }}>
        <span style={{ color: t.textSec, display: 'flex' }}><Icon name={icon} size={13} /></span>
        <span style={{ fontSize: 10, color: t.textMute, letterSpacing: '0.04em', textTransform: 'uppercase' }}>{label}</span>
        <span style={{ marginLeft: 'auto', fontSize: 11, color: t.text, fontVariantNumeric: 'tabular-nums', fontFamily: type.mono }}>{Math.round(pct * 100)}%</span>
      </div>
      <div style={{ fontSize: 11.5, color: t.text, fontFamily: type.mono, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', marginBottom: 5 }}>{name}</div>
      <PDProgressBar tok={tok} value={pct} />
    </div>
  );
}

// LogView — matches the engineer's `LogView` exactly: SF symbol + monospaced
// line, color by kind. Same icon names: info.circle / arrow.down.doc /
// arrow.right.doc / checkmark.seal / exclamationmark.triangle.fill.
function DA_LogView({ tok, entries }) {
  const { t, type } = tok;
  return (
    <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '6px 20px 14px' }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {entries.map((entry, i) => <DA_LogRow key={i} tok={tok} entry={entry} />)}
      </div>
    </div>
  );
}

function DA_LogRow({ tok, entry }) {
  const { t, type } = tok;
  const meta = {
    copied:   { icon: 'arrow.down.doc',                 fg: t.text },
    skipped:  { icon: 'arrow.right.doc',                fg: t.skip },
    verified: { icon: 'checkmark.seal.fill',            fg: t.ok },
    error:    { icon: 'exclamationmark.triangle.fill',  fg: t.err },
    info:     { icon: 'info.circle',                    fg: t.textSec },
  }[entry.kind] || { icon: 'info.circle', fg: t.textSec };
  // Reproduce the codebase's single-line "line" formatting:
  //   "10:42:18  copied   DCIM/108_FUJI/DSCF1839.RAF  (54.2 MB)"
  const parts = [
    entry.time,
    entry.kind === 'copied'   ? 'copied'
    : entry.kind === 'skipped' ? 'skipped'
    : entry.kind === 'verified'? 'verified'
    : entry.kind === 'error'   ? 'error'
    : 'info',
    entry.file,
    entry.size ? `(${entry.size})` : '',
    entry.note ? '— ' + entry.note : '',
  ].filter(Boolean).join('  ');
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      color: meta.fg,
    }}>
      <span style={{ width: 14, display: 'flex', alignItems: 'center', justifyContent: 'flex-start', flexShrink: 0 }}>
        <Icon name={meta.icon} size={12} />
      </span>
      <span style={{
        fontFamily: type.mono, fontSize: 11,
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        flex: 1, minWidth: 0,
        fontVariantNumeric: 'tabular-nums',
      }}>{parts}</span>
    </div>
  );
}

Object.assign(window, {
  SealGrid, DA_Sidebar, SidebarSectionHeader,
  DA_Preview, DA_FolderRow, DA_Inspector,
  DA_Progress, DA_DestTile, DA_LogView, DA_LogRow,
});
