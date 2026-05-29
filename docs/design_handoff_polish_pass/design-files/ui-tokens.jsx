// ui-tokens.jsx — shared design tokens for both directions
// Two visual directions share monochrome philosophy; each one swaps out
// type stack, density, accent treatment, "verified" mark.

// macOS system accent colors AND a curated set of Apple silicone-case
// blues. Apple ships several distinct "Blue" silicone cases — pick the
// one that matches the physical case in hand.
const ACCENTS = {
  // The four candidate Apple silicone blues, ordered by saturation.
  // Names match real Apple Store SKUs so the user can identify by sight.
  blueCobalt:    { name: 'iPhone 12 mini · Blue',  hex: '#1c5cdb', soft: 'rgba(28,92,219,0.14)',  label: 'Cobalt' },
  blueClassic:   { name: 'iPhone 15 · Blue',       hex: '#4577d1', soft: 'rgba(69,119,209,0.14)', label: 'Classic' },
  blueUltra:     { name: 'iPhone 16 · Ultramarine',hex: '#6678c2', soft: 'rgba(102,120,194,0.14)', label: 'Ultramarine' },
  blueDenim:     { name: 'iPhone 16 · Denim',      hex: '#3f5872', soft: 'rgba(63,88,114,0.14)',  label: 'Denim' },

  // System accents kept available alongside.
  blue:     { name: 'Ultramarine',  hex: '#120A8F', soft: 'rgba(18,10,143,0.12)', label: 'Ultramarine' },
  purple:   { name: 'Purple',       hex: '#953dff', soft: 'rgba(149,61,255,0.14)', label: 'Purple'  },
  green:    { name: 'Green',        hex: '#34b860', soft: 'rgba(52,184,96,0.14)',  label: 'Green'   },
  graphite: { name: 'Graphite',     hex: '#878d97', soft: 'rgba(135,141,151,0.14)', label: 'Graphite' },
};

// Resolve a single direction × dark × density × accent into a flat token bag
// every screen can read from. Keeping the resolver here means a tweak change
// re-renders the whole shell with the new bag — no styled-context drilling.
function makeTokens({ direction = 'a', dark = false, density = 'comfortable', accentKey = 'blue' }) {
  const accent = ACCENTS[accentKey] || ACCENTS.blue;

  // Cool neutral ramp — true monochrome utilitarian. Slight blue undertone
  // so it reads as "instrument" rather than "paper". No warm cast anywhere.
  // macOS Sonoma+ system colors. Values lifted from NSColor system tones so
  // the mockups look like what `Color.accentColor` / `Color(NSColor.*)`
  // actually resolve to. Sidebars use an opaque approximation of
  // .ultraThinMaterial; the content area uses windowBackgroundColor.
  const light = {
    bg:        '#ffffff',          // windowBackgroundColor (content)
    panel:     '#ffffff',          // controlBackgroundColor
    panelAlt:  '#f2f2f4',          // sidebar approx (no real vibrancy on web)
    sidebar:   '#e9e9ec',          // .sidebar List bg
    border:    'rgba(0,0,0,0.10)', // .separator
    borderHi:  'rgba(0,0,0,0.18)',
    text:      'rgba(0,0,0,0.85)', // .primary label
    textSec:   'rgba(0,0,0,0.55)', // .secondary
    textMute:  'rgba(0,0,0,0.40)', // .tertiary
    textFaint: 'rgba(0,0,0,0.25)', // .quaternary
    chrome:    '#ecebeb',          // unified toolbar bg
    chromeIn:  '#f5f5f7',
    ok:        '#1d8a3a',          // system green
    okSoft:    'rgba(29,138,58,0.12)',
    warn:      '#c05a1a',          // system orange (toned for log readability)
    warnSoft:  'rgba(192,90,26,0.14)',
    err:       '#d3322f',          // system red
    errSoft:   'rgba(211,50,47,0.12)',
    skip:      '#a85f1a',          // matches .orange used in current LogView
    skipSoft:  'rgba(168,95,26,0.12)',
    selBg:     accent.hex,         // .sidebar selection uses ACCENT fill
    selFg:     '#ffffff',
  };

  const darkT = {
    bg:        '#1e1e1e',          // windowBackgroundColor dark
    panel:     '#2a2a2c',
    panelAlt:  '#252527',
    sidebar:   '#2a2a2c',
    border:    'rgba(255,255,255,0.10)',
    borderHi:  'rgba(255,255,255,0.20)',
    text:      'rgba(255,255,255,0.92)',
    textSec:   'rgba(255,255,255,0.62)',
    textMute:  'rgba(255,255,255,0.42)',
    textFaint: 'rgba(255,255,255,0.26)',
    chrome:    '#272729',
    chromeIn:  '#222224',
    ok:        '#2fc257',
    okSoft:    'rgba(47,194,87,0.18)',
    warn:      '#ff9d4a',
    warnSoft:  'rgba(255,157,74,0.18)',
    err:       '#ff5a52',
    errSoft:   'rgba(255,90,82,0.18)',
    skip:      '#ff9d4a',
    skipSoft:  'rgba(255,157,74,0.16)',
    selBg:     accent.hex,
    selFg:     '#ffffff',
  };

  const t = dark ? darkT : light;

  // Density just nudges padding/row-height; type scale itself stays steady so
  // we keep the calm "Mac app" feel rather than collapsing into pro-tool noise.
  const pad = density === 'compact'
    ? { row: 28, gut: 10, pane: 16, gap: 8,  card: 14 }
    : { row: 34, gut: 14, pane: 22, gap: 12, card: 20 };

  // Type: SF Pro everywhere (renders as actual SF Pro on macOS via
  // -apple-system; Inter as a passable web fallback so the proportions
  // hold elsewhere). Mono is SF Mono / Menlo on Mac, ui-monospace otherwise.
  // Direction B keeps Instrument Serif for one emotional moment — the
  // completion headline. Everything else stays SF Pro so the app reads as
  // a real Mac app, not a typographic showpiece.
  const sansStack = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "Inter", system-ui, sans-serif';
  const monoStack = '"SF Mono", ui-monospace, Menlo, Consolas, monospace';
  const type = direction === 'b'
    ? {
        body: sansStack,
        mono: monoStack,
        display: '"Instrument Serif", "New York", "Iowan Old Style", Georgia, serif',
      }
    : {
        body: sansStack,
        mono: monoStack,
        display: sansStack,
      };

  return { dark, direction, accent, t, type, pad, density };
}

// Tiny class-less "card" + "row" primitives so each direction stays terse.
function card(tok, extra = {}) {
  return {
    background: tok.t.panel,
    border: `0.5px solid ${tok.t.border}`,
    borderRadius: 10,
    ...extra,
  };
}

// Format helpers — every "file count" and "size" in the UI comes through here
// so the language stays uniform. "12,438 files · 187.4 GB" everywhere.
const fmt = {
  int: (n) => n.toLocaleString('en-US'),
  size: (gb) => {
    if (gb >= 100) return gb.toFixed(0) + ' GB';
    if (gb >= 10)  return gb.toFixed(1) + ' GB';
    if (gb >= 1)   return gb.toFixed(2) + ' GB';
    return Math.round(gb * 1024) + ' MB';
  },
  mbs: (n) => n.toFixed(1) + ' MB/s',
  eta: (s) => {
    if (s < 60) return Math.round(s) + 's';
    const m = Math.floor(s / 60), r = Math.round(s % 60);
    return m + ':' + String(r).padStart(2, '0');
  },
  date: (iso) => {
    const d = new Date(iso);
    return d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
  },
};

Object.assign(window, { ACCENTS, makeTokens, card, fmt });
