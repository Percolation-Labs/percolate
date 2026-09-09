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
 */

import { select, rpc, ApiError } from "./api.js";
import { h, chip, status, table, stat, panel, gap, fmtTime, short, seg, stream, eventTone, dag } from "./ui.js";

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

/* The definitions map. runs_api carries workflow_def_id and no name, so every
   screen that labels a run needs this. One fetch, cached for the page load --
   the upstream fix is a `name` column on runs_api, and then this goes. */
let DEFS = null;
export async function defs() {
  if (DEFS) return DEFS;
  const r = await tryRead(() => select("workflow", "definitions_api",
    "select=id,name,version,step_count,step_kinds,queues,created_at&order=name"), () => ({ rows: [] }));
  DEFS = { rows: r.rows || [], byId: new Map((r.rows || []).map((d) => [d.id, d])) };
  return DEFS;
}
export const wfName = (d, id) => (d.byId.get(id) ? d.byId.get(id).name : short(id));

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
  const node = page(head("live · this deployment", "Overview",
    "Every number is a read. Counts come from a view or a Content-Range header - " +
    "aggregates are disabled here, so nothing on this page is a group-by composed in a browser."));

  const [byStatus, d, runsRes, evRes, qRes] = await Promise.all([
    tryRead(() => select("workflow", "runs_by_status_api"), (e) => ({ rows: [], error: e })),
    defs(),
    tryRead(() => select("workflow", "runs_api",
      "select=id,status,external_id,created_at,workflow_def_id&order=created_at.desc&limit=8"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "task_events_api",
      "select=step_key,from_status,to_status,queue,detail,at&order=at.desc&limit=8"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "queues_api"), (e) => ({ rows: [], error: e })),
  ]);

  const n = (s) => (byStatus.rows || []).filter((r) => r.status === s).reduce((a, r) => a + Number(r.n), 0);
  const total = (byStatus.rows || []).reduce((a, r) => a + Number(r.n), 0);
  node.append(h("div", { class: "grid g4" },
    stat("Runs", total, "workflow.runs_by_status_api"),
    stat("Running", n("running"), n("running") ? "in flight now" : "queue is clear"),
    stat("Failed", n("failed"), n("failed") ? "needs a person" : "none", n("failed") ? "down" : "up"),
    stat("Definitions", (d.rows || []).length, "registered")));

  node.append(h("div", { class: "grid g-2-1" },
    panel("Runs", "newest first",
      runsRes.error ? gap("workflow.runs_api", runsRes.error.message, "schema")
        : table(["Run", "Workflow", "Status", "External id", "Started"], runsRes.rows, (r) =>
            h("tr", {},
              h("td", { class: "mono" }, h("a", { href: "#/run/" + r.id }, short(r.id))),
              h("td", {}, wfName(d, r.workflow_def_id)),
              h("td", {}, status(r.status)),
              h("td", { class: "mono" }, r.external_id || "-"),
              h("td", { class: "mono" }, fmtTime(r.created_at)))),
      h("a", { class: "btn ghost", href: "#/runs" }, "All runs")),
    h("div", { style: "display:flex;flex-direction:column;gap:1rem" },
      panel("Queue depth", "queue_depth(), the true depth",
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
      panel("Recent events", "task_events_api",
        evRes.error ? gap("workflow.task_events_api", evRes.error.message, "schema")
          : stream((evRes.rows || []).map(evRow)),
        h("a", { class: "btn ghost", href: "#/events" }, "Stream")))));
  return node;
}

