import {splitWorkspace,contextualHelp} from "./workspace.js";
import { rpc, read } from "./api.js";
import { READS } from "./reads.js";
import { HELP_AGENT, suggestQuery, withoutTerminator } from "./query-assist.js";
import { h, panel, table } from "./ui.js";
import { page, head } from "./views.js";
import { draftStore, stageWorkflow, sameInput } from "./drafts.js";

export function jsonObject(text) {
  let value;
  try { value = JSON.parse(text); }
  catch (_) { throw new Error('The inputs are not valid JSON. Use double quotes around names and text, and remove trailing commas. Example: {"topic": "outage"}.'); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Enter a JSON object, such as {\"topic\": \"outage\"}.");
  return value;
}

export function downloadJSON(value, filename) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], {type: "application/json"}));
  const link = h("a", { href: url, download: filename });
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function runForm(name, options = {}) {
  const store = draftStore(options.draftKey || "workflow-run:" + name);
  const saved = store.read();
  const reference = () => "ui-" + crypto.randomUUID();
  const input = h("textarea", {class: "control mono", rows: 5, "aria-label": "Workflow input JSON", style: "width:100%"}, saved.input ?? options.input ?? "{}");
  const external = h("input", {class: "control mono", "aria-label": "Run reference", value: saved.reference || reference()});
  const out = h("div", {role: "status"});
  const draftNote = h("span", {class:"hint"});
  let attempted = saved.attempted || null;
  const remember = () => {
    draftNote.textContent = store.write({input:input.value, reference:external.value, attempted})
      ? "Draft saved in this tab." : "This browser could not save the draft. Keep this page open.";
  };
  input.addEventListener("input", () => {
    if (attempted && input.value !== attempted.input && external.value === attempted.reference) {
      external.value = reference(); attempted = null;
      out.replaceChildren(h("p", {}, "Inputs changed. A new run reference is ready."));
    }
    remember();
  });
  external.addEventListener("input", remember);
  const start = h("button", {class: "btn primary", onclick: async () => {
    if (start.disabled) return;
    start.disabled = true;
    let started = false;
    try {
      const payload = jsonObject(input.value);
      if (!external.value.trim()) external.value = reference();
      input.disabled = external.disabled = true;
      attempted = {input:input.value, reference:external.value}; remember();
      const {rows} = await rpc("workflow", "start_workflow", {p_name: typeof name === "function" ? name() : name,
        p_input:payload, p_external_id:external.value.trim()});
      const id = typeof rows === "string" ? rows : rows?.id;
      if (!id) throw new Error("No run ID was returned. Keep this reference and retry to recover the run.");
      started = true; store.clear(); draftNote.textContent = "";
      out.replaceChildren(h("a", {class:"btn primary", href: "#/run/" + id}, "Open run"));
      start.textContent = "Run started";
      try {
        const found = (await read(READS.run, "id=eq." + encodeURIComponent(id))).rows[0];
        if (found && !sameInput(found.input, payload)) out.prepend(h("div", {class:"note", role:"alert"},
          "This reference belongs to an earlier run with different inputs. Open it to inspect the original work, or choose Prepare another run for these inputs."));
      } catch (_) { /* The run ID is the receipt even if the status read fails. */ }
      out.append(h("button", {class:"btn", onclick:() => {
        external.value = reference(); attempted = null;
        input.disabled = external.disabled = start.disabled = false;
        start.textContent = "Start workflow"; out.replaceChildren(); remember(); input.focus();
      }}, "Prepare another run"));
    } catch (e) {
      out.replaceChildren(h("div", {class: "note rose", role:"alert"}, e.message));
    } finally {
      if (!started) input.disabled = external.disabled = start.disabled = false;
    }
  }}, "Start workflow");
  return h("div", {class: "form-stack"},
    h('div',{class:'workspace-actions'},start,draftNote),out,
    h('label',{class:'field'},'Input JSON',input),
    contextualHelp('Run reference',h('label',{class:'field'},'Reference',external),
      h('p',{class:'hint'},'Reuse a reference to recover the same run after a connection failure.')));
}


