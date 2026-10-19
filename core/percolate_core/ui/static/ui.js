/* Twenty lines of DOM, so there is no framework in the dependency list.
 * `h` is the only abstraction: tag, attrs, children. Everything else in this
 * app is a function that returns one of these. */

export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2).toLowerCase(), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat(9)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

export const chip = (text, kind = "") => h("span", { class: "chip " + kind }, h("i", { class: "dot" }), text);

/* `status()` chips several vocabularies -- a run's or task's lifecycle state, a
 * run's compensation_state, a user's account status, a pool's phase -- so the
 * wording below is per-state styling, not a list of what a status may be.
 *
 * What it cannot be is the only answer: a lifecycle state added to
 * workflow.lifecycle_states and not remembered here used to chip as neutral
 * grey, which is how `quota_exceeded` -- a run that stopped because a budget
 * ran out -- read as nothing in particular. setStatusVocabulary() is filled at
 * boot from that table, and a state this map has never heard of is styled by
 * what the table says it IS: finished well, finished badly, or still going
 * (REM-52). */
const VOCAB = new Map();

export function setStatusVocabulary(rows) {
  VOCAB.clear();
  for (const r of rows || []) VOCAB.set(r.state, r);
}

const STATUS_CLASS = {
  succeeded: "succeeded", running: "running", failed: "failed", cancelled: "cancelled",
  pending: "pending", ready: "ready", waiting_external: "waiting", compensating: "compensating",
  active: "succeeded", pending_verification: "pending", suspended: "cancelled",
};

export function statusClass(s) {
  if (STATUS_CLASS[s]) return STATUS_CLASS[s];
  const v = VOCAB.get(s);
  if (!v) return "";
  return v.is_success ? "succeeded" : v.is_terminal ? "failed" : "running";
}

export const status = (s) => chip(s || "—", statusClass(s));

export function table(cols, rows, render) {
  return h("table", { class: "data" },
    h("thead", {}, h("tr", {}, cols.map((c) => h("th", {}, c)))),
    h("tbody", {}, rows.length
      ? rows.map((r) => render(r))
      : h("tr", {}, h("td", { colspan: cols.length },
          h("div", { class: "empty" }, "No rows. The view is reachable and RLS returned nothing.")))));
}

export const stat = (label, value, note, tone = "") =>
  h("div", { class: "stat" },
    h("span", { class: "label" }, label),
    h("span", { class: "value" }, value),
    note ? h("span", { class: "trend " + tone }, note) : null);

/** The stat-tile form of `gap`. A read that failed is not a zero.
 *
 * "0 running · queue is clear" and "0 failed · none" are the sentences a
 * HEALTHY deployment writes, so a tile that renders them from a failed read
 * claims all-clear on no evidence -- the one thing a dashboard must never do,
 * and the shape a live misconfiguration took here: a 404 from the wrong REST
 * URL while the headline read zero and nine runs, two of them still running,
 * were in the database. An em dash is not a number, and the error goes where
 * the trend would have been. A successful EMPTY result still renders zero:
 * that one is evidence. */
export const statGap = (label, err) =>
  h("div", { class: "stat" },
    h("span", { class: "label" }, label),
    h("span", { class: "value", style: "color:var(--faint)" }, "—"),
    h("span", { class: "trend down", title: (err && err.message) || "" },
      "unavailable · " + String((err && (err.code || err.message)) || "read failed").slice(0, 44)));

export const panel = (title, label, body, right) =>
  h("div", { class: "panel" },
    h("header", {}, h("h3", {}, title), label ? h("span", { class: "label" }, label) : null,
      h("span", { class: "spacer" }), right || null),
    h("div", { class: "body tight" }, body));

/** A gap, rendered as itself.
 *
 * Every screen here that the database cannot answer says so, in place, naming
 * the object and the error the database actually returned. A mockup can invent
 * a number; this cannot, and pretending otherwise is how a UI ends up being the
 * thing that decides what is true. */
export function gap(what, detail, owner) {
  return h("div", { class: "note rose" },
    h("strong", {}, "Not reachable: "), what, " — ", detail,
    h("br"), h("span", { class: "mono", style: "font-size:.72rem" }, "Owner: " + owner));
}

