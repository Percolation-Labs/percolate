import {editorWorkspace,contextualHelp} from "./workspace.js";
/* Access, chat, settings -- and Surface, which re-measures the whole thing.
 *
 * Same two rules as views.js. The one worth repeating here: no button on these
 * screens is hidden or disabled because of a role. `rbac.grant_role` and
 * `agentic.upsert_agent` check permission themselves; a UI that also decided
 * would be a second authorization model to keep in sync with the first, and the
 * one that matters is the one in the database.
 */

import { authFetch } from "./api.js";
import { select, rpc, read, probeQuery, config, setEndpoint, token } from "./api.js";
import { READS, PROBES } from "./reads.js";
import { agentEditor } from "./agent-editor.js";
import { HELP_AGENT, createChatSession } from "./query-assist.js";
import { chip, fmtTime, gap, h, icon, panel, seg, setStatusVocabulary, short, stat, statGap, status, stream, table } from "./ui.js";
import { markdown } from "./md.js";
import { head, page, tryRead, defs } from "./views.js";

/* A count that came back, or the reason it did not. `3 tool servers` and
   `0 tool servers` are both claims about the database; a refused read is
   neither, and saying "0" there is the failure this file had twice. */
const countOf = (res, n, noun) => (res && res.error ? noun + " unavailable" : n + " " + noun);

/* -- Agents ------------------------------------------------ */
export async function agents() {
  const editor = agentEditor();
  const [ag, sk, ts, pl] = await Promise.all([
    tryRead(() => read(READS.agents), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.skills), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.toolServers), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.plugins), (e) => ({ rows: [], error: e })),
  ]);
  const node = page(head([countOf(ag, (ag.rows || []).length, "agents"),
                          countOf(ts, (ts.rows || []).length, "tool servers"),
                          countOf(sk, (sk.rows || []).length, "skills")].join(" · "), "Agents & Plugins",
    "Configure the instructions, models and tools your workflows use."));

  node.append(panel("Agents", "agentic.agents_api",
    ag.error ? gap("agents_api", ag.error.message, "schema")
      /* Six columns, not seven. Provenance rides with the name because most
         agents are hand-authored, so a column for it is mostly empty and buys
         its width from the two columns that hold unbreakable identifiers. */
      /* The row opens the agent. One target, the whole row, the way the source
         library's cards work — rather than an actions column whose two ghost
         buttons made "edit" compete with "prompt" for the same intent. The
         prompt is not a separate disclosure any more because the editor shows
         it, composed with its skills, which the inline expander never could. */
      : table(["Agent", "Model", "Tools", "Skills", "Output"], ag.rows || [], (a) =>
          h("tr", { class: "row-open", onclick: (e) => {
            if (!e.target.closest("button, a, input, select")) editor.load(a);
          } },
            h("td", { class: "ident" },
              h("button", { class: "row-open-name", onclick: () => editor.load(a) }, a.name),
              a.plugin ? h("span", { class: "sub" }, "from " + a.plugin) : null),
            h("td", { class: "mono ident" }, a.model || "-"),
            h("td", { class: "pill-row" }, (a.tools || []).map((t) =>
              h("span", { class: "chip kind" }, typeof t === "string" ? t : (t.server || JSON.stringify(t))))),
            h("td", { class: "pill-row" }, (a.skills || []).map((s) => h("span", { class: "chip kind" }, s))),
            h("td", { class: "mono" }, a.structured_output_schema ? "typed" : "-")))));

  /* One catalogue, not three equal cards. They are not three equal things:
     skills are a flat list of names, plugins are usually empty, and a tool
     server has a status and an action. Giving each a third of the width left
     the names in a single column and put a button in the middle of a
     sentence. */
  const chips = (rows, label) => rows.length
    ? h("div", { class: "catalogue-chips" }, rows.map((r) =>
        h("span", { class: "chip", title: r.description || "" }, r.name)))
    : h("p", { class: "catalogue-empty" }, label);

  const server = (s) => {
    const count = (s.cached_tools || []).length;
    const status = h("span", { class: "catalogue-status" }, count
      ? `${count} operation${count === 1 ? "" : "s"} discovered`
      : "Catalogue not synced");
    const button = h("button", { class: "btn", onclick: async (e) => {
      e.target.disabled = true;
      try {
        const base = config().core?.replace(/\/$/, "");
        if (!base) throw new Error("Configure the agent runtime in Settings.");
        const res = await authFetch(base + "/tools/" + encodeURIComponent(s.name) + "/sync",
          { method: "POST", headers: { Authorization: "Bearer " + token() } });
        const data = await res.json();
        if (!res.ok) throw new Error(data.detail || "HTTP " + res.status);
        status.textContent = `${data.tools.length} operation${data.tools.length === 1 ? "" : "s"} discovered`;
      } catch (err) { status.replaceChildren(h("span", { class: "note rose" }, err.message)); }
      finally { e.target.disabled = false; }
    } }, count ? "Re-sync" : "Sync");
    return h("div", { class: "catalogue-row" },
      h("span", { class: "chip kind" }, s.name), h("span", { class: "mono" }, s.kind),
      status, h("span", { class: "spacer" }), button);
  };

  const group = (title, count, body, error, view) => h("div", { class: "catalogue-group" },
    h("h4", {}, title, count === null ? null : h("span", { class: "catalogue-count" }, count)),
    error ? gap(view, error.message, "schema") : body);

  node.append(h("div", { class: "catalogue" },
    group("Skills", sk.error ? null : (sk.rows || []).length,
      chips(sk.rows || [], "No skills registered. A skill is a named prompt fragment agents can share."),
      sk.error, "skills_api"),
    group("Tool servers", ts.error ? null : (ts.rows || []).length,
      (ts.rows || []).length
        ? h("div", { class: "catalogue-list" }, (ts.rows || []).map(server))
        : h("p", { class: "catalogue-empty" }, "No tool servers registered."),
      ts.error, "tool_servers_api"),
    group("Plugins", pl.error ? null : (pl.rows || []).length,
      chips(pl.rows || [], "None installed. A plugin installs agents and skills as a set."),
      pl.error, "plugins_api")));

  const browse=h('div',{class:'form-stack'},...Array.from(node.children).slice(1));
  const catalogue=browse.querySelector('.grid.g3');
  if(catalogue)browse.append(contextualHelp('Tools, skills & plugins',catalogue));
  const space=editorWorkspace({label:'Agent',browse,editor,createLabel:'Create agent',onCreate:()=>editor.startNew()});
  const load=editor.load;
  editor.load=value=>{space.open(value.name||'Agent',{expanded:true});load(value);};
  node.querySelector('.head-row').append(space.create);node.append(space.node);
  return node;
}

