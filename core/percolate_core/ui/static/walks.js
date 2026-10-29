/* Walks: a walk shown as an investigation (REM-1246).
 *
 * The question the user asked, the questions it was split into and closed, the
 * conversation the walk moved through, and the reads it judged to bear on each
 * question. Every number and row on these screens is what the query layer's
 * walk structure returns for one run (aiq.walk_structure, walk_stack,
 * walk_clues, walk_clue_texts, walk_graph_stats; the walk spec's sections 9 and
 * 11). This file computes nothing about a walk. It lays rows out and filters
 * them by the wave the reader has scrubbed to.
 *
 * ORACLE MODE is off until the reader loads a labels file. The walk never saw
 * those labels: they are passed to aiq.walk_structure beside the run, and every
 * part they add is marked `oracle: true` and drawn in its own colour. A shipped
 * page cannot know any benchmark's answer key, so it is always the reader's to
 * bring. */

import { h, chip, table, panel, gap, fmtTime, short } from "./ui.js";
import { read, rpc, claims, ApiError } from "./api.js";
import { READS } from "./reads.js";
import { head, page, tryRead } from "./views.js";

const KINDS = ["search", "next", "near", "term", "queued"];
const KIND_LABEL = { search: "search", next: "beside a read", near: "close in meaning",
                     term: "shared term", queued: "queued by a travel" };
const kindOf = (via) => (via == null ? "queued" : via === "search" ? "search" : via.split(":")[0]);
const esc = (t) => String(t ?? "");
/* replaceChildren() writes a null argument as the text "null"; h() skips it. This keeps h()'s rule. */
const fill = (el, ...kids) => el.replaceChildren(...kids.flat(9).filter((k) => k != null && k !== false));

/* Who is signed in, checked against the database before anything is read or started as them. A development token
   can name any id; one that is no user here reads nothing and starts nothing (runs_owner_id_fkey), so the screen says
   so rather than showing an empty list. Returns the warning, or null. */
async function identityNote() {
  const sub = (claims() || {}).sub;
  if (!sub) return h("p", { class: "note rose" }, "Nobody is signed in. ", h("a", { href: "#/signin" }, "Sign in"), " to see walks.");
  const me = await tryRead(() => read(READS.users, `id=eq.${sub}&limit=1`), (e) => ({ rows: null, error: e }));
  if (me.error || (me.rows && me.rows.length)) return null;
  return h("p", { class: "note rose" }, "Signed in as ", h("span", { class: "mono" }, sub),
    ", which is not a user in this database: it can read no walk and start none. ",
    h("a", { href: "#/signin" }, "Sign in"), " as a user who exists (Development identity), or ask for the deployment's demo user.");
}

/* -- Starting a walk ----------------------------------------------
   The questions a user may walk and the start itself are the query layer's (aiq.walk_questions, aiq.walk_launch):
   the page picks a question and a mode, and assembles no walk input. 'replay' answers from the question's recorded
   verdicts, offline and free; 'live' asks Jev, and the layer refuses it where no key is bound. */
async function startPanel() {
  const qs = await tryRead(() => rpc("aiq", "walk_questions", {}), (e) => ({ rows: null, error: e }));
  if (qs.error) return panel("Start a walk", "walk_questions · walk_launch",
    h("div", { class: "walk-pad" }, gap("aiq.walk_questions", qs.error.message, "query layer (REM-1245)")));
  const rows = qs.rows || [];
  if (!rows.length) return panel("Start a walk", "walk_questions", h("div", { class: "walk-pad" },
    h("p", { class: "hint" }, "No questions to walk are loaded for this account. Load a sample with questions (percolate sample load), or sign in as the account that holds them.")));
  const pick = h("select", { class: "control", "aria-label": "Question" },
    rows.map((q, i) => h("option", { value: String(i) }, `${q.text} (${q.channel}${q.has_replay ? ", replay" : ""})`)));
  const mode = h("select", { class: "control", "aria-label": "How the walk is judged" },
    h("option", { value: "replay" }, "Replay: Jev's recorded verdicts, offline, free"),
    h("option", { value: "live" }, "Live: ask Jev now (needs the deployment's Jev key)"));
  const out = h("div", { role: "status" });
  const sync = () => { const q = rows[Number(pick.value)]; mode.value = q.has_replay ? mode.value : "live"; mode.options[0].disabled = !q.has_replay; };
  pick.addEventListener("change", sync); sync();
  const start = h("button", { class: "btn primary", type: "button", onclick: async (e) => {
    e.target.disabled = true;
    try {
      const q = rows[Number(pick.value)];
      const res = await rpc("aiq", "walk_launch", { p_question: q.node_id, p_mode: mode.value });
      const id = typeof res.rows === "string" ? res.rows : (res.rows && (res.rows.walk_launch || res.rows[0]));
      location.hash = "#/walk/" + id;
    } catch (err) {
      fill(out, h("p", { class: "note rose" }, "The walk did not start: ", err instanceof ApiError ? err.message : String(err.message || err)));
    } finally { e.target.disabled = false; }
  } }, "Start the walk");
  return panel("Start a walk", "walk_questions · walk_launch", h("div", { class: "walk-pad form-stack" },
    h("label", { class: "field" }, h("span", {}, "Question"), pick),
    h("label", { class: "field" }, h("span", {}, "Judged by"), mode),
    h("div", { class: "form-actions" }, start), out));
}