export const fmtTime = (s) => {
  if (!s) return "—";
  const d = new Date(s), secs = (Date.now() - d) / 1000;
  /* A timestamp in the FUTURE is not an age of zero. `expires_at` is the one
     that matters: clamping its negative age to zero rendered a refresh token
     good for another month as "0s ago", i.e. a live credential shown as one
     that had just lapsed. Under a day it reads as a countdown; past that it
     is a date, which is what the branch below does with old timestamps. */
  if (secs < -1) {
    const ahead = -secs;
    if (ahead < 60) return "in " + Math.round(ahead) + "s";
    if (ahead < 3600) return "in " + Math.round(ahead / 60) + "m";
    if (ahead < 86400) return "in " + Math.round(ahead / 3600) + "h";
    return d.toISOString().slice(0, 10);
  }
  if (secs < 60) return Math.max(0, Math.round(secs)) + "s ago";
  if (secs < 3600) return Math.round(secs / 60) + "m ago";
  if (secs < 86400) return Math.round(secs / 3600) + "h ago";
  return d.toISOString().slice(0, 10);
};

/* UUIDv7 sorts by time, which means every id minted in the same millisecond
   shares a prefix -- four runs seeded together all read "01a085a1". The tail is
   the part that distinguishes them. */
export const short = (id) => (id || "").slice(-12);


/* ── The icon vocabulary, in one place ─────────────────────
 *
 * It used to be in three: a nav set in `index.html`, a four-entry set in
 * `access.js` for the Chat rail, and nothing anywhere else -- so every screen
 * outside Chat spelled a per-row action as a full-width labelled button, and
 * the Queues table gave a pool's `enable` control more width than its name,
 * image and replica range put together.
 *
 * Three sets meant an icon was cheaper to write inline than to share, which is
 * how a vocabulary stops being one. This is a module, so `index.html` and every
 * screen import the same map and a new icon is added once.
 */
export const ICONS = {
  home: '<path d="M2 7l5.5-4.5L13 7v6H2z"/>',
  chat: '<path d="M2 3h11v8H7l-3 3v-3H2z"/>',
  flow: '<path d="M2 3h4v3H2zM9 3h4v3H9zM5.5 10h4v3h-4z"/><path d="M4 6v2h7V6M7.5 8v2"/>',
  book: '<path d="M2.5 2.5h4c1 0 1 .8 1 .8V13s0-.8-1-.8h-4zM12.5 2.5h-4c-1 0-1 .8-1 .8V13s0-.8 1-.8h4z"/>',
  runs: '<path d="M2 8h3l2-5 2 10 2-5h2"/>',
  clock: '<circle cx="7.5" cy="7.5" r="5.5"/><path d="M7.5 4v3.5L10 9"/>',
  pools: '<rect x="1.5" y="2" width="12" height="3.2"/><rect x="1.5" y="6.4" width="12" height="3.2"/><rect x="1.5" y="10.8" width="12" height="2.4"/>',
  scale: '<path d="M2 12.5V6M6 12.5V3M10 12.5V8M14 12.5V4.5"/>',
  events: '<path d="M1.5 11l3-4 2.5 2L10 4.5l3.5 3"/>',
  agents: '<circle cx="7.5" cy="4.5" r="2.5"/><path d="M2.5 13c0-2.8 2.2-4.5 5-4.5s5 1.7 5 4.5"/>',
  users: '<circle cx="5.5" cy="5" r="2.3"/><circle cx="11" cy="5.8" r="1.8"/><path d="M1.5 12.5c0-2.3 1.8-3.8 4-3.8s4 1.5 4 3.8M10.5 9c1.8 0 3 1.2 3 3.2"/>',
  roles: '<path d="M7.5 1.5l5 2.2v4c0 3-2.2 5.2-5 6.3-2.8-1.1-5-3.3-5-6.3v-4z"/>',
  keys: '<circle cx="4.5" cy="7.5" r="2.8"/><path d="M7.3 7.5H14M12 7.5v2.6M10 7.5v2"/>',
  settings: '<circle cx="7.5" cy="7.5" r="2.3"/><path d="M7.5 1.2v1.8M7.5 12v1.8M13.8 7.5H12M3 7.5H1.2M12 3l-1.3 1.3M4.3 10.7L3 12M12 12l-1.3-1.3M4.3 4.3L3 3"/>',
  grid: '<rect x="2" y="2" width="4.6" height="4.6"/><rect x="8.4" y="2" width="4.6" height="4.6"/><rect x="2" y="8.4" width="4.6" height="4.6"/><rect x="8.4" y="8.4" width="4.6" height="4.6"/>',
  /* The Chat rail's set, moved here from access.js. */
  panelLeft: '<rect x="1.5" y="2.5" width="12" height="10" rx="1.5"/><path d="M5.5 2.5v10"/>',
  panelRight: '<rect x="1.5" y="2.5" width="12" height="10" rx="1.5"/><path d="M9.5 2.5v10"/>',
  plus: '<path d="M7.5 3v9M3 7.5h9"/>',
  send: '<path d="M2 7.5h10M8 3.5l4 4-4 4"/>',
  /* Per-row actions. */
  play: '<path d="M5 3.2l7 4.3-7 4.3z"/>',
  pause: '<path d="M5.5 3.5v8M9.5 3.5v8"/>',
  power: '<path d="M7.5 2v5"/><path d="M4.2 4.2a4.6 4.6 0 1 0 6.6 0"/>',
  signal: '<path d="M7.5 6.5v5"/><circle cx="7.5" cy="4" r="1.2"/>',
  refresh: '<path d="M12.5 7.5a5 5 0 1 1-1.6-3.7"/><path d="M13 2v3h-3"/>',
};

