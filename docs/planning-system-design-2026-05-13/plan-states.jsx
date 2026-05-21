/* ─────────────────────────────────────────────────────────────
   Plan States — phase 1
   Two artboards: empty-month page, and the unified edit modal
   (weekly + monthly variants).
   Visual restraint follows the user's reference HTMLs exactly:
     • 0.5px borders, calm spacing
     • lowercase status text in semantic colors, no capsules
     • one accent (text-primary as primary CTA bg) used sparingly
     • short uppercase section labels, no subtitles
   ───────────────────────────────────────────────────────────── */

const NavIconPath = {
  today:  "M4 8 a4 4 0 1 0 8 0 a4 4 0 0 0 -8 0 z M8 5 v3 l2 1.5",
  cal:    "M3 4 H13 V13 H3 z M3 7 H13 M6 2 V5 M10 2 V5",
  target: "M8 2 a6 6 0 1 0 0 12 a6 6 0 0 0 0 -12 z M8 5 a3 3 0 1 0 0 6 a3 3 0 0 0 0 -6 z",
  shield: "M8 1 L13 3 V8 C13 11 11 13 8 14.5 C5 13 3 11 3 8 V3 z",
  gear:   "M8 1 v2 M8 13 v2 M1 8 h2 M13 8 h2 M8 5.5 a2.5 2.5 0 1 0 0 5 a2.5 2.5 0 0 0 0 -5 z",
};
const NavIcon = ({k}) => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4">
    <path d={NavIconPath[k]} />
  </svg>
);

const SparkIcon = () => (
  <svg width="11" height="11" viewBox="0 0 16 16" fill="none"
    stroke="currentColor" strokeWidth="1.4" strokeLinecap="round">
    <path d="M8 1 L9.3 6 L14 7 L9.3 8 L8 13 L6.7 8 L2 7 L6.7 6 Z" />
  </svg>
);
const ClockIcon = () => (
  <svg width="12" height="12" viewBox="0 0 16 16" fill="none"
    stroke="currentColor" strokeWidth="1.4" strokeLinecap="round">
    <path d="M3 8 a5 5 0 1 0 1.5 -3.5" />
    <path d="M3 3 V5.5 H5.5" />
    <path d="M8 5 V8 L10 9.5" />
  </svg>
);
const PlusIcon = () => (
  <svg width="11" height="11" viewBox="0 0 16 16" fill="none"
    stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
    <path d="M8 3 V13 M3 8 H13" />
  </svg>
);

// ───────────────────────────────────────────────────────────────
// Sidebar — used by every full-page artboard
// ───────────────────────────────────────────────────────────────
function Sidebar({ active = "plan" }) {
  const items = [
    { k: 'today',  label: 'Today',          id: 'today'  },
    { k: 'cal',    label: 'Plan',           id: 'plan'   },
    { k: 'target', label: 'Focus modes',    id: 'focus'  },
    { k: 'shield', label: 'Accountability', id: 'acct'   },
    { k: 'gear',   label: 'Settings',       id: 'settings' },
  ];
  return (
    <aside className="sidebar">
      <div className="brand">Intentional</div>
      <nav className="nav">
        {items.map(it => (
          <a key={it.id} className={active === it.id ? 'active' : ''}>
            <NavIcon k={it.k} />
            <span>{it.label}</span>
          </a>
        ))}
      </nav>
    </aside>
  );
}

// ───────────────────────────────────────────────────────────────
// Page header — eyebrow + title on left, History + Help on right
// ───────────────────────────────────────────────────────────────
function PageHead({ eyebrow, title, showHelp = true }) {
  return (
    <div className="pg-head">
      <div>
        {eyebrow && <div className="eyebrow-row">{eyebrow}</div>}
        <h1>{title}</h1>
      </div>
      <div className="head-actions">
        <button className="btn-ghost"><ClockIcon />History</button>
        {showHelp && (
          <button className="btn-ghost"><SparkIcon />Help me plan</button>
        )}
      </div>
    </div>
  );
}

// ───────────────────────────────────────────────────────────────
// Artboard 1 — Empty month state (full page)
// ───────────────────────────────────────────────────────────────
function EmptyMonthArtboard() {
  return (
    <div className="artboard-page">
      <div className="win">
        <Sidebar active="plan" />
        <main className="page">
          <PageHead eyebrow="Wednesday · June 3" title="Your plan" showHelp={false} />

          <div className="prompt">
            <div>
              <h2>Set up June</h2>
              <p>The monthly ritual is three short prompts. Pick up to three goals you want to make real this month — everything else hangs off them.</p>
            </div>
            <button className="btn-primary">
              <SparkIcon /><span style={{ marginLeft: 6 }}>Start ritual</span>
            </button>
          </div>

          <div>
            <div className="eyebrow">June</div>
            <div className="row3">
              <button className="empty-card"><PlusIcon />Add monthly goal</button>
              <button className="empty-card"><PlusIcon />Add monthly goal</button>
              <button className="empty-card"><PlusIcon />Add monthly goal</button>
            </div>
          </div>

          <div>
            <div className="eyebrow">This week</div>
            <div className="quiet">Set monthly goals first, then plan this week.</div>
          </div>
        </main>
      </div>
    </div>
  );
}

