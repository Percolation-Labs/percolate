/* The work and monitoring screens.
 *
 * Each is a function that fetches and returns a node. Two rules hold across
 * all of them:
 *   1. Show what the database says. Where it refuses, show THAT -- named, with
 *      the error it returned. A UI that fills in what the database would not
 *      say is a UI that has started deciding what is true.
 *   2. Every mutation is an RPC that checks its own permission. Nothing here
 *      hides a button because of a role; it lets the function refuse and shows
 *      the refusal, because the function is the authority and this is not.
 *
 * Rule 1 has a corollary that cost this app five broken screens and a green
 * dashboard over them: a read that FAILED is not a read that returned nothing.
 * Every count below comes from a `stat`/`statGap` pair for that reason, and
 * every projection comes from `reads.js` so the audit executes the same one.
 */

import { select, rpc, read, ApiError, config, claims } from "./api.js";
import { READS } from "./reads.js";
import { describeCron, nextFires } from "./cron.js";
import { suggestSchedule } from "./schedule-assist.js";
import { runForm, jsonObject } from "./workbench.js";
import { BRIEF_INPUT, evidenceBrief, taskResult } from "./workflow-authoring.js";
import {workflowComposer} from './workflow-composer.js';
import { draftStore, stageWorkflow } from "./drafts.js";
import { markdown } from "./md.js";
import {workspaceTabs,contextualHelp,editorWorkspace} from "./workspace.js";
import { chip, dag, eventTone, fmtTime, gap, h, iconAction, panel, seg, short, stat, statGap, status, stream, table } from "./ui.js";

/* The tile, or the reason there is no tile. One call site cannot get this
   wrong in the direction that matters, which is why it is a function. */
const pad2 = (n) => String(n).padStart(2, "0");

/* A stored expression the engine accepted should always describe, but a row
   predating a validation change should not take the page down with it. */
const safeDescribe = (expr) => {
  try { return describeCron(expr); } catch (e) { return "unreadable expression: " + e.message; }
};

export const statOf = (res, label, value, note, tone) =>
  res && res.error ? statGap(label, res.error) : stat(label, value, note, tone);

export const head = (kicker, title, lede, actions) =>
  h("header", { class: "page-head" },
    h("div", { class: "head-row" },
      h("div", { style: "display:flex;flex-direction:column;gap:.4rem" },
        h("span", { class: "kicker" }, kicker), h("h1", {}, title)),
      h("span", { class: "spacer" }), actions || null),
    lede ? h("p", { class: "lede" }, lede) : null);

export const page = (...kids) => h("div", { class: "page wide" }, ...kids);

export async function tryRead(fn, fallback) {
  try { return await fn(); }
  catch (e) { return fallback(e instanceof ApiError ? e : new ApiError(0, { message: String(e) }, "")); }
}

/* The definitions map. `runs_api` carries `name` now (REM-62), so labelling a
   run no longer needs this -- but two things still do, and they are why it did
   not go away entirely:

     - a run started by a data source is labelled with the SOURCE's name, not
       the generated `source_<uuid>` workflow it runs, and that correspondence
       lives on the channel row;
     - the run detail screen prints the definition's VERSION beside the name.

   A FAILED load is not cached and carries its error out. It used to do
   neither: the empty result was cached as though it were an answer, so one
   refused read turned into "0 definitions" on every screen for the rest of
   the page's life, including after the cause was fixed. */
let DEFS = null, DEFS_ACCOUNT = null;
addEventListener("p8-definitions-changed", () => { DEFS = null; });
export async function defs() {
  const account = config().rest + ":" + claims()?.sub;
  if (DEFS && DEFS_ACCOUNT === account) return DEFS;
  const r = await tryRead(() => read(READS.definitions), (e) => ({ rows: [], error: e }));
  const sources = await tryRead(() => read(READS.dataSources), () => ({rows:[]}));
  const sourceNames = new Map(sources.rows.filter(s=>s.config.ingest_workflow).map(s=>[s.config.ingest_workflow,s.name]));
  const d = { rows: r.rows || [], error: r.error, sourceNames,
              byId: new Map((r.rows || []).map((x) => [x.id, x])) };
  if (!r.error) { DEFS = d; DEFS_ACCOUNT = account; }
  return d;
}
/* The run's own name, with the source overlay on top of it. The fallback to
   the definitions map is for a caller that has an id and no row -- and to
   short(id), because a run whose definition has been deleted still has to
   render as something. */
export const wfName = (d, run) => {
  const name = typeof run === "object" && run
    ? (run.name ?? d.byId.get(run.workflow_def_id)?.name)
    : d.byId.get(run)?.name;
  const id = typeof run === "object" && run ? run.workflow_def_id : run;
  return d.sourceNames?.get(name) || name || short(id);
};

/* task_events.detail carries every field the trigger recorded, most of them
   null on a normal transition. Printing them makes every row read the same. */
const detailText = (d) => {
  if (!d || typeof d !== "object") return null;
  const kept = Object.entries(d).filter(([, v]) => v !== null && v !== "" && v !== 0);
  return kept.length ? kept.map(([k, v]) => k + "=" + JSON.stringify(v)).join(" ").slice(0, 90) : null;
};

const evRow = (e) => ({
  t: (e.at || e.created_at || "").slice(11, 19),
  tone: eventTone(e.to_status),
  what: (e.step_key ? e.step_key + "  " : "") + (e.from_status ? e.from_status + " -> " : "") + (e.to_status || ""),
  meta: [e.queue && e.queue !== "none" ? "queue " + e.queue : null,
         detailText(e.detail)].filter(Boolean).join(" · "),
});

