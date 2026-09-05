// menu-bar.jsx — native-style MenuBarExtra dropdown.
// Mirrors the real `MenuBarMenu.swift` shape: a plain menu list with the
// primary "Ingest from {Label}…" action, then standard app items. No
// custom popover chrome — this is just SwiftUI's `Menu` styling rendered
// faithfully.

function MenuBarMenu({ tok, state = 'ready', label = 'EOS R5 SD', subtitle, secondary }) {
  const { t, type, accent } = tok;
  // The menu width matches AppKit's NSMenu — about 280pt with a 6pt
  // inner pad. Items are 22pt high with a single-line label.
  return (
    <div style={{
      width: 280,
      background: tok.dark ? 'rgba(40,40,42,0.92)' : 'rgba(246,246,247,0.92)',
      backdropFilter: 'blur(40px) saturate(180%)',
      WebkitBackdropFilter: 'blur(40px) saturate(180%)',
      border: `0.5px solid ${tok.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.14)'}`,
      borderRadius: 8,
      padding: '5px 0',
      color: t.text,
      fontFamily: type.body, fontSize: 13,
      boxShadow: '0 16px 48px rgba(0,0,0,0.22), 0 2px 4px rgba(0,0,0,0.10)',
    }}>
      {state === 'no-card' ? (
        <>
          <MBItem tok={tok}>Open PhotoDrop</MBItem>
          <MBStatic tok={tok}>No card inserted</MBStatic>
        </>
      ) : (
        <>
          <MBItem tok={tok} primary shortcut="⌘I">Ingest from {label}…</MBItem>
          {subtitle && <MBStatic tok={tok}>{subtitle}</MBStatic>}
          {secondary && <MBStatic tok={tok}>{secondary}</MBStatic>}
        </>
      )}

      <MBSeparator tok={tok} />
      <MBItem tok={tok} shortcut="⌘,">Preferences…</MBItem>
      <MBSeparator tok={tok} />
      <MBItem tok={tok}>About PhotoDrop</MBItem>
      <MBItem tok={tok} shortcut="⌘Q">Quit PhotoDrop</MBItem>
    </div>
  );
}

function MBItem({ tok, children, shortcut, primary, disabled }) {
  const { t, type } = tok;
  return (
    <div style={{
      padding: '3px 16px 3px 22px',
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      color: disabled ? t.textFaint : t.text,
      fontSize: 13,
      fontWeight: primary ? 500 : 400,
      cursor: 'default',
      minHeight: 22,
      lineHeight: 1.2,
    }}>
      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{children}</span>
      {shortcut && (
        <span style={{
          fontSize: 13, color: t.textMute,
          fontFamily: type.body, fontVariantNumeric: 'tabular-nums',
          marginLeft: 16, letterSpacing: 0.5,
        }}>{shortcut}</span>
      )}
    </div>
  );
}

function MBStatic({ tok, children }) {
  const { t } = tok;
  return (
    <div style={{
      padding: '3px 16px 3px 22px',
      fontSize: 13, color: t.textSec,
      minHeight: 22, lineHeight: 1.2,
      cursor: 'default',
      display: 'flex', alignItems: 'center',
    }}>{children}</div>
  );
}

function MBSeparator({ tok }) {
  return (
    <div style={{
      height: 1, margin: '5px 8px',
      background: tok.dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.10)',
    }} />
  );
}

