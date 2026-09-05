// settings.jsx — Preferences window.
// Matches the real SettingsView.swift: a TabView with General + Ingest tabs,
// each one a `Form .formStyle(.grouped)` of `Section { Toggle/TextField }`.
// We add a Menu Bar tab to expose the (currently-implicit) menu bar
// preferences as a design proposal — flagged in the spec sheet.

function SettingsPane({ tok, tab = 'general' }) {
  const { t, type } = tok;
  const Tab = ({ id, icon, label }) => {
    const active = tab === id;
    return (
      <div style={{
        padding: '6px 12px 7px',
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
        background: active ? (tok.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.07)') : 'transparent',
        borderRadius: 6,
        color: active ? t.text : t.textSec,
        minWidth: 60, cursor: 'default',
      }}>
        <Icon name={icon} size={18} />
        <span style={{ fontSize: 11, fontWeight: 400, letterSpacing: -0.1 }}>{label}</span>
      </div>
    );
  };
  return (
    <PDWindow tok={tok} title="PhotoDrop Settings" width={520} height={420}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', height: '100%' }}>
        {/* TabView header — three tabs centered, vibrant chrome */}
        <div style={{
          padding: '4px 8px 6px',
          display: 'flex', justifyContent: 'center', gap: 2,
          background: t.chrome,
          borderBottom: `0.5px solid ${t.border}`,
        }}>
          <Tab id="general" icon="gearshape" label="General" />
          <Tab id="ingest"  icon="square.and.arrow.down" label="Ingest" />
          <Tab id="menubar" icon="sdcard.fill" label="Menu Bar" />
        </div>

        <div style={{ flex: 1, overflowY: 'auto', background: tok.dark ? '#252527' : '#eeeef0' }}>
          {tab === 'general' && <SettingsGeneral tok={tok} />}
          {tab === 'ingest'  && <SettingsIngest tok={tok} />}
          {tab === 'menubar' && <SettingsMenuBar tok={tok} />}
        </div>
      </div>
    </PDWindow>
  );
}

// ─── General tab — destinations ─────────────────────────────────────────────
function SettingsGeneral({ tok }) {
  return (
    <PDForm tok={tok}>
      <PDFormSection tok={tok} title="Destinations" hint="PhotoDrop remembers these between runs — you only set them once.">
        <PDFormRow tok={tok} label="Primary library">
          <PDPathField tok={tok} value="~/Pictures/PhotoDrop" placeholder="Choose folder…" />
        </PDFormRow>
        <PDFormRow tok={tok} label="Archive copy" hint="Optional second destination — verified independently" isLast>
          <PDPathField tok={tok} value="" placeholder="Second copy location" />
        </PDFormRow>
      </PDFormSection>
    </PDForm>
  );
}

// ─── Ingest tab — defaults applied to every job ─────────────────────────────
function SettingsIngest({ tok }) {
  return (
    <PDForm tok={tok}>
      <PDFormSection tok={tok} title="Defaults"
        hint="Applied to every job, overridable per-ingest in the inspector.">
        <PDFormRow tok={tok} label="Verify copies with xxHash" hint="Hash-check every byte after copy — recommended.">
          <SettingsToggle tok={tok} on />
        </PDFormRow>
        <PDFormRow tok={tok} label="Eject card when finished">
          <SettingsToggle tok={tok} on={false} />
        </PDFormRow>
        <PDFormRow tok={tok} label="Show completion summary" isLast>
          <SettingsToggle tok={tok} on />
        </PDFormRow>
      </PDFormSection>
    </PDForm>
  );
}

// ─── Menu Bar tab — proposed (not yet in the code) ──────────────────────────
function SettingsMenuBar({ tok }) {
  const { t } = tok;
  return (
    <PDForm tok={tok}>
      <PDFormSection tok={tok} title="Menu bar status"
        hint="Many users live in the menu bar — these controls keep that path one-click.">
        <PDFormRow tok={tok} label="Show in menu bar">
          <SettingsSegmented tok={tok} options={['Always', 'With card', 'Hidden']} value="Always" />
        </PDFormRow>
        <PDFormRow tok={tok} label="Auto-open window when a card arrives" hint="Matches PhotoDropMacApp.swift's openWindow(id: 'main') on mount.">
          <SettingsToggle tok={tok} on />
        </PDFormRow>
        <PDFormRow tok={tok} label="One-click ingest from menu bar"
          hint="Uses the primary destination + your defaults — still verifies." isLast>
          <SettingsToggle tok={tok} on={false} />
        </PDFormRow>
      </PDFormSection>

      <div style={{
        fontSize: 11, color: t.textSec, padding: '4px 8px', lineHeight: 1.4,
      }}>
        Proposed — not yet wired in the code. Add as new <code style={{ fontFamily: 'ui-monospace' }}>@AppStorage</code> keys
        on the existing trio (MainView, InspectorPane, SettingsView).
      </div>
    </PDForm>
  );
}

// ─── Toggle + Segmented control matching macOS Form ─────────────────────────
function SettingsToggle({ tok, on }) {
  const { t, accent } = tok;
  return (
    <div style={{
      position: 'relative', width: 30, height: 18, borderRadius: 999,
      background: on ? accent.hex : (tok.dark ? 'rgba(255,255,255,0.14)' : 'rgba(120,120,128,0.32)'),
      transition: 'background .12s',
      flexShrink: 0,
    }}>
      <div style={{
        position: 'absolute', top: 1.5, left: on ? 13.5 : 1.5,
        width: 15, height: 15, borderRadius: '50%', background: '#fff',
        boxShadow: '0 1px 2px rgba(0,0,0,0.2), 0 0 0 0.5px rgba(0,0,0,0.05)',
        transition: 'left .14s ease',
      }} />
    </div>
  );
}

function SettingsSegmented({ tok, options, value }) {
  const { t } = tok;
  return (
    <div style={{
      display: 'inline-flex', padding: 2, gap: 1,
      background: tok.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.06)',
      borderRadius: 5,
    }}>
      {options.map((o) => (
        <div key={o} style={{
          padding: '3px 12px', borderRadius: 4,
          background: o === value ? (tok.dark ? '#3a3a3c' : '#ffffff') : 'transparent',
          color: o === value ? t.text : t.textSec,
          fontSize: 12, fontWeight: o === value ? 500 : 400,
          boxShadow: o === value ? '0 1px 2px rgba(0,0,0,0.10), 0 0 0 0.5px rgba(0,0,0,0.06)' : 'none',
          cursor: 'default',
        }}>{o}</div>
      ))}
    </div>
  );
}

Object.assign(window, {
  SettingsPane, SettingsGeneral, SettingsIngest, SettingsMenuBar,
  SettingsToggle, SettingsSegmented,
});