/* -- Overview ---------------------------------------------- */
export async function overview() {
  const node = page(head("Your work, in motion", "Overview",
    "Define the job. Run it with your data. See what happened at every step."));
  node.append(h("section", {class:"workflow-hero", "aria-label":"Start a workflow"},
    h("div", {class:"workflow-hero-copy"}, h("span", {class:"kicker"}, "From a task to a repeatable process"),
      h("h2", {}, "What work needs doing?"),
      h("p", {}, "Build a workflow from queries, agents and calls to other systems. Give it inputs, inspect its results, and run it again when the job returns."),
      h("div", {class:"form-actions"}, h("a", {class:"btn primary", href:"#/draft"}, "Create a workflow"),
        h("a", {class:"btn", href:"#/workflows"}, "Browse workflows"), h("a", {href:"#/help"}, "Help me plan it"))),
    h("ol", {class:"workflow-lifecycle"},
      [["01","Define","Choose the steps and their inputs."],["02","Run","Follow progress and inspect each result."],["03","Repeat","Use new inputs or add a schedule."]].map(([n,title,copy]) =>
        h("li", {}, h("span", {class:"lifecycle-number"}, n), h("div", {}, h("h3", {}, title), h("p", {}, copy)))))));

  const [byStatus, d, runsRes, evRes, qRes] = await Promise.all([
    tryRead(() => read(READS.runsByStatus), (e) => ({ rows: [], error: e })),
    defs(),
    tryRead(() => read(READS.recentRuns, "limit=8"), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.taskEvents, "limit=8"), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.queueDepth), (e) => ({ rows: [], error: e })),
  ]);

  node.querySelector('.head-row').append(h('a',{class:'btn primary',href:'#/draft'},'Create a workflow'));
  if(!d.error && d.rows.length){
    const hero=node.querySelector('.workflow-hero');
    const help=contextualHelp('How a workflow comes together',hero);
    node.append(help);
  }
  const n = (s) => (byStatus.rows || []).filter((r) => r.status === s).reduce((a, r) => a + Number(r.n), 0);
  const total = (byStatus.rows || []).reduce((a, r) => a + Number(r.n), 0);
  node.append(h("div", { class: "grid g4" },
    statOf(byStatus, "Runs", total, "recorded executions"),
    statOf(byStatus, "Running", n("running"), n("running") ? "in flight now" : "no active runs"),
    statOf(byStatus, "Failed", n("failed"), n("failed") ? "needs a person" : "none",
           n("failed") ? "down" : "up"),
    statOf(d, "Definitions", (d.rows || []).length, "registered")));

  node.append(h("div", { class: "grid g-2-1" },
    panel("Runs", "newest first",
      runsRes.error ? gap("workflow.runs_api", runsRes.error.message, "schema")
        : table(["Run", "Workflow", "Status", "External id", "Started"], runsRes.rows, (r) =>
            h("tr", {},
              h("td", { class: "mono" }, h("a", { href: "#/run/" + r.id }, short(r.id))),
              h("td", {}, wfName(d, r)),
              h("td", {}, status(r.status)),
              h("td", { class: "mono" }, r.external_id || "-"),
              h("td", { class: "mono" }, fmtTime(r.created_at)))),
      h("a", { class: "btn ghost", href: "#/runs" }, "All runs")),
    h("div", { style: "display:flex;flex-direction:column;gap:1rem" },
      panel("Queued work", "waiting for a worker",
        h("div", { class: "body" },
          qRes.error ? gap("queues_api", qRes.error.message, "schema")
            : (qRes.rows || []).length
              ? (qRes.rows || []).map((q) =>
                  h("div", { class: "row-between" },
                    h("span", { class: "mono", style: "font-size:.72rem" }, q.queue),
                    h("span", { class: "spacer" }),
                    h("span", { class: "mono", style: "font-size:.72rem;color:var(--muted)" }, String(q.depth))))
              : h("div", { class: "note" },
                  h("strong", {}, "No queues configured. "),
                  "queue_config is empty here, and a queue only appears once someone tunes it - " +
                  "tasks route by name whether or not a row exists."))),
      panel("Recent activity", "task transitions",
        evRes.error ? gap("workflow.task_events_api", evRes.error.message, "schema")
          : stream((evRes.rows || []).map(evRow)),
        h("a", { class: "btn ghost", href: "#/events" }, "Stream")))));
  const onboarding=node.querySelector(':scope > .contextual-help');if(onboarding)node.append(onboarding);
  return node;
}

/* -- Runs -------------------------------------------------- */
export async function runs() {
  const node = page(head("Execution history", "Runs",
    "Follow work in progress, inspect completed results and find the step that needs attention."));
  const d = await defs();
  const holder = h("div", { class: "panel" });
  let filter = "";

  const load = async () => {
    holder.replaceChildren(h("div", { class: "empty" }, "Loading..."));
    const res = await tryRead(() => read(READS.runs,
      "limit=50" + (filter ? "&" + filter : ""), { count: true }),
      (e) => ({ rows: [], error: e }));
    if (res.error) {
      holder.replaceChildren(h("div", { class: "body" }, gap("runs_api", res.error.message, "schema")));
      return;
    }
    holder.replaceChildren(
      h("header", {}, h("h3", {}, "Runs"),
        h("span", { class: "label" }, (res.total === null ? res.rows.length : res.total) + " matching")),
      h("div", { class: "body tight" },
        table(["Run", "Workflow", "Status", "Compensation", "External id", "Started", "Finished"], res.rows, (r) =>
          h("tr", {},
            h("td", { class: "mono" }, h("a", { href: "#/run/" + r.id }, short(r.id))),
            h("td", {}, wfName(d, r)),
            h("td", {}, status(r.status)),
            h("td", {}, r.compensation_state === "none" ? h("span", { class: "chip" }, "none") : status(r.compensation_state)),
            h("td", { class: "mono" }, r.external_id || "-"),
            h("td", { class: "mono" }, fmtTime(r.created_at)),
            h("td", { class: "mono" }, fmtTime(r.completed_at))))));
  };

  node.append(h("div", { class: "toolbar" },
    seg([["All", ""], ["Running", "status=eq.running"], ["Succeeded", "status=eq.succeeded"],
         ["Failed", "status=eq.failed"], ["Cancelled", "status=eq.cancelled"],
         ["Compensating", "compensation_state=neq.none"]], (f) => { filter = f; load(); }),
    h("span", { class: "spacer" }),
    h("span", { class: "mono", style: "font-size:.7rem;color:var(--muted)" }, "RLS: your rows and your org's")),
    holder);
  await load();
  return node;
}