export async function query() {
  let split=null;
  const queryStore = draftStore("query-options"), savedOptions = queryStore.read();
  let queryRevision = 0;
  const input = h("textarea", {class:"control mono", rows:6, "aria-label":"Query", style:"width:100%"}, sessionStorage.getItem("p8-query-draft") || "SCHEMA");
  const out = h("div", {role:"status"}, h("div", {class:"library-empty"}, "Run a query to see its results here."));
  const schema = h("div");
  const vector = h("textarea", {class:"control mono", rows:3, "aria-label":"Embedding vector JSON", placeholder:"[1, 0, 0, 0]", style:"width:100%"});
  vector.value = savedOptions.vector || "";
  let result = null;
  input.addEventListener("input", () => {
    queryRevision++;
    sessionStorage.setItem("p8-query-draft", input.value);
    if (result) {
      result = null; exportBtn.disabled = true;
      out.replaceChildren(h("div", {class:"library-empty"}, "Query changed. Run it again to see current results."));
    }
  });
  const exportBtn = h("button", {class:"btn", disabled:true, onclick:() => downloadJSON(result, "percolate-query.json")}, "Download result");
  const execute = h("button", {class:"btn primary", onclick:async () => {
    if (!input.value.trim()) return;
    if (execute.disabled) return;
    const requestRevision = queryRevision;
    execute.disabled = true; exportBtn.disabled = true;
    switchTab("write");split?.reveal("secondary");
    out.replaceChildren(h("p", {}, "Running query…"));
    try {
      const statement = input.value.trim();
      sessionStorage.setItem("p8-query-draft", statement);
      const args = {p_query:statement};
      if (vector.value.trim()) {
        const embedding = JSON.parse(vector.value);
        if (!Array.isArray(embedding) || !embedding.length || !embedding.every(n => typeof n === "number" && Number.isFinite(n))) throw new Error("Embedding must be a nonempty JSON array of numbers.");
        args.p_embedding = JSON.stringify(embedding);
      }
      let {rows} = await rpc("aiq", "query", args);
      if (rows?.mode === "SQL") {
        const statement = withoutTerminator(rows.statement);
        const executed = await rpc("aiq", "sql_passthrough", {p_statement:statement});
        rows = {mode:"SQL", statement, rows:executed.rows};
      }
      if (requestRevision !== queryRevision) {
        result = null; out.replaceChildren(h("div", {class:"library-empty"}, "The query or vector changed while this request ran. Run again to see results for your current inputs.")); return;
      }
      result = {query:statement, embedding:args.p_embedding || null, result:rows};
      exportBtn.disabled = false;
      const records = Array.isArray(rows?.rows) ? rows.rows : null;
      const columns = records?.length ? [...new Set(records.slice(0,100).flatMap(r => Object.keys(r)))] : [];
      out.replaceChildren(h("div", {class:"query-results"},
        h("p", {}, records ? records.length + (records.length === 1 ? " row returned" : " rows returned") + (records.length > 100 ? " · showing the first 100; download contains all returned rows" : "") : "Query completed"),
        h("details", {class:"executed-query"}, h("summary", {}, "Executed query"), h("pre", {class:"code suggestion-code"}, statement)),
        columns.length ? h("div", {style:"overflow:auto"}, table(columns, records.slice(0,100), r => h("tr", {}, columns.map(c => h("td", {}, h("div", {class:"query-cell"}, typeof r[c] === "object" ? JSON.stringify(r[c]) : r[c])))))) : null,
        h("details", {open: !columns.length}, h("summary", {}, "Full response and query plan"), h("pre", {class:"code", style:"max-height:36rem;overflow:auto"}, JSON.stringify(rows,null,2)))));
    } catch (e) { result = null; out.replaceChildren(h("div", {class:"note rose"}, requestRevision === queryRevision ? e.message : "The earlier request failed. Your newer query is still in the editor; run it to try again.")); }
    finally { execute.disabled = false; }
  }}, "Run query");
  input.addEventListener("keydown", e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {e.preventDefault(); if (!execute.disabled) execute.click();} });
  const resultsPanel = panel("Results", "", out);
  const editorPanel = h("div", {class:"form-stack", role:"tabpanel", id:"query-write-panel", "aria-labelledby":"query-write-tab"},
      h("label", {class:"field"}, h("span", {}, "Your query"), input),
      h("details", {}, h("summary", {}, "Semantic search input"),
        h("p", {}, "SEMANTIC and SEARCH accept a vector from the selected embedding model. Alternatively, use the query in a workflow to compute its embedding with the configured worker."), vector),
      h("div", {class:"form-actions"}, execute,
        h("button", {class:"btn", onclick:() => {description.value = ""; switchTab("ai"); requestSuggestion("check");}}, "Check with AI"), exportBtn,
        h("button", {class:"btn", onclick:async () => {
          try { const {rows} = await rpc("aiq", "query", {p_query:'SCHEMA "p8ql"'});
            schema.replaceChildren(h("details", {open:true}, h("summary", {}, "Live query guide"), h("pre", {class:"code", style:"max-height:32rem;overflow:auto"}, JSON.stringify(rows,null,2))));
          } catch (e) { schema.replaceChildren(h("div",{class:"note rose"},e.message)); }
        }}, "Query guide"),
        h("button", {class:"btn", onclick:() => {
          if (!input.value.trim()) { input.focus(); return; }
          stageWorkflow("name: evidence_" + Date.now() + "\nsteps:\n  - id: retrieve\n    p8ql: " + JSON.stringify(input.value.trim()) + "\n");
          sessionStorage.setItem('p8-workflow-open-definition','1');
          location.hash = "#/draft";
        }}, "Use in workflow"), h("span", {class:"hint"}, "Creates a new workflow draft. Your previous draft can be restored.")), schema);

  const description = h("textarea", {class:"control", rows:4, "aria-label":"Describe your query",
    placeholder:"Find the passages about product recalls in my documents, and show their source IDs."}, savedOptions.description || "");
  let currentTab = savedOptions.tab || "write";
  const rememberOptions = () => queryStore.write({vector:vector.value, description:description.value, tab:currentTab});
  description.addEventListener("input", rememberOptions);
  vector.addEventListener("input", () => { queryRevision++; result = null; exportBtn.disabled = true; rememberOptions(); out.replaceChildren(h("p", {}, "Search input changed. Run the query to update results.")); });
  const aiOut = h("div", {class:"suggestion-output", "aria-live":"polite"});
  const aiStatus = h("p", {class:"document-help", role:"status"});
  let busy = false, available = false;
  const openConversation = session => h("a", {class:"btn", href:"#/chat", onclick:() => {
    sessionStorage.setItem("p8-chat-agent", HELP_AGENT);
    sessionStorage.setItem("p8-chat-session", session);
  }}, "Open conversation");
  const requestSuggestion = async mode => {
    if (busy) return;
    if (!available) { aiStatus.textContent = "The Percolate help agent is unavailable. Check Agents and the connection to your workspace."; return; }
    busy = true; suggestBtn.disabled = checkBtn.disabled = true;
    aiPanel.setAttribute("aria-busy", "true");
    aiOut.replaceChildren();
    const requestedRevision=queryRevision;
    try {
      const suggestion = await suggestQuery({mode, description:description.value.trim(), query:input.value.trim(),
        onStatus:message => {aiStatus.textContent = message;}});
      aiStatus.textContent = "Review the suggestion below. Your editor has not changed.";
      aiOut.replaceChildren(h("div", {class:"suggestion-card"},
        h("div", {class:"suggestion-heading"}, h("h3", {}, mode === "check" ? "Query review" : "Suggested query"), h("span", {class:"chip"}, "Draft · not executed")),
        h("p", {}, suggestion.explanation),
        suggestion.query ? h("pre", {class:"code suggestion-code", tabindex:"0", "aria-label":"Suggested query"}, suggestion.query) : null,
        suggestion.assumptions.length ? h("div", {}, h("h4", {}, "Assumptions & notes"), h("ul", {}, suggestion.assumptions.map(a => h("li", {}, a)))) : null,
        suggestion.requires_embedding ? h("div", {class:"note"}, "This query needs an embedding vector from the matching model. Supply it in Semantic search input, or use a workflow to generate it.") : null,
        h("div", {class:"form-actions"}, suggestion.query ? h("button", {class:"btn primary", onclick:() => {
          if(queryRevision!==requestedRevision){aiStatus.textContent='Your query changed. Ask AI to review the current draft before applying a suggestion.';return;}
          queryRevision++; input.value = suggestion.query;
          sessionStorage.setItem("p8-query-draft", input.value);
          vector.value = ""; result = null; exportBtn.disabled = true;
          out.replaceChildren(h("div", {class:"library-empty"}, "Suggestion added. Review your query, then run it to see results."));
          switchTab("write");split?.reveal("primary"); input.focus();
        }}, "Use in editor") : null, openConversation(suggestion.session))));
    } catch (e) {
      aiStatus.textContent = "Could not finish this request. Your query is still in the editor.";
      aiOut.replaceChildren(h("div", {class:"note rose", role:"alert"}, e.message));
      if (e.session) aiOut.append(openConversation(e.session));
    } finally {
      busy = false; suggestBtn.disabled = checkBtn.disabled = !available;
      aiPanel.setAttribute("aria-busy", "false");
    }
  };
  const suggestBtn = h("button", {class:"btn primary", disabled:true, onclick:() => requestSuggestion("suggest")}, "Suggest query");
  const checkBtn = h("button", {class:"btn", disabled:true, onclick:() => requestSuggestion("check")}, "Check current query");
  const aiPanel = h("div", {class:"form-stack", role:"tabpanel", id:"query-ai-panel", "aria-labelledby":"query-ai-tab", hidden:true},
    h("div", {class:"assistant-intro"}, h("h3", {}, "What would you like to find?"),
      h("p", {}, "Describe the result you need, or ask Percolate to check the query in your editor. The assistant uses your workspace’s live query language and schema.")),
    h("label", {class:"field"}, h("span", {}, "Describe a query or give review instructions"), description),
    h("div", {class:"query-examples", "aria-label":"Example requests"},
      ["Find passages about product recalls with source IDs", "List my five most recent files", "Count workflow runs by status"].map(example =>
        h("button", {class:"example-prompt", onclick:() => {description.value = example; description.focus();}}, example))),
    h("div", {class:"form-actions"}, suggestBtn, checkBtn, h("a", {href:"#/help"}, "How queries work")), aiStatus, aiOut);
  const switchTab = name => {
    currentTab = name; rememberOptions();
    const ai = name === "ai";
    editorPanel.hidden = false; aiPanel.hidden = !ai; resultsPanel.hidden = ai;
    split?.secondaryLabel(ai ? "AI assistance" : "Results");if(ai)split?.reveal("secondary");
    for (const [button, active] of [[writeTab,!ai],[aiTab,ai]]) {
      button.setAttribute("aria-selected", String(active)); button.tabIndex = active ? 0 : -1;
    }
  };
  const writeTab = h("button", {role:"tab", id:"query-write-tab", "aria-controls":"query-results-panel", "aria-selected":"true", onclick:() => switchTab("write")}, "Results");
  const aiTab = h("button", {role:"tab", id:"query-ai-tab", "aria-controls":"query-ai-panel", "aria-selected":"false", tabindex:"-1", onclick:() => switchTab("ai")}, "Ask AI");
  const tabs = h("div", {class:"query-tabs", role:"tablist", "aria-label":"Query authoring"}, writeTab, aiTab);
  tabs.addEventListener("keydown", e => {
    if (!["ArrowLeft","ArrowRight","Home","End"].includes(e.key)) return;
    e.preventDefault();
    const ai = e.key === "End" || (e.key !== "Home" && document.activeElement === writeTab);
    switchTab(ai ? "ai" : "write"); (ai ? aiTab : writeTab).focus();
  });
  try {
    const {rows} = await read(READS.agentNames);
    available = rows.some(a => a.name === HELP_AGENT);
    aiStatus.textContent = available ? "Suggestions use the Percolate help agent. Queries run only when you choose Run query." : "Set up the percolate_help agent to enable suggestions. Open Help for setup guidance.";
  } catch (e) { aiStatus.textContent = e.message; }
  suggestBtn.disabled = checkBtn.disabled = !available;
  switchTab(currentTab);
  editorPanel.removeAttribute('role');editorPanel.removeAttribute('aria-labelledby');
  resultsPanel.id='query-results-panel';resultsPanel.setAttribute('role','tabpanel');resultsPanel.setAttribute('aria-labelledby','query-write-tab');
  const editorActions=editorPanel.querySelector('.form-actions');editorActions.classList.add('workspace-actions');editorPanel.prepend(editorActions);
  const guideButton=Array.from(editorActions.querySelectorAll('button')).find(b=>b.textContent==='Query guide');
  editorPanel.append(contextualHelp('Query help & options',guideButton,editorActions.querySelector('.hint'),editorPanel.querySelector('details'),schema));
  resultsPanel.querySelector('header').append(exportBtn);
  const primary=h('section',{class:'query-workspace','aria-label':'Query editor'},h('header',{class:'workspace-section-head'},h('h2',{},'Query editor')),editorPanel);
  const secondary=h('section',{class:'query-workspace','aria-label':'Query results and assistance'},tabs,aiPanel,resultsPanel);
  split=splitWorkspace({primary,secondary});
  switchTab(currentTab);
  return page(head('Query','Explore your data','Write a query or ask AI, inspect the result, then use it in a workflow.'),split.node);
}