// MenuBarScene — places the dropdown under a stylized macOS menu bar so
// it reads as the real OS surface, not a free-floating popover.
function MenuBarScene({ tok, state = 'ready', label = 'EOS R5 SD',
                        subtitle, secondary, badge }) {
  const { t, type, accent } = tok;
  return (
    <div style={{
      width: '100%', height: '100%',
      // Subtle vertical desktop gradient
      background: tok.dark
        ? 'linear-gradient(180deg, #1a1d22 0%, #20242b 40%, #161a1f 100%)'
        : 'linear-gradient(180deg, #c8d3e1 0%, #d8e0eb 30%, #e3ebf3 60%, #eef2f7 100%)',
      fontFamily: type.body,
      position: 'relative', overflow: 'hidden',
    }}>
      {/* fake menu bar */}
      <div style={{
        height: 26,
        background: tok.dark ? 'rgba(28,28,30,0.62)' : 'rgba(252,252,254,0.62)',
        backdropFilter: 'blur(22px) saturate(180%)',
        WebkitBackdropFilter: 'blur(22px) saturate(180%)',
        borderBottom: `0.5px solid ${tok.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.08)'}`,
        display: 'flex', alignItems: 'center', padding: '0 12px', gap: 16,
        fontSize: 13, color: t.text,
      }}>
        {/* Apple logo placeholder */}
        <svg width="13" height="14" viewBox="0 0 13 14" style={{ opacity: 0.9 }}>
          <path d="M9.6 7.4c0-1.9 1.5-2.8 1.6-2.8-0.9-1.3-2.2-1.5-2.7-1.5-1.2-0.1-2.3 0.7-2.8 0.7-0.6 0-1.5-0.7-2.5-0.7-1.3 0-2.5 0.8-3.1 1.9-1.3 2.3-0.3 5.7 1 7.6 0.6 0.9 1.3 1.9 2.3 1.9 0.9 0 1.3-0.6 2.4-0.6 1.1 0 1.4 0.6 2.4 0.6 1 0 1.6-0.9 2.2-1.9 0.7-1.1 1-2.1 1-2.2 0 0-2-0.8-2-3z M8 1.8c0.5-0.6 0.8-1.4 0.7-2.2-0.7 0-1.5 0.4-2 1-0.5 0.5-0.9 1.4-0.8 2.1 0.8 0.1 1.6-0.4 2.1-0.9z" fill={t.text}/>
        </svg>
        <span style={{ fontWeight: 700 }}>PhotoDrop</span>
        <span style={{ opacity: 0.7 }}>File</span>
        <span style={{ opacity: 0.7 }}>Edit</span>
        <span style={{ opacity: 0.7 }}>View</span>
        <span style={{ opacity: 0.7 }}>Window</span>
        <span style={{ opacity: 0.7 }}>Help</span>
        <span style={{ flex: 1 }} />

        {/* status icon for PhotoDrop's MenuBarExtra — open state */}
        <span style={{
          display: 'flex', alignItems: 'center', gap: 4,
          padding: '0 4px', height: 18, borderRadius: 4,
          background: tok.dark ? 'rgba(255,255,255,0.15)' : 'rgba(0,0,0,0.10)',
        }}>
          <Icon name={state === 'no-card' ? 'sdcard' : 'sdcard.fill'} size={14} />
          {badge && (
            <span style={{
              fontSize: 11, color: t.text,
              fontVariantNumeric: 'tabular-nums', fontWeight: 500,
              minWidth: 22, textAlign: 'right',
            }}>{badge}</span>
          )}
        </span>

        {/* battery + wifi placeholders */}
        <span style={{ opacity: 0.7, display: 'flex', gap: 2, alignItems: 'center' }}>
          <svg width="22" height="11" viewBox="0 0 22 11">
            <rect x="0.5" y="0.5" width="18" height="10" rx="2" fill="none" stroke={t.text} strokeWidth="0.7" opacity="0.6"/>
            <rect x="2" y="2" width="11" height="7" rx="0.8" fill={t.text} opacity="0.85"/>
            <rect x="19.4" y="3.5" width="1.6" height="4" rx="0.4" fill={t.text} opacity="0.6"/>
          </svg>
        </span>
        <span style={{ fontSize: 13, opacity: 0.85 }}>Tue Apr 17</span>
        <span style={{ fontSize: 13, opacity: 0.85, fontVariantNumeric: 'tabular-nums' }}>10:42</span>
      </div>

      {/* dropdown anchored under the menu bar icon */}
      <div style={{ position: 'absolute', top: 28, right: 88 }}>
        <MenuBarMenu tok={tok} state={state} label={label} subtitle={subtitle} secondary={secondary} />
      </div>

      {/* caption */}
      <div style={{
        position: 'absolute', bottom: 14, left: 16,
        fontSize: 11, color: tok.dark ? 'rgba(255,255,255,0.55)' : 'rgba(0,0,0,0.55)',
        fontFamily: type.mono, letterSpacing: '0.04em',
      }}>
        macOS menu-bar dropdown · MenuBarExtra · {state}
      </div>
    </div>
  );
}

Object.assign(window, { MenuBarMenu, MenuBarScene, MBItem, MBStatic, MBSeparator });