/* -- Run detail -------------------------------------------- */
export async function run(id) {
  const actions = h("div", { class: "pill-row" });
  const node = page(head("workflow", short(id), null, actions));
  const d = await defs();

  const [runRes, taskRes, edgeRes, evRes] = await Promise.all([
    tryRead(() => read(READS.run, "id=eq." + id), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.tasks, "run_id=eq." + id), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.taskDeps, "run_id=eq." + id), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.taskEvents, "run_id=eq." + id + "&limit=40"), (e) => ({ rows: [], error: e })),
  ]);
  const r = (runRes.rows || [])[0];
  const tasks = taskRes.rows || [];
  const out = h("span");
  const def = r ? d.byId.get(r.workflow_def_id) : null;
  const repeat = h("div", {hidden:true});
  const showRepeat = () => {
    if (!repeat.childNodes.length) repeat.append(panel("Run again", "latest saved version · new inputs",
      runForm(def.name, {input:JSON.stringify(r.input || {}, null, 2), draftKey:"repeat:"+id})));
    repeat.hidden = false;
  };
  if (def && draftStore("repeat:"+id).read().input !== undefined) showRepeat();
  const active = r?.status === "running";

  actions.append(
    r ? status(r.status) : chip("not found", "failed"),
    ...(r && def ? [h("button", {class:"btn primary", onclick:() => {
      showRepeat();
      repeat.scrollIntoView({behavior:"smooth", block:"start"});
    }}, "Run again")] : []),
    iconAction("refresh", "Refresh this run", { onclick: async (e) => {
      e.currentTarget.disabled = true;
      const refreshed = await run(id);
      if (node.isConnected) node.replaceWith(refreshed);
    } }),
    iconAction("signal", "Send a signal to this run", { disabled:!active, onclick: async () => {
      const sig = prompt("Signal name for signal_task()");
      if (!sig) return;
      const res = await tryRead(() => rpc("workflow", "signal_task",
        { p_run_id: id, p_signal: sig, p_payload: {} }), (e) => ({ error: e }));
      out.replaceChildren(res.error ? chip(res.error.message, "failed") : chip("signalled", "succeeded"));
    } }),
    /* Cancelling a run is not reversible, so it keeps its words
       (`ui-design-language.md` §3.2). Not an oversight. */
    h("button", { class: "btn danger", disabled:!active, onclick: async (e) => {
      e.target.disabled = true;
      const res = await tryRead(() => rpc("workflow", "cancel_run", { p_run_id: id }), (err) => ({ error: err }));
      out.replaceChildren(res.error ? chip(res.error.message, "failed") : chip("cancel_run sent", "succeeded"));
      if (!res.error) setTimeout(() => location.reload(), 700);
    } }, "Cancel run"), out);

  const done = tasks.filter((t) => t.status === "succeeded").length;
  node.querySelector("h1").textContent = r ? wfName(d, r) : "Run unavailable";
  node.append(repeat);
  const failed = tasks.filter(t => t.status === "failed");
  if (failed.length) node.append(h("div", {class:"note rose", role:"alert"},
    h("strong", {}, "This run needs attention"), failed.map(t => h("p", {},
      t.step_key + ": " + (typeof t.error === "string" ? t.error : t.error?.message || t.error?.detail || t.error?.error || JSON.stringify(t.error || "The step failed.")))),
    h("p", {}, "Check the failed step below. Correct its inputs or configuration, then use Run again to start a fresh run.")));
  node.append(h("div", { class: "grid g4" },
    statOf(runRes, "Workflow", h("span",{class:"stat-name"},r ? wfName(d, r) : "-"), def ? "v" + def.version : ""),
    statOf(taskRes, "Tasks", done + " / " + tasks.length, "succeeded / total"),
    statOf(taskRes, "Retries", tasks.reduce((a, t) => a + Math.max(0, (t.attempts || 1) - 1), 0),
           "attempts beyond the first"),
    statOf(runRes, "Run reference", h("span",{class:"stat-reference"},(r && r.external_id) || "-"), "deduplication reference")));

  const dependents = new Set((edgeRes.rows || []).map(e => e.depends_on_task_id));
  const completed = tasks.filter(t => t.status === "succeeded" && !dependents.has(t.id));
  const evidence = new Map(tasks.flatMap(t => {
    const rows = taskResult(t.output)?.rows;
    return Array.isArray(rows) ? rows.filter(row => row.content && (row.chunk_id || row.resource_id))
      .map(row => [row.chunk_id || row.resource_id, row.content]) : [];
  }));
  const sourcePassage = s => evidence.get(String(s).trim().replace(/^(?:chunk_id|resource_id)\s*:\s*/i, ""));
  if (completed.length && !edgeRes.error) node.append(panel("Results", "completed final steps",
    h("div", {class:"form-stack"}, completed.map(t => {
      const result = taskResult(t.output);
      const resultSources=[...(Array.isArray(result?.sources)?result.sources:[]),...(Array.isArray(result?.source_urls)?result.source_urls:[])];
      return h("article", {class:"workflow-result"}, h("h3", {}, t.step_key),
        result?.mode === "SQL" && Array.isArray(result.rows)
          ? h("div", {}, h("p",{},result.rows.length+" rows returned"+(result.rows.length>100?" · showing the first 100":"")),
              result.rows.length ? h("div",{style:"overflow:auto"},table(Object.keys(result.rows[0]),result.rows.slice(0,100),row=>h("tr",{},Object.keys(result.rows[0]).map(key=>h("td",{},h("div",{class:"query-cell"},typeof row[key]==="object"?JSON.stringify(row[key]):row[key])))))) : null,
              h("details",{},h("summary",{},"Full query result"),h("pre",{class:"code"},JSON.stringify(result,null,2))))
          : result && typeof result === "object" && result.source_id && ['complete','paused'].includes(result.status)
          ? h("div", {class:"api-receipt"}, h("p",{},result.has_more ? "Page budget reached. Continue from the saved checkpoint." : "Pull complete. Incremental progress is saved."),
              h("div",{class:"api-receipt-counts"}, ['inserted','updated','unchanged','pages'].map(k=>h("span",{}, String(result[k]??0)+" "+({inserted:"new records",updated:"updated",unchanged:"unchanged",pages:"pages"}[k])))),
              h("p",{},"Committed watermark: "+(result.watermark||"Not advanced yet")),
              h("p",{class:"document-help"},result.has_more?"Counts cover this run. The source keeps progress across continuations.":"Counts cover the completed pull, including its continuation runs."),
              h("a",{class:"btn",href:"#/sources/"+result.source_id},"Open source & records"),
              h("details",{},h("summary",{},"Full ingestion receipt"),h("pre",{class:"code"},JSON.stringify(result,null,2))))
          : result && typeof result === "object" && typeof result.summary === "string"
          ? h("div", {}, markdown(result.summary),
              resultSources.length ? h("div", {class:"result-sources"}, h("h4", {}, "Sources"), h("ul", {}, resultSources.map(s => h("li", {}, sourcePassage(s)
                ? h("details", {class:"result-source"}, h("summary", {class:"mono"}, s), markdown(sourcePassage(s)))
                : typeof s==='string' && /^https?:\/\//i.test(s) ? h('a',{href:s,target:'_blank',rel:'noopener noreferrer'},s)
                : h("span", {class:"mono"}, typeof s==='object'?JSON.stringify(s):s))))) : null,
              Array.isArray(result.next_steps) && result.next_steps.length ? h("div", {}, h("h4", {}, "Suggested next steps"), h("ul", {}, result.next_steps.map(s => h("li", {}, typeof s==='object'?JSON.stringify(s):s)))) : null,
              h('details',{},h('summary',{},'Full structured result'),h('pre',{class:'composition-code'},JSON.stringify(result,null,2))))
          : typeof result === "string" ? markdown(result) : h("pre", {class:"code suggestion-code"}, JSON.stringify(result, null, 2)));
    }))));
  node.append(panel("Task graph", "step dependencies",
    edgeRes.error ? h("div", { class: "body" }, gap("task_dependencies_api", edgeRes.error.message, "schema"))
      : dag(tasks, edgeRes.rows || []),
    h("div", { class: "legend" },
      h("span", {}, h("i", { style: "background:var(--green-soft);border:1px solid var(--green)" }), "succeeded"),
      h("span", {}, h("i", { style: "background:var(--amber-soft);border:1px solid var(--amber)" }), "running"),
      h("span", {}, h("i", { style: "background:var(--card);border:1px solid var(--rule)" }), "pending"))));

  node.append(panel("Tasks", tasks.length + " rows",
    taskRes.error ? gap("tasks_api", taskRes.error.message, "schema")
      : table(["Step", "Kind", "Status", "Queue", "Attempts", "Finished", ""], tasks, (t) =>
          h("tr", {},
            h("td", { class: "mono" }, t.step_key),
            h("td", {}, h("span", { class: "chip kind" }, t.kind)),
            h("td", {}, status(t.status)),
            h("td", { class: "mono" }, t.queue),
            h("td", { class: "num" }, t.attempts + " / " + t.max_attempts),
            h("td", { class: "mono" }, fmtTime(t.completed_at)),
            h("td", {}, h("button", { class: "btn ghost", onclick: (e) => {
              const tr = e.target.closest("tr");
              tr.after(h("tr", {}, h("td", { colspan: 7 },
                h("pre", { class: "code" }, JSON.stringify(t.error || t.output || {}, null, 2)))));
              e.target.remove();
            } }, "payload"))))));

  node.append(h("div", { class: "grid g2" },
    panel("Events", "task_events_api",
      evRes.error ? h("div", { class: "body" }, gap("task_events_api", evRes.error.message, "schema"))
        : stream((evRes.rows || []).map(evRow))),
    panel("Run", "runs_api", h("div", { class: "body" },
      h("pre", { class: "code" }, JSON.stringify(r || {}, null, 2))))));
  const panels=[...node.children].filter(el=>el.classList.contains('panel'));
  const byTitle=title=>panels.find(el=>el.querySelector('header h3')?.textContent===title);
  const history=node.querySelector('.grid.g2');
  const resultPanel=byTitle('Results')||h('div',{class:'library-empty'},active?'This run is in progress. Open Tasks to follow its steps.':'No final result is available. Open Tasks to inspect outputs or errors.');
  const tabs=workspaceTabs({label:'Run inspection',initial:failed.length?'tasks':'results',sections:[
    {key:'results',title:'Results',content:resultPanel},
    {key:'tasks',title:'Tasks',content:byTitle('Tasks')},
    {key:'graph',title:'Dependencies',content:byTitle('Task graph')},
    {key:'history',title:'History & details',content:history}]});
  node.classList.add('run-page');node.append(tabs.node);
  return node;
}