/* -- Runs -------------------------------------------------- */
export async function runs() {
  const node = page(head("workflow.runs_api", "Runs",
    "Filtered server-side: every control below is PostgREST query syntax on the URL, " +
    "and RLS decides which rows exist before any filter applies."));
  const d = await defs();
  const holder = h("div", { class: "panel" });
  let filter = "";

  const load = async () => {
    holder.replaceChildren(h("div", { class: "empty" }, "Loading..."));
    const res = await tryRead(() => select("workflow", "runs_api",
      "select=id,status,compensation_state,external_id,created_at,completed_at,workflow_def_id" +
      "&order=created_at.desc&limit=50" + (filter ? "&" + filter : ""), { count: true }),
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
            h("td", {}, wfName(d, r.workflow_def_id)),
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
    tryRead(() => select("workflow", "runs_api", "id=eq." + id), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "tasks_api", "run_id=eq." + id +
      "&select=id,step_key,kind,status,queue,attempts,max_attempts,error,output,created_at,completed_at&order=created_at"),
      (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "task_dependencies_api", "run_id=eq." + id), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "task_events_api", "run_id=eq." + id +
      "&select=step_key,from_status,to_status,queue,detail,at&order=at.desc&limit=40"), (e) => ({ rows: [], error: e })),
  ]);
  const r = (runRes.rows || [])[0];
  const tasks = taskRes.rows || [];
  const out = h("span");

  actions.append(
    r ? status(r.status) : chip("not found", "failed"),
    h("button", { class: "btn", onclick: async () => {
      const sig = prompt("Signal name for signal_task()");
      if (!sig) return;
      const res = await tryRead(() => rpc("workflow", "signal_task",
        { p_run_id: id, p_signal: sig, p_payload: {} }), (e) => ({ error: e }));
      out.replaceChildren(res.error ? chip(res.error.message, "failed") : chip("signalled", "succeeded"));
    } }, "Signal"),
    h("button", { class: "btn danger", onclick: async (e) => {
      e.target.disabled = true;
      const res = await tryRead(() => rpc("workflow", "cancel_run", { p_run_id: id }), (err) => ({ error: err }));
      out.replaceChildren(res.error ? chip(res.error.message, "failed") : chip("cancel_run sent", "succeeded"));
      if (!res.error) setTimeout(() => location.reload(), 700);
    } }, "Cancel run"), out);

  const done = tasks.filter((t) => t.status === "succeeded").length;
  const def = r ? d.byId.get(r.workflow_def_id) : null;
  node.append(h("div", { class: "grid g4" },
    stat("Workflow", r ? wfName(d, r.workflow_def_id) : "-", def ? "v" + def.version : ""),
    stat("Tasks", done + " / " + tasks.length, "succeeded / total"),
    stat("Retries", tasks.reduce((a, t) => a + Math.max(0, (t.attempts || 1) - 1), 0), "attempts beyond the first"),
    stat("External id", (r && r.external_id) || "-", r ? r.compensation_state : "")));

  node.append(panel("Task graph", "task_dependencies_api",
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
  return node;
}

/* -- Workflows --------------------------------------------- */
export async function workflows() {
  const d = await defs();
  const node = page(head((d.rows || []).length + " definitions", "Workflows",
    "A definition is a row. Registering one runs validate_spec() first, so a graph with an " +
    "unreachable step is rejected there rather than discovered as a stalled run.",
    h("a", { class: "btn primary", href: "#/draft" }, "+ Draft one")));

  node.append(panel("Definitions", "workflow.definitions_api",
    table(["Workflow", "Version", "Steps", "Kinds", "Queues", "Registered", ""], d.rows, (w) =>
      h("tr", {},
        h("td", {}, w.name),
        h("td", { class: "mono" }, "v" + w.version),
        h("td", { class: "num" }, w.step_count),
        h("td", { class: "pill-row" }, (w.step_kinds || []).map((k) => h("span", { class: "chip kind" }, k))),
        h("td", { class: "mono" }, (w.queues || []).join(", ") || "default"),
        h("td", { class: "mono" }, fmtTime(w.created_at)),
        h("td", {}, h("button", { class: "btn", onclick: async (e) => {
          e.target.disabled = true;
          const res = await tryRead(() => rpc("workflow", "start_workflow",
            { p_name: w.name, p_input: {}, p_external_id: "ui-" + Date.now() }), (err) => ({ error: err }));
          e.target.replaceWith(res.error ? chip(res.error.message, "failed")
            : h("a", { class: "chip succeeded", href: "#/run/" + String(res.rows).replace(/"/g, "") }, "started"));
        } }, "Start"))))));

  node.append(h("div", { class: "grid g2" },
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "Why there is no spec on this page"),
      h("div", { class: "note amber" },
        h("strong", {}, "definitions_api publishes names and shapes, not bodies. "),
        "workflow.definitions has no owner_id, no org_id and no RLS, so a view over its ",
        h("code", { class: "mono" }, "spec"), " column would show every tenant every workflow body. ",
        "Scoping it is rbac.add_scope_columns + add_scope_policy - the collection's own primitive, ",
        "and a schema decision rather than a UI one."))),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "Who may define"),
      h("div", { class: "note" }, "workflow.define_yaml() is executable by ",
        h("code", { class: "mono" }, "authenticated"), " and checks ",
        h("code", { class: "mono" }, "workflow.may_define"), " itself. This screen disables nothing ",
        "on the strength of a role - it lets the function refuse, and shows the refusal.")))));
  return node;
}

