// spec-sheet.jsx — design-system reference per direction.
// Same primitives the engineer is already using in the codebase, so
// every value here is implementable verbatim.

function SpecSheet({ tok, direction }) {
  const { t, type, accent } = tok;
  const isB = direction === 'b';
  return (
    <div style={{
      width: '100%', height: '100%',
      padding: 36, overflowY: 'auto',
      background: t.bg, color: t.text,
      fontFamily: type.body, fontSize: 12.5, lineHeight: 1.45,
    }}>
      <div style={{ marginBottom: 26 }}>
        <div style={{ fontSize: 10, color: t.textMute, letterSpacing: '0.1em', textTransform: 'uppercase' }}>Spec sheet</div>
        <div style={{
          fontFamily: type.display, fontSize: 32, fontWeight: isB ? 400 : 600,
          letterSpacing: -0.6, marginTop: 4, fontStyle: isB ? 'italic' : 'normal',
        }}>
          {isB ? 'Direction B · Ledger' : 'Direction A · Steady'}
        </div>
        <div style={{ color: t.textSec, fontSize: 13, marginTop: 6, maxWidth: 540, lineHeight: 1.5 }}>
          {isB
            ? 'Same SwiftUI bones; a stamp-ring verification mark and an Instrument Serif headline carry one moment of warmth.'
            : 'Native to the existing codebase. SF Pro everywhere, SF Symbols, system accent. Verification mark is the only invented motif.'}
        </div>
      </div>

      <SS_Section title="Verification mark">
        <div style={{ display: 'flex', gap: 24, alignItems: 'center', padding: '6px 0 14px' }}>
          {isB ? (
            <>
              <StampMark tok={tok} progress={0}     size={56} />
              <StampMark tok={tok} progress={0.4}   size={56} />
              <StampMark tok={tok} progress={0.75}  size={56} />
              <StampMark tok={tok} progress={1}     size={56} stamped />
            </>
          ) : (
            <>
              <SealGrid tok={tok} progress={0}      size={56} />
              <SealGrid tok={tok} progress={0.3}    size={56} />
              <SealGrid tok={tok} progress={0.7}    size={56} />
              <SealGrid tok={tok} progress={1}      size={56} pulse />
            </>
          )}
          <div style={{ fontSize: 12.5, color: t.textSec, lineHeight: 1.5, maxWidth: 300 }}>
            {isB
              ? 'A 24-tick ring fills clockwise as bundles verify. The center shows live percent during ingest, then stamps with the accent-color check on completion.'
              : 'A 4×4 grid fills cell-by-cell as bundles verify. The last cell pulses once on completion. Reads as a mechanical seal — more trustworthy than the generic checkmark.seal.fill.'}
          </div>
        </div>
      </SS_Section>

      <SS_Section title="Type scale">
        <SS_Type tok={tok} label="display / 30"   text="All 482 verified."
          style={{ fontFamily: type.display, fontSize: 30, fontWeight: isB ? 400 : 600, letterSpacing: -0.7 }} />
        <SS_Type tok={tok} label="title / 17"     text="Ingesting… 62%"
          style={{ fontFamily: type.body, fontSize: 17, fontWeight: 600 }} />
        <SS_Type tok={tok} label="headline / 15"  text="Preview" style={{ fontSize: 15, fontWeight: 600 }} />
        <SS_Type tok={tok} label="body / 13"      text="Verify copies with xxHash" style={{ fontSize: 13 }} />
        <SS_Type tok={tok} label="subheadline / 12.5" text="Bundle 298 of 482 · 38.4 MB/s · 4:12 left"
          style={{ fontSize: 12.5, color: t.textSec, fontVariantNumeric: 'tabular-nums' }} />
        <SS_Type tok={tok} label="caption / 11"   text="64.2 GB · 482 photos" style={{ fontSize: 11, color: t.textSec }} />
        <SS_Type tok={tok} label="mono / 12"      text="DSCF1839.RAF [a3f7…7fa3]"
          style={{ fontFamily: type.mono, fontSize: 12, fontVariantNumeric: 'tabular-nums' }} />
        <SS_Type tok={tok} label="micro / 10.5"   text="VERIFIED"
          style={{ fontSize: 10.5, fontWeight: 600, letterSpacing: '0.05em', textTransform: 'uppercase', color: t.textMute }} />
      </SS_Section>

      <SS_Section title="Color tokens">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 10 }}>
          <SS_Swatch tok={tok} label="text"      sample={{ bg: t.panel,    fg: t.text }} value="primary" />
          <SS_Swatch tok={tok} label="textSec"   sample={{ bg: t.panel,    fg: t.textSec }} value="secondary" />
          <SS_Swatch tok={tok} label="textMute"  sample={{ bg: t.panel,    fg: t.textMute }} value="tertiary" />
          <SS_Swatch tok={tok} label="bg"        sample={{ bg: t.bg,       fg: t.textSec }} value="window" />
          <SS_Swatch tok={tok} label="sidebar"   sample={{ bg: t.sidebar,  fg: t.text }} value="sidebar" />

          <SS_Swatch tok={tok} label="accent"    sample={{ bg: accent.hex, fg: '#fff' }} value={accent.name} />
          <SS_Swatch tok={tok} label="ok"        sample={{ bg: t.okSoft,   fg: t.ok }} value="verified" />
          <SS_Swatch tok={tok} label="skip"      sample={{ bg: t.skipSoft, fg: t.skip }} value="skipped" />
          <SS_Swatch tok={tok} label="warn"      sample={{ bg: t.warnSoft, fg: t.warn }} value="warning" />
          <SS_Swatch tok={tok} label="err"       sample={{ bg: t.errSoft,  fg: t.err }} value="error" />
        </div>
        <div style={{ fontSize: 11.5, color: t.textMute, marginTop: 10, lineHeight: 1.5 }}>
          Resolves to system semantic colors at runtime —
          <code style={{ fontFamily: type.mono, marginLeft: 4 }}>Color.primary</code>,
          <code style={{ fontFamily: type.mono, marginLeft: 4 }}>.secondary</code>,
          <code style={{ fontFamily: type.mono, marginLeft: 4 }}>Color.accentColor</code>,
          <code style={{ fontFamily: type.mono, marginLeft: 4 }}>.green</code> / <code style={{ fontFamily: type.mono }}>.orange</code> / <code style={{ fontFamily: type.mono }}>.red</code>.
        </div>
      </SS_Section>

      <SS_Section title="Buttons">
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <PDButton tok={tok} variant="borderedProminent" size="large">Ingest</PDButton>
          <PDButton tok={tok} variant="borderedProminent">Ingest</PDButton>
          <PDButton tok={tok} variant="bordered">Cancel</PDButton>
          <PDButton tok={tok} variant="bordered" size="small">Cancel</PDButton>
          <PDButton tok={tok} variant="borderless">Show in Finder</PDButton>
          <PDButton tok={tok} variant="bordered" role="destructive">Stop</PDButton>
          <PDButton tok={tok} variant="bordered" disabled>Disabled</PDButton>
        </div>
        <div style={{ fontSize: 11.5, color: t.textMute, marginTop: 10, lineHeight: 1.5 }}>
          Maps to <code style={{ fontFamily: type.mono }}>.buttonStyle(.borderedProminent)</code>,
          {' '}<code style={{ fontFamily: type.mono }}>.bordered</code>, <code style={{ fontFamily: type.mono }}>.borderless</code>. Sizes: <code style={{ fontFamily: type.mono }}>.small</code> / <code style={{ fontFamily: type.mono }}>.regular</code> / <code style={{ fontFamily: type.mono }}>.large</code>.
        </div>
      </SS_Section>

      <SS_Section title="Log row">
        <div style={{
          background: t.panel, border: `0.5px solid ${t.border}`, borderRadius: 8,
          padding: '8px 12px', display: 'flex', flexDirection: 'column', gap: 2,
        }}>
          <DA_LogRow tok={tok} entry={{ time: '10:42:18', kind: 'verified', file: 'DSCF1839.RAF → 20260417_104218_DSCF1839.RAF', size: '[a3f7…7fa3]' }} />
          <DA_LogRow tok={tok} entry={{ time: '10:42:19', kind: 'skipped',  file: 'DSCF1840.RAF — already present as 20260417_DSCF1840.RAF' }} />
          <DA_LogRow tok={tok} entry={{ time: '10:42:19', kind: 'copied',   file: 'DSCF1841.RAF → 20260417_104219_DSCF1841.RAF' }} />
          <DA_LogRow tok={tok} entry={{ time: '10:42:20', kind: 'error',    file: 'Verify mismatch on DSCF1842.RAF — destination copy deleted' }} />
          <DA_LogRow tok={tok} entry={{ time: '10:42:20', kind: 'info',     file: 'Halting job on verification mismatch.' }} />
        </div>
        <div style={{ fontSize: 11.5, color: t.textMute, marginTop: 10, lineHeight: 1.5 }}>
          One SF Symbol + monospaced line, color by kind — same shape as <code style={{ fontFamily: type.mono }}>LogView</code> in ProgressPane.swift. The xxHash signature on every verified line is the trust signal.
        </div>
      </SS_Section>

      <SS_Section title="Voice">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <SS_Voice tok={tok} k="Idle"          v="No card selected — Insert a memory card to begin." />
          <SS_Voice tok={tok} k="First run"     v="Pick a destination to enable Ingest. PhotoDrop will remember it for every card." />
          <SS_Voice tok={tok} k="Done · clean"  v="Ingest complete — All files copied and verified. Card ejected — safe to remove." />
          <SS_Voice tok={tok} k="Done · skips"  v="478 copied, 12 already present. Card ejected — safe to remove." />
          <SS_Voice tok={tok} k="Done · errors" v="Ingest completed with errors — 4 files failed; see log for details." />
          <SS_Voice tok={tok} k="Cancelled"     v="Partial files from the current bundle were rolled back. 153 already-verified bundles are safe on disk." />
          <SS_Voice tok={tok} k="Halted"        v="Halted: verification mismatch. 219 already-verified bundles are safe on disk; the failing file is still on the card." />
          <SS_Voice tok={tok} k="Empty card"    v="No photos found — This card has no recognized photo files." />
        </div>
      </SS_Section>

      <SS_Section title="Iconography">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(8, 1fr)', gap: 14 }}>
          {[
            'sdcard.fill','eject.fill','externaldrive.fill','shippingbox','folder.fill','folder','calendar','photo',
            'checkmark.seal.fill','arrow.down.doc','arrow.right.doc','info.circle','exclamationmark.triangle.fill','xmark.octagon','arrow.clockwise','gearshape',
          ].map((n) => (
            <div key={n} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, color: t.textSec }}>
              <Icon name={n} size={20} />
              <span style={{ fontSize: 9.5, fontFamily: type.mono, color: t.textMute, textAlign: 'center' }}>{n}</span>
            </div>
          ))}
        </div>
        <div style={{ fontSize: 11.5, color: t.textMute, marginTop: 10, lineHeight: 1.5 }}>
          All names are real SF Symbol identifiers — pass directly to <code style={{ fontFamily: type.mono }}>Image(systemName:)</code>.
        </div>
      </SS_Section>

      <SS_Section title="Layout">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 14 }}>
          <SS_Pair tok={tok} k="Window"        v="1020 × 700 (matches PhotoDropMacApp.swift)" />
          <SS_Pair tok={tok} k="Sidebar"       v={isB ? '248pt' : '232pt'} />
          <SS_Pair tok={tok} k="Inspector"     v={`${isB ? 332 : 308}pt · isPresented binding`} />
          <SS_Pair tok={tok} k="List style"    v=".listStyle(.sidebar) / .inset" />
          <SS_Pair tok={tok} k="Form style"    v=".formStyle(.grouped) — settings" />
          <SS_Pair tok={tok} k="Toolbar"       v=".windowToolbarStyle(.unified) · 38pt" />
          <SS_Pair tok={tok} k="Sheet width"   v="480pt · radius 10" />
          <SS_Pair tok={tok} k="Hairline"      v="0.5pt · separator color" />
        </div>
      </SS_Section>

      <SS_Section title="State map (matches Copier.state)">
        <div style={{ background: t.panel, border: `0.5px solid ${t.border}`, borderRadius: 8, overflow: 'hidden' }}>
          {[
            ['idle',                  'PreviewTree / ContentUnavailableView · inspector enabled'],
            ['running(progress)',     'ProgressPane + LogView · inspector disabled'],
            ['completed(result)',     'PreviewTree below + CompletionSheet over (.sheet item:)'],
            ['cancelled',             'ContentUnavailableView "Ingest cancelled" + Reset'],
            ['failed(msg)',           'ContentUnavailableView "Ingest failed" + Reset'],
          ].map((row, i) => (
            <div key={row[0]} style={{
              display: 'grid', gridTemplateColumns: '220px 1fr',
              padding: '10px 14px',
              borderBottom: i < 4 ? `0.5px solid ${t.border}` : 'none',
            }}>
              <code style={{ fontFamily: type.mono, fontSize: 11.5, color: t.text }}>.{row[0]}</code>
              <span style={{ fontSize: 12.5, color: t.textSec }}>{row[1]}</span>
            </div>
          ))}
        </div>
      </SS_Section>
    </div>
  );
}