/* -- The list -------------------------------------------------- */
export async function walks() {
  const node = page(head("Investigations", "Walks",
    "Each walk starts from one question and reads its way through what was said. Open one to see its questions, what it judged to bear on each and the path it took."));
  const who = await identityNote();
  if (who) node.append(who);
  node.append(await startPanel());
  const res = await tryRead(() => read(READS.walkRuns, "limit=50"), (e) => ({ rows: [], error: e }));
  if (res.error) {
    node.append(panel("Walks", null, h("div", { class: "body" },
      gap("aiq.walk_runs", res.error.message, "query layer (REM-1245)"))));
    return node;
  }
  if (!res.rows.length) {
    /* An empty list is a fact about who is signed in as much as about the database: a walk is readable by the
       account that ran it, its org, and operators. Say so, and who is signed in, rather than "no rows". */
    const sub = (claims() || {}).sub || "nobody";
    node.append(panel("Walks", "0 you may read", h("div", { class: "walk-pad walk-stack" },
      h("p", {}, "No walks are readable by the account signed in (", h("span", { class: "mono" }, sub), ")."),
      h("p", { class: "hint" }, "A walk is readable by the account that ran it, that account's organisation, and operators. ",
        "If walks were run on this database by another account, sign in as it: ",
        h("a", { href: "#/signin" }, "Account"), ", then Development identity or an access token. ",
        "Or start one above."))));
    return node;
  }
  node.append(panel("Walks", res.rows.length + " shown",
    table(["Walk", "Question", "Status", "Control of", "Started"], res.rows, (r) =>
      h("tr", {},
        h("td", { class: "mono" }, h("a", { href: "#/walk/" + r.run }, short(r.run))),
        h("td", {}, esc(r.question_text)),
        h("td", {}, chip(r.status, r.status === "succeeded" ? "succeeded" : r.status === "failed" ? "failed" : "running")),
        h("td", { class: "mono" }, r.control_of ? h("a", { href: "#/walk/" + r.control_of }, short(r.control_of)) : "—"),
        h("td", { class: "mono" }, fmtTime(r.created_at))))));
  return node;
}

