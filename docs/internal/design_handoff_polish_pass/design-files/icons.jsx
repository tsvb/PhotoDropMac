// icons.jsx — SF Symbol-shaped icon set
// These approximate the SF Symbols the engineer is already using in the
// codebase. Style: filled by default, slightly rounded, weight matches SF
// Symbols' "Regular" weight. Drawn at 17×17 viewBox (matches SF Symbol
// pixel grid) and sized via the `size` prop.
//
// Names map 1:1 to SF Symbol names so the engineer can swap them in
// directly: <Image(systemName: "sdcard.fill") />

function Icon({ name, size = 17, color, style = {} }) {
  const common = {
    width: size, height: size, viewBox: '0 0 17 17',
    fill: color || 'currentColor',
    style: { display: 'block', flexShrink: 0, ...style },
  };
  switch (name) {
    case 'sdcard':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 1.8h6.4L13 4.4V14a1.2 1.2 0 0 1-1.2 1.2H4A1.2 1.2 0 0 1 2.8 14V3a1.2 1.2 0 0 1 1.2-1.2z"/>
        <path d="M5.5 3v1.4M7.3 3v1.4M9.1 3v1.4M10.9 3.2v1.2"/>
      </svg>);
    case 'sdcard.fill':
      return (<svg {...common}>
        <path d="M4 1.8h6.4L13 4.4V14a1.2 1.2 0 0 1-1.2 1.2H4A1.2 1.2 0 0 1 2.8 14V3a1.2 1.2 0 0 1 1.2-1.2z" stroke="currentColor" strokeWidth="0.6" strokeLinejoin="round"/>
        <rect x="5" y="2.8" width="0.7" height="1.8" rx="0.2" fill="rgba(255,255,255,0.85)"/>
        <rect x="6.8" y="2.8" width="0.7" height="1.8" rx="0.2" fill="rgba(255,255,255,0.85)"/>
        <rect x="8.6" y="2.8" width="0.7" height="1.8" rx="0.2" fill="rgba(255,255,255,0.85)"/>
        <rect x="10.4" y="3" width="0.7" height="1.5" rx="0.2" fill="rgba(255,255,255,0.85)"/>
      </svg>);
    case 'eject':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M3.4 9.4L8.5 4l5.1 5.4"/>
        <path d="M3.5 12.8h10"/>
      </svg>);
    case 'eject.fill':
      return (<svg {...common}>
        <path d="M3.4 9.4L8.5 4l5.1 5.4a0.5 0.5 0 0 1-0.36 0.85H3.76A0.5 0.5 0 0 1 3.4 9.4z"/>
        <rect x="3.4" y="11.6" width="10.2" height="1.5" rx="0.5"/>
      </svg>);
    case 'folder':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round">
        <path d="M2.4 5.2a1 1 0 0 1 1-1h2.6l1.6 1.6h6a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3.4a1 1 0 0 1-1-1V5.2z"/>
      </svg>);
    case 'folder.fill':
      return (<svg {...common}>
        <path d="M2.4 5.2a1 1 0 0 1 1-1h2.6l1.6 1.6h6a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3.4a1 1 0 0 1-1-1V5.2z"/>
      </svg>);
    case 'checkmark':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
        <path d="M3 8.8L6.5 12.2L14 4.8"/>
      </svg>);
    case 'checkmark.seal.fill':
      // 12-bump seal (SF Symbol look)
      return (<svg {...common}>
        <path d={sealPath(8.5, 8.5, 6.4)} />
        <path d="M5.5 8.6L7.5 10.6L11.4 6.4" fill="none" stroke="#fff" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>);
    case 'arrow.down.doc':
      return (<svg {...common}>
        <path d="M5.5 1.6a1 1 0 0 0-1 1V14a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V5l-3.4-3.4H5.5z M9.1 1.7v3.2h3.2" fill="none" stroke="currentColor" strokeWidth="1" strokeLinejoin="round"/>
        <path d="M8.5 7v4.6m-1.6-1.6L8.5 11.6L10.1 10" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>);
    case 'arrow.right.doc':
      return (<svg {...common}>
        <path d="M5.5 1.6a1 1 0 0 0-1 1V14a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V5l-3.4-3.4H5.5z M9.1 1.7v3.2h3.2" fill="none" stroke="currentColor" strokeWidth="1" strokeLinejoin="round"/>
        <path d="M6.4 9h4m-1.6-1.6L10.4 9L8.8 10.6" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>);
    case 'exclamationmark.triangle.fill':
      return (<svg {...common}>
        <path d="M8.5 1.8L15.2 14a1 1 0 0 1-0.87 1.5H1.67A1 1 0 0 1 0.8 14L7.5 1.8a1 1 0 0 1 1 0z"/>
        <path d="M8.5 6V10" stroke="#fff" strokeWidth="1.3" strokeLinecap="round" fill="none"/>
        <circle cx="8.5" cy="12.4" r="0.7" fill="#fff"/>
      </svg>);
    case 'exclamationmark.octagon.fill':
      return (<svg {...common}>
        <path d={octagonPath(8.5, 8.5, 6.6)} />
        <path d="M8.5 5V9.3" stroke="#fff" strokeWidth="1.3" strokeLinecap="round" fill="none"/>
        <circle cx="8.5" cy="11.4" r="0.7" fill="#fff"/>
      </svg>);
    case 'xmark.octagon':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round">
        <path d={octagonPath(8.5, 8.5, 6.6)} />
        <path d="M6 6L11 11M11 6L6 11" strokeLinecap="round"/>
      </svg>);
    case 'info.circle':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1">
        <circle cx="8.5" cy="8.5" r="6.4"/>
        <path d="M8.5 11.4V7.4" strokeLinecap="round"/>
        <circle cx="8.5" cy="5.4" r="0.65" fill="currentColor" stroke="none"/>
      </svg>);
    case 'gearshape':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round">
        <path d={gearPath(8.5, 8.5, 6.2, 4)}/>
        <circle cx="8.5" cy="8.5" r="1.9"/>
      </svg>);
    case 'square.and.arrow.down':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 9V13a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V9"/>
        <path d="M8.5 2V10.4M6 8L8.5 10.6L11 8"/>
      </svg>);
    case 'photo':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round">
        <rect x="2.4" y="3.6" width="12.2" height="9.6" rx="1.2"/>
        <circle cx="5.6" cy="6.4" r="0.95"/>
        <path d="M2.6 11l3.6-3.2 3 2.6L11.5 9l3 2.4"/>
      </svg>);
    case 'arrow.clockwise':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M2.8 8.5a5.7 5.7 0 1 1 1.7 4.1"/>
        <path d="M4.2 14.8v-2.9h2.9"/>
      </svg>);
    case 'sidebar.right':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1">
        <rect x="2.4" y="4.2" width="12.2" height="8.6" rx="1.2"/>
        <path d="M11.2 4.4v8.4" strokeLinecap="round"/>
      </svg>);
    case 'externaldrive':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round">
        <rect x="2" y="6.6" width="13" height="4.4" rx="1.1"/>
        <circle cx="12.6" cy="8.8" r="0.55" fill="currentColor" stroke="none"/>
        <circle cx="11" cy="8.8" r="0.55" fill="currentColor" stroke="none"/>
      </svg>);
    case 'externaldrive.fill':
      return (<svg {...common}>
        <rect x="2" y="6.6" width="13" height="4.4" rx="1.1"/>
        <circle cx="12.6" cy="8.8" r="0.55" fill="#fff"/>
        <circle cx="11" cy="8.8" r="0.55" fill="#fff"/>
      </svg>);
    case 'shippingbox':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round">
        <path d="M2.4 5L8.5 2.4L14.6 5L8.5 7.6L2.4 5z"/>
        <path d="M2.4 5v6.4L8.5 14V7.6"/>
        <path d="M14.6 5v6.4L8.5 14"/>
      </svg>);
    case 'calendar':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round">
        <rect x="2.4" y="3.4" width="12.2" height="11.2" rx="1.3"/>
        <path d="M2.4 6.6h12.2" strokeLinecap="round"/>
        <path d="M5.5 1.6V3.8M11.5 1.6V3.8" strokeLinecap="round"/>
      </svg>);
    case 'magnifyingglass':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round">
        <circle cx="7.4" cy="7.4" r="4.6"/>
        <path d="M10.8 10.8L14 14"/>
      </svg>);
    case 'plus':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round">
        <path d="M8.5 3v11M3 8.5h11"/>
      </svg>);
    case 'chevron.right':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
        <path d="M6 3L11.5 8.5L6 14"/>
      </svg>);
    case 'chevron.down':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
        <path d="M3 6L8.5 11.5L14 6"/>
      </svg>);
    case 'play.fill':
      return (<svg {...common}><path d="M4.6 3.4L13 8.5L4.6 13.6V3.4z"/></svg>);
    case 'stop.fill':
      return (<svg {...common}><rect x="4" y="4" width="9" height="9" rx="1.2"/></svg>);
    case 'circle':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1"><circle cx="8.5" cy="8.5" r="6.4"/></svg>);
    case 'circle.fill':
      return (<svg {...common}><circle cx="8.5" cy="8.5" r="6.4"/></svg>);
    case 'questionmark.circle':
      return (<svg {...common} fill="none" stroke="currentColor" strokeWidth="1.1">
        <circle cx="8.5" cy="8.5" r="6.4"/>
        <path d="M6.5 6.4a2 2 0 0 1 4 0c0 0.9-1 1.4-2 2v1.2" strokeLinecap="round"/>
        <circle cx="8.5" cy="12" r="0.65" fill="currentColor" stroke="none"/>
      </svg>);
    default:
      return null;
  }
}

