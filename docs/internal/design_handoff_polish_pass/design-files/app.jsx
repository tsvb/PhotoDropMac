// app.jsx — composes every state into the design canvas.
//
// Native PhotoDropMac scaffold (matches the SwiftUI shipped in
// tsvb/PhotoDropMac):
//
//   PDWindow (Window .windowToolbarStyle(.unified))
//     PDSplit (NavigationSplitView)
//       sidebar : List(selection:) .listStyle(.sidebar)
//                 — cards + recent ingests
//       detail  : morphs by Copier.state:
//                   .idle      → PreviewTree / ContentUnavailableView
//                   .running   → ProgressPane + LogView
//                   .completed → PreviewTree (state below) + CompletionSheet (overlay)
//                   .cancelled → ContentUnavailableView "Ingest cancelled"
//                   .failed    → ContentUnavailableView "Ingest failed"
//       inspector: stays mounted across states; ingest button disabled
//                  whenever canStart is false.
//
// Direction A and Direction B differ in:
//   • verification motif (SealGrid vs StampMark)
//   • preview row chrome (folder name primary vs date+description)
//   • completion sheet typography (system vs Instrument Serif)
// Everything else — scaffolding, log lines, settings, menu bar — is shared.

// ─── Fixtures ───────────────────────────────────────────────────────────────

const SAMPLE_CARDS = [
  { id: 'r5',  name: 'EOS R5 SD',  kind: 'SDXC · 128 GB',  capGB: 128, usedGB: 64.2 },
];

const SAMPLE_DAYS = [
  { date: '2026-04-17', weekday: 'Thu', description: 'Reykjanes — black sand',     photos: 184, files: 372, sizeGB: 11.2, dupes: 0  },
  { date: '2026-04-16', weekday: 'Wed', description: 'Diamond beach, blue hour',   photos:  96, files: 196, sizeGB:  5.8, dupes: 4  },
  { date: '2026-04-15', weekday: 'Tue', description: 'Vík — pebbles + spray',      photos: 142, files: 286, sizeGB:  8.4, dupes: 0  },
  { date: '2026-04-14', weekday: 'Mon', description: 'Flight + drive',              photos:  28, files:  56, sizeGB:  1.6, dupes: 12 },
  { date: '2026-04-13', weekday: 'Sun', description: '',                            photos:  32, files:  64, sizeGB:  2.0, dupes: 0  },
];

const SAMPLE_DAYS_DUPES = SAMPLE_DAYS.map((d, i) =>
  i === 0 ? { ...d, dupes: 18 } : i === 2 ? { ...d, dupes: 6 } : d
);

const SAMPLE_TOTALS = (days) => ({
  photos: days.reduce((a, d) => a + d.photos, 0),
  files:  days.reduce((a, d) => a + d.files,  0),
  sizeGB: days.reduce((a, d) => a + d.sizeGB, 0),
  dupes:  days.reduce((a, d) => a + d.dupes,  0),
});

// Log lines — match the format the engineer's `LogView` renders:
//   info     → "Starting ingest: 482 bundles, 24.6 GB"
//   copied   → "P1380472.RAF → P1380472.RAF"
//   verified → "P1380472.RAF → P1380472.RAF  [a3f7…b912]"  ← the xxHash signature
//   skipped  → "P1380472.RAF — already present as P1380472.RAF"
//   error    → "Verify mismatch on P1380472.RAF — see log"
const HASH = (seed) => seed.padStart(4, 'a') + '…' + seed.split('').reverse().join('').padStart(4, '0');

const SAMPLE_LOG = [
  { time: '10:42:00', kind: 'info',     file: 'Starting ingest: 482 bundles, 24.6 GB' },
  { time: '10:42:01', kind: 'info',     file: 'Indexing destination for duplicates…' },
  { time: '10:42:18', kind: 'verified', file: 'DSCF1839.RAF → 20260417_104218_DSCF1839.RAF',  size: HASH('a3f7') },
  { time: '10:42:18', kind: 'verified', file: 'DSCF1839.JPG → 20260417_104218_DSCF1839.JPG',  size: HASH('2c91') },
  { time: '10:42:19', kind: 'verified', file: 'DSCF1840.RAF → 20260417_104219_DSCF1840.RAF',  size: HASH('b428') },
  { time: '10:42:20', kind: 'verified', file: 'DSCF1840.xmp → 20260417_104219_DSCF1840.xmp',  size: HASH('00cf') },
  { time: '10:42:21', kind: 'verified', file: 'DSCF1841.RAF → 20260417_104221_DSCF1841.RAF',  size: HASH('9d11') },
  { time: '10:42:22', kind: 'verified', file: 'DSCF1842.RAF → 20260417_104222_DSCF1842.RAF',  size: HASH('77ae') },
  { time: '10:42:23', kind: 'verified', file: 'DSCF1843.RAF → 20260417_104223_DSCF1843.RAF',  size: HASH('5102') },
];