/* -- Users ------------------------------------------------- */
export async function users() {
  const [us, rs, roles, orgs] = await Promise.all([
    tryRead(() => read(READS.users), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.userRoles), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.roleNames), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.orgMembers), (e) => ({ rows: [], error: e })),
  ]);
  const roleOf = {};
  (rs.rows || []).forEach((r) => { (roleOf[r.user_id] = roleOf[r.user_id] || []).push(r.role); });
  const orgsOf = {};
  (orgs.rows || []).forEach((r) => { (orgsOf[r.user_id] = orgsOf[r.user_id] || []).push(r.role); });

  const node = page(head(countOf(us, (us.rows || []).length, "visible"), "Users",
    "Inspect workspace members, their roles and their access."));

  node.append(panel("Users", "rbac.users_api",
    us.error ? gap("users_api", us.error.message, "schema")
      : table(["Email", "Roles", "Org roles", "Status", "Created", "Grant"], us.rows || [], (u) =>
          h("tr", {},
            h("td", {}, u.email, h("span", { class: "sub" }, short(u.id))),
            h("td", { class: "pill-row" }, (roleOf[u.id] || []).map((r) => h("span", { class: "chip accent" }, r))),
            h("td", { class: "pill-row" }, (orgsOf[u.id] || []).map((r) => h("span", { class: "chip" }, r))),
            h("td", {}, status(u.status)),
            h("td", { class: "mono" }, fmtTime(u.created_at)),
            h("td", {}, (() => {
              /* No inline padding: it would win over select.control's right
                 padding and the chevron would sit on top of the word. */
              const sel = h("select", { class: "control compact" },
                (roles.rows || []).map((r) => h("option", { value: r.name }, r.name)));
              const out = h("span");
              return h("span", { class: "pill-row" }, sel,
                h("button", { class: "btn ghost", onclick: async () => {
                  const res = await tryRead(() => rpc("rbac", "grant_role",
                    { p_target_user_id: u.id, p_role: sel.value }), (e) => ({ error: e }));
                  out.replaceChildren(res.error ? chip(res.error.message, "failed") : chip("granted", "succeeded"));
                } }, "grant"), out);
            })())))));

  node.append(h("div", { class: "grid g2" },
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "Escalation is the function's problem, not this page's"),
      h("div", { class: "note" }, "The grant control is offered for every user and every role. ",
        h("code", { class: "mono" }, "rbac.grant_role()"), " is gated on ",
        h("code", { class: "mono" }, "users:admin"), " and raises if the caller does not hold it - ",
        "so what you see when you try is the database's answer, not a guess this page made."))),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What is missing"),
      h("div", { class: "note amber" }, h("strong", {}, "No API-key issuance. "),
        h("code", { class: "mono" }, "rbac.verify_api_key()"), " exists and nothing creates what it verifies, ",
        "so Keys can list and revoke and cannot issue. Writing the other half means deciding how a ",
        "secret is generated, returned exactly once and scoped - which belongs in user-rbac/schema.sql ",
        "beside the rest of the credential handling.")))));
  const help=node.querySelector('.grid.g2');if(help)node.append(contextualHelp('About access and available actions',help));
  return node;
}

/* -- Roles ------------------------------------------------- */
export async function roles() {
  const [kinds, perms, rl] = await Promise.all([
    tryRead(() => read(READS.permissionKinds), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.rolePermissions), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.roles), (e) => ({ rows: [], error: e })),
  ]);
  const held = new Set((perms.rows || []).map((p) => p.role + "|" + p.resource + "|" + p.action));
  const names = (rl.rows || []).map((r) => r.name);
  const node = page(head(countOf(rl, names.length, "roles") + " · " +
    countOf(kinds, (kinds.rows || []).length, "permission kinds"),
    "Roles & permissions",
    "One primitive for every module: rows in role_permissions, and one policy that calls " +
    "has_permission(). There is no per-module authorization code to review, which is why this " +
    "table is the whole surface."));

  /* A matrix built from a failed read is a grid of "·" -- which is a specific
     and false claim ("no role holds any permission"), not an absence of one. */
  const matrixErr = (kinds.error || rl.error || perms.error);
  node.append(panel("Matrix", "role x (resource : action)",
    matrixErr ? h("div", { class: "body" },
      gap("rbac.permission_kinds / roles / role_permissions", matrixErr.message, "schema"))
    : h("div", { class: "body", style: "overflow-x:auto" },
      h("table", { class: "matrix" },
        h("thead", {}, h("tr", {}, h("th", { class: "rowhead" }, "resource : action"),
          names.map((r) => h("th", {}, r)), h("th", {}, "checked by"))),
        h("tbody", {}, (kinds.rows || []).map((k) =>
          h("tr", {},
            h("td", { class: "rowhead" }, k.resource + " : " + k.action),
            names.map((r) => {
              const role = (rl.rows || []).find((x) => x.name === r);
              if (role && role.grants_all) return h("td", {}, h("span", { class: "inherit" }, "grants_all"));
              return h("td", {}, held.has(r + "|" + k.resource + "|" + k.action)
                ? h("span", { class: "yes" }, "✓") : h("span", { class: "no" }, "·"));
            }),
            h("td", { class: "mono", style: "text-align:left;color:var(--muted)" }, k.checked_by))))))));

  node.append(h("div", { class: "grid g2" },
    panel("Roles", "rbac.roles",
      rl.error ? gap("rbac.roles", rl.error.message, "schema")
      : table(["Role", "grants_all", "Description"], rl.rows || [], (r) =>
        h("tr", {}, h("td", { class: "mono" }, r.name),
          h("td", {}, r.grants_all ? chip("yes", "accent") : h("span", { class: "chip" }, "no")),
          h("td", {}, r.description || "-")))),
    panel("Visibility scopes", "rbac.visibilities", h("div", { class: "body" },
      h("dl", { class: "kv" },
        h("dt", {}, "private"), h("dd", {}, "the owner only"),
        h("dt", {}, "org"), h("dd", {}, "every member of the owning org"),
        h("dt", {}, "public"), h("dd", {}, "every authenticated caller")),
      h("div", { class: "note" }, "Orthogonal to roles: a role says what you may do, a scope says ",
        "which rows you may do it to. Generated into one RLS policy per table by add_scope_policy().")))));
  return node;
}