/* -- Workflows --------------------------------------------- */
export async function workflows() {
  const d = await defs();
  const node = page(head(d.error ? "definitions unavailable" : (d.rows || []).length + " definitions",
    "Workflows",
    "Combine sources, queries and agents into repeatable jobs. Run them with new inputs and package their definitions for reuse.",
    h("a", { class: "btn primary", href: "#/draft" }, "Create a workflow")));

  node.append(panel("Definitions", "workflow.definitions_api",
    d.error ? gap("workflow.definitions_api", d.error.message, "schema")
    : table(["Workflow", "Version", "Steps", "Kinds", "Queues", "Registered", ""], d.rows, (w) =>
      h("tr", {},
        h("td", {}, w.name),
        h("td", { class: "mono" }, "v" + w.version),
        h("td", { class: "num" }, w.step_count),
        h("td", { class: "pill-row" }, (w.step_kinds || []).map((k) => h("span", { class: "chip kind" }, k))),
        h("td", { class: "mono" }, (w.queues || []).join(", ") || "default"),
        h("td", { class: "mono" }, fmtTime(w.created_at)),
        /* `is_latest` is the view's answer. It used to be a max() over the
           rows this page happened to have read, which is a claim about a
           page rather than about the database. */
        h("td", {}, iconAction("play", "Start a run of " + w.name,
          { disabled: !w.is_latest, onclick: async (e) => {
          const button = e.currentTarget;
          button.closest("tr").after(h("tr", {}, h("td", {colspan:7}, runForm(w.name))));
          button.disabled = true;
        } }))))));

  node.append(h("p", {class:"document-help"}, "Start uses the latest saved version. Choose Create a workflow to author a definition, or open Runs to inspect an execution."));
  return node;
}

/* -- Draft ------------------------------------------------- */
export async function draft() {
  const yaml = h("textarea", {class:"control mono", rows:18, "aria-label":"Workflow YAML",
    placeholder:"Describe a job in Design with AI, choose a starter, or write your workflow here."}, sessionStorage.getItem("p8-workflow-draft") || "");
  const out = h("div", {role:"status"});
  const runHolder = h("div");
  const draftState = h("span", {class:"draft-state", role:"status"}, "Draft");
  let workflowWorkspace = null;
  let composer = null;
  let saving = false;
  const save = h("button", {class:"btn primary", disabled:!yaml.value.trim(), onclick:async () => {
    if (saving || !yaml.value.trim()) return;
    saving = true; save.disabled = true; runHolder.replaceChildren();
    const submitted = yaml.value;
    out.replaceChildren(h("p", {}, "Validating and saving your workflow…"));
    try {
      await composer?.beforeSave();
      const {rows} = await rpc("workflow", "define_yaml", {p_yaml:submitted});
      DEFS = null;
      const id = typeof rows === "string" ? rows : rows?.id;
      const definition = (await defs()).byId.get(id);
      if (submitted !== yaml.value) {
        out.replaceChildren(h("div", {class:"note"}, "The submitted definition was saved. Your newer edits have not been saved yet."));
      } else if (definition) {
        out.replaceChildren(h("div", {class:"note"}, "Saved ", h("strong", {}, definition.name), " · version " + definition.version + ". Ready to run."));
        draftState.textContent = "Saved · version " + definition.version;
        runHolder.replaceChildren(panel("Run this workflow", "2 · provide inputs", runForm(definition.name,
          {input:sessionStorage.getItem("p8-workflow-input") || JSON.stringify(BRIEF_INPUT, null, 2)})));
        workflowWorkspace?.enable("run", true); workflowWorkspace?.show("run");
      } else {
        out.replaceChildren(h("div", {class:"note"}, "Saved. ", h("a", {href:"#/workflows"}, "Open Workflows to start a run.")));
      }
    } catch (e) { out.replaceChildren(h("div", {class:"note rose", role:"alert"}, e.message)); }
    finally { saving = false; save.disabled = !yaml.value.trim(); }
  }}, "Validate & save");
  const changed = () => {
    sessionStorage.setItem("p8-workflow-draft", yaml.value);
    runHolder.replaceChildren(); out.replaceChildren(); save.disabled = saving || !yaml.value.trim();
    draftState.textContent = "Unsaved changes"; workflowWorkspace?.enable("run",false);
    composer?.changed();
  };
  const restore = h("button", {class:"btn", hidden:!sessionStorage.getItem("p8-workflow-draft-backup"), onclick:() => {
    sessionStorage.setItem("p8-workflow-input", sessionStorage.getItem("p8-workflow-input-backup") || "{}");
    yaml.value = sessionStorage.getItem("p8-workflow-draft-backup") || ""; changed();
  }}, "Restore previous draft");
  yaml.addEventListener("input", changed);
  const name = h("input", {class:"control", value:"evidence_brief", "aria-label":"Workflow name"});
  const agents = await tryRead(() => read(READS.agentNames), e => ({rows:[],error:e}));
  const agent = h("select", {class:"control", "aria-label":"Briefing agent"},
    (agents.rows || []).map(a => h("option", {value:a.name}, a.name)));
  if (agents.rows.some(a => a.name === "operations_brief")) agent.value = "operations_brief";
  else if (agents.rows.some(a => a.name === "percolate_help")) agent.value = "percolate_help";
  const starterStatus = h("div", {role:"status"});
  const starter = h("section", {class:"workflow-starter"},
    h("div", {class:"assistant-intro"}, h("span", {class:"kicker"}, "A useful starting point"),
      h("h2", {}, "Turn evidence into a brief"),
      h("p", {}, "Run a query, pass its evidence to an agent, and get a sourced answer with suggested next steps. Change the question and query for each run.")),
    h("div", {class:"workflow-step-strip", "aria-label":"Starter steps"},
      h("span", {}, "1. Retrieve evidence"), h("span", {"aria-hidden":"true"}, "→"), h("span", {}, "2. Write the brief")),
    h("div", {class:"starter-fields"},
      h("label", {class:"field"}, h("span", {}, "Workflow name"), name),
      h("label", {class:"field"}, h("span", {}, "Agent"), agent),
      h("button", {class:"btn primary", disabled:!agents.rows.length, onclick:() => {
        try {
          const next = evidenceBrief(name.value.trim(), agent.value, config().workflowQueue || "http");
          stageWorkflow(next, BRIEF_INPUT); restore.hidden = !sessionStorage.getItem("p8-workflow-draft-backup");
          yaml.value = next; sessionStorage.setItem("p8-workflow-input", JSON.stringify(BRIEF_INPUT,null,2)); changed();
          starterChoice.open = false;
          out.replaceChildren(h('div',{class:'note'},'Starter added. Review the steps, then validate and save.'));
          yaml.focus();
        } catch (e) { starterStatus.textContent = e.message; }
      }}, "Use this starter")),
    agents.error ? h("div", {class:"note rose"}, agents.error.message) : !agents.rows.length ? h("p", {}, "Create an agent in ", h("a", {href:"#/agents"}, "Agents"), " to use this starter.") : null,
    starterStatus);
  const starterChoice=h('details',{class:'contextual-help starter-choice',open:!yaml.value.trim()},h('summary',{},'Start from an example'),starter);
  const definition=h('div',{class:'workflow-definition'},
    h('div',{class:'workspace-actions'},save,draftState,h('a',{class:'btn',href:'#/query'},'Develop a query')),
    starterChoice,h('label',{class:'field'},h('span',{},'Workflow YAML'),yaml),
    contextualHelp('Workflow help & draft recovery',
      h('p',{},'Define your steps and inputs, validate and save, then start a recorded run. Use {{run.field}} for an input and {{steps.retrieve.result}} for a previous result.'),
      h('div',{class:'form-actions'},h('a',{href:'#/help'},'Open workflow help'),restore)));
  yaml.addEventListener('input',()=>{if(yaml.value.trim())starterChoice.open=false;});
  composer=await workflowComposer({getDraft:()=>({yaml:yaml.value,input:sessionStorage.getItem('p8-workflow-input') || '{}'}),
    applyDraft:(text,input)=>{stageWorkflow(text,input);yaml.value=text;changed();starterChoice.open=false;restore.hidden=!sessionStorage.getItem('p8-workflow-draft-backup');},
    showDefinition:()=>workflowWorkspace.show('definition',true)});
  const initialMode=sessionStorage.getItem('p8-workflow-open-definition')?'definition':'design';
  sessionStorage.removeItem('p8-workflow-open-definition');
  workflowWorkspace=workspaceTabs({label:'Workflow authoring',initial:initialMode,sections:[
    {key:'design',title:'Design with AI',content:composer.node},
    {key:'definition',title:'Definition',content:definition},
    {key:'run',title:'Run with inputs',content:runHolder,disabled:true},
    {key:'package',title:'Package',content:composer.packagePane}]});
  return page(head('Workflows','Create a workflow','Describe the job. Compose sources, queries and agents. Run it, inspect the result and package it for reuse.'),out,workflowWorkspace.node);
}