const SAMPLE_LOG_DUPES = [
  { time: '10:42:00', kind: 'info',     file: 'Starting ingest: 482 bundles, 24.6 GB' },
  { time: '10:42:01', kind: 'info',     file: 'Indexing destination for duplicates…' },
  { time: '10:42:18', kind: 'verified', file: 'DSCF1839.RAF → 20260417_104218_DSCF1839.RAF',  size: HASH('a3f7') },
  { time: '10:42:19', kind: 'skipped',  file: 'DSCF1840.RAF — already present as 20260417_DSCF1840.RAF' },
  { time: '10:42:19', kind: 'skipped',  file: 'DSCF1840.xmp — already present as 20260417_DSCF1840.xmp' },
  { time: '10:42:20', kind: 'verified', file: 'DSCF1841.RAF → 20260417_104220_DSCF1841.RAF',  size: HASH('9d11') },
  { time: '10:42:21', kind: 'skipped',  file: 'DSCF1842.RAF — already present as 20260417_DSCF1842.RAF' },
  { time: '10:42:22', kind: 'verified', file: 'DSCF1843.RAF → 20260417_104222_DSCF1843.RAF',  size: HASH('5102') },
];

const SAMPLE_LOG_HALT = [
  { time: '10:42:00', kind: 'info',     file: 'Starting ingest: 482 bundles, 24.6 GB' },
  { time: '10:42:18', kind: 'verified', file: 'DSCF1839.RAF → 20260417_104218_DSCF1839.RAF',  size: HASH('a3f7') },
  { time: '10:42:19', kind: 'verified', file: 'DSCF1840.RAF → 20260417_104219_DSCF1840.RAF',  size: HASH('b428') },
  { time: '10:42:20', kind: 'error',    file: 'Verify mismatch on DSCF1841.RAF — destination copy deleted, original safe on card' },
  { time: '10:42:20', kind: 'error',    file: 'Halting job on verification mismatch.' },
];

// ─── Stable scaffold ────────────────────────────────────────────────────────
// Every state below renders inside the same scaffold so the engineer sees one
// shape repeatedly, not 15 different layouts.