// Build a 12-petal seal path (SF Symbol's checkmark.seal shape).
function sealPath(cx, cy, r) {
  const n = 12, bump = 0.6;
  const pts = [];
  for (let i = 0; i < n * 2; i++) {
    const a = (i / (n * 2)) * Math.PI * 2 - Math.PI / 2;
    const rr = i % 2 === 0 ? r : r * (1 - bump * 0.18);
    pts.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr]);
  }
  return 'M' + pts.map((p, i) => `${p[0].toFixed(2)} ${p[1].toFixed(2)}`).join(' Q ') + ' Z';
}

function octagonPath(cx, cy, r) {
  const sides = 8;
  const offset = Math.PI / sides;
  const pts = [];
  for (let i = 0; i < sides; i++) {
    const a = (i / sides) * Math.PI * 2 - Math.PI / 2 + offset;
    pts.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r]);
  }
  return 'M' + pts.map((p) => `${p[0].toFixed(2)} ${p[1].toFixed(2)}`).join(' L ') + ' Z';
}

function gearPath(cx, cy, rOuter, rInner) {
  // 8-tooth gear approximated as a star+inner-circle compound.
  const teeth = 8;
  let d = '';
  for (let i = 0; i < teeth * 2; i++) {
    const a = (i / (teeth * 2)) * Math.PI * 2 - Math.PI / 2;
    const r = i % 2 === 0 ? rOuter : rOuter * 0.78;
    const x = cx + Math.cos(a) * r, y = cy + Math.sin(a) * r;
    d += (i === 0 ? 'M' : 'L') + ` ${x.toFixed(2)} ${y.toFixed(2)} `;
  }
  return d + 'Z';
}

Object.assign(window, { Icon });
