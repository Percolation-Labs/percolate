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

const STATUS_CLASS = {
  succeeded: "succeeded", running: "running", failed: "failed", cancelled: "cancelled",
  pending: "pending", ready: "ready", waiting_external: "waiting", compensating: "compensating",
  active: "succeeded", pending_verification: "pending", suspended: "cancelled",
};
export const status = (s) => chip(s || "—", STATUS_CLASS[s] || "");

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