function MainView({ tok, state, cards = SAMPLE_CARDS, days = SAMPLE_DAYS,
                    description = 'Iceland', primaryDest = '~/Pictures/PhotoDrop',
                    archiveDest = '' }) {
  const direction = tok.direction;
  const { t, type } = tok;
  const totals = SAMPLE_TOTALS(days);

  // Direction-aware leaf components
  const Preview    = direction === 'b' ? DB_Preview    : DA_Preview;
  const Progress   = direction === 'b' ? DB_Progress   : DA_Progress;
  const Completion = direction === 'b' ? DB_Completion : DA_Completion;

  // Subtitle in the title bar — matches detailSubtitle in MainView.swift
  let subtitle = '';
  switch (state) {
    case 'idle':            subtitle = ''; break;
    case 'scanning':        subtitle = '— · Scanning…'; break;
    case 'preview':         subtitle = `64.2 GB · ${fmt.int(totals.photos)} photos`; break;
    case 'first-run':       subtitle = `64.2 GB · ${fmt.int(totals.photos)} photos`; break;
    case 'ingesting':       subtitle = '64.2 GB · Ingesting 62%'; break;
    case 'ingesting-dupes': subtitle = '64.2 GB · Ingesting 48%'; break;
    case 'dual-dest':       subtitle = '64.2 GB · Ingesting 41% · 2 dests'; break;
    case 'completed':
    case 'completed-skips':
    case 'completed-errors':subtitle = '64.2 GB'; break;
    case 'cancelled':       subtitle = '64.2 GB · Cancelled'; break;
    case 'halted':          subtitle = '64.2 GB · Failed'; break;
  }

  // The detail pane content per state
  const detail = (() => {
    switch (state) {
      case 'idle':
        return <PDContentUnavailable tok={tok}
          systemImage="sdcard"
          title="No card selected"
          description="Insert a memory card to begin." />;

      case 'scanning':
        return <ScanningDetail tok={tok} />;

      case 'preview':
        return <Preview tok={tok} days={days} totals={totals} />;

      case 'first-run':
        return (
          <Preview tok={tok} days={days} totals={totals} />
        );

      case 'ingesting':
        return <Progress tok={tok} job={sampleJob({ log: SAMPLE_LOG })} />;

      case 'ingesting-dupes':
        return <Progress tok={tok} job={sampleJob({
          pct: 0.48, bundleI: 232, copiedGB: 11.8,
          skippedI: 12, log: SAMPLE_LOG_DUPES,
        })} />;

      case 'dual-dest':
        return <Progress tok={tok} job={sampleJob({
          pct: 0.41, mbs: 22.8, eta: 432, copiedGB: 10.1,
          archive: true,
          archiveName: '/Volumes/Backup/PhotoDrop',
          destPct: 0.68, archivePct: 0.41,
          log: SAMPLE_LOG,
        })} />;

      case 'completed':
      case 'completed-skips':
      case 'completed-errors':
        return (
          <SheetOverlay>
            <Preview tok={tok} days={days} totals={totals} />
            <Completion tok={tok} result={completionResult(state)} />
          </SheetOverlay>
        );

      case 'cancelled':
        return <PDContentUnavailable tok={tok}
          systemImage="xmark.octagon"
          title="Ingest cancelled"
          description="Partial files from the current bundle were rolled back. The 153 already-verified bundles are safe on disk."
          actions={<PDButton tok={tok} variant="borderedProminent">Reset</PDButton>}
        />;

      case 'halted':
        return <PDContentUnavailable tok={tok}
          systemImage="exclamationmark.triangle.fill"
          customGlyph={
            <div style={{ color: t.err, marginBottom: 4 }}>
              <Icon name="exclamationmark.triangle.fill" size={48} />
            </div>
          }
          title="Ingest failed"
          description="Halted: verification mismatch. The 219 already-verified bundles are safe on disk; the failing file is still on the card."
          actions={<PDButton tok={tok} variant="borderedProminent">Reset</PDButton>}
        />;

      default:
        return null;
    }
  })();

  // Inspector — STABLE across states (matches InspectorPane.swift, which
  // doesn't morph). The Ingest button disables based on canStart.
  const isRunning = ['ingesting', 'ingesting-dupes', 'dual-dest'].includes(state);
  const canIngest = state === 'preview';
  const ingestLabel = isRunning ? 'Ingesting…' : 'Ingest';
  const inspector = (
    <DA_Inspector tok={tok}
      dest={primaryDest}
      archive={archiveDest}
      description={description}
      verify
      eject={state !== 'first-run'}
      skipDupes
      canIngest={canIngest}
      ingestLabel={ingestLabel}
      hint={state === 'first-run'
        ? 'Pick a destination to enable Ingest. PhotoDrop will remember it for every card.'
        : null}
    />
  );

  const toolbar = (
    <>
      <PDToolbarButton tok={tok} icon="arrow.clockwise" label="Refresh" />
      <div style={{ width: 1, height: 18, background: tok.t.border, margin: '0 2px' }} />
      <PDToolbarButton tok={tok} icon="sidebar.right" label="Toggle Inspector" />
    </>
  );

  return (
    <PDWindow tok={tok} title={cards[0]?.name || 'PhotoDrop'} subtitle={subtitle} toolbar={toolbar} width={1100} height={720}>
      <PDSplit tok={tok}
        sidebar={<DA_Sidebar tok={tok} cards={cards} selectedId={cards[0]?.id} />}
        detail={detail}
        inspector={inspector}
        sidebarWidth={direction === 'b' ? 248 : 232}
        inspectorWidth={direction === 'b' ? 332 : 308}
      />
    </PDWindow>
  );
}