/* -- Draft ------------------------------------------------- */
export async function draft() {
  const yaml = h("textarea", { class: "control mono", rows: 18, style: "width:100%;resize:vertical" },
    "name: demo_" + Math.floor(Math.random() * 9999) + "\n" +
    "steps:\n" +
    "  - id: plan\n" +
    "    sql: {function: p8ql, args: ['SELECT 1']}\n\n" +
    "  - id: gather\n" +
    "    needs: [plan]\n" +
    "    sql: {function: p8ql, args: ['SELECT 1']}\n\n" +
    "  - id: assemble\n" +
    "    needs: [gather]\n" +
    "    sql: {function: p8ql, args: ['SELECT 1']}\n");
  const out = h("div");
  const node = page(head("workflow.define_yaml()", "Draft",
    "The YAML compiles to ordinary workflow.tasks rows. validate_spec() runs as a trigger on " +
    "registration - duplicate keys, unknown dependencies, unreachable steps and cycles with no " +
    "entry point are rejected by the database, not by this page."));

  node.append(h("div", { class: "grid g-2-1" },
    panel("YAML", "compiles to tasks", h("div", { class: "body" }, yaml,
      h("div", { class: "pill-row" },
        h("button", { class: "btn primary", onclick: async () => {
          out.replaceChildren(h("span", { class: "chip" }, "defining..."));
          const res = await tryRead(() => rpc("workflow", "define_yaml", { p_yaml: yaml.value }), (e) => ({ error: e }));
          if (res.error) { out.replaceChildren(h("div", { class: "note rose" }, res.error.message)); return; }
          out.replaceChildren(h("div", { class: "note" }, "Registered ",
            h("code", { class: "mono" }, String(res.rows).replace(/"/g, "")), ". ",
            h("a", { href: "#/workflows" }, "Workflows")));
        } }, "Register"),
        h("button", { class: "btn", onclick: async () => {
          const m = yaml.value.match(/^name:\s*(\S+)/m);
          if (!m) { out.replaceChildren(h("div", { class: "note rose" }, "No name: line to start.")); return; }
          const res = await tryRead(() => rpc("workflow", "start_workflow",
            { p_name: m[1], p_input: {}, p_external_id: "draft-" + Date.now() }), (e) => ({ error: e }));
          out.replaceChildren(res.error ? h("div", { class: "note rose" }, res.error.message)
            : h("div", { class: "note" },
                h("a", { href: "#/run/" + String(res.rows).replace(/"/g, "") }, "Run started")));
        } }, "Start it"),
        h("span", { class: "mono", style: "font-size:.7rem;color:var(--muted)" }, "checked by workflow.may_define")),
      out)),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What the database checks"),
      ["Every needs: names a declared step", "No duplicate step keys", "No unreachable step",
       "No cycle without an entry point", "Every sql: function is in step_functions"]
        .map((s) => h("div", { class: "row-between" }, chip("trigger", "accent"), h("span", {}, s))),
      h("div", { class: "note" }, "A rejection arrives as a Postgres error with its reason, and this ",
        "page shows it verbatim rather than restating it.")))));
  return node;
}

/* -- Schedules --------------------------------------------- */
export async function schedules() {
  const node = page(head("workflow.schedules_api", "Schedules",
    "A schedule is a row that calls start_workflow on a cron. Overlap policy is the only " +
    "interesting decision: skip while the previous run is going, or queue behind it."));
  const [s, d] = await Promise.all([
    tryRead(() => select("workflow", "schedules_api",
      "select=name,workflow_name,cron_expr,timezone,enabled,overlap_policy,last_fired_at,fire_count,skip_count,last_error&order=name"),
      (e) => ({ rows: [], error: e })),
    defs(),
  ]);
  node.append(panel("Schedules", (s.rows || []).length + " defined",
    s.error ? gap("schedules_api", s.error.message, "schema")
      : table(["Schedule", "Workflow", "Cron", "Overlap", "Last fired", "Fired", "Skipped", "Enabled"], s.rows || [], (r) =>
          h("tr", {},
            h("td", {}, r.name, r.last_error ? h("span", { class: "sub" }, r.last_error) : null),
            h("td", { class: "mono" }, r.workflow_name),
            h("td", { class: "mono" }, r.cron_expr + " " + (r.timezone || "")),
            h("td", {}, h("span", { class: "chip" }, r.overlap_policy)),
            h("td", { class: "mono" }, fmtTime(r.last_fired_at)),
            h("td", { class: "num" }, r.fire_count),
            h("td", { class: "num" }, r.skip_count),
            h("td", {}, h("button", { class: "btn ghost", onclick: async (e) => {
              const res = await tryRead(() => rpc("workflow", "set_schedule_enabled",
                { p_name: r.name, p_enabled: !r.enabled }), (err) => ({ error: err }));
              e.target.replaceWith(res.error ? chip(res.error.message, "failed") : chip("toggled", "succeeded"));
            } }, r.enabled ? "on" : "off"))))));

  const name = h("input", { class: "control", style: "width:100%", value: "nightly" });
  const wf = h("select", { class: "control", style: "width:100%" },
    (d.rows || []).map((x) => h("option", { value: x.name }, x.name)));
  const cron = h("input", { class: "control mono", style: "width:100%", value: "0 2 * * *" });
  const out = h("div");
  node.append(panel("Schedule a workflow", "workflow.schedule_workflow()",
    h("div", { class: "body" },
      h("div", { class: "grid g3" },
        h("div", { class: "field" }, h("label", {}, "name"), name),
        h("div", { class: "field" }, h("label", {}, "workflow"), wf),
        h("div", { class: "field" }, h("label", {}, "cron"), cron)),
      h("button", { class: "btn primary", onclick: async () => {
        const res = await tryRead(() => rpc("workflow", "schedule_workflow",
          { p_name: name.value, p_workflow: wf.value, p_cron: cron.value, p_input: {} }), (e) => ({ error: e }));
        out.replaceChildren(res.error ? h("div", { class: "note rose" }, res.error.message)
          : h("div", { class: "note" }, "Scheduled."));
        if (!res.error) setTimeout(() => location.reload(), 800);
      } }, "Schedule"), out)));
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
      const r = await tryRead(() => select("rbac", "auth_events",
        "select=id,user_id,event,detail,created_at&order=created_at.desc&limit=60"), (e) => ({ rows: [], error: e }));
      holder.replaceChildren(
        h("header", {}, h("h3", {}, "auth_events"), h("span", { class: "label" }, (r.rows || []).length + " rows")),
        h("div", { class: "body tight" }, r.error ? gap("rbac.auth_events", r.error.message, "schema")
          : stream((r.rows || []).map((e) => ({
              t: (e.created_at || "").slice(11, 19),
              tone: /fail|revoke|reuse/.test(e.event || "") ? "bad" : "info",
              what: e.event,
              meta: short(e.user_id) + (e.detail ? " · " + JSON.stringify(e.detail).slice(0, 80) : ""),
            })))));
      return;
    }
    const r = await tryRead(() => select("workflow", "task_events_api",
      "select=id,run_id,step_key,kind,queue,from_status,to_status,detail,at&order=at.desc&limit=60"),
      (e) => ({ rows: [], error: e }));
    holder.replaceChildren(
      h("header", {}, h("h3", {}, "task_events"), h("span", { class: "label" }, (r.rows || []).length + " rows")),
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
  const node = page(head("workflow.pools · v_pools · queue_depth()", "Queues & pools",
    "A worker pool is a row. A manager reconciles it into a Deployment and a KEDA ScaledObject, " +
    "and KEDA scales it 0 to N on that pool's queue depth. Nothing on this page holds cluster " +
    "credentials, and no YAML is authored per pool."));

  const [pools, binds, unserved, depth, t, rl, policy] = await Promise.all([
    tryRead(() => select("workflow", "v_pools", "order=name"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "pool_queues", "order=queue"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "v_unserved_queues", "order=queue"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "queues_api"), () => ({ rows: [] })),
    tryRead(() => select("workflow", "tasks_by_status_api", "order=queue"), () => ({ rows: [] })),
    tryRead(() => select("workflow", "rate_limits_api", "order=key"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "pool_image_policy", "order=pattern"), (e) => ({ rows: [], error: e })),
  ]);

  const pending = (pools.rows || []).filter((p) => p.reconcile_pending).length;
  node.append(h("div", { class: "grid g4" },
    stat("Pools", (pools.rows || []).length, "workflow.pools"),
    stat("Enabled", (pools.rows || []).filter((p) => p.enabled).length, "in the desired set"),
    stat("Awaiting a manager", pending, pending ? "observed_generation is behind" : "all reconciled",
         pending ? "down" : "up"),
    stat("Unserved queues", (unserved.rows || []).length, "tasks with no pool",
         (unserved.rows || []).length ? "down" : "")));

  node.append(panel("Pools", "desired state and observed state, joined",
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
            h("td", {}, h("button", { class: "btn ghost", onclick: async (e) => {
              const res = await tryRead(() => select("workflow", "pools",
                "name=eq." + p.name, { method: "PATCH", body: { enabled: !p.enabled } }),
                (err) => ({ error: err }));
              e.target.replaceWith(res.error ? chip(res.error.message, "failed") : chip("toggled", "succeeded"));
            } }, p.enabled ? "disable" : "enable"))))));

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

  node.append(panel("Queues", "one pool per queue, enforced by a primary key",
    table(["Queue", "Served by", "Depth (global)", "Your tasks, by status"], [...queueNames], (q) =>
      h("tr", {},
        h("td", { class: "mono" }, q),
        h("td", {}, poolOf.has(q) ? chip(poolOf.get(q), "accent")
                                  : h("span", { class: "chip failed" }, "no pool")),
        h("td", { class: "num" }, depths.has(q) ? String(depths.get(q)) : "—"),
        h("td", { class: "pill-row" }, (t.rows || []).filter((r) => r.queue === q).map((b) =>
          h("span", { class: "chip" }, b.status + " " + b.n)))))));

  node.append(h("div", { class: "grid g3" },
    panel("Unserved queues", "tasks waiting, no pool bound",
      unserved.error ? gap("v_unserved_queues", unserved.error.message, "schema")
        : table(["Queue", "Ready", "Running", "Oldest"], unserved.rows || [], (u) =>
            h("tr", {}, h("td", { class: "mono" }, u.queue), h("td", { class: "num" }, u.ready_tasks),
              h("td", { class: "num" }, u.running_tasks), h("td", { class: "mono" }, fmtTime(u.oldest_task))))),
    panel("Image allow-list", "deny by default",
      policy.error ? gap("pool_image_policy", policy.error.message, "schema")
        : table(["Pattern", "Note"], policy.rows || [], (r) =>
            h("tr", {}, h("td", { class: "mono" }, r.pattern), h("td", {}, r.note || "—")))),
    panel("Rate limits", "the bucket, minus the personal keys",
      rl.error ? gap("rate_limits_api", rl.error.message, "schema")
        : table(["Key", "Capacity", "Tokens"], rl.rows || [], (r) =>
            h("tr", {}, h("td", { class: "mono" }, r.key), h("td", { class: "num" }, r.capacity),
              h("td", { class: "num" }, Number(r.tokens).toFixed(1)))))));

  node.append(h("div", { class: "grid g2" },
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
        "Measured in pools.md §13: 4 against 2 on the same queue.")))));
  return node;
}

/* -- Load & limits ----------------------------------------- */
export async function scale() {
  const node = page(head("lifecycle · load · retention", "Load & limits",
    "What a load trial produces is not in the database - dev/scale writes it to a run log. This " +
    "screen shows what IS measurable from here, and names the rest as absent."));
  const [t, rs] = await Promise.all([
    tryRead(() => select("workflow", "tasks_by_status_api"), (e) => ({ rows: [], error: e })),
    tryRead(() => select("workflow", "runs_by_status_api"), (e) => ({ rows: [], error: e })),
  ]);
  const tasks = (t.rows || []).reduce((a, r) => a + Number(r.n), 0);
  const runsN = (rs.rows || []).reduce((a, r) => a + Number(r.n), 0);
  node.append(h("div", { class: "grid g4" },
    stat("Tasks visible", tasks, "tasks_by_status_api"),
    stat("Runs visible", runsN, "runs_by_status_api"),
    stat("Trials recorded", "-", "no table for them", "down"),
    stat("Retention", "-", "no policy row", "down")));

  node.append(h("div", { class: "grid g2" },
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
      h("div", { class: "note" }, "Both are schema work in workflow-engine, not UI work.")))));
  return node;
}