function SS_Section({ title, children }) {
  return (
    <div style={{ marginBottom: 30 }}>
      <div style={{
        fontSize: 11, fontWeight: 600, letterSpacing: '0.08em',
        textTransform: 'uppercase', color: 'rgba(0,0,0,0.55)',
        marginBottom: 12,
      }}>{title}</div>
      {children}
    </div>
  );
}

function SS_Type({ tok, label, text, style }) {
  const { t, type } = tok;
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '130px 1fr',
      gap: 14, alignItems: 'baseline', padding: '6px 0',
      borderBottom: `0.5px dashed ${t.border}`,
    }}>
      <div style={{ fontSize: 10.5, color: t.textMute, fontFamily: type.mono }}>{label}</div>
      <div style={style}>{text}</div>
    </div>
  );
}

function SS_Swatch({ tok, label, value, sample }) {
  const { t, type } = tok;
  return (
    <div>
      <div style={{
        height: 56, borderRadius: 6,
        background: sample.bg, color: sample.fg,
        border: `0.5px solid ${t.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 11, fontWeight: 500,
      }}>{value}</div>
      <div style={{ fontSize: 10.5, color: t.textMute, fontFamily: type.mono, marginTop: 4 }}>{label}</div>
    </div>
  );
}

function SS_Pair({ tok, k, v }) {
  const { t, type } = tok;
  return (
    <div style={{
      display: 'flex', justifyContent: 'space-between',
      borderBottom: `0.5px dashed ${t.border}`, padding: '6px 0',
    }}>
      <span style={{ color: t.textSec }}>{k}</span>
      <span style={{ fontFamily: type.mono, fontSize: 12, color: t.text }}>{v}</span>
    </div>
  );
}

function SS_Voice({ tok, k, v }) {
  const { t, type } = tok;
  return (
    <div style={{
      background: t.panel, border: `0.5px solid ${t.border}`,
      padding: '10px 12px', borderRadius: 6,
    }}>
      <div style={{
        fontSize: 10, color: t.textMute, fontFamily: type.mono,
        letterSpacing: '0.05em', textTransform: 'uppercase', marginBottom: 4,
      }}>{k}</div>
      <div style={{ fontSize: 13, color: t.text, lineHeight: 1.4 }}>{v}</div>
    </div>
  );
}

Object.assign(window, { SpecSheet });