/* -- Keys & sessions --------------------------------------- */
export async function keys() {
  const [ak, rt] = await Promise.all([
    tryRead(() => read(READS.apiKeys), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.refreshSessions), (e) => ({ rows: [], error: e })),
  ]);
  const node = page(head("revocable rows, which is the point of them", "Keys & sessions",
    "A JWT you cannot revoke is a decision you cannot take back, so both of these are rows. " +
    "Presenting an already-rotated refresh token revokes the whole chain - theft shows up as a " +
    "revocation rather than a quiet second session.",
    h("button", { class: "btn danger", onclick: async (e) => {
      e.target.disabled = true;
      const res = await tryRead(() => rpc("rbac", "revoke_all_sessions", {}), (err) => ({ error: err }));
      e.target.replaceWith(res.error ? chip(res.error.message, "failed") : chip("all sessions revoked", "succeeded"));
    } }, "Revoke everywhere")));

  node.append(h("div", { class: "grid g2" },
    panel("API keys", "rbac.api_keys_api - no key_hash in the view",
      ak.error ? gap("api_keys_api", ak.error.message, "schema")
        : table(["Key", "Scopes", "Created", "Last used"], ak.rows || [], (k) =>
            h("tr", {}, h("td", {}, k.label || short(k.id)),
              h("td", { class: "pill-row" }, (k.scopes || []).map((s) => h("span", { class: "chip kind" }, s))),
              h("td", { class: "mono" }, fmtTime(k.created_at)),
              h("td", { class: "mono" }, fmtTime(k.last_used_at))))),
    panel("Sessions", "rbac.refresh_tokens_api - no token_hash either",
      rt.error ? gap("refresh_tokens_api", rt.error.message, "schema")
        : table(["Device", "Issued", "Expires", ""], rt.rows || [], (s) =>
            h("tr", {}, h("td", {}, s.device_label || "-"),
              h("td", { class: "mono" }, fmtTime(s.issued_at)),
              h("td", { class: "mono" }, fmtTime(s.expires_at)),
              h("td", {}, h("button", { class: "btn ghost danger", onclick: async (e) => {
                const res = await tryRead(() => rpc("rbac", "revoke_session", { p_refresh_token_id: s.id }),
                  (err) => ({ error: err }));
                e.target.replaceWith(res.error ? chip(res.error.message, "failed") : chip("revoked", "succeeded"));
              } }, "revoke")))))));

  node.append(h("div", { class: "note amber" },
    h("strong", {}, "Issuing is the missing half. "),
    "There is no function that creates an API key, so this screen lists and revokes and cannot ",
    "issue - and the list is empty on a deployment where nothing has ever made one."));
  return node;
}

/* -- Settings ---------------------------------------------- */
export async function settings() {
  const [orgs, mem, vis, states] = await Promise.all([
    tryRead(() => read(READS.orgs), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.orgMembers), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.visibilities), (e) => ({ rows: [], error: e })),
    tryRead(() => read(READS.lifecycleStates), (e) => ({ rows: [], error: e })),
  ]);
  /* Read here as well as at boot: this screen is where somebody asks what a
     word on a run means, and the same read is what colours the chips. */
  if (states.rows) setStatusVocabulary(states.rows);
  const rest = h("input", { class: "control mono", style: "width:100%", value: config().rest });
  const core = h("input", { class: "control mono", style: "width:100%", value: config().core });
  const content = h("input", { class: "control mono", style: "width:100%", "aria-label": "Content Server URL", value: config().content });
  const out = h("div");
  const node = page(head("this deployment", "Settings",
    "Three endpoints and a handful of rows. Everything else this app knows, it asks the database."));

  node.append(h("div", { class: "grid g2" },
    panel("Endpoints", "where this browser points", h("div", { class: "body" },
      h("div", { class: "field" }, h("label", {}, "PostgREST"), rest,
        h("span", { class: "hint" }, "every read and every write on every other screen")),
      h("div", { class: "field" }, h("label", {}, "Agent Runtime"), core,
        h("span", { class: "hint" }, "agent turns and tool discovery")),
      h("div", { class: "field" }, h("label", {}, "Content Server"), content,
        h("span", { class: "hint" }, "upload and download file bytes")),
      h("button", { class: "btn primary", onclick: () => {
        setEndpoint("rest", rest.value.replace(/\/$/, ""));
        setEndpoint("core", core.value.replace(/\/$/, ""));
        setEndpoint("content", content.value.replace(/\/$/, ""));
        out.replaceChildren(h("div", { class: "note" }, "Saved to localStorage."));
      } }, "Save"), out)),
    panel("Orgs", "rbac.orgs",
      orgs.error ? gap("rbac.orgs", orgs.error.message, "schema")
        : table(["Slug", "Name", "Members"], orgs.rows || [], (o) =>
            h("tr", {}, h("td", { class: "mono" }, o.slug), h("td", {}, o.name),
              h("td", { class: "num" }, (mem.rows || []).filter((m) => m.org_id === o.id).length))))));

  node.append(panel("Run status vocabulary", "workflow.lifecycle_states - what each word means, and which of them are finished",
    states.error ? gap("workflow.lifecycle_states", states.error.message, "schema")
      : table(["State", "Finished", "Succeeded", "Meaning"], states.rows || [], (v) =>
          h("tr", {}, h("td", {}, status(v.state)), h("td", {}, v.is_terminal ? "yes" : "no"),
            h("td", {}, v.is_success ? "yes" : "no"), h("td", {}, v.note)))));

  node.append(panel("Visibility vocabulary", "rbac.visibilities - a table, not an enum",
    table(["Scope", "Rank", "Requires org", "Meaning"], vis.rows || [], (v) =>
      h("tr", {}, h("td", { class: "mono" }, v.scope), h("td", { class: "num" }, v.rank),
        h("td", {}, v.requires_org ? "yes" : "no"), h("td", {}, v.description)))));
  return node;
}

