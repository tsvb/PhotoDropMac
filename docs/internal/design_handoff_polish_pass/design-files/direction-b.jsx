// direction-b.jsx — "Ledger" direction
// Same SwiftUI scaffold as Steady — sidebar, .inspector, .listStyle(.inset),
// SF Symbols, system accent. The differences are deliberate:
//   • Verification motif is a 24-tick stamp ring (StampMark) instead of the
//     seal grid. Reads as a postal/wax seal rather than a parts-grid.
//   • Year headers and the completion headline use Instrument Serif — a
//     single moment of typographic warmth that anchors the emotional payoff.
//   • Day rows in the preview show their date in tabular monospace,
//     description in serif italic. Same data, more journal energy.
//
// Direction B reuses Steady's Sidebar / Inspector / LogView verbatim (they
// already read from tokens). Only the Preview, the Progress *badge*, and
// the Completion sheet diverge.

// ─── StampMark — circular tick-ring verification motif ─────────────────────
function StampMark({ tok, progress = 1, size = 56, stamped = false }) {
  const { accent, t } = tok;
  const cx = size / 2, cy = size / 2;
  const rOuter = size / 2 - 1;
  const rInner = size / 2 - 6;
  const ticks = 24;
  const filled = Math.round(progress * ticks);
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <circle cx={cx} cy={cy} r={rOuter} fill="none"
        stroke={tok.dark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.10)'} strokeWidth="0.75" />
      <circle cx={cx} cy={cy} r={rInner} fill="none"
        stroke={tok.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.06)'} strokeWidth="0.5" />
      {Array.from({ length: ticks }).map((_, i) => {
        const angle = (i / ticks) * Math.PI * 2 - Math.PI / 2;
        const t1 = rOuter - 1, t2 = rInner + 1;
        return (
          <line key={i}
            x1={cx + Math.cos(angle) * t1} y1={cy + Math.sin(angle) * t1}
            x2={cx + Math.cos(angle) * t2} y2={cy + Math.sin(angle) * t2}
            stroke={i < filled ? accent.hex : (tok.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.10)')}
            strokeWidth={i < filled ? 1.6 : 1} strokeLinecap="round"
          />
        );
      })}
      {stamped ? (
        <g transform={`translate(${cx},${cy})`}>
          <circle r={rInner - 3} fill={accent.hex} opacity="0.10" />
          <path d="M-4.5 0 L-1 4 L5 -3.5" fill="none" stroke={accent.hex}
            strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </g>
      ) : (
        <text x={cx} y={cy + 3.5} textAnchor="middle"
          fontSize={size / 4.5} fontFamily="ui-monospace" fontWeight="500"
          fill={t.textSec} style={{ fontVariantNumeric: 'tabular-nums' }}>
          {Math.round(progress * 100)}
        </text>
      )}
    </svg>
  );
}

// ─── DB_Preview — same PreviewTree shape, serif Year, journal day rows ──────
function DB_Preview({ tok, days = [], totals }) {
  const { t, type } = tok;
  const groups = days.reduce((acc, d) => {
    const y = d.date.slice(0, 4);
    (acc[y] = acc[y] || []).push(d);
    return acc;
  }, {});
  return (
    <PDList tok={tok}
      header={(
        <>
          <div style={{ fontFamily: type.display, fontSize: 18, fontWeight: 400, color: t.text, letterSpacing: -0.3, lineHeight: 1.1 }}>
            Preview
          </div>
          <div style={{ fontSize: 12, color: t.textSec, fontVariantNumeric: 'tabular-nums' }}>
            {fmt.int(totals.files)} files · {fmt.size(totals.sizeGB)}
          </div>
        </>
      )}
    >
      {Object.entries(groups).map(([year, list]) => (
        <PDDisclosure key={year} tok={tok}
          label={
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
              <span style={{ color: t.textSec, display: 'flex', alignSelf: 'center' }}><Icon name="folder" size={16} /></span>
              <span style={{ fontFamily: type.display, fontStyle: 'italic', fontSize: 20, fontWeight: 400, color: t.text, letterSpacing: -0.3, lineHeight: 1.05 }}>{year}</span>
              <span style={{ fontSize: 11, color: t.textSec, fontVariantNumeric: 'tabular-nums' }}>
                · {fmt.int(list.reduce((a, d) => a + d.files, 0))} files · {fmt.size(list.reduce((a, d) => a + d.sizeGB, 0))}
              </span>
            </div>
          }
        >
          {list.map((d) => <DB_FolderRow key={d.date} tok={tok} day={d} />)}
        </PDDisclosure>
      ))}
    </PDList>
  );
}

function DB_FolderRow({ tok, day }) {
  const { t, type, accent } = tok;
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: 'auto auto 1fr auto',
      gap: 12, alignItems: 'center',
      padding: '6px 8px',
    }}>
      <span style={{ color: accent.hex, display: 'flex' }}><Icon name="folder.fill" size={16} /></span>
      <span style={{ fontFamily: type.mono, fontSize: 12, color: accent.hex, fontVariantNumeric: 'tabular-nums' }}>
        {day.date}
      </span>
      <span style={{
        fontFamily: type.display, fontSize: 13.5, fontStyle: day.description ? 'italic' : 'normal',
        color: day.description ? t.text : t.textMute, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
      }}>{day.description || 'untitled day'}</span>
      <span style={{ fontSize: 11, color: t.textSec, fontVariantNumeric: 'tabular-nums' }}>
        {fmt.int(day.files)} files · {fmt.size(day.sizeGB)}
        {day.dupes ? <span style={{ marginLeft: 6, color: t.skip }}>· {day.dupes} skip</span> : null}
      </span>
    </div>
  );
}

// ─── DB_Progress — same shape, StampMark instead of SealGrid ────────────────
function DB_Progress({ tok, job }) {
  const { t, type, accent } = tok;
  const pct = job.pct;
  const dual = !!job.archive;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <div style={{ padding: '20px 24px 18px', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 18 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <div style={{ fontFamily: type.display, fontSize: 20, fontWeight: 400, color: t.text, letterSpacing: -0.3 }}>
                <span style={{ fontStyle: 'italic' }}>Ingesting</span>
                <span style={{ fontFamily: type.mono, fontVariantNumeric: 'tabular-nums', marginLeft: 8, fontSize: 18 }}>{Math.round(pct * 100)}%</span>
              </div>
              <PDButton tok={tok} size="small" role="destructive" variant="bordered">Cancel</PDButton>
            </div>

            <div style={{ marginTop: 12 }}><PDProgressBar tok={tok} value={pct} /></div>

            <div style={{ marginTop: 10, fontSize: 12, color: t.textSec, fontVariantNumeric: 'tabular-nums', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
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
              <div style={{ marginTop: 6, fontSize: 11.5, color: t.textMute, fontFamily: type.mono, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{job.currentFile}</div>
            )}
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, flexShrink: 0 }}>
            <StampMark tok={tok} progress={pct} size={64} />
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

Object.assign(window, {
  StampMark, DB_Preview, DB_FolderRow, DB_Progress,
});
