// mac-window.jsx — SwiftUI-shaped primitives for a NavigationSplitView app.
// Every primitive here maps to a specific SwiftUI view so the engineer
// can implement directly. No invented chrome.
//
//   PDWindow           ↔ Window(...) .windowToolbarStyle(.unified)
//   PDSplit            ↔ NavigationSplitView { sidebar } detail: { ... }
//                          .inspector(isPresented:) { ... }
//   PDSidebar          ↔ List(selection:) { Row } .listStyle(.sidebar)
//   PDSidebarRow       ↔ List row (with .accent-fill selection)
//   PDInspector        ↔ ScrollView { VStack(...) Divider() ... }
//   PDList             ↔ List { Section { ... } } .listStyle(.inset)
//   PDDisclosure       ↔ DisclosureGroup
//   PDForm + PDFormSection + PDFormRow ↔ Form .formStyle(.grouped)
//   PDTextField        ↔ TextField .textFieldStyle(.roundedBorder)
//   PDPathField        ↔ TextField + Button (folder.fill)
//   PDCheckbox         ↔ Toggle(...) .toggleStyle(.checkbox)
//   PDButton           ↔ Button .buttonStyle(.borderedProminent / .bordered / .borderless)
//   PDDivider          ↔ Divider()
//   PDProgressBar      ↔ ProgressView(value:) .progressViewStyle(.linear)
//   PDSheet            ↔ .sheet(...) — centered modal
//   PDContentUnavailable ↔ ContentUnavailableView(_, systemImage:, description:)

// ─── Traffic lights ─────────────────────────────────────────────────────────
function PDTrafficLights({ active = true }) {
  const dot = (bg) => (
    <div style={{
      width: 12, height: 12, borderRadius: '50%',
      background: active ? bg : '#cfcfcf',
      boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.18)',
    }} />
  );
  return (
    <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
      {dot('#ff5f57')}{dot('#febc2e')}{dot('#28c840')}
    </div>
  );
}

// ─── PDWindow — Window + unified toolbar ────────────────────────────────────
function PDWindow({ tok, width = 1020, height = 700, title = 'PhotoDrop',
                    subtitle, toolbar, children }) {
  const { t, type } = tok;
  return (
    <div style={{
      width, height,
      borderRadius: 10,
      overflow: 'hidden',
      background: t.bg,
      color: t.text,
      fontFamily: type.body,
      fontSize: 13, lineHeight: 1.35,
      // Window edge: thin shadow + hairline (real macOS rim)
      boxShadow: tok.dark
        ? '0 0 0 0.5px rgba(0,0,0,0.7), 0 30px 60px rgba(0,0,0,0.40)'
        : '0 0 0 0.5px rgba(0,0,0,0.18), 0 30px 60px rgba(0,0,0,0.18)',
      display: 'flex', flexDirection: 'column',
      position: 'relative',
    }}>
      {/* unified toolbar — single 38pt bar with traffic lights + title +
          subtitle + trailing toolbar items */}
      <div style={{
        height: 38, flex: '0 0 38px',
        display: 'flex', alignItems: 'center',
        padding: '0 12px',
        background: t.chrome,
        borderBottom: `0.5px solid ${t.border}`,
        gap: 14,
      }}>
        <PDTrafficLights />
        <div style={{ flex: 1, display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: t.text, letterSpacing: -0.1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</span>
          {subtitle && (
            <span style={{ fontSize: 11.5, color: t.textSec, fontFamily: type.body, fontVariantNumeric: 'tabular-nums', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</span>
          )}
        </div>
        {toolbar && <div style={{ flexShrink: 0, display: 'flex', gap: 4, alignItems: 'center' }}>{toolbar}</div>}
      </div>

      {/* body */}
      <div style={{ flex: 1, minHeight: 0, display: 'flex' }}>{children}</div>
    </div>
  );
}

// PDToolbarButton — small icon button for the unified toolbar
function PDToolbarButton({ tok, icon, label, disabled }) {
  const { t } = tok;
  return (
    <button title={label} disabled={disabled} style={{
      width: 28, height: 28, padding: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: 'transparent',
      color: disabled ? t.textFaint : t.textSec,
      border: '0',
      borderRadius: 6,
      cursor: disabled ? 'default' : 'pointer',
    }}><Icon name={icon} size={15} /></button>
  );
}

// ─── PDSplit — NavigationSplitView + Inspector ──────────────────────────────
function PDSplit({ tok, sidebar, detail, inspector, sidebarWidth = 240, inspectorWidth = 320 }) {
  const { t } = tok;
  return (
    <>
      <aside style={{
        width: sidebarWidth, flex: `0 0 ${sidebarWidth}px`,
        background: t.sidebar,
        borderRight: `0.5px solid ${t.border}`,
        overflowY: 'auto',
        display: 'flex', flexDirection: 'column',
      }}>{sidebar}</aside>
      <main style={{ flex: 1, minWidth: 0, background: t.bg, overflowY: 'auto', position: 'relative' }}>{detail}</main>
      {inspector && (
        <aside style={{
          width: inspectorWidth, flex: `0 0 ${inspectorWidth}px`,
          background: t.panel,
          borderLeft: `0.5px solid ${t.border}`,
          overflowY: 'auto',
        }}>{inspector}</aside>
      )}
    </>
  );
}

// ─── PDSidebar / PDSidebarRow — List(selection:) .listStyle(.sidebar) ────────
function PDSidebar({ tok, header, children, footer }) {
  const { t, type } = tok;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0 }}>
      {header && (
        <div style={{
          padding: '8px 16px 6px 14px',
          fontSize: 11, fontWeight: 600,
          color: t.textSec, letterSpacing: 0.02,
        }}>{header}</div>
      )}
      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '0 8px 12px' }}>
        {children}
      </div>
      {footer && (
        <div style={{ padding: '8px 14px', borderTop: `0.5px solid ${t.border}` }}>{footer}</div>
      )}
    </div>
  );
}