// ───────────────────────────────────────────────────────────────
// Edit modal — unified weekly/monthly with field-level diffs
// ───────────────────────────────────────────────────────────────
const MONTHLIES = [
  { id: 'm1', title: 'Ship Puck to 25', hue: 'var(--hue-1)' },
  { id: 'm2', title: '4hr deep work',   hue: 'var(--hue-2)' },
  { id: 'm3', title: 'Hit 10k Puck IG', hue: 'var(--hue-3)' },
];

function EditModal({ kind = 'weekly', initialTitle, initialOutcome, initialLink = 'm1', initialHours = 3 }) {
  const [title, setTitle] = React.useState(initialTitle);
  const [outcome, setOutcome] = React.useState(initialOutcome);
  const [link, setLink] = React.useState(initialLink);
  const [hours, setHours] = React.useState(initialHours);

  return (
    <div className="ig-modal-stage">
      <div className="ig-modal">
        <div className="ig-modal-head">
          <div className="ig-modal-kind">{kind === 'weekly' ? 'Weekly goal' : 'Monthly goal'}</div>
          <button className="ig-modal-close">Close</button>
        </div>

        <div className="fld">
          <label>Title</label>
          <input type="text" value={title} onChange={e => setTitle(e.target.value)} />
        </div>

        <div className="fld">
          <label>Done looks like</label>
          <input type="text" value={outcome} onChange={e => setOutcome(e.target.value)} />
        </div>

        {kind === 'weekly' && (
          <div className="fld">
            <label>For monthly goal</label>
            <div className="pills">
              {MONTHLIES.map(m => (
                <button key={m.id}
                  className={`pill${link === m.id ? ' on' : ''}`}
                  style={{ '--hue': m.hue }}
                  onClick={() => setLink(m.id)}>
                  <span className="dot" />
                  {m.title}
                </button>
              ))}
              <button className={`pill${link === null ? ' on' : ''}`}
                onClick={() => setLink(null)}>
                No link
              </button>
            </div>
          </div>
        )}

        <div className="fld" style={{ marginBottom: 0 }}>
          <label>Hours target<span className="opt"> — optional</span></label>
          <div className="stepper">
            <button onClick={() => setHours(Math.max(0, hours - 1))}>−</button>
            <span className="val">{hours === 0 ? 'none' : `${hours}h`}</span>
            <button onClick={() => setHours(hours + 1)}>+</button>
          </div>
        </div>

        <div className="ig-modal-foot">
          <button className="btn-text" style={{ color: 'var(--text-3)' }}>Delete</button>
          <div className="right">
            <button className="btn-ghost">Cancel</button>
            <button className="btn-primary">Save</button>
          </div>
        </div>
      </div>
    </div>
  );
}

function EditModalWeeklyArtboard() {
  return (
    <EditModal
      kind="weekly"
      initialTitle="Record 3 demo videos"
      initialOutcome="Posted to IG by Sunday"
      initialLink="m1"
      initialHours={3}
    />
  );
}
function EditModalMonthlyArtboard() {
  return (
    <EditModal
      kind="monthly"
      initialTitle="Ship Puck to 25 founding members"
      initialOutcome="25 paid orders by May 31"
      initialHours={0}
    />
  );
}

// ───────────────────────────────────────────────────────────────
// Canvas
// ───────────────────────────────────────────────────────────────
function App() {
  return (
    <DesignCanvas projectName="Plan States" initialZoom={0.62}>
      <DCSection id="empty" title="Empty states">
        <DCArtboard id="empty-month" label="Empty month · new month, no goals set"
          width={1100} height={780}>
          <EmptyMonthArtboard />
        </DCArtboard>
      </DCSection>

      <DCSection id="edit" title="Edit goal modal — unified for weekly + monthly">
        <DCArtboard id="edit-weekly" label="Editing a weekly goal"
          width={580} height={640}>
          <EditModalWeeklyArtboard />
        </DCArtboard>

        <DCArtboard id="edit-monthly" label="Editing a monthly goal"
          width={580} height={520}>
          <EditModalMonthlyArtboard />
        </DCArtboard>
      </DCSection>
    </DesignCanvas>
  );
}

ReactDOM.createRoot(document.getElementById('canvas-root')).render(<App />);