// SheetOverlay — preview underneath, completion sheet centered on top with
// a darkened backdrop. Matches `.sheet(item:)` in MainView.swift.
function SheetOverlay({ children }) {
  // children = [previewUnderlay, sheet]
  return (
    <div style={{ position: 'relative', width: '100%', height: '100%', overflow: 'hidden' }}>
      <div style={{ position: 'absolute', inset: 0 }}>{children[0]}</div>
      <div style={{
        position: 'absolute', inset: 0,
        background: 'rgba(0,0,0,0.18)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 24,
      }}>
        {children[1]}
      </div>
    </div>
  );
}

// ─── Sample job + result data ───────────────────────────────────────────────
function sampleJob(overrides = {}) {
  return {
    pct: 0.62,
    bundleI: 298, bundleN: 482,
    copiedGB: 15.2, totalGB: 24.6,
    mbs: 38.4, eta: 252,
    skippedI: 0,
    currentFile: '/Volumes/EOS R5 SD/DCIM/108_FUJI/DSCF1843.RAF',
    archive: false, destName: '~/Pictures/PhotoDrop', archiveName: null,
    destPct: undefined, archivePct: undefined,
    log: SAMPLE_LOG,
    ...overrides,
  };
}

function completionResult(state) {
  const base = {
    bundles: 482,
    copied: 482, copiedGB: 24.6,
    skipped: 0, failed: 0,
    elapsed: '10m 42s', mbs: 38.4,
    dest: '~/Pictures/PhotoDrop/2026/2026-04-17_Iceland',
    archive: null,
    wasEjected: true, halted: false, haltReason: null,
  };
  if (state === 'completed-skips')   return { ...base, copied: 466, skipped: 16 };
  if (state === 'completed-errors')  return { ...base, copied: 478, failed:  4, wasEjected: false };
  return base;
}

// ─── DA_Completion — completion sheet (Direction A) ─────────────────────────
// Wraps CompletionSheet.swift's layout: big seal-grid + headline + stats
// grid + actions. Width 480, looks like a real macOS sheet.
function DA_Completion({ tok, result }) {
  const { t, type, accent } = tok;
  const hadIssues = result.failed > 0;
  const title = hadIssues ? 'Ingest completed with errors' : 'Ingest complete';
  const subtitle = (
    hadIssues
      ? `${fmt.int(result.failed)} file${result.failed === 1 ? '' : 's'} failed — see log for details.`
      : result.copied === 0 && result.skipped > 0
      ? 'Everything was already there — nothing new to copy.'
      : result.skipped > 0
      ? `${fmt.int(result.copied)} copied, ${fmt.int(result.skipped)} already present.`
      : 'All files copied and verified.'
  );
  const ejectedLine = result.wasEjected ? ' Card ejected — safe to remove.' : '';

  return (
    <CompletionSheetCard tok={tok}>
      <div style={{ marginBottom: 4 }}>
        {hadIssues
          ? <Icon name="exclamationmark.octagon.fill" size={48} color={t.warn} />
          : <SealGrid tok={tok} progress={1} size={56} pulse />}
      </div>
      <div style={{ fontSize: 18, fontWeight: 600, color: t.text, letterSpacing: -0.2, marginTop: 8 }}>
        {title}
      </div>
      <div style={{ fontSize: 13, color: t.textSec, marginTop: 4, maxWidth: 360, textAlign: 'center', lineHeight: 1.4 }}>
        {subtitle}{ejectedLine}
      </div>

      <div style={{ marginTop: 18, marginBottom: 18 }}>
        <CompletionStats tok={tok} result={result} />
      </div>

      <div style={{ display: 'flex', gap: 10 }}>
        <PDButton tok={tok} variant="bordered">Open Log</PDButton>
        <PDButton tok={tok} variant="bordered">Show in Finder</PDButton>
        <PDButton tok={tok} variant="borderedProminent">Done</PDButton>
      </div>
    </CompletionSheetCard>
  );
}