function PDSidebarRow({ tok, icon, label, secondary, trailing, selected }) {
  const { t, type, accent } = tok;
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: '5px 8px',
      borderRadius: 6,
      background: selected ? accent.hex : 'transparent',
      color: selected ? '#fff' : t.text,
      cursor: 'default',
    }}>
      {icon && (
        <span style={{
          color: selected ? '#fff' : accent.hex,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          width: 18, flexShrink: 0,
        }}>
          {typeof icon === 'string' ? <Icon name={icon} size={17} /> : icon}
        </span>
      )}
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ fontSize: 13, fontWeight: 400, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{label}</div>
        {secondary && (
          <div style={{
            fontSize: 11, marginTop: 1,
            color: selected ? 'rgba(255,255,255,0.78)' : t.textSec,
            fontVariantNumeric: 'tabular-nums',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{secondary}</div>
        )}
      </div>
      {trailing}
    </div>
  );
}

// ─── PDList — List { Section { ... } } .listStyle(.inset) ───────────────────
function PDList({ tok, header, children, style = {} }) {
  const { t } = tok;
  return (
    <div style={{ padding: '8px 0 14px', ...style }}>
      {header && (
        <div style={{ padding: '6px 22px 8px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          {header}
        </div>
      )}
      <div style={{ padding: '0 14px' }}>{children}</div>
    </div>
  );
}

// PDDisclosure — a DisclosureGroup. Always renders open in mocks.
function PDDisclosure({ tok, label, secondary, children, defaultOpen = true }) {
  const { t, type } = tok;
  const [open, setOpen] = React.useState(defaultOpen);
  return (
    <div style={{ marginBottom: 4 }}>
      <div onClick={() => setOpen(!open)} style={{
        display: 'flex', alignItems: 'center', gap: 6,
        padding: '5px 8px',
        cursor: 'pointer',
        borderRadius: 5,
      }}>
        <span style={{
          color: t.textSec,
          transform: open ? 'rotate(90deg)' : 'rotate(0deg)',
          transition: 'transform .15s',
          display: 'flex', alignItems: 'center',
          width: 12,
        }}>
          <Icon name="chevron.right" size={11} />
        </span>
        {label}
        <span style={{ flex: 1 }} />
        {secondary}
      </div>
      {open && <div style={{ paddingLeft: 22 }}>{children}</div>}
    </div>
  );
}

// ─── PDForm + sections — Form .formStyle(.grouped) ──────────────────────────
function PDForm({ tok, children }) {
  return (
    <div style={{ padding: '18px 22px', display: 'flex', flexDirection: 'column', gap: 16 }}>{children}</div>
  );
}

function PDFormSection({ tok, title, hint, children }) {
  const { t, type } = tok;
  return (
    <div>
      {title && (
        <div style={{ fontSize: 12, fontWeight: 600, color: t.text, padding: '0 4px 6px' }}>{title}</div>
      )}
      <div style={{
        background: t.panel,
        border: `0.5px solid ${t.border}`,
        borderRadius: 8,
        overflow: 'hidden',
      }}>{children}</div>
      {hint && (
        <div style={{ fontSize: 11, color: t.textSec, padding: '6px 4px 0', lineHeight: 1.4 }}>{hint}</div>
      )}
    </div>
  );
}

function PDFormRow({ tok, label, hint, isLast, children, align = 'center' }) {
  const { t } = tok;
  return (
    <div style={{
      padding: '11px 14px',
      display: 'grid', gridTemplateColumns: '170px 1fr',
      alignItems: align,
      gap: 14,
      borderBottom: isLast ? 'none' : `0.5px solid ${t.border}`,
    }}>
      <div>
        <div style={{ fontSize: 12.5, color: t.text }}>{label}</div>
        {hint && <div style={{ fontSize: 11, color: t.textSec, marginTop: 2, lineHeight: 1.35 }}>{hint}</div>}
      </div>
      <div>{children}</div>
    </div>
  );
}

// ─── PDTextField — TextField .roundedBorder ─────────────────────────────────
function PDTextField({ tok, value, placeholder, mono, leadingIcon }) {
  const { t, type } = tok;
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 6,
      height: 22, padding: '0 6px',
      background: tok.dark ? 'rgba(0,0,0,0.25)' : '#fff',
      border: `0.5px solid ${t.borderHi}`,
      borderRadius: 5,
      boxShadow: tok.dark ? 'none' : 'inset 0 1px 0 rgba(0,0,0,0.03)',
      color: t.text,
      fontFamily: mono ? type.mono : type.body,
      fontSize: 12,
      minWidth: 0,
    }}>
      {leadingIcon}
      <span style={{
        flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        color: value ? t.text : t.textMute,
      }}>{value || placeholder}</span>
    </div>
  );
}