/* -- Schedules --------------------------------------------- */
export async function schedules(sourceWorkflow) {
  const node = page(head("workflow.schedules_api", "Schedules",
    "Run a workflow on a schedule with saved inputs and a timezone. Choose whether runs may overlap."));
  const [s, d] = await Promise.all([
    tryRead(() => read(READS.schedules), (e) => ({ rows: [], error: e })),
    defs(),
  ]);
  const listing = panel("Schedules", (s.rows || []).length + " defined",
    s.error ? gap("schedules_api", s.error.message, "schema")
      : table(["Schedule", "Workflow", "Cron", "Overlap", "Last fired", "Fired", "Skipped", "Enabled"], s.rows || [], (r) =>
          h("tr", {},
            h("td", {}, r.name, r.last_error ? h("span", { class: "sub" }, r.last_error) : null),
            h("td", {}, d.sourceNames?.get(r.workflow_name) || r.workflow_name),
            /* The expression stays visible — it is what the database holds —
               with the sentence under it, so a schedule somebody else wrote is
               readable without parsing five fields. */
            h("td", {}, h("div", { class: "mono" }, r.cron_expr + " " + (r.timezone || "")),
              h("div", { class: "sub" }, safeDescribe(r.cron_expr))),
            h("td", {}, h("span", { class: "chip" }, r.overlap_policy)),
            h("td", { class: "mono" }, fmtTime(r.last_fired_at)),
            h("td", { class: "num" }, r.fire_count),
            h("td", { class: "num" }, r.skip_count),
            h("td", {}, h("button", { class: "btn ghost", onclick: async (e) => {
              const res = await tryRead(() => rpc("workflow", "set_schedule_enabled",
                { p_name: r.name, p_enabled: !r.enabled }), (err) => ({ error: err }));
              e.target.replaceWith(res.error ? chip(res.error.message, "failed") : chip("toggled", "succeeded"));
            } }, r.enabled ? "on" : "off")))));

  const name = h("input", { class: "control", style: "width:100%", value: "nightly", "aria-label":"Schedule name" });
  const wf = h("select", { class: "control", style: "width:100%", "aria-label":"Scheduled workflow" },
    [...new Set((d.rows || []).map(x => x.name))].map(name => h("option", { value:name }, d.sourceNames?.get(name) || name)));
  if(sourceWorkflow && [...wf.options].some(o=>o.value===sourceWorkflow)){wf.value=sourceWorkflow;name.value=(d.sourceNames?.get(sourceWorkflow)||sourceWorkflow)+"_schedule";}
  const cron = h("input", { class: "control mono", style: "width:100%", value: "0 2 * * *", "aria-label":"Cron expression" });
  /* The expression in words, and the next three firings, recomputed on every
     keystroke. Cron's day-of-month/day-of-week OR rule is the reason this is
     worth the space: `0 0 13 * 5` reads as Friday the 13th and is not. */
  const preview = h("div", { class: "note" });
  const repaint = () => {
    try {
      const sentence = describeCron(cron.value, timezone.value.trim() || "UTC");
      const fires = nextFires(cron.value, timezone.value.trim() || "UTC", 3);
      preview.className = "note";
      preview.replaceChildren(
        h("strong", {}, sentence),
        ...fires.map((f) => h("div", { class: "mono", style: "font-size:.72rem;color:var(--muted)" },
          `${f.local.year}-${pad2(f.local.month)}-${pad2(f.local.day)} `
          + `${pad2(f.local.hour)}:${pad2(f.local.minute)}`
          + (f.note ? "  — " + f.note : ""))),
        ...(fires.length ? [] : [h("div", { class: "mono", style: "font-size:.72rem" },
          "No firing in the next 400 days.")]));
    } catch (e) {
      preview.className = "note rose";
      preview.replaceChildren(e.message);
    }
  };
  cron.addEventListener("input", repaint);
  const scheduleInput = h("textarea", {class:"control mono", rows:4, "aria-label":"Schedule input JSON", style:"width:100%"}, "{}");
  const timezone = h("input", {class:"control", value:"UTC", "aria-label":"Schedule timezone"});
  const describe = h("input", { class: "control", style: "flex:1",
    placeholder: "every weekday at 7am London, skip if the last one is still running",
    "aria-label": "Describe the schedule in words" });
  const overlap = h("select", {class:"control", "aria-label":"Overlap policy"}, h("option", {value:"skip"}, "Skip while running"), h("option", {value:"allow"}, "Allow overlapping runs"));
  const out = h("div");
  repaint();
  const editor = panel("Schedule a workflow", "",
    h("div", { class: "body" },
      h("div", { class: "grid g3" },
        h("div", { class: "field" }, h("label", {}, "name"), name),
        h("div", { class: "field" }, h("label", {}, "workflow"), wf),
        h("div", { class: "field" }, h("label", {}, "cron"), cron)),
      preview,
      h("div", { class: "field" }, h("label", {}, "or describe it"),
        h("div", { class: "pill-row" }, describe,
          h("button", { class: "btn", onclick: async (e) => {
            e.target.disabled = true;
            const status = h("span", { class: "mono", style: "font-size:.72rem" }, "");
            out.replaceChildren(status);
            const requestedDraft=JSON.stringify([cron.value,timezone.value,overlap.value]);
            try {
              const s = await suggestSchedule({
                description: describe.value,
                workflows: (d.rows || []).map((w) => w.name),
                onStatus: (t) => status.replaceChildren(t),
              });
              /* A question and a draft are different answers, and the assistant
                 returns them in different fields, so this cannot render one as
                 the other. Neither writes anything: filling the form is not
                 saving it. */
              if (!s.cron_expr.trim()) {
                out.replaceChildren(h("div", { class: "note amber" },
                  h("strong", {}, "Needs one more detail. "), s.needs_clarification));
              } else {
                out.replaceChildren(h('article',{class:'suggestion-card'},
                  h('h3',{},'Suggested schedule'),h('p',{},s.explanation),
                  h('p',{},describeCron(s.cron_expr,s.timezone)),
                  h('p',{class:'mono'},s.cron_expr+' · '+s.timezone+' · '+s.overlap_policy),
                  ...s.assumptions.map(a=>h('p',{class:'hint'},a)),
                  h('button',{class:'btn primary',onclick:()=>{
                    if(JSON.stringify([cron.value,timezone.value,overlap.value])!==requestedDraft){out.replaceChildren(h('p',{class:'note'},'The schedule changed. Ask for a new suggestion to review the current draft.'));return;}
                    cron.value=s.cron_expr;timezone.value=s.timezone;overlap.value=s.overlap_policy;repaint();
                    out.replaceChildren(h('p',{class:'note'},'Suggestion applied. Review the next fire times, then choose Schedule to save it.'));
                  }},'Apply suggestion')));
              }
            } catch (err) {
              out.replaceChildren(h("div", { class: "note rose" }, err.message));
            }
            e.target.disabled = false;
          } }, "Suggest"))),
      h("label", {}, "Input JSON", scheduleInput),
      h("label", {}, "Timezone", timezone), h("label", {}, "Overlap", overlap),
      h("button", { class: "btn primary", onclick: async () => {
        const res = await tryRead(() => rpc("workflow", "schedule_workflow",
          { p_name: name.value, p_workflow: wf.value, p_cron: cron.value, p_input: jsonObject(scheduleInput.value), p_timezone: timezone.value, p_overlap: overlap.value }), (e) => ({ error: e }));
        out.replaceChildren(res.error ? h("div", { class: "note rose" }, res.error.message)
          : h("div", { class: "note" }, "Scheduled."));
        if (!res.error) setTimeout(() => location.reload(), 800);
      } }, "Schedule"), out));
  timezone.addEventListener('input',repaint);
  const scheduleBody=editor.querySelector('.body > .body');
  scheduleBody.prepend(h('div',{class:'workspace-actions'},scheduleBody.querySelector('.btn.primary')),out);
  const space=editorWorkspace({label:'Schedule',browse:listing,editor,createLabel:'New schedule'});
  node.querySelector('.head-row').append(space.create);
  node.append(space.node);
  if(sourceWorkflow)space.open('New schedule',{expanded:true,focus:false});
  return node;
}