// ─── DB_Completion — same data, more emotional typography ───────────────────
function DB_Completion({ tok, result }) {
  const { t, type, accent } = tok;
  const hadIssues = result.failed > 0;
  return (
    <CompletionSheetCard tok={tok}>
      <div style={{ marginBottom: 4 }}>
        {hadIssues
          ? <Icon name="exclamationmark.octagon.fill" size={56} color={t.warn} />
          : <StampMark tok={tok} progress={1} size={72} stamped />}
      </div>

      <div style={{
        marginTop: 14,
        fontFamily: type.display, fontSize: 30, fontWeight: 400,
        color: t.text, letterSpacing: -0.7, textAlign: 'center', lineHeight: 1.1,
        maxWidth: 380,
      }}>
        {hadIssues
          ? <>Done, <em style={{ fontStyle: 'italic' }}>but check a few.</em></>
          : result.skipped > 0
          ? <>Done. <em style={{ fontStyle: 'italic' }}>{fmt.int(result.copied)} new</em>, {fmt.int(result.skipped)} already there.</>
          : <>Done. <em style={{ fontStyle: 'italic' }}>All {fmt.int(result.copied)}</em> verified.</>}
      </div>

      {result.wasEjected && (
        <div style={{ marginTop: 6, fontSize: 13, color: t.textSec, display: 'flex', alignItems: 'center', gap: 4 }}>
          <Icon name="eject.fill" size={12} /> Card ejected — safe to remove
        </div>
      )}

      <div style={{ marginTop: 18, marginBottom: 18 }}>
        <CompletionStats tok={tok} result={result} />
      </div>

      <div style={{ display: 'flex', gap: 10 }}>
        <PDButton tok={tok} variant="bordered">Open Log</PDButton>
        <PDButton tok={tok} variant="bordered">Show in Finder</PDButton>
        <PDButton tok={tok} variant="borderedProminent">Done</PDButton>
      </div>
    </CompletionSheetCard>
  );
}

// Sheet chrome — both directions share it.
function CompletionSheetCard({ tok, children }) {
  const { t } = tok;
  return (
    <div style={{
      width: 480,
      background: t.panel,
      border: `0.5px solid ${t.borderHi}`,
      borderRadius: 10,
      padding: 28,
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      boxShadow: '0 22px 56px rgba(0,0,0,0.28), 0 0 0 0.5px rgba(0,0,0,0.05)',
    }}>{children}</div>
  );
}

// Stats grid matching CompletionSheet.swift's `Grid` block.
function CompletionStats({ tok, result }) {
  const { t, type } = tok;
  const row = (k, v) => (
    <>
      <div style={{ color: t.textSec, fontSize: 13, paddingRight: 16 }}>{k}</div>
      <div style={{ color: t.text, fontSize: 13, fontVariantNumeric: 'tabular-nums', fontFamily: type.body }}>{v}</div>
    </>
  );
  const filesLine = [
    `${result.copied} copied`,
    result.skipped ? `${result.skipped} skipped` : null,
    result.failed  ? `${result.failed} failed`  : null,
  ].filter(Boolean).join(', ');

  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: 'auto auto',
      rowGap: 6, columnGap: 0,
      padding: '0 4px',
    }}>
      {row('Files',   filesLine)}
      {row('Size',    fmt.size(result.copiedGB))}
      {row('Elapsed', result.elapsed)}
      {row('Speed',   fmt.mbs(result.mbs))}
    </div>
  );
}

// ─── Scanning detail — large spinner + label ────────────────────────────────
function ScanningDetail({ tok }) {
  const { t, type, accent } = tok;
  return (
    <div style={{
      height: '100%', display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center', gap: 14,
    }}>
      {/* Native-feeling spinner: 8 spokes fading, like NSProgressIndicator */}
      <div style={{ position: 'relative', width: 28, height: 28 }}>
        {Array.from({ length: 8 }).map((_, i) => (
          <div key={i} style={{
            position: 'absolute', top: 0, left: '50%',
            width: 2.5, height: 8, marginLeft: -1.25,
            background: accent.hex,
            borderRadius: 1.25,
            transformOrigin: '50% 14px',
            transform: `rotate(${i * 45}deg)`,
            opacity: 0.18 + (i / 8) * 0.8,
            animation: 'pd-spin 1s steps(8) infinite',
            animationDelay: `${(i / 8) * -1}s`,
          }} />
        ))}
        <style>{`@keyframes pd-spin { to { transform: rotate(360deg); } }`}</style>
      </div>
      <div style={{ fontSize: 13, color: t.textSec }}>Scanning card…</div>
    </div>
  );
}