// ─── PDPathField — TextField + folder picker button ─────────────────────────
function PDPathField({ tok, value, placeholder }) {
  const { t } = tok;
  return (
    <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <PDTextField tok={tok} value={value} placeholder={placeholder} mono />
      </div>
      <button style={{
        height: 22, width: 26,
        background: tok.dark ? '#3a3a3c' : '#ffffff',
        border: `0.5px solid ${t.borderHi}`,
        borderRadius: 5,
        color: t.textSec,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        cursor: 'pointer',
        boxShadow: tok.dark ? 'none' : '0 0.5px 0 rgba(0,0,0,0.06)',
      }} title="Choose folder…"><Icon name="folder" size={13} /></button>
    </div>
  );
}

// ─── PDCheckbox — Toggle .toggleStyle(.checkbox) ────────────────────────────
function PDCheckbox({ tok, checked, label }) {
  const { t, accent } = tok;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}>
      <span style={{
        width: 14, height: 14, borderRadius: 3,
        background: checked ? accent.hex : (tok.dark ? '#3a3a3c' : '#ffffff'),
        border: `0.5px solid ${checked ? accent.hex : t.borderHi}`,
        boxShadow: checked ? 'inset 0 1px 0 rgba(255,255,255,0.18)' : (tok.dark ? 'none' : 'inset 0 1px 0 rgba(0,0,0,0.04)'),
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0,
      }}>
        {checked && <Icon name="checkmark" size={10} color="#fff" />}
      </span>
      <span style={{ fontSize: 12.5, color: t.text }}>{label}</span>
    </div>
  );
}