/* -- Events ------------------------------------------------ */
export async function events() {
  const node = page(head("append-only, and the same shape twice", "Events",
    "task_events and auth_events are both append-only histories, so one screen reads both. " +
    "A trigger writes the task half, which is why a worker cannot forget to."));
  const holder = h("div", { class: "panel" });
  let which = "task";

  const load = async () => {
    holder.replaceChildren(h("div", { class: "empty" }, "Loading..."));
    if (which === "auth") {
      const r = await tryRead(() => read(READS.authEvents, "limit=60"), (e) => ({ rows: [], error: e }));
      holder.replaceChildren(
        h("header", {}, h("h3", {}, "auth_events"),
          h("span", { class: "label" }, r.error ? "unavailable" : (r.rows || []).length + " rows")),
        h("div", { class: "body tight" }, r.error ? gap("rbac.auth_events", r.error.message, "schema")
          : stream((r.rows || []).map((e) => ({
              t: (e.at || "").slice(11, 19),
              tone: /fail|revoke|reuse/.test(e.event_type || "") ? "bad" : "info",
              what: e.event_type,
              meta: short(e.user_id) + (e.detail ? " · " + JSON.stringify(e.detail).slice(0, 80) : ""),
            })))));
      return;
    }
    const r = await tryRead(() => read(READS.eventStream, "limit=60"), (e) => ({ rows: [], error: e }));
    holder.replaceChildren(
      h("header", {}, h("h3", {}, "task_events"),
        h("span", { class: "label" }, r.error ? "unavailable" : (r.rows || []).length + " rows")),
      h("div", { class: "body tight" }, r.error ? gap("workflow.task_events_api", r.error.message, "schema")
        : stream((r.rows || []).map(evRow))));
  };

  node.append(h("div", { class: "toolbar" },
    seg([["Tasks", "task"], ["Auth", "auth"]], (v) => { which = v; load(); }),
    h("span", { class: "spacer" }),
    h("span", { class: "mono", style: "font-size:.7rem;color:var(--muted)" },
      "polled - a browser cannot LISTEN, so live needs a relay")), holder);
  await load();
  return node;
}