/** One `<svg>` for a named icon. Unknown names fall back visibly, not silently. */
export const icon = (name) => {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox", "0 0 15 15"); s.setAttribute("fill", "none");
  s.setAttribute("stroke", "currentColor"); s.setAttribute("stroke-width", "1.2");
  s.setAttribute("stroke-linecap", "round"); s.setAttribute("stroke-linejoin", "round");
  s.setAttribute("aria-hidden", "true");
  s.innerHTML = ICONS[name] || ICONS.grid;
  return s;
};

/** A per-row action drawn as an icon, with ONE source for its name.
 *
 * `label` becomes the `aria-label` a screen reader announces AND the tooltip a
 * pointer or keyboard user sees, so an icon cannot ship without an accessible
 * name -- the failure mode of every icon toolbar, and one a reviewer cannot
 * catch by looking at a screenshot.
 *
 * The tooltip is CSS on `data-tip`, not `title`: a native tooltip appears on
 * hover only, and a control that explains itself to a mouse and not to a
 * keyboard is the accessibility half of the same bug. `theme.css` shows it on
 * `:hover` and on `:focus-visible`.
 *
 * WHAT THIS IS NOT FOR. A consequential action keeps its words
 * (`ui-design-language.md` §3.2): Save, Run, Apply, and anything destructive or
 * access-changing. `revoke` and `grant` are text buttons on purpose, not by
 * oversight -- an icon is for an action whose worst outcome is that you do it
 * again.
 */
export function iconAction(name, label, attrs = {}) {
  if (!label) throw Error("an icon action needs a label: it is the accessible name");
  return h("button", { class: "icon-btn " + (attrs.class || ""), type: "button",
    "aria-label": label, "data-tip": label, ...attrs }, icon(name));
}

/* ── Components the mockups established ───────────────────── */

/** A segmented filter. Returns the element; `onpick` gets the value. */
export function seg(options, onpick, initial = 0) {
  const box = h("div", { class: "seg" });
  options.forEach(([label, value], i) => {
    const b = h("button", { "aria-pressed": i === initial ? "true" : "false",
      onclick: () => {
        [...box.children].forEach((c) => c.setAttribute("aria-pressed", c === b ? "true" : "false"));
        onpick(value);
      } }, label);
    box.append(b);
  });
  return box;
}