// ─── PDButton — .borderedProminent / .bordered / .borderless ────────────────
function PDButton({ tok, variant = 'bordered', size = 'regular', children, disabled, full,
                    iconLeft, role, onClick, style = {} }) {
  const { t, type, accent } = tok;
  const h = size === 'small' ? 18 : size === 'large' ? 28 : 22;
  const px = size === 'small' ? 8 : size === 'large' ? 16 : 12;
  const fs = size === 'small' ? 11.5 : size === 'large' ? 13 : 12.5;
  const isDestructive = role === 'destructive';

  let bg, fg, border, shadow;
  if (variant === 'borderedProminent') {
    bg = accent.hex; fg = '#fff'; border = 'transparent';
    shadow = 'inset 0 1px 0 rgba(255,255,255,0.22), 0 0.5px 0 rgba(0,0,0,0.08)';
  } else if (variant === 'borderless') {
    bg = 'transparent';
    fg = isDestructive ? t.err : accent.hex;
    border = 'transparent';
    shadow = 'none';
  } else { // bordered
    bg = tok.dark ? '#3a3a3c' : '#ffffff';
    fg = isDestructive ? t.err : t.text;
    border = t.borderHi;
    shadow = tok.dark ? 'inset 0 1px 0 rgba(255,255,255,0.04)' : '0 0.5px 0 rgba(0,0,0,0.06)';
  }

  return (
    <button type="button" onClick={disabled ? undefined : onClick} disabled={disabled} style={{
      height: h, padding: `0 ${px}px`,
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 5,
      width: full ? '100%' : undefined,
      background: bg, color: fg,
      border: `0.5px solid ${border}`,
      borderRadius: variant === 'borderless' ? 4 : 5,
      fontFamily: type.body, fontSize: fs, fontWeight: 500, letterSpacing: -0.1,
      cursor: disabled ? 'default' : 'pointer',
      opacity: disabled ? 0.42 : 1,
      boxShadow: shadow,
      ...style,
    }}>
      {iconLeft && <span style={{ display: 'flex' }}>{iconLeft}</span>}
      <span>{children}</span>
    </button>
  );
}

// ─── PDProgressBar — ProgressView(value:) .progressViewStyle(.linear) ───────
function PDProgressBar({ tok, value = 0 }) {
  const { t, accent } = tok;
  return (
    <div style={{
      height: 4, borderRadius: 2,
      background: tok.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.10)',
      overflow: 'hidden', position: 'relative',
    }}>
      <div style={{ height: '100%', width: `${value * 100}%`, background: accent.hex, borderRadius: 2, transition: 'width .25s' }} />
    </div>
  );
}

// ─── PDDivider — .Divider() ─────────────────────────────────────────────────
function PDDivider({ tok }) {
  return <div style={{ height: '0.5px', background: tok.t.border }} />;
}

// ─── PDContentUnavailable — empty-state placeholder ─────────────────────────
function PDContentUnavailable({ tok, title, systemImage, description, actions, customGlyph }) {
  const { t, type } = tok;
  return (
    <div style={{
      height: '100%', display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center',
      gap: 8, padding: 60, textAlign: 'center',
    }}>
      {customGlyph || (
        <div style={{ color: t.textFaint, marginBottom: 4 }}>
          <Icon name={systemImage} size={48} />
        </div>
      )}
      <div style={{ fontSize: 18, fontWeight: 600, color: t.text, letterSpacing: -0.2 }}>{title}</div>
      {description && (
        <div style={{ fontSize: 13, color: t.textSec, maxWidth: 320, lineHeight: 1.45 }}>{description}</div>
      )}
      {actions && <div style={{ marginTop: 10 }}>{actions}</div>}
    </div>
  );
}

// ─── PDTag — small inline label (used by log status) ────────────────────────
function PDTag({ tok, children, color, style = {} }) {
  const { t, type } = tok;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 4,
      fontSize: 10.5, fontWeight: 500,
      color: color || t.textSec,
      fontVariantNumeric: 'tabular-nums',
      ...style,
    }}>{children}</span>
  );
}

Object.assign(window, {
  PDTrafficLights, PDWindow, PDToolbarButton,
  PDSplit, PDSidebar, PDSidebarRow,
  PDList, PDDisclosure,
  PDForm, PDFormSection, PDFormRow,
  PDTextField, PDPathField, PDCheckbox, PDButton, PDProgressBar, PDDivider,
  PDContentUnavailable, PDTag,
});