Object.assign(window, {
  MainView, sampleJob, completionResult,
  DA_Completion, DB_Completion, CompletionSheetCard, CompletionStats,
  ScanningDetail, SheetOverlay,
});

// ─── App root ───────────────────────────────────────────────────────────────

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "dark": false,
  "accent": "blueClassic",
  "density": "comfortable"
}/*EDITMODE-END*/;

function App() {
  const [tw, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const dark    = !!tw.dark;
  const density = tw.density;
  const accent  = tw.accent in ACCENTS ? tw.accent : 'blueClassic';

  const tokA = makeTokens({ direction: 'a', dark, density, accentKey: accent });
  const tokB = makeTokens({ direction: 'b', dark, density, accentKey: accent });

  const states = [
    { id: 'idle',             label: '01 · Idle (no card)' },
    { id: 'scanning',         label: '02 · Scanning card' },
    { id: 'preview',          label: '03 · Preview ready' },
    { id: 'first-run',        label: '04 · First run · no destination' },
    { id: 'ingesting',        label: '05 · Ingesting · live progress' },
    { id: 'ingesting-dupes',  label: '06 · Ingesting · skipping duplicates' },
    { id: 'dual-dest',        label: '07 · Dual destination' },
    { id: 'completed',        label: '08 · Done (safe to remove)' },
    { id: 'completed-skips',  label: '09 · Done with skips' },
    { id: 'completed-errors', label: '10 · Done with errors' },
    { id: 'cancelled',        label: '11 · Cancelled' },
    { id: 'halted',           label: '12 · Halted (verify mismatch)' },
  ];

  // helpers for first-run + idle
  const cardsFor = (id) => (id === 'idle' || id === 'first-run') ? [] : SAMPLE_CARDS;
  const daysFor  = (id) => id === 'ingesting-dupes' || id === 'completed-skips' ? SAMPLE_DAYS_DUPES : SAMPLE_DAYS;
  const destFor  = (id) => id === 'first-run' ? '' : '~/Pictures/PhotoDrop';

  return (
    <>
      <DesignCanvas>
        <DCSection id="rationale"
          title="PhotoDrop · design rationale"
          subtitle="A polish pass on the SwiftUI app, plus a bolder alternative.">
          <DCArtboard id="ra" label="Rationale + plan" width={920} height={780}>
            <RationaleCard tok={tokA} />
          </DCArtboard>
        </DCSection>

        <DCSection id="dir-a"
          title="Direction A · Steady"
          subtitle="A faithful pass on the existing SwiftUI app — NavigationSplitView, SF Symbols, system accent. Three deliberate additions: a seal-grid verification mark, better empty-state voice, and a completion sheet that leads with 'safe to remove'.">
          {states.map((s) => (
            <DCArtboard key={s.id} id={`a-${s.id}`} label={s.label} width={1100} height={720} data-screen-label={s.label}>
              <MainView tok={tokA} state={s.id}
                cards={cardsFor(s.id)} days={daysFor(s.id)} primaryDest={destFor(s.id)} />
            </DCArtboard>
          ))}
          <DCArtboard id="a-menu-ready" label="13 · Menu bar · ready" width={780} height={520}>
            <MenuBarScene tok={tokA} state="ready" label="EOS R5 SD"
              subtitle="482 photos · 24.6 GB" />
          </DCArtboard>
          <DCArtboard id="a-menu-ingest" label="13b · Menu bar · ingesting" width={780} height={520}>
            <MenuBarScene tok={tokA} state="ingesting" label="EOS R5 SD"
              subtitle="Bundle 298 of 482 · 62%" secondary="38.4 MB/s · 4:12 left" badge="62%" />
          </DCArtboard>
          <DCArtboard id="a-menu-none" label="13c · Menu bar · no card" width={780} height={520}>
            <MenuBarScene tok={tokA} state="no-card" />
          </DCArtboard>
          <DCArtboard id="a-settings-gen" label="14a · Settings · General" width={520} height={420}>
            <SettingsPane tok={tokA} tab="general" />
          </DCArtboard>
          <DCArtboard id="a-settings-ing" label="14b · Settings · Ingest" width={520} height={420}>
            <SettingsPane tok={tokA} tab="ingest" />
          </DCArtboard>
          <DCArtboard id="a-settings-mb" label="14c · Settings · Menu Bar (proposed)" width={520} height={420}>
            <SettingsPane tok={tokA} tab="menubar" />
          </DCArtboard>
          <DCArtboard id="a-spec" label="Spec sheet · Steady" width={920} height={1080}>
            <SpecSheet tok={tokA} direction="a" />
          </DCArtboard>
        </DCSection>

        <DCSection id="dir-b"
          title="Direction B · Ledger"
          subtitle="Same SwiftUI bones, more opinionated chrome: a stamp-ring verification motif and Instrument Serif on the completion headline. The emotional moment lands differently.">
          {states.map((s) => (
            <DCArtboard key={s.id} id={`b-${s.id}`} label={s.label} width={1100} height={720} data-screen-label={s.label}>
              <MainView tok={tokB} state={s.id}
                cards={cardsFor(s.id)} days={daysFor(s.id)} primaryDest={destFor(s.id)} />
            </DCArtboard>
          ))}
          <DCArtboard id="b-menu-ready" label="13 · Menu bar · ready" width={780} height={520}>
            <MenuBarScene tok={tokB} state="ready" label="EOS R5 SD"
              subtitle="482 photos · 24.6 GB" />
          </DCArtboard>
          <DCArtboard id="b-spec" label="Spec sheet · Ledger" width={920} height={1080}>
            <SpecSheet tok={tokB} direction="b" />
          </DCArtboard>
        </DCSection>
      </DesignCanvas>

      <TweaksPanel title="PhotoDrop · Tweaks">
        <TweakSection label="Apple silicone blues" />
        <TweakColor label="Pick the case"
          value={ACCENTS[accent].hex}
          options={['#1c5cdb', '#4577d1', '#6678c2', '#3f5872']}
          onChange={(hex) => {
            const k = Object.keys(ACCENTS).find((key) => ACCENTS[key].hex === hex);
            if (k) setTweak('accent', k);
          }} />
        <div style={{ fontSize: 11, color: 'rgba(41,38,27,.55)', lineHeight: 1.45, marginTop: -4 }}>
          Left → right: Cobalt (12 mini) · Classic (15) · Ultramarine (16) · Denim (16). Currently <strong>{ACCENTS[accent].name}</strong>.
        </div>

        <TweakSection label="Other accents" />
        <TweakColor label="System swatches"
          value={ACCENTS[accent].hex}
          options={['#0a7aff', '#953dff', '#34b860', '#878d97']}
          onChange={(hex) => {
            const k = Object.keys(ACCENTS).find((key) => ACCENTS[key].hex === hex);
            if (k) setTweak('accent', k);
          }} />

        <TweakSection label="Appearance" />
        <TweakToggle label="Dark mode" value={dark} onChange={(v) => setTweak('dark', v)} />

        <TweakSection label="Density" />
        <TweakRadio label="Density" value={density} options={['compact', 'comfortable']}
          onChange={(v) => setTweak('density', v)} />

        <TweakSection label="Tips" />
        <div style={{ fontSize: 11, color: 'rgba(41,38,27,.55)', lineHeight: 1.45 }}>
          Click the expand arrow on any artboard to enter full-screen focus mode — ←/→ then cycles every state in that direction.
        </div>
      </TweaksPanel>
    </>
  );
}

// ─── RationaleCard — the manager's read-me ──────────────────────────────────
function RationaleCard({ tok }) {
  const { t, type, accent } = tok;
  const Block = ({ k, children }) => (
    <div style={{ display: 'grid', gridTemplateColumns: '180px 1fr', gap: 18, padding: '12px 0', borderBottom: `0.5px solid ${t.border}` }}>
      <div style={{ fontSize: 11, fontWeight: 600, color: t.textSec, letterSpacing: '0.04em', textTransform: 'uppercase' }}>{k}</div>
      <div style={{ fontSize: 13.5, color: t.text, lineHeight: 1.55 }}>{children}</div>
    </div>
  );
  const Code = ({ children }) => (
    <span style={{ fontFamily: type.mono, fontSize: 12, padding: '1px 5px', borderRadius: 3, background: tok.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)', color: t.text }}>{children}</span>
  );
  return (
    <div style={{
      padding: 44, background: t.bg, color: t.text,
      fontFamily: type.body, height: '100%', overflowY: 'auto',
    }}>
      <div style={{ fontSize: 11, letterSpacing: '0.12em', textTransform: 'uppercase', color: t.textMute }}>PhotoDropMac · design exploration</div>
      <div style={{
        fontFamily: type.display, fontSize: 38, fontWeight: 500, color: t.text,
        letterSpacing: -1.1, marginTop: 6, lineHeight: 1.05,
      }}>
        A polish pass on the SwiftUI<br />— plus a slightly bolder alternative.
      </div>
      <div style={{ fontSize: 14, color: t.textSec, marginTop: 14, lineHeight: 1.55, maxWidth: 640 }}>
        Rooted in the real codebase (<Code>tsvb/PhotoDropMac</Code>). Direction A is what the app could look
        like with three small additions; Direction B is a louder take that keeps the same SwiftUI bones but lets a
        serif and a stamp do some of the emotional work.
      </div>

      <div style={{ marginTop: 28 }}>
        <Block k="Same scaffold">
          Both directions use <Code>NavigationSplitView</Code> with <Code>.inspector()</Code>, a unified toolbar
          (Refresh + Inspector toggle), <Code>List(selection:) .listStyle(.sidebar)</Code> for cards, and
          the same <Code>@AppStorage</Code> keys (<Code>primaryDestination</Code>, <Code>verifyCopies</Code>, …).
          Nothing here invents a new IA — it's all implementable from the existing files.
        </Block>

        <Block k="Verification, made legible">
          The current app draws <Code>checkmark.seal.fill</Code> on completion — fine, but the same glyph as a
          million Mac apps. Both directions replace it with a custom motif that fills <em>in proportion to verified bundles</em>:
          a 4×4 seal grid in Steady, a 24-tick stamp ring in Ledger. The mark is the same component everywhere it
          appears (sidebar, progress, completion sheet) so the app's "trust" signal has a single, recognizable shape.
        </Block>

        <Block k="Voice changes">
          Where the brief says checkmarks feel generic, the copy carries the trust instead — every progress + completion
          state shows an xxHash signature on each verified file (e.g. <Code>a3f7…7fa3</Code>) in the log. The
          completion sheet leads with "safe to remove" when the card was ejected; the failure sheet leads with what
          was preserved before what failed. No "errors never your fault" theatrics — just facts and a next step.
        </Block>

        <Block k="What's different in B">
          Same fields, same flows, same toolbar. Different feel via three switches:
          <ul style={{ paddingLeft: 18, marginTop: 6, lineHeight: 1.7 }}>
            <li>Verification motif → stamp ring instead of seal grid.</li>
            <li>Year header + completion headline → Instrument Serif (one moment of warmth).</li>
            <li>Preview rows reformat: date in mono, description in serif italic, like a journal entry.</li>
          </ul>
        </Block>

        <Block k="What I'd raise with engineering">
          <ol style={{ paddingLeft: 18, margin: 0, lineHeight: 1.7 }}>
            <li>The inspector currently shows <Code>"Verify copies with xxHash"</Code> — strong and specific. I leaned into it
              (the hash signature lives in the log). Worth keeping that exact label.</li>
            <li><Code>CompletionSheet</Code>'s "Everything was already there" copy is great — I kept it verbatim.</li>
            <li>Cancelled / Failed are <Code>ContentUnavailableView</Code> with a Reset button. I made the description more
              informative (how many bundles were verified, where they are) without growing the component.</li>
            <li>The menu bar currently has no "one-click ingest" — I drew it as a future option (in Settings · Menu Bar,
              behind an off-by-default toggle). Mention this in your next planning round.</li>
            <li>Dual destination shows in the progress card via two destination tiles below the bar — derived from the
              existing <Code>archiveDestination</Code> string. Zero new state.</li>
          </ol>
        </Block>
      </div>

      <div style={{
        marginTop: 28, paddingTop: 20,
        borderTop: `0.5px solid ${t.border}`,
        fontSize: 11.5, color: t.textMute, lineHeight: 1.5,
      }}>
        Tweaks panel: dark mode · system accent (5 macOS swatches) · density. Every artboard re-renders live.
      </div>
    </div>
  );
}

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);