/* -- Chat -------------------------------------------------- */

/* One tool call, as a row that changes state.
 *
 * The same component renders a stored call and a live one, because they are the
 * same thing at different times -- a transcript read back from `messages_api`
 * is a turn that finished, and rendering it with a second component is how the
 * two drift into looking like different events. */
function toolRow(name, state, detail, opts = {}) {
  const marks = { running: "running", ok: "succeeded", error: "failed", pending: "" };
  const mark = (st) => h("span", { class: "chip " + (marks[st] || "") },
    h("i", { class: st === "running" ? "spin" : "dot" }),
    st === "running" ? "running" : st === "ok" ? "done" : st);

  const row = h("div", { class: "tool-call" + (opts.delegated ? " delegated" : ""), "data-tool": name },
    h("div", { class: "head" },
      h("span", { class: "tool-name" }, name),
      /* A delegated call is a whole child run with its own event stream, not a
         function that happened to take a while. It gets its own chip and its own
         indent rather than a "(delegated)" appended to the name -- which wrapped
         at any sensible column width, and read as part of the tool's name. */
      opts.delegated ? h("span", { class: "chip accent" }, "sub-agent") : null,
      h("span", { class: "spacer" }),
      mark(state)),
    detail ? h("div", { class: "out" }, detail) : null);

  row.setState = (next, text) => {
    row.querySelector(".head .chip:last-of-type").replaceWith(mark(next));
    if (text) row.append(h("div", { class: "out" }, text));
  };
  return row;
}

const bubble = (role, when, body) =>
  h("div", { class: "msg " + (role === "user" ? "user" : "assistant") },
    h("span", { class: "name" }, role === "user" ? "you" : role, when ? " · " + when : ""),
    body);


export async function help() {
  const guide = h("div", {class:"help-guide"});
  try {
    const response = await fetch("help.md");
    if (!response.ok) throw new Error("The product guide could not be loaded.");
    guide.append(markdown(await response.text()));
  } catch (e) { guide.append(h("div", {class:"note rose"}, e.message)); }
  const notice = h("div", {role:"status"});
  const ask = async prompt => {
    for (const button of actions.querySelectorAll("button")) button.disabled = true;
    notice.textContent = "Opening your help conversation…";
    try {
      const {rows:agents} = await read(READS.agentNames);
      if (!agents.some(a => a.name === HELP_AGENT)) throw new Error("The help agent has not been configured. Ask your workspace administrator to run dev/ui_assistant.py with a configured model; the guide below is available now.");
      const session = await createChatSession("Percolate help");
      sessionStorage.setItem("p8-chat-session", session);
      sessionStorage.setItem("p8-chat-agent", HELP_AGENT);
      sessionStorage.setItem("p8-chat-prompt", prompt);
      location.hash = "#/chat";
    } catch (e) {
      notice.replaceChildren(h("div", {class:"note rose"}, e.message));
      for (const button of actions.querySelectorAll("button")) button.disabled = false;
    }
  };
  const actions = h("div", {class:"help-actions"},
    h("div", {class:"assistant-intro"}, h("h3", {}, "What work do you want to automate?"), h("p", {}, "Get help defining a workflow, choosing its steps and understanding a run.")),
    h("div", {class:"form-actions"}, h("button", {class:"btn primary", onclick:() => ask("")}, "Start a help conversation"),
      h("button", {class:"btn", onclick:() => ask("How does Percolate work?")}, "How does Percolate work?"),
      h("button", {class:"btn", onclick:() => ask("Help me plan a recurring operations review with queries and an agent step. Explain what to define and how to inspect a run.")}, "Plan a workflow")), notice);
  return page(head("A guide to your workspace", "Help", "Understand Percolate and put it to work."), actions, guide);
}