/* -- Queues & pools ---------------------------------------- */
export async function queues() {
  const [pools, binds, unserved, depth, t, rl, policy] = await Promise.all([
    tryRead(() => read(READS.pools), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.poolQueues), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.unservedQueues), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.queueDepth), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.tasksByStatus), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.rateLimits), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.imagePolicy), (e) => ({ rows: [], error: e })),
  ]);

  /* pools.sql is on build-sql.py's NOT_SHIPPED list -- pools.md §13 verifies
     the data model and leaves the control loop a proposal -- so a standard
     install has NONE of these relations. Detected from what the database
     answers (42P01 on every pool relation), never assumed: a deployment that
     applies pools.sql gets the pool screen back with no change here.

     Absent, the screen is for the person who opened Queues: how much is
     waiting and what paces it, in words. The refusals, relation names and the
     file that installs them were the first thing on the page -- four
     `unavailable · 42P01` tiles and a rose gap -- and are operator detail. They
     move behind a toggle rather than going away, because
     ui-design-language.md §5 says a smaller first screen "must not make
     failures, evidence, advanced configuration or the next action
     inaccessible", and §4 asks this screen for a consistent unavailable state. */
  const poolsAbsent = [pools, binds, unserved, policy].every((r) => r.error?.code === "42P01");
  const node = page(poolsAbsent
    ? head("queues · rate limits", "Queues & pools",
        "Work waits in a queue until a worker claims it. This shows how much is waiting on each " +
        "queue and the rate limits that pace it.")
    : head("workflow.pools · v_pools · queue_depth()", "Queues & pools",
        "A worker pool is a row. A manager reconciles it into a Deployment and a KEDA ScaledObject, " +
        "and KEDA scales it 0 to N on that pool's queue depth. Nothing on this page holds cluster " +
        "credentials, and no YAML is authored per pool."));
  const operator = poolsAbsent
    ? h("details", { class: "operator" }, h("summary", {}, "Operator detail: the pool schema"))
    : null;
  const poolPart = (...kids) => (operator || node).append(...kids);

  if (poolsAbsent) {
    const waiting = (depth.rows || []).reduce((a, r) => a + Number(r.depth || 0), 0);
    /* The same queues the table below lists: queues_api has a row only for a
       queue with work ready or running, so counting it said "0 queues" over a
       table of three. */
    const known = new Set([...(t.rows || []).map((r) => r.queue), ...(depth.rows || []).map((r) => r.queue)]);
    node.append(h("div", { class: "note" },
      h("strong", {}, "Worker pools are not installed on this deployment. "),
      "Queues are served by the workers you run, and everything below works without pools. Pools " +
      "scale workers per queue on Kubernetes; they are an optional component, and the operator " +
      "detail at the end of this page says what installs them."));
    node.append(h("div", { class: "grid g3" },
      statOf(depth.error ? depth : t, "Queues", known.size, "with tasks recorded"),
      statOf(depth, "Tasks in queues", waiting, "ready or running, every queue"),
      statOf(rl, "Rate limits", (rl.rows || []).length, "buckets defined")));
    operator.append(h("div", { class: "note" },
      h("strong", {}, "This deployment has no pool schema. "),
      "The extension does not ship one: ", h("code", { class: "mono" }, "pools.md"),
      " §13 verifies the data model and leaves the control loop a proposal, so a table with no " +
      "manager behind it stays out of the product. Apply ",
      h("code", { class: "mono" }, "specs/workflow-engine/pools.sql"),
      " to a deployment that runs one. Queue depth and rate limits below are core and work either way."));
  }

  const pending = (pools.rows || []).filter((p) => p.reconcile_pending).length;
  poolPart(h("div", { class: "grid g4" },
    statOf(pools, "Pools", (pools.rows || []).length, "workflow.pools"),
    statOf(pools, "Enabled", (pools.rows || []).filter((p) => p.enabled).length, "in the desired set"),
    statOf(pools, "Awaiting a manager", pending,
           pending ? "observed_generation is behind" : "all reconciled", pending ? "down" : "up"),
    statOf(unserved, "Unserved queues", (unserved.rows || []).length, "tasks with no pool",
           (unserved.rows || []).length ? "down" : "")));

  poolPart(panel("Pools", "desired state and observed state, joined",
    pools.error ? gap("workflow.v_pools", pools.error.message, "schema — apply specs/workflow-engine/pools.sql")
      : table(["Pool", "Image", "Queues", "Replicas", "Node class", "Generation", "Phase", ""],
              pools.rows || [], (p) =>
          h("tr", {},
            h("td", {}, p.name, p.enabled ? null : h("span", { class: "sub" }, "disabled")),
            h("td", { class: "mono" }, p.image),
            h("td", { class: "pill-row" }, (p.queues || []).map((q) => h("span", { class: "chip kind" }, q))),
            h("td", { class: "mono" }, p.min_replicas + "–" + p.max_replicas),
            h("td", {}, h("span", { class: "chip" }, p.node_class)),
            h("td", { class: "mono" }, "gen " + p.generation +
              (p.observed_generation === null ? " / never observed"
                                              : " / obs " + p.observed_generation)),
            h("td", {}, p.phase ? status(p.phase) : h("span", { class: "chip" }, "no status")),
            /* Reversible in one click, which is what earns an icon: the worst
               outcome of a mis-click is that you click it again. */
            h("td", {}, iconAction(p.enabled ? "pause" : "power",
              (p.enabled ? "Disable pool " : "Enable pool ") + p.name,
              { onclick: async (e) => {
                const button = e.currentTarget;
                const res = await tryRead(() => select("workflow", "pools",
                  "name=eq." + p.name, { method: "PATCH", body: { enabled: !p.enabled } }),
                  (err) => ({ error: err }));
                button.replaceWith(res.error ? chip(res.error.message, "failed") : chip("toggled", "succeeded"));
              } }))))));

  if (pending && !pools.error) {
    node.append(h("div", { class: "note amber" },
      h("strong", {}, pending + " pool(s) declared and never observed. "),
      "That is the correct reading of this database: the rows exist, and no manager has reported " +
      "back on them. ", h("code", { class: "mono" }, "p8 pool run"),
      " is the process that would — and `render` is implemented while the loop is not."));
  }

  const depths = new Map((depth.rows || []).map((r) => [r.queue, r.depth]));
  const queueNames = new Set([...(binds.rows || []).map((b) => b.queue),
                              ...(t.rows || []).map((r) => r.queue),
                              ...depths.keys()]);
  const poolOf = new Map((binds.rows || []).map((b) => [b.queue, b.pool]));

  /* The em dashes in this table mean "no row". When the depth or task-count
     read FAILED they would mean nothing of the kind, so the label says so
     rather than letting a column of dashes read as a quiet queue. */
  /* binds is in this list and was not: when pool_queues is unreadable every
     row rendered "no pool", which is a CLAIM -- the same mistake the em-dash
     comment below refuses to make about depth. Absence and refusal have to
     read differently or the screen is confidently wrong. With no pool schema
     at all there is nothing to serve a queue BY, so the column goes rather
     than reading "unknown" on every row. */
  const queuesGap = [["workflow.queues_api", depth],
                     ["workflow.tasks_by_status_api", t],
                     ...(poolsAbsent ? [] : [["workflow.pool_queues", binds]])].filter(([, r]) => r.error);
  node.append(panel("Queues",
    queuesGap.length
      ? queuesGap.map(([what]) => what).join(", ") + " unavailable · "
        + (queuesGap[0][1].error.code || "read failed")
      : poolsAbsent ? "depth counts ready and running tasks" : "one pool per queue, enforced by a primary key",
    table(poolsAbsent ? ["Queue", "Depth (global)", "Your tasks, by status"]
                      : ["Queue", "Served by", "Depth (global)", "Your tasks, by status"], [...queueNames], (q) =>
      h("tr", {},
        h("td", { class: "mono" }, q),
        poolsAbsent ? null
          : h("td", {}, binds.error ? h("span", { class: "chip" }, "unknown")
                      : poolOf.has(q) ? chip(poolOf.get(q), "accent")
                                      : h("span", { class: "chip failed" }, "no pool")),
        h("td", { class: "num" }, depths.has(q) ? String(depths.get(q)) : "—"),
        h("td", { class: "pill-row" }, (t.rows || []).filter((r) => r.queue === q).map((b) =>
          h("span", { class: "chip" }, b.status + " " + b.n)))))));

  const unservedPanel = panel("Unserved queues", "tasks waiting, no pool bound",
    unserved.error ? gap("workflow.v_unserved_queues", unserved.error.message, "schema — apply specs/workflow-engine/pools.sql")
      : table(["Queue", "Ready", "Running", "Oldest"], unserved.rows || [], (u) =>
          h("tr", {}, h("td", { class: "mono" }, u.queue), h("td", { class: "num" }, u.ready_tasks),
            h("td", { class: "num" }, u.running_tasks), h("td", { class: "mono" }, fmtTime(u.oldest_task)))));
  const policyPanel = panel("Image allow-list", "deny by default",
    policy.error ? gap("workflow.pool_image_policy", policy.error.message, "schema — apply specs/workflow-engine/pools.sql")
      : table(["Pattern", "Note"], policy.rows || [], (r) =>
          h("tr", {}, h("td", { class: "mono" }, r.pattern), h("td", {}, r.note || "—"))));
  const ratePanel = panel("Rate limits", "the bucket, minus the personal keys",
    rl.error ? gap("workflow.rate_limits_api", rl.error.message, "schema")
      : table(["Key", "Capacity", "Tokens"], rl.rows || [], (r) =>
          h("tr", {}, h("td", { class: "mono" }, r.key), h("td", { class: "num" }, r.capacity),
            h("td", { class: "num" }, Number(r.tokens).toFixed(1)))));
  if (poolsAbsent) {
    node.append(ratePanel);
    operator.append(h("div", { class: "grid g2" }, unservedPanel, policyPanel));
  } else {
    node.append(h("div", { class: "grid g3" }, unservedPanel, policyPanel, ratePanel));
  }

  poolPart(h("div", { class: "grid g2" },
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What the database refuses, so this screen does not have to"),
      h("div", { class: "note" }, h("strong", {}, "An image outside the allow-list. "),
        "Empty policy table means no pool may be declared at all — the other default is running " +
        "an arbitrary image from an arbitrary registry inside the cluster."),
      h("div", { class: "note" }, h("strong", {}, "A reserved environment key. "),
        h("code", { class: "mono" }, "P8_DSN"), " is injected by the manager from a Secret it " +
        "controls; a consumer-settable one would hand a consumer's image the ability to connect " +
        "as whatever role it can name."),
      h("div", { class: "note" }, h("strong", {}, "Two pools on one queue. "),
        "A primary key on ", h("code", { class: "mono" }, "pool_queues.queue"), " — two " +
        "ScaledObjects each computing a replica count from a depth the other is draining oscillates."))),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "Depth counts running, not only ready"),
      h("div", { class: "note" }, "queue_depth() is SECURITY DEFINER, so the number above is the " +
        "true global depth rather than this caller's slice — which is what KEDA scales on and what " +
        "an operator needs."),
      h("div", { class: "note amber" }, h("strong", {}, "Counting only "),
        h("code", { class: "mono" }, "ready"), h("strong", {}, " is the subtle wrong version. "),
        "A pool of pods mid-task reports depth 0 and gets scaled out from under work in flight. " +
        "Measured in pools.md §13: 4 against 2 on the same queue."))),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "Depth counts running, not only ready"),
      h("div", { class: "note" }, "queue_depth() is SECURITY DEFINER, so the number above is the " +
        "true global depth rather than this caller's slice — which is what KEDA scales on and what " +
        "an operator needs."),
      h("div", { class: "note amber" }, h("strong", {}, "Counting only "),
        h("code", { class: "mono" }, "ready"), h("strong", {}, " is the subtle wrong version. "),
        "A pool of pods mid-task reports depth 0 and gets scaled out from under work in flight. " +
        "Measured in pools.md §13: 4 against 2 on the same queue.")))));
  if (operator) node.append(operator);
  return node;
}