/* -- One walk -------------------------------------------------- */
export async function walk(run) {
  if (!/^[0-9a-f-]{36}$/i.test(run || "")) {
    return page(head("Investigation", "No walk named", "Open a walk from the list."),
      h("a", { class: "btn", href: "#/walks" }, "All walks"));
  }
  const call = (fn, args) => tryRead(() => rpc("aiq", fn, { p_run: run, ...args }), (e) => ({ rows: null, error: e }));
  const fetchAll = async () => {
    const [st, stack, clues, texts, gstats] = await Promise.all([
      call("walk_structure"), call("walk_stack"), call("walk_clues"), call("walk_clue_texts"), call("walk_graph_stats")]);
    return { st, s: st.rows, stack: stack.rows || [], clues: clues.rows || [], gstats: gstats.rows || {},
             texts: Object.fromEntries((texts.rows || []).map((t) => [t.key, t])),
             errors: { stack: stack.error, clues: clues.error, texts: texts.error, gstats: gstats.error } };
  };
  const first0 = await fetchAll();
  if (first0.st.error) {
    return page(head("Investigation", short(run)),
      gap("aiq.walk_structure", first0.st.error.message, "query layer (REM-1245)"));
  }
  const S = { ...first0, oracle: null, wave: 0, selected: null, follow: true };
  // The walk's waves so far: a running walk adds one each reload, and the slider follows unless the reader moved it.
  const maxWave = () => Math.max(0, ...S.s.waves.map((w) => w.wave));
  const live = () => ["initializing", "running"].includes((S.s.state || {}).phase);
  S.wave = maxWave();
  const first = (S.s.questions[0] && S.s.questions[0].evidence || [])[0];
  S.selected = first ? first.doc : null;

  const node = page(head("Investigation · " + (S.s.summary.scope.channel || S.s.summary.scope.nodes || "scope"),
    S.s.question.text, null,
    h("a", { class: "btn ghost", href: "#/walks" }, "All walks")));
  const meta = h("div", { class: "walk-meta" });
  const progress = h("div", { class: "walk-progress" });
  const errorNote = h("p", { class: "note rose" });
  const scrub = h("input", { type: "range", min: 0, max: maxWave(), value: S.wave, "aria-label": "Wave" });
  const waveLabel = h("span", { class: "mono walk-wave" });
  const play = h("button", { class: "btn", type: "button" }, "Play");
  const oracleNote = h("span", { class: "mono walk-oracle-state" }, "oracle off");
  const oracleFile = h("input", { type: "file", accept: ".json,application/json", "aria-label": "Load an oracle labels file" });
  const stackBody = h("div", { class: "walk-stack" });
  const itemsBody = h("div", { class: "walk-stack" });
  const pad = (el) => h("div", { class: "walk-pad" }, el);
  const itemsPanel = panel("The answer's items", "oracle-scored", pad(itemsBody));
  itemsPanel.classList.add("walk-oracle-panel");
  const graphSvg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  graphSvg.setAttribute("class", "graph walk-graph");
  const legend = h("div", { class: "legend" });
  const insp = h("div", { class: "walk-insp" });
  const wavesBody = h("div", {});
  const statsBody = h("div", {});
  const oracleBody = h("div", { class: "walk-oracle-body" });
  const oraclePanel = panel("Oracle", "oracle-scored · full run", pad(oracleBody));
  const spendBody = h("div", { class: "walk-stack" });
  const spendPanel = panel("Spend", "full run · walk_structure.cost", pad(spendBody));
  oraclePanel.classList.add("walk-oracle-panel");

  node.append(
    h("div", { class: "walk-head" }, meta, errorNote, progress),
    h("div", { class: "toolbar walk-toolbar" }, play, scrub, waveLabel, h("span", { class: "spacer" }),
      h("details", { class: "disclosure walk-oracle-toggle" },
        h("summary", {}, h("span", { class: "chip walk-oracle-chip" }, h("i", { class: "dot" }), "oracle"), " the answer key, never shown to the walk"),
        h("div", { class: "form-stack" },
          h("p", { class: "hint" }, "Load a JSON file {\"labelled\": [document keys], \"items\": [{\"item\", \"docs\"}]} for this walk's question, or a bundle's oracle/all.json, from which the entry for this question is taken. ",
            "It is passed to aiq.walk_structure beside the run, and only what it adds is shown in this colour."),
          oracleFile, oracleNote))),
    h("div", { class: "grid g-1-2" },
      h("div", { class: "grid" }, panel("Question stack", "walk_stack", pad(stackBody)), itemsPanel),
      h("div", { class: "grid" },
        panel("The walk across the conversation", "walk_structure.reads",
          h("div", { class: "walk-graph-body walk-pad" }, legend, h("div", { class: "graphwrap" }, graphSvg),
            h("p", { class: "hint" }, "Each dot is a message the walk read: across, its place in the conversation; down, the wave it was read in. A line joins a read to the read whose lead brought it. Select a dot to inspect it."))),
        panel("Selected message", "walk_clues · walk_clue_texts", pad(insp)))),
    h("div", { class: "grid g2" },
      panel("Waves", "full run · walk_structure.waves", wavesBody),
      panel("Graph and run", "full run · walk_graph_stats", pad(statsBody))),
    spendPanel,
    oraclePanel);

  const render = () => {
    const s = S.s;
    scrub.value = S.wave;
    waveLabel.textContent = `wave ${S.wave} of ${maxWave()} · ${s.reads.filter((r) => r.wave <= S.wave).length} reads`;
    fill(meta, ...[
      ["walk", short(s.run)], ["decider", s.counts.jev.model && s.counts.jev.model !== "None" ? s.counts.jev.model : s.summary.decider.mode],
      ["describes leads by", s.settings.describe], ["question stack", s.stack_kept ? "kept" : "not kept"],
      ...stateItems(s.state || {})].map(([k, v]) =>
        h("div", { class: "walk-meta-item" }, h("span", { class: "label" }, k), typeof v === "string" ? h("span", { class: "mono" }, esc(v)) : v)));
    scrub.max = maxWave();
    errorNote.hidden = !(s.state && s.state.error);
    if (s.state && s.state.error) fill(errorNote, h("strong", {}, "The walk failed: "), esc(typeof s.state.error === "string" ? s.state.error : JSON.stringify(s.state.error)));
    renderProgress(); renderStack(); renderGraph(); renderInspector(); renderWaves(); renderStats(); renderOracle(); renderSpend();
  };

  /* The walk's real state, from walk_structure's state (phase: initializing, running, failed, stopped). The stop is
     shown only once there is one. */
  function stateItems(st) {
    const tone = { stopped: "succeeded", failed: "failed", running: "running", initializing: "pending" }[st.phase] || "";
    const items = [["state", chip(st.phase || "unknown", tone)]];
    if (st.wave != null) items.push(["wave", String(st.wave)]);
    if (st.step) items.push(["in flight", String(st.step)]);
    if (st.stop) items.push(["stopped", `${st.stop.reason} at wave ${st.stop.wave}`]);
    return items;
  }

  const stackAt = (w) => {
    const ws = S.stack.map((r) => r.wave);
    const at = Math.min(w, Math.max(-1, ...ws));
    return S.stack.filter((r) => r.wave === at);
  };

  const renderProgress = () => {
    // V0 answers no question on a line; a question closes only by structure (stale, displaced, its parts closed).
    const rows = stackAt(S.wave), ans = rows.filter((r) => r.state !== "open").length;
    const kids = [h("span", { class: "label" }, "questions closed, by structure"),
      h("div", { class: "bar" }, h("span", { style: `width:${rows.length ? 100 * ans / rows.length : 0}%` })),
      h("span", { class: "mono" }, `${ans} of ${rows.length}`)];
    const o = S.oracle;
    if (o && o.items && o.items.length) {
      const n = o.items.filter((i) => i.first_read_wave != null && i.first_read_wave <= S.wave).length;
      kids.push(h("span", { class: "label walk-oracle-ink" }, "oracle-scored: answer items reached"),
        h("div", { class: "bar walk-oracle-bar" }, h("span", { style: `width:${100 * n / o.items.length}%` })),
        h("span", { class: "mono" }, `${n} of ${o.items.length}`));
    }
    fill(progress, ...kids);
  };

  // What each read message says, from the latest structure (a running walk adds reads).
  const lineOfDoc = () => Object.fromEntries(S.s.reads.map((r) => [r.doc, r.line]));
  const labelled = () => new Set(S.oracle ? S.oracle.labelled || [] : []);

  const renderStack = () => {
    const rows = stackAt(S.wave), lab = labelled();
    const prev = Object.fromEntries(stackAt(S.wave - 1).map((r) => [r.question, new Set(r.evidence)]));
    const kids = [];
    if (S.errors.stack) kids.push(gap("aiq.walk_stack", S.errors.stack.message, "query layer (REM-1245)"));
    else if (!S.s.stack_kept) kids.push(h("p", { class: "hint" }, "This walk kept no question stack: it ran without one, so the question asked is all there is."));
    else if (rows.length === 1) kids.push(h("p", { class: "hint" }, "The decider split nothing on this walk: the question asked is the only one. The reads it judged to bear on it are listed, newest at each wave first."));
    rows.forEach((r) => {
      const ev = r.evidence.map((doc, i) => ({ doc, p: r.evidence_p[i] }));
      const nLab = ev.filter((e) => lab.has(e.doc)).length;
      /* V0 closes a question by structure only (stale, displaced, its parts closed); no line closes one as
         answered (spec §14, F12). A closed question shows its structural reason. Its highest-P lines and the board's
         links both read 'judged to bear on': 'this line answers it' measured 43% precision at best, so no phrase on
         this screen says a line answers a question. */
      const full = (S.s.questions || []).find((q) => q.id === r.question) || {};
      const reason = full.closed_by || full.close_reason || null;
      const top = Array.isArray(full.judged_to_bear_on) ? full.judged_to_bear_on : [];
      kids.push(h("div", { class: "walk-question" },
        h("div", { class: "pill-row" }, h("span", { class: "chip kind" }, r.question),
          chip(r.state === "open" ? "open" : reason ? `closed: ${reason}` : r.state, r.state === "open" ? "running" : "cancelled"),
          h("span", { class: "chip kind" }, "opened wave " + r.opened_wave),
          h("span", { class: "chip kind" }, ev.length + " judged to bear on it"),
          S.oracle ? h("span", { class: "chip walk-oracle-chip" }, `oracle-scored: ${nLab} of ${ev.length} labelled`) : null),
        h("p", { class: "walk-qtext" }, esc(r.text)),
        h("div", { class: "walk-evidence" }, ev.length ? ev.map((e) =>
          h("button", { type: "button", class: "walk-ev" + (prev[r.question] && !prev[r.question].has(e.doc) ? " fresh" : ""),
                        onclick: () => { S.selected = e.doc; renderGraph(); renderInspector(); } },
            h("span", { class: "mono walk-p" }, e.p != null ? e.p.toFixed(2) : "—"),
            h("span", { class: "walk-ev-line" }, esc(lineOfDoc()[e.doc] || e.doc),
              lab.has(e.doc) ? h("span", { class: "walk-oracle-ink mono walk-ev-tag" }, "oracle-scored: labelled evidence") : null)))
          : h("p", { class: "hint" }, "Nothing judged to bear on it yet.")),
        top.length ? h("div", { class: "walk-judged" },
          h("span", { class: "label" }, "Top lines judged to bear on it · full run"),
          h("p", { class: "hint" }, "The lines the decider rated highest for this question. Unscored: the calibration found no P at which such a line reliably answers it (spec §14)."),
          top.map((t) => h("button", { type: "button", class: "walk-ev", onclick: () => { S.selected = t.doc; renderGraph(); renderInspector(); } },
            h("span", { class: "mono walk-p" }, t.p != null ? Number(t.p).toFixed(2) : "—"),
            h("span", { class: "walk-ev-line" }, esc(t.line || t.doc))))) : null));
    });
    fill(stackBody, ...kids);
    itemsPanel.hidden = !(S.oracle && S.oracle.items);
    if (S.oracle && S.oracle.items) {
      fill(itemsBody, h("p", { class: "hint" }, "The benchmark's answer needs these items. Each closes at the walk's first read of a message it cites: the stack an omniscient reader would keep."),
        ...S.oracle.items.map((i) => {
          const closed = i.first_read_wave != null && i.first_read_wave <= S.wave;
          return h("button", { type: "button", class: "walk-ev", onclick: () => { if (i.first_read_doc) { S.selected = i.first_read_doc; renderGraph(); renderInspector(); } } },
            h("span", { class: "mono walk-p walk-oracle-ink" }, closed ? "w" + i.first_read_wave : "open"),
            h("span", { class: "walk-ev-line" }, h("strong", {}, esc(i.item)), " ",
              chip(closed ? "closed at read " + i.first_read_k : i.first_read_wave != null ? "closes at wave " + i.first_read_wave : "never reached",
                closed ? "succeeded" : "running")));
        }));
    }
  };

  const renderGraph = () => {
    const s = S.s, mw = maxWave(), N = (S.gstats && S.gstats.documents) || 1;
    const W = Math.max(640, graphSvg.parentElement ? graphSvg.parentElement.clientWidth - 30 : 640);
    const pad = { l: 34, r: 10, t: 12, b: 44 }, rowH = 24, oracleRow = S.oracle ? 22 : 0;
    const H = pad.t + pad.b + (mw + 1) * rowH + oracleRow;
    const x = (pos) => pad.l + (W - pad.l - pad.r) * pos / Math.max(1, N - 1);
    const y = (w) => pad.t + w * rowH + rowH / 2;
    const byDoc = Object.fromEntries(s.reads.map((r) => [r.doc, r]));
    const clue = Object.fromEntries(S.clues.map((c) => [c.key, c]));
    const lab = labelled();
    graphSvg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    graphSvg.setAttribute("width", W); graphSvg.setAttribute("height", H);
    let g = "";
    for (let w = 0; w <= mw; w++) g += `<line class="walk-row" x1="${pad.l}" x2="${W - pad.r}" y1="${y(w)}" y2="${y(w)}"/><text x="4" y="${y(w) + 3}">w${w}</text>`;
    [0, 250, 500, 750, 1000, 1500, 2000].filter((t) => t < N).forEach((t) => g += `<text x="${x(t)}" y="${H - 22}" text-anchor="middle">${t}</text>`);
    g += `<text class="lbl" x="${W - pad.r}" y="${H - 6}" text-anchor="end">PLACE IN THE CONVERSATION, OF ${N}</text>`;
    const shown = s.reads.filter((r) => r.wave <= S.wave && r.pos != null);
    shown.forEach((r) => {
      const c = r.via && r.via !== "search" ? clue[r.via] : null, src = c ? byDoc[c.source] : null;
      if (!src || src.pos == null) return;
      const x1 = x(src.pos), y1 = y(src.wave), x2 = x(r.pos), y2 = y(r.wave);
      const hot = S.selected && (S.selected === r.doc || S.selected === src.doc);
      g += `<path class="walk-hop k-${kindOf(r.via)}${hot ? " hot" : ""}" d="M${x1},${y1} Q${(x1 + x2) / 2},${Math.min(y1, y2) - 10} ${x2},${y2}"/>`;
    });
    if (S.oracle) {
      const yo = H - pad.b - 4;
      g += `<text class="walk-oracle-fill" x="4" y="${yo + 3}">key</text>`;
      (S.oracle.labelled || []).forEach((doc) => {
        const r = byDoc[doc];
        if (r && r.pos != null) g += `<circle class="walk-key${r.wave <= S.wave ? " read" : ""}" cx="${x(r.pos)}" cy="${yo}" r="4"><title>${doc}</title></circle>`;
      });
    }
    shown.forEach((r) => {
      const sel = S.selected === r.doc;
      g += `<circle data-doc="${r.doc}" class="walk-read k-${kindOf(r.via)}${lab.has(r.doc) ? " labelled" : ""}${sel ? " sel" : ""}" cx="${x(r.pos)}" cy="${y(r.wave)}" r="${sel ? 6 : 3.4}"><title>${r.doc} · wave ${r.wave} · ${KIND_LABEL[kindOf(r.via)]}</title></circle>`;
    });
    graphSvg.innerHTML = g;
    graphSvg.querySelectorAll("circle[data-doc]").forEach((c) => c.addEventListener("click", () => {
      S.selected = c.getAttribute("data-doc"); renderGraph(); renderInspector(); }));
    fill(legend, ...KINDS.map((k) => h("span", {}, h("i", { class: "k-" + k }), `${KIND_LABEL[k]} (${s.counts.reads_by[k] || 0})`)),
      S.oracle ? h("span", { class: "walk-oracle-ink" }, h("i", { class: "walk-oracle-swatch" }), "oracle-scored: labelled evidence, ringed if read; hollow on the key row if not yet") : null);
  };

  const renderInspector = () => {
    const r = S.s.reads.find((x) => x.doc === S.selected);
    if (!r) { fill(insp, h("p", { class: "hint" }, "Select a message on the conversation, or a read in the stack.")); return; }
    /* The inspector shows the walk as of the wave on the slider. A message read later is not shown: its words, and
       the leads out of it, are things the walk did not know yet. */
    if (r.wave > S.wave) {
      fill(insp, h("div", { class: "row-between" }, h("strong", { class: "mono" }, r.doc)),
        h("p", { class: "hint" }, `Not read yet at wave ${S.wave}: the walk reads this message at wave ${r.wave}.`),
        h("button", { class: "btn", type: "button", onclick: () => { S.wave = r.wave; render(); } }, `Go to wave ${r.wave}`));
      return;
    }
    const c = r.via && r.via !== "search" ? S.clues.find((x) => x.key === r.via) : null;
    // Leads out of this message the walk had judged by this wave; a lead counts as travelled only once it was.
    const out = S.clues.filter((x) => x.source === r.doc && x.wave <= S.wave).sort((a, b) => (b.p ?? -1) - (a.p ?? -1));
    const stateAt = (x) => (x.travelled_wave != null && x.travelled_wave <= S.wave ? "travelled" : x.decision);
    const lab = labelled().has(r.doc);
    const leadText = h("div", {});
    const said = (key) => S.texts[key] ? h("pre", { class: "walk-said" }, esc(S.texts[key].text)) : null;
    fill(insp, 
      h("div", { class: "row-between" }, h("strong", { class: "mono" }, r.doc), h("span", { class: "spacer" }),
        h("span", { class: "mono hint" }, `read ${r.ord} · wave ${r.wave} · sitting ${r.sitting ?? "—"} · ${r.said_at ? r.said_at.slice(0, 10) : ""}`)),
      h("p", { class: "walk-qtext" }, esc(r.line)),
      h("div", { class: "pill-row" },
        h("span", { class: "chip kind" }, "reached by " + (r.via == null ? "a travel, queued" : r.via === "search" ? "search" : r.via)),
        c ? h("span", { class: "chip kind" }, "P " + (c.p != null ? c.p.toFixed(2) : "—")) : null,
        c ? chip(c.decision, c.decision === "accepted" ? "succeeded" : "failed") : null,
        r.answers && r.answers.length ? chip("linked to " + r.answers.join(", "), "succeeded") : null,
        lab ? h("span", { class: "chip walk-oracle-chip" }, "oracle-scored: labelled evidence") : null),
      c ? h("div", { class: "form-stack" }, h("span", { class: "label" }, "What the decider read for the lead that brought it"), said(c.key),
            S.texts[c.key] && typeof S.texts[c.key].state_line === "string" && S.texts[c.key].state_line !== "null" ? h("p", { class: "hint" }, "With the stack: " + S.texts[c.key].state_line) : null) : null,
      S.errors.texts ? gap("aiq.walk_clue_texts", S.errors.texts.message, "query layer (REM-1245)") : null,
      h("span", { class: "label" }, `Leads out of this message judged by wave ${S.wave} · ${out.length} · select one for its text`),
      out.length ? h("div", { class: "walk-leads" }, out.map((x) =>
        h("button", { type: "button", class: "walk-lead", onclick: () => fill(leadText, h("strong", { class: "mono" }, x.key), said(x.key)) },
          h("span", { class: "mono" }, x.p != null ? "P " + x.p.toFixed(2) : "unjudged"),
          h("span", { class: "mono" }, "w" + x.wave),
          chip(stateAt(x), stateAt(x) === "travelled" ? "succeeded" : stateAt(x) === "rejected" ? "failed" : stateAt(x) === "accepted" ? "running" : "cancelled"),
          h("span", { class: "mono walk-key-text" }, `${x.key} → ${x.targets.length}`)))) : h("p", { class: "hint" }, "None."),
      leadText);
  };

  const renderWaves = () => {
    fill(wavesBody, table(["Wave", "Reads", "Judged", "Accepted", "Open", "Fresh"], S.s.waves, (w) =>
      h("tr", { class: w.wave === S.wave ? "walk-cur" : w.wave > S.wave ? "walk-future" : "" },
        h("td", { class: "mono" }, w.wave), h("td", { class: "mono" }, w.reads), h("td", { class: "mono" }, w.judged),
        h("td", { class: "mono" }, w.accepted), h("td", { class: "mono" }, w.open_leads), h("td", { class: "mono" }, w.fresh))));
  };

  const renderStats = () => {
    if (S.errors.gstats) { fill(statsBody, gap("aiq.walk_graph_stats", S.errors.gstats.message, "query layer (REM-1245)")); return; }
    const g = S.gstats, c = S.s.counts;
    const rows = [["messages", g.documents], ["links beside (next)", g.links.next], ["links close in meaning", g.links.near],
      ["terms under the cap", `${g.terms.under_cap} of ${g.terms.held}`], ["leads per read, median / max", `${g.leads_per_read.median} / ${g.leads_per_read.max}`],
      ["within 1 / 2 hops of the seeds", `${Math.round(g.within_1_hop * 100)}% / ${Math.round(g.within_2_hops * 100)}%`],
      ["reads", c.reads], ["leads raised", c.leads], ["judgements", c.judgements], ["leads accepted", c.leads_accepted],
      ["reads judged to bear on a question", c.evidence_edges], ["Jev requests", c.jev.requests], ["Jev input tokens", Number(c.jev.input_tokens).toLocaleString()]];
    fill(statsBody, h("dl", { class: "kv" }, rows.flatMap(([k, v]) => [h("dt", {}, k), h("dd", { class: "mono" }, esc(v))])));
  };

  /* What the walk cost, from walk_structure's cost part (james, 42d61547): totals at the stated price, per wave,
     per move and per question, and the cost-against-discovery curve, all cumulative and ready-made. The page only
     lays them out and plots the curve's points. */
  const usd = (v) => (v == null ? "—" : "$" + Number(v).toFixed(v < 0.01 ? 4 : 3));
  const renderSpend = () => {
    const c = (S.oracle && S.oracleCost) || S.s.cost;
    if (!c) { fill(spendBody, h("p", { class: "hint" }, "This database's walk structure has no cost part yet.")); return; }
    const t = c.total || {}, pr = c.price || {};
    fill(spendBody,
      h("dl", { class: "kv" }, [["Jev requests", t.requests], ["judgements", t.judgements], ["input tokens", Number(t.input_tokens || 0).toLocaleString()],
        ["output tokens", Number(t.output_tokens || 0).toLocaleString()], ["spend", usd(t.usd)],
        ["price", `$${pr.usd_per_m_input}/M in, $${pr.usd_per_m_output}/M out, as of ${pr.as_of}`]]
        .flatMap(([k, v]) => [h("dt", {}, k), h("dd", { class: "mono" }, esc(v))])),
      c.curve && c.curve.length ? curve(c.curve) : null,
      h("span", { class: "label" }, "By wave"),
      table(["Wave", "Requests", "Judgements", "Input tokens", "Spend", "Reads", "Judged to bear on"].concat(S.oracle ? ["Labelled read (oracle)"] : []),
        c.by_wave || [], (w) => h("tr", { class: w.wave === S.wave ? "walk-cur" : w.wave > S.wave ? "walk-future" : "" },
          [w.wave, w.requests, w.judgements, Number(w.input_tokens || 0).toLocaleString(), usd(w.usd), w.reads, w.reads_bearing]
            .concat(S.oracle ? [w.labelled_read] : []).map((v) => h("td", { class: "mono" }, esc(v))))),
      h("span", { class: "label" }, "By move"),
      table(["Move", "Requests", "Judgements", "Tokens per judgement", "Spend", "Share"], c.by_move || [], (m) =>
        h("tr", {}, [m.move, m.requests, m.judgements, m.tokens_per_judgement, usd(m.usd), m.share != null ? Math.round(m.share * 100) + "%" : "—"]
          .map((v, i) => h("td", { class: i ? "mono" : "" }, esc(v))))),
      (c.by_question || []).length ? h("span", { class: "label" }, "By question (the judge requests per question a lead was judged against)") : null,
      (c.by_question || []).length ? table(["Question", "Requests", "Judgements", "Input tokens", "Spend"], c.by_question, (q) =>
        h("tr", {}, h("td", {}, esc(q.question)), ...[q.requests, q.judgements, Number(q.input_tokens || 0).toLocaleString(), usd(q.usd)].map((v) => h("td", { class: "mono" }, esc(v))))) : null);
  };

  /* The cost-against-discovery curve: the layer's cumulative points per wave, spend across, reads judged to bear on
     the question up (and, with the oracle, labelled reads, in its own colour). The viewed wave's point is marked. */
  const curve = (pts) => {
    const W = 520, H = 200, pad = { l: 44, r: 14, t: 12, b: 34 };
    const xmax = Math.max(...pts.map((p) => Number(p.usd) || 0), 1e-9);
    const series = [["reads_bearing", "walk-curve-bear", "judged to bear on"]].concat(S.oracle ? [["labelled_read", "walk-curve-oracle", "oracle-scored: labelled read"]] : []);
    const ymax = Math.max(1, ...pts.flatMap((p) => series.map(([k]) => Number(p[k]) || 0)));
    const x = (v) => pad.l + (W - pad.l - pad.r) * (Number(v) || 0) / xmax, y = (v) => H - pad.b - (H - pad.t - pad.b) * (Number(v) || 0) / ymax;
    let g = `<line class="walk-row" x1="${pad.l}" x2="${W - pad.r}" y1="${H - pad.b}" y2="${H - pad.b}"/><line class="walk-row" x1="${pad.l}" x2="${pad.l}" y1="${pad.t}" y2="${H - pad.b}"/>`;
    g += `<text x="${pad.l}" y="${H - 18}" text-anchor="start">$0</text><text x="${W - pad.r}" y="${H - 18}" text-anchor="end">${usd(xmax)}</text>`;
    g += `<text x="${pad.l - 6}" y="${pad.t + 8}" text-anchor="end">${ymax}</text><text x="${pad.l - 6}" y="${H - pad.b}" text-anchor="end">0</text>`;
    g += `<text class="lbl" x="${W - pad.r}" y="${H - 4}" text-anchor="end">CUMULATIVE SPEND</text>`;
    for (const [k, cls] of series) {
      g += `<polyline class="${cls}" points="${pts.map((p) => `${x(p.usd)},${y(p[k])}`).join(" ")}"/>`;
      const cur = pts.filter((p) => p.wave <= S.wave).slice(-1)[0];
      if (cur) g += `<circle class="${cls}" cx="${x(cur.usd)}" cy="${y(cur[k])}" r="4"><title>wave ${cur.wave}: ${usd(cur.usd)}, ${cur[k]}</title></circle>`;
    }
    return h("div", { class: "form-stack" },
      h("span", { class: "label" }, "Spend against discovery, cumulative by wave"),
      h("div", { class: "legend" }, series.map(([, cls, lbl]) => h("span", {}, h("i", { class: cls }), lbl))),
      h("div", { class: "graphwrap", html: `<svg class="graph walk-graph" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="Spend against reads judged to bear on the question, by wave">${g}</svg>` }));
  };

  const renderOracle = () => {
    oraclePanel.hidden = !S.oracle;
    if (!S.oracle) return;
    const o = S.oracle;
    fill(oracleBody, 
      h("p", { class: "hint" }, esc(o.note)),
      /* The ceiling is the oracle decider (spec section 11): same graph, seeds and budget, choosing with the key. Beside
         it, what the walk and search's order read of the labelled set by the same budgets. */
      o.ceiling && o.ceiling.built && o.ceiling.evidence_by
        ? table(["Reads", "Ceiling (oracle decider)", "Walk", "Search", "Of"], o.ceiling.evidence_by, (r) =>
            h("tr", {}, h("td", { class: "mono" }, r.k), h("td", { class: "mono walk-oracle-ink" }, r.oracle),
              h("td", { class: "mono" }, r.walk), h("td", { class: "mono" }, r.search), h("td", { class: "mono" }, (o.labelled || []).length)))
        : o.coverage ? table(["Reads", "Walk", "Search", "Of"], o.coverage, (r) =>
            h("tr", {}, h("td", { class: "mono" }, r.k), h("td", { class: "mono" }, r.walk), h("td", { class: "mono" }, r.search), h("td", { class: "mono" }, r.labelled))) : null,
      o.ceiling && o.ceiling.built === false ? h("p", { class: "hint" }, "Ceiling: " + o.ceiling.note + ".") : null,
      h("p", { class: "hint" }, `Of the ${S.s.counts.evidence_edges} reads the decider judged to bear on a question, ${Array.isArray(o.linked_evidence) ? o.linked_evidence.length : o.linked_evidence} are labelled evidence.`),
      h("span", { class: "label" }, "Oracle-scored: labelled evidence missed, and why"),
      (o.why || []).length ? table(["Message", "Why", "Lead"], o.why, (w) =>
        h("tr", {}, h("td", { class: "mono" }, w.doc), h("td", {}, chip(w.reason + (w.p != null ? " " + w.p.toFixed(2) : ""), w.reason === "open" ? "running" : "failed")),
          h("td", { class: "mono" }, esc(w.key) + (w.detail ? " · " + w.detail : "")))) : h("p", { class: "hint" }, "None."),
      o.timeline ? timeline(o.timeline) : null);
  };

  /* Each labelled message across the waves, from walk_structure's oracle timeline (spec §11): when a lead to it was
     first offered (hollow), first accepted (diamond), and when the walk read it (filled). A long gap after an early
     offer is the decider's or the opener's choice; a late first offer is distance. The rows are the layer's; the
     page draws them where they say and adds nothing. */
  const timeline = (rows) => {
    const mw = maxWave(), W = 300, cell = W / (mw + 1), x = (w) => cell * w + cell / 2;
    const glyphs = (t) => {
      let g = "";
      if (t.first_offered_wave != null) {
        const end = t.read_wave != null ? t.read_wave : mw;
        g += `<line class="walk-tl-wait${t.read_wave == null ? " never" : ""}" x1="${x(t.first_offered_wave)}" x2="${x(end)}" y1="9" y2="9"/>`;
        g += `<circle class="walk-tl-offered" cx="${x(t.first_offered_wave)}" cy="9" r="4"><title>offered at wave ${t.first_offered_wave} by ${esc(t.first_offered_lead)}</title></circle>`;
      }
      if (t.first_accepted_wave != null)
        g += `<rect class="walk-tl-accepted" x="${x(t.first_accepted_wave) - 4}" y="5" width="8" height="8" transform="rotate(45 ${x(t.first_accepted_wave)} 9)"><title>accepted at wave ${t.first_accepted_wave} by ${esc(t.first_accepted_lead)}, P ${t.first_accepted_p}</title></rect>`;
      if (t.read_wave != null)
        g += `<circle class="walk-tl-read${t.read_wave <= S.wave ? "" : " later"}" cx="${x(t.read_wave)}" cy="9" r="4.5"><title>read at wave ${t.read_wave} via ${esc(t.read_via ?? "a queued travel")}</title></circle>`;
      return g;
    };
    const said = (t) => t.read_wave == null ? (t.first_offered_wave == null ? "never offered, never read" : `offered at wave ${t.first_offered_wave}, never read`)
      : t.first_offered_wave == null ? `read at wave ${t.read_wave} via ${t.read_via === "search" ? "search" : t.read_via || "a queued travel"}, no lead offered first`
      : `read ${t.wait} wave(s) after its first offer` + (t.first_accepted_wave != null && t.first_accepted_wave < t.read_wave ? `, ${t.read_wave - t.first_accepted_wave} after acceptance` : "");
    return h("div", { class: "form-stack" },
      h("span", { class: "label" }, "Oracle-scored, full run: when each labelled message was offered, accepted and read"),
      h("div", { class: "legend" },
        h("span", {}, h("i", { class: "walk-tl-swatch offered" }), "a lead to it first offered"),
        h("span", {}, h("i", { class: "walk-tl-swatch accepted" }), "first accepted"),
        h("span", {}, h("i", { class: "walk-tl-swatch read" }), "read")),
      table(["Message", `Waves 0–${mw}`, "What happened"], rows, (t) =>
        h("tr", {},
          h("td", { class: "mono" }, h("a", { href: "#", onclick: (e) => { e.preventDefault(); if (lineOfDoc()[t.doc]) { S.selected = t.doc; renderGraph(); renderInspector(); } } }, t.doc)),
          h("td", { html: `<svg class="walk-tl" viewBox="0 0 ${W} 18" width="${W}" height="18" role="img" aria-label="${esc(said(t))}">${glyphs(t)}</svg>` }),
          h("td", {}, said(t)))));
  };

  scrub.addEventListener("input", () => { S.wave = Number(scrub.value); S.follow = S.wave === maxWave(); render(); });
  // A walk still running is read again every few seconds, until it stops or the reader leaves the screen.
  const poll = async () => {
    if (!node.isConnected || !live()) return;
    const next = await fetchAll();
    if (!next.st.error) {
      Object.assign(S, next);
      if (S.follow) S.wave = maxWave();
      render();
    }
    if (live()) setTimeout(poll, 3000);
  };
  if (live()) setTimeout(poll, 3000);
  let timer = null;
  play.addEventListener("click", () => {
    if (timer) { clearInterval(timer); timer = null; play.textContent = "Play"; return; }
    S.wave = 0; render(); play.textContent = "Pause";
    timer = setInterval(() => {
      if (S.wave >= maxWave() || !node.isConnected) { clearInterval(timer); timer = null; play.textContent = "Play"; return; }
      S.wave += 1; render();
    }, 900);
  });
  oracleFile.addEventListener("change", async () => {
    const f = oracleFile.files && oracleFile.files[0];
    if (!f) return;
    try {
      const file = JSON.parse(await f.text());
      /* One question's key, or a bundle's all.json holding every question's: then the entry whose question is this
         walk's, word for word. A file with no entry for this question says so rather than scoring with another's. */
      const spec = Array.isArray(file.questions)
        ? file.questions.find((q) => q.question === S.s.question.text)
        : file;
      if (!spec) throw new Error("the file holds no answer key for this walk's question");
      if (!Array.isArray(spec.labelled)) throw new Error("the file has no \"labelled\" list of document keys");
      const res = await rpc("aiq", "walk_structure", { p_run: run, p_oracle: spec.labelled, p_items: spec.items || null });
      S.oracle = res.rows.oracle || null;
      S.oracleCost = res.rows.cost || null;   // the cost part with labelled_read, which only the oracle call carries
      oracleNote.textContent = S.oracle ? `oracle on · ${spec.labelled.length} labelled` : "the query layer returned no oracle parts";
    } catch (e) {
      S.oracle = null;
      oracleNote.textContent = "oracle off · " + ((e instanceof ApiError ? e.message : String(e.message || e)));
    }
    render();
  });
  addEventListener("resize", () => { if (node.isConnected) renderGraph(); });
  render();
  requestAnimationFrame(() => renderGraph());
  return node;
}