export async function chat() {
  const sessions = await tryRead(() => read(READS.chatSessions, "limit=40"), (e) => ({ rows: [], error: e }));
  const ag = await tryRead(() => read(READS.agentNames), (e) => ({ rows: [], error: e }));

  const convo = h("div", { class: "thread" }, h("div", { class: "empty" }, "Pick a session, or create one."));
  let list = null, sendBtn = null;
  const aside = h("div", { class: "body", style: "padding:.9rem;display:flex;flex-direction:column;gap:.8rem" },
    h("div", { class: "note" }, "Runs and messages for the selected session appear here."));
  let current = null;
  let sending = false;

  /* The scroller is the conversation column, not the thread inside it. */
  const scroller = () => convo.parentElement;
  const atBottom = () => {
    const el = scroller();
    return !el || el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };
  const stick = (was) => { const el = scroller(); if (was && el) el.scrollTop = el.scrollHeight; };

  const openSession = async (s, node) => {
    if (sending) return;
    current = s;
    sessionStorage.setItem("p8-chat-session", s.id);
    [...node.parentElement.children].forEach((c) => c.removeAttribute("aria-current"));
    node.setAttribute("aria-current", "true");
    convo.replaceChildren(h("div", { class: "empty" }, "Loading..."));
    const [msgs, runsRes] = await Promise.all([
      tryRead(() => read(READS.messages, "session_id=eq." + s.id), (e) => ({ rows: [], error: e })),
      tryRead(() => read(READS.sessionRuns, "session_id=eq." + s.id), (e) => ({ rows: [], error: e })),
    ]);

    if (current?.id !== s.id) return;
    const body = msgs.error ? [gap("messages_api", msgs.error.message, "schema")]
      : ((msgs.rows || []).length
          ? (msgs.rows || []).flatMap((m) => {
              const content = typeof m.content === "string" ? m.content : JSON.stringify(m.content);
              const parts = [markdown(content)];
              (m.tool_calls || []).forEach((t) => {
                const name = t.name || t.tool_name || (t.function && t.function.name) || "tool";
                const args = t.args || t.arguments || (t.function && t.function.arguments);
                parts.push(toolRow(name, (t.is_error || m.is_error) ? "error" : "ok",
                                   args ? JSON.stringify(args).slice(0, 200) : null));
                if (t.content !== undefined) parts.push(h("details", {}, h("summary", {}, "Tool result"),
                  h("pre", {class:"code"}, typeof t.content === "string" ? t.content : JSON.stringify(t.content, null, 2))));
              });
              return [bubble(m.role, fmtTime(m.created_at),
                             h("div", { class: "text" }, ...parts))];
            })
          : [h("div", { class: "empty" }, "No messages. Nothing has run in this session.")]);
    for (const run of runsRes.rows || []) {
      if (run.status === "failed") body.push(h("div", {class:"note rose"}, run.state?.error || "An agent run failed."));
    }
    convo.replaceChildren(...body);
    title.textContent = s.title || "(untitled)";
    stick(true);

    aside.replaceChildren(
      h("dl", { class: "kv" },
        h("dt", {}, "session"), h("dd", { class: "mono" }, short(s.id)),
        h("dt", {}, "created"), h("dd", {}, fmtTime(s.created_at)),
        h("dt", {}, "runs"), h("dd", {}, runsRes.error ? "unavailable" : String((runsRes.rows || []).length))),
      runsRes.error ? gap("agentic.runs_api", runsRes.error.message, "schema")
        : (runsRes.rows || []).length
          ? stream((runsRes.rows || []).map((r) => ({
              t: (r.created_at || "").slice(11, 19),
              tone: r.status === "failed" ? "bad" : r.status === "running" ? "warn" : "ok",
              what: (r.trigger_kind || "run") + " " + r.status,
              meta: "depth " + r.depth + " · " + short(r.id) })))
          : h("div", { class: "note" }, "No runs yet. A run row is created by agentic.start_run(), ",
              "which the runtime calls when a turn begins."));
  };

  /* The live turn.
   *
   * AG-UI events, rendered as they arrive: RUN_STARTED opens a progress block,
   * TOOL_CALL_START/END drive rows in it, TEXT_MESSAGE_CONTENT deltas stream
   * into a bubble that is re-rendered as markdown, RUN_FINISHED closes it. The
   * events are the runtime's contract (agentic/contracts/protocol.py), not a
   * shape invented here -- which is why the progress block can show a delegated
   * sub-agent: a TOOL_CALL_START carrying child_run_id IS the delegation. */
  function turnRenderer() {
    const rows = new Map();
    let agent = "agent";
    const started = Date.now();
    const status = h("span", { class: "chip running" }, h("i", { class: "spin" }), "starting");
    const elapsed = h("span", { class: "mono elapsed" }, "0.0s");
    const steps = h("div", { class: "turn-steps" });
    const head = h("div", { class: "turn-head" },
      h("span", { class: "label" }, "turn"), status, h("span", { class: "spacer" }), elapsed);
    const block = h("div", { class: "turn" }, head, steps);
    const tick = setInterval(() => {
      elapsed.textContent = ((Date.now() - started) / 1000).toFixed(1) + "s";
    }, 100);

    let bubbleEl = null, text = "", pending = false;
    const paint = () => {
      pending = false;
      if (!bubbleEl) return;
      const was = atBottom();
      bubbleEl.replaceChildren(markdown(text));
      stick(was);
    };

    const setStatus = (cls, label, spin) => {
      status.className = "chip " + cls;
      status.replaceChildren(h("i", { class: spin ? "spin" : "dot" }), label);
    };

    return {
      block,
      failed: false,
      handle(type, data) {
        const was = atBottom();
        if (type === "RUN_STARTED") {
          agent = data.agent_name || "agent";
          setStatus("running", agent, true);
        } else if (type === "TOOL_CALL_START") {
          const label = data.tool_name || "tool";
          const row = toolRow(label, "running", null, { delegated: !!data.child_run_id });
          rows.set(data.tool_call_id, row);
          steps.append(row);
          // The header counts; the rows name. Repeating the running tool in both
          // put the same word twice on one screen and told a reader nothing the
          // second time.
          setStatus("running", agent + " · step " + rows.size, true);
        } else if (type === "TOOL_CALL_END") {
          const row = rows.get(data.tool_call_id);
          if (row) row.setState(data.is_error ? "error" : "ok", data.error_kind || null);
        } else if (type === "TEXT_MESSAGE_START") {
          bubbleEl = h("div", { class: "text" });
          text = "";
          convo.append(bubble("assistant", "now", bubbleEl));
          setStatus("running", agent + " · writing", true);
        } else if (type === "TEXT_MESSAGE_CONTENT") {
          text += data.delta || "";
          // One repaint per frame: a token-rate re-render of a markdown tree is
          // the one place this UI could actually be slow.
          if (!pending) { pending = true; requestAnimationFrame(paint); }
        } else if (type === "TEXT_MESSAGE_END") {
          paint();
        } else if (type === "RUN_FINISHED") {
          clearInterval(tick);
          this.failed ||= !!data.status && data.status !== "succeeded";
          setStatus(this.failed ? "failed" : "succeeded", data.status || "done", false);
        } else if (type === "RUN_ERROR") {
          this.failed = true;
          clearInterval(tick);
          setStatus("failed", "failed", false);
          steps.append(h("div", { class: "note rose" }, data.message || "the run failed"));
        }
        stick(was);
      },
      stop(message) {
        clearInterval(tick);
        setStatus("failed", "no stream", false);
        if (message) steps.append(h("div", { class: "note rose" }, message));
      },
      note(message) {
        steps.append(h("div", { class: "note amber" }, message));
      },
    };
  }

  /* Both panels collapse, and the state persists. `data-left`/`data-right` on
     the container rather than a class on each panel, so the CSS can also move
     the toggle that reopens them into the conversation header -- one attribute,
     two consequences, no second source of truth. */
  const shell = h("div", { class: "chat" });
  const stored = (k, d) => { try { return localStorage.getItem(k) || d; } catch (e) { return d; } };
  const setPanel = (side, state) => {
    shell.dataset[side] = state;
    try { localStorage.setItem("p8-chat-" + side, state); } catch (e) {}
  };
  const rightBtn = h("button", { class: "icon-btn", title: "Session details",
    onclick: () => setPanel("right", shell.dataset.right === "open" ? "shut" : "open") }, icon('panelRight'));

  const title = h("span", { class: "title" }, "Chat");
  const newSession = async () => {
    if (sending) return;
    const res = await tryRead(async () => ({rows:await createChatSession("Session " + new Date().toISOString().slice(11, 19))}), (e) => ({ error: e }));
    if (!res.error) {
      sessionStorage.setItem("p8-chat-session", String(res.rows));
      location.reload();
    } else convo.append(h("div", {class:"note rose"}, res.error.message));
  };

  const threads = h("div", { class: "threads rail-list" },
    sessions.error ? gap("sessions_api", sessions.error.message, "schema")
      : ((sessions.rows || []).length
          ? (sessions.rows || []).map((sess) => {
              const node = h("div", { class: "thread-item" },
                h("strong", {}, sess.title || "(untitled)"),
                h("div", { class: "meta" }, h("span", {}, fmtTime(sess.created_at)),
                  h("span", { class: "mono" }, short(sess.id))));
              node.addEventListener("click", () => openSession(sess, node));
              return node;
            })
          : h("div", { class: "empty" }, "No sessions.")));
  list = threads;

  const box = h("textarea", { class: "box", rows: 1, "aria-label":"Message", placeholder: "Describe work to automate, or ask about Percolate…" });
  const starter = sessionStorage.getItem("p8-chat-prompt");
  if (starter) { box.value = starter; sessionStorage.removeItem("p8-chat-prompt"); }
  /* An empty picker and an unreadable agents_api look identical, and one of
     them means "ask somebody about your grants" rather than "register one". */
  const agentPick = h("select", { class: "control", style: "padding:.15rem .35rem;font-size:.72rem" },
    ag.error ? h("option", { value: "", disabled: true, selected: true },
                 "agents unavailable · " + (ag.error.code || ag.error.message))
             : (ag.rows || []).map((a) => h("option", { value: a.name }, a.name)));
  const picked = sessionStorage.getItem("p8-chat-agent");
  if ((ag.rows || []).some(a => a.name === picked)) agentPick.value = picked;
  else if ((ag.rows || []).some(a => a.name === HELP_AGENT)) agentPick.value = HELP_AGENT;
  agentPick.setAttribute("aria-label", "Agent");
  agentPick.addEventListener("change", () => sessionStorage.setItem("p8-chat-agent", agentPick.value));
  sendBtn = h("button", { class: "send-btn", title: "Send  ⌘↵" }, icon('send'));

  /* Grow with the text and stop -- a fixed three-row box is too tall for "yes"
     and too short for a spec. Capped in CSS at 40vh so it cannot eat the
     transcript. */
  const autosize = () => { box.style.height = "auto"; box.style.height = box.scrollHeight + "px"; };
  box.addEventListener("input", autosize);

  const send = async () => {
    if (sending) return;
    if (!current) { convo.append(h("div", { class: "note rose" }, "Pick a session first.")); return; }
    const text = box.value.trim();
    if (!text) return;
    sending = true;
    box.value = "";
    sendBtn.disabled = true;
    agentPick.disabled = true;
    convo.append(bubble("user", "now", h("div", { class: "text" }, markdown(text))));

    /* How many rows the transcript had before this turn -- the check that
       decides whether the re-read below is authoritative or destructive. */
    const counted = await tryRead(() => read(READS.messageSeqs,
      "session_id=eq." + current.id, { count: true }), () => ({ total: 0 }));
    const before = counted.total || 0;

    const turn = turnRenderer();
    convo.append(turn.block);
    autosize();
    stick(true);

    const endpoint = (config().core || "").replace(/\/$/, "");
    if (!endpoint) {
      /* Not an exception: "this deployment has no runtime" is a configuration
         fact, and reporting it as a failed request would send the reader
         looking for a broken service instead of an unset variable. */
      turn.stop(null);
      turn.note("No agent runtime configured — config.json reports core: \"\". " +
                "Set P8_UI_CORE_URL on the server to the runtime's base URL and the " +
                "composer posts there. Everything else on this page is PostgREST, " +
                "which is why only this one control is inert.");
      sending = false;
      sendBtn.disabled = false;
      agentPick.disabled = false;
      stick(true);
      return;
    }
    try {
      const res = await authFetch(endpoint + "/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + token(),
                   Accept: "text/event-stream" },
        body: JSON.stringify({ session_id: current.id, model: agentPick.value,
                               messages: [{ role: "user", content: text }], stream: true }),
      });
      if (!res.ok || !res.body) {
        const error = await res.json().catch(() => ({}));
        throw new Error(error.detail || error.message || "HTTP " + res.status);
      }

      /* SSE off a fetch body: frames are separated by a blank line, and a
         frame's `data:` is one JSON object. Parsed here rather than with
         EventSource because EventSource cannot POST -- and the POST is what
         starts the turn. `GET /sessions/{id}/events` is the EventSource half,
         for an observer or a reconnect. */
      const reader = res.body.getReader(), dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let cut;
        while ((cut = buf.indexOf("\n\n")) !== -1) {
          const frame = buf.slice(0, cut);
          buf = buf.slice(cut + 2);
          let type = "message", data = {};
          for (const line of frame.split("\n")) {
            if (line.startsWith("event:")) type = line.slice(6).trim();
            else if (line.startsWith("data:")) {
              try { data = JSON.parse(line.slice(5).trim()); } catch (e) { data = {}; }
            }
          }
          turn.handle(type, data);
        }
      }

      /* Re-read the turn as rows -- but only swap if the rows are actually
         there. The runtime persists during the turn, so normally they are; if
         they are not, replacing the transcript would delete the answer the user
         just watched arrive, which is the worst thing this screen could do.
         Found by streaming against dev/agui_stub.py, which writes nothing. */
      const after = await tryRead(() => read(READS.messageSeqs,
        "session_id=eq." + current.id, { count: true }), () => ({ total: null }));
      const node = list && list.querySelector('.thread-item[aria-current]');
      if (node && !turn.failed && after.total !== null && after.total > before) {
        sending = false;
        await openSession(current, node);
      } else if (!turn.failed) {
        turn.note("Streamed, and not written to agentic.messages -- messages_api still " +
                  "reports " + (after.total === null ? "unknown" : after.total) + " rows for this " +
                  "session. What you can see above is this page's copy; reload and it is gone.");
      }
    } catch (e) {
      /* Report what happened, then what it probably means -- in that order. An
         explanation that arrives before the fact is an explanation that is
         sometimes wrong about a fact the reader can see. */
      turn.stop(String(e.message || e) + " — POST " + endpoint + "/chat. " +
                "Sessions, runs and messages are all readable over PostgREST; the turn " +
                "is the one part of chat that is not a query, so it needs a runtime.");
    } finally {
      sending = false;
      agentPick.disabled = false;
      sendBtn.disabled = false;
      stick(true);
    }
  };

  sendBtn.addEventListener("click", send);
  box.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
  });

  /* Into the rail, under the Chat item. index.html's drawNav left the slot. */
  const slot = document.getElementById("rail-sessions");
  if (slot) {
    slot.replaceChildren(
      h("button", { class: "new", onclick: newSession }, "+ new session"),
      threads);
  }

  shell.append(
    h("section", { class: "convo" },
      h("div", { class: "convo-head" }, title, h("span", { class: "spacer" }),
        h("span", { class: "chip" }, config().core ? "runtime configured" : "no runtime configured"),
        rightBtn),
      h("div", { class: "scroll" }, convo),
      h("div", { class: "composer" },
        h("div", { class: "composer-inner" }, box,
          h("div", { class: "row" },
            h("span", { class: "chip accent" }, "agent"), agentPick,
            h("span", { class: "spacer" }),
            h("span", { class: "mono", style: "font-size:.62rem;color:var(--faint)" }, "⌘↵"),
            sendBtn)))),
    h("aside", { class: "chat-aside" },
      h("div", { class: "panel-head" },
        h("div", { class: "tabs" }, h("button", { "aria-selected": "true" }, "Session")),
        h("span", { class: "spacer" }),
        h("button", { class: "icon-btn", title: "Hide", onclick: () => setPanel("right", "shut") },
          icon('panelRight'))),
      aside));

  shell.dataset.left = stored("p8-chat-left", "open");
  shell.dataset.right = stored("p8-chat-right", "open");

  queueMicrotask(() => {
    const index = Math.max(0, (sessions.rows || []).findIndex(s => s.id === sessionStorage.getItem("p8-chat-session")));
    const first = threads.querySelectorAll(".thread-item")[index];
    if (first) openSession(sessions.rows[index], first);
    if (starter) { box.focus(); autosize(); }
  });

  return h("div", { class: "page flush" }, shell);
}