/* -- Load & limits ----------------------------------------- */
/* What this database can say about load: how much work it holds, by status.
   The screen used to lead with two tiles reading "-" -- `no table for them`,
   `no policy row` -- under a panel titled "What would stop this being a
   placeholder". Both are true and neither is for the person who opened Load &
   limits: load trials are written to a run log by dev/scale and retention has no
   policy rows, so there is nothing here to detect and nothing to show. What IS
   measurable leads; the rest keeps its words behind a toggle
   (ui-design-language.md §5). */
export async function scale() {
  const node = page(head("load · limits", "Load & limits",
    "How much work this deployment holds, by status, as the database reports it when the page loads."));
  const [t, rs] = await Promise.all([
    tryRead(() => read(READS.tasksByStatus), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.runsByStatus), (e) => ({ rows: [], error: e })),
  ]);
  const tasks = (t.rows || []).reduce((a, r) => a + Number(r.n), 0);
  const runsN = (rs.rows || []).reduce((a, r) => a + Number(r.n), 0);
  node.append(h("div", { class: "grid g2" },
    statOf(t, "Tasks", tasks, "visible to you, every queue"),
    statOf(rs, "Workflow runs", runsN, "visible to you")));

  node.append(h("div", { class: "grid g2" },
    panel("Tasks by status", "per queue",
      t.error ? gap("workflow.tasks_by_status_api", t.error.message, "schema")
        : table(["Queue", "Status", "Tasks"], t.rows || [], (r) =>
            h("tr", {}, h("td", { class: "mono" }, r.queue), h("td", {}, status(r.status)),
              h("td", { class: "num" }, r.n)))),
    panel("Runs by status", "every workflow",
      rs.error ? gap("workflow.runs_by_status_api", rs.error.message, "schema")
        : table(["Status", "Runs"], rs.rows || [], (r) =>
            h("tr", {}, h("td", {}, status(r.status)), h("td", { class: "num" }, r.n))))));

  node.append(h("details", { class: "operator" },
    h("summary", {}, "Operator detail: load trials and retention"),
    h("div", { class: "grid g2" },
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What the specs already measured"),
      h("div", { class: "note" }, h("strong", {}, "13,965 tasks/s "), "on compose, one host; ",
        h("strong", {}, "9,407 "), "on a three-node cluster. Both from scale.md, neither from this database."),
      h("div", { class: "note" }, h("strong", {}, "The ceiling is connections, not throughput. "),
        "Two per worker against the connection budget, reached long before the database runs out of headroom."),
      h("div", { class: "note amber" }, h("strong", {}, "Retention at a million rows is unmeasured, "),
        "and scale.md says so. Nothing here should imply otherwise."))),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What would stop this being a placeholder"),
      h("div", { class: "note rose" }, "A table of trial results - substrate, shape, throughput, claim p99, verdict. ",
        "Then this is a list, and every number carries the environment that produced it."),
      h("div", { class: "note rose" }, "A retention policy expressed as rows rather than a cron somebody wrote once."),
      h("div", { class: "note" }, "Both are schema work in workflow-engine, not UI work."))))));
  return node;
}