const TONE = { succeeded: "ok", failed: "bad", cancelled: "bad", running: "warn",
               ready: "info", pending: "", waiting_external: "info" };

/** The event stream row: time, marker, what happened, and the detail under it. */
export const stream = (events) =>
  h("div", { class: "stream" }, events.length ? events.map((e) =>
    h("div", { class: "ev " + (e.tone || "") },
      h("span", { class: "t" }, e.t),
      h("span", { class: "m" }),
      h("span", { class: "d" }, h("code", {}, e.what),
        e.meta ? h("span", { class: "meta" }, e.meta) : null)))
    : h("div", { class: "empty" }, "Nothing yet."));

export const eventTone = (toStatus) => TONE[toStatus] || "";

/** A task graph, laid out from the edges the database returned.
 *
 * Longest-path layering: a node sits one column right of its deepest
 * dependency. That is not the prettiest layout but it is the honest one --
 * the column IS the dependency depth, so a wide column is real fan-out and a
 * long row is a real chain. Nothing here decides anything the graph did not. */
export function dag(tasks, edges) {
  if (!tasks.length) return h("div", { class: "empty" }, "No tasks.");
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const deps = new Map(tasks.map((t) => [t.id, []]));
  edges.forEach((e) => { if (deps.has(e.task_id)) deps.get(e.task_id).push(e.depends_on_task_id); });

  const depth = new Map();
  const layer = (id, seen = new Set()) => {
    if (depth.has(id)) return depth.get(id);
    if (seen.has(id)) return 0;                       // a cycle cannot be laid out; do not hang
    seen.add(id);
    const d = (deps.get(id) || []).filter((p) => byId.has(p));
    const v = d.length ? 1 + Math.max(...d.map((p) => layer(p, seen))) : 0;
    depth.set(id, v);
    return v;
  };
  tasks.forEach((t) => layer(t.id));

  const cols = new Map();
  tasks.forEach((t) => { const d = depth.get(t.id); (cols.get(d) || cols.set(d, []).get(d)).push(t); });
  const W = 150, H = 44, GAPX = 42, GAPY = 16, PAD = 12;
  const pos = new Map();
  [...cols.keys()].sort((a, b) => a - b).forEach((d) => {
    cols.get(d).forEach((t, i) => pos.set(t.id, { x: PAD + d * (W + GAPX), y: PAD + i * (H + GAPY) }));
  });
  const width = PAD * 2 + (Math.max(...cols.keys()) + 1) * (W + GAPX) - GAPX;
  const height = PAD * 2 + Math.max(...[...cols.values()].map((c) => c.length)) * (H + GAPY) - GAPY;

  const cls = { succeeded: "ok", running: "run", failed: "bad", cancelled: "bad",
                waiting_external: "wait" };
  const svg = (tag, attrs, ...kids) => {
    const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
    kids.flat().forEach((c) => e.append(c.nodeType ? c : document.createTextNode(String(c))));
    return e;
  };
  const g = svg("svg", { class: "graph", viewBox: `0 0 ${width} ${height}`,
                         width: String(width), height: String(height) });
  edges.forEach((e) => {
    const a = pos.get(e.depends_on_task_id), b = pos.get(e.task_id);
    if (!a || !b) return;
    const x1 = a.x + W, y1 = a.y + H / 2, x2 = b.x, y2 = b.y + H / 2, mid = x1 + (x2 - x1) / 2;
    g.append(svg("path", { class: "edge", d: `M${x1} ${y1} H${mid} V${y2} H${x2}` }));
  });
  tasks.forEach((t) => {
    const p = pos.get(t.id);
    g.append(svg("rect", { class: "node " + (cls[t.status] || ""), x: p.x, y: p.y, width: W, height: H }));
    g.append(svg("text", { x: p.x + W / 2, y: p.y + 18, "text-anchor": "middle" }, t.step_key));
    g.append(svg("text", { class: "lbl", x: p.x + W / 2, y: p.y + 32, "text-anchor": "middle" },
                 (t.kind || "") .toUpperCase() + " · " + (t.status || "").toUpperCase()));
  });
  return h("div", { class: "graphwrap" }, g);
}