/* -- Surface ----------------------------------------------- */

/* Is the runtime there, and which build -- asked the way that costs nothing.
 *
 * `GET /_build` is unauthenticated, touches no provider and returns the source
 * fingerprint. A model turn is the other question, it costs real money, and a
 * health page that spends provider credits every time somebody opens it is a
 * health page nobody can afford to leave open. So this reports TRANSPORT, and
 * says as much: the Chat screen is where a turn gets proved.
 *
 * A browser cannot tell a refused CORS preflight from an unreachable host --
 * both arrive as one opaque TypeError, by design -- so neither can this. It
 * names both, which is the honest answer and also the useful one: those are
 * the two things to go and check. */
async function runtimeProbe() {
  const base = (config().core || "").replace(/\/$/, "");
  if (!base) return { state: "unconfigured" };
  const t0 = Date.now();
  try {
    const res = await fetch(base + "/_build", { cache: "no-store" });
    const ms = Date.now() - t0;
    if (!res.ok) return { state: "error", detail: "HTTP " + res.status, ms, base };
    const body = await res.json().catch(() => ({}));
    return { state: "ok", build: body.build || "(no fingerprint)", ms, base };
  } catch (e) {
    return { state: "blocked", detail: String((e && e.message) || e), base };
  }
}

export async function surface() {
  const node = page(head("measured now, against this deployment", "Surface",
    "Every row is a request made when this page loaded, and it is the SAME request the screen " +
    "makes - same columns, same ordering, from reads.js. An audit that only asked whether the " +
    "table existed is what let five screens ship asking for columns no view has."));

  const contracts = Object.entries(READS).map(([key, c]) => ({ key, ...c }));
  const [rows, existence, runtime] = await Promise.all([
    Promise.all(contracts.map(async (c) => {
      try { await select(c.schema, c.view, probeQuery(c)); return { ...c, ok: true }; }
      catch (e) { return { ...c, ok: false, code: e.code, msg: e.message }; }
    })),
    Promise.all(PROBES.map(async (p) => {
      try { await select(p.schema, p.view, "limit=1"); return { ...p, ok: true }; }
      catch (e) { return { ...p, ok: false, code: e.code, msg: e.message }; }
    })),
    runtimeProbe(),
  ]);
  const okN = rows.filter((r) => r.ok).length;
  /* A failure with no SQLSTATE never reached Postgres at all -- wrong URL,
     refused connection, blocked preflight. The three tiles below classify what
     Postgres SAID, so with unreachable reads in the mix a zero in them is not
     "no such problem", it is "no information" -- the same false all-clear this
     page exists to stop the Overview making. */
  const unreachable = rows.filter((r) => !r.ok && !r.code).length;
  const kind = (code) => rows.filter((r) => r.code === code).length;
  const classify = (label, code, bad, good) =>
    unreachable ? statGap(label, { message: unreachable + " read(s) never reached PostgREST" })
                : stat(label, kind(code), kind(code) ? bad : good, kind(code) ? "down" : "up");

  node.append(h("div", { class: "grid g4" },
    stat("Screen reads", okN + " / " + rows.length, "contracts executed, right now",
         okN === rows.length ? "up" : "down"),
    classify("Undefined column", "42703", "a screen asks for what no view has", "none"),
    classify("Refused", "42501", "permission denied", "none denied"),
    classify("Absent", "42P01", "relation does not exist", "all present")));

  node.append(panel("Screen reads", okN + " of " + rows.length + " executed",
    table(["Screen", "Object", "Read", "Result"], rows, (r) =>
      h("tr", {},
        h("td", {}, r.screen),
        h("td", { class: "mono" }, r.schema + "." + r.view),
        h("td", { class: "mono", style: "font-size:.68rem;color:var(--muted);max-width:26rem;overflow-wrap:anywhere" },
          r.q || r.note || "(whole row)"),
        h("td", {}, r.ok ? chip("200", "succeeded")
          : h("span", { class: "pill-row" }, chip(String(r.code || "err"), "failed"),
              h("span", { class: "mono", style: "font-size:.72rem" }, r.msg)))))));

  node.append(h("div", { class: "grid g2" },
    panel("Runtime", "percolate-core, transport only", h("div", { class: "body" },
      runtime.state === "unconfigured"
        ? h("div", { class: "note amber" }, h("strong", {}, "No runtime configured. "),
            "Settings has an empty percolate-core endpoint, so Chat cannot run a turn.")
        : runtime.state === "ok"
          ? h("div", { class: "note" }, h("strong", {}, "GET /_build answered in " + runtime.ms + "ms. "),
              h("code", { class: "mono" }, runtime.build))
          : gap(runtime.base + "/_build", runtime.detail,
                runtime.state === "blocked"
                  ? "unreachable, or this origin is not in P8_CORS_ORIGINS - a browser cannot tell them apart"
                  : "runtime"),
      h("div", { class: "note" }, h("strong", {}, "This is not a model turn. "),
        "Reachability and a real answer from a provider are different claims, and only one of them " +
        "is free. Nothing on this page calls a paid provider; proving a turn is the Chat screen."))),
    panel("Existence only", existence.length + " objects no screen reads",
      h("div", { class: "body" },
        table(["Object", "Why", "Result"], existence, (p) =>
          h("tr", {},
            h("td", { class: "mono" }, p.schema + "." + p.view),
            h("td", { style: "font-size:.72rem;color:var(--muted)" }, p.why),
            h("td", {}, p.ok ? chip("200", "succeeded") : chip(String(p.code || "err"), "failed")))),
        h("div", { class: "note" }, h("strong", {}, "Kept apart on purpose. "),
          "A reachable table is not a working screen, so these cannot count towards the number " +
          "above. Writes are RPC throughout - there are no table grants anywhere.")))));

  node.append(h("div", { class: "grid g2" },
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What percolate-core has to own"),
      h("div", { class: "note" }, h("strong", {}, "Minting a JWT. "),
        "rbac.login() returns (user_id, refresh_token_id) - ids, not a token. Signing is not a query."),
      h("div", { class: "note" }, h("strong", {}, "The agent turn. "),
        "POST /chat and GET /sessions/{id}/events: an LLM call, and an SSE relay of Postgres NOTIFY."),
      h("div", { class: "note" }, h("strong", {}, "Bytes. "),
        "POST /files and GET /files/{id}. The database halves - register_upload, resolve_file - are reachable."),
      h("div", { class: "note" }, h("strong", {}, "Live updates. "),
        "The triggers already pg_notify. A browser cannot LISTEN, so the relay is a service job."))),
    h("div", { class: "panel" }, h("div", { class: "body" },
      h("h3", {}, "What was a schema gap, and what closing it took"),
      h("div", { class: "note" }, h("strong", {}, "Six views and four grants. "),
        "definitions_api, task_events_api, task_dependencies_api, runs_by_status_api, ",
        "tasks_by_status_api, queues_api, rate_limits_api - all in sql/ui-views.sql, all additive, ",
        "each owned by api_viewer so RLS still applies."),
      h("div", { class: "note amber" }, h("strong", {}, "One of them is a filter, not a grant. "),
        "rate_limits holds login throttle keys containing email addresses, so granting it would ",
        "publish who has tried to sign in."),
      h("div", { class: "note" }, h("strong", {}, "workflow.pools now exists. "),
        "pools.sql shipped -- and could not load as app_owner until its two CREATE ROLEs moved to ",
        h("code", { class: "mono" }, "user-rbac/roles.sql"), ", which is where this collection's own ",
        "rule says cluster roles live."),
      h("div", { class: "note amber" }, h("strong", {}, "No manager has observed any of them. "),
        "The rows are desired state; ", h("code", { class: "mono" }, "p8 pool run"),
        " is what would reconcile them, and only ", h("code", { class: "mono" }, "p8 pool render"),
        " is implemented.")))));
  return node;
}
