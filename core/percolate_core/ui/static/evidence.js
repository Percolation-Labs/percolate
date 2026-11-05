/* Recorded evidence is a view in the core admin console. Live reads still belong to PostgREST. */
import { h, panel, seg, stat, table, chip } from "./ui.js";
import { page, head } from "./views.js";
import { config } from "./api.js";

const QUERIES = [
  ["Compare labels", "SELECT oracle_label, count(*) AS cases,\n  count(*) FILTER (WHERE readable_both) AS readable,\n  round(100.0 * count(*) FILTER (WHERE readable_both) / count(*), 1) AS percent\nFROM cases GROUP BY oracle_label ORDER BY oracle_label"],
  ["Missing answers", "SELECT case_id, question, reader_a_reason\nFROM cases\nWHERE oracle_label = 'NEW-shown' AND NOT readable_both\nORDER BY case_id"],
  ["Reader disagreements", "SELECT case_id, question, reader_a, reader_b, reader_a_reason, reader_b_reason\nFROM cases WHERE reader_a != reader_b"],
];
const button = (text, action) => h("button", {class:"btn", onclick:action}, text);

export async function evidence(caseId) {
  if (!config().evidenceExample) return page(head("WORK", "Evidence", "No recorded example is configured on this console."));
  const response = await fetch("example/cases.json");
  if (!response.ok) throw new Error("The recorded example is unavailable (" + response.status + ").");
  const {cases, manifest} = await response.json();
  let view = caseId ? "Cases" : "Finding", selected = caseId || "N004", type = "all", search = "", engine, pendingEngine, disposed = false;
  addEventListener("hashchange", () => { disposed = true; engine?.close(); }, {once:true});
  const content = h("div", {class:"evidence-content"});
  const switcher = seg(["Finding", "Cases", "Query"].map(v => [v,v]), v => {view=v; render();}, caseId ? 1 : 0);
  const picker = h("select", {class:"control", "aria-label":"Question type", onchange:e => {type=e.target.value; render();}},
    h("option", {value:"all"}, "All questions"), h("option", {value:"knowledge_update"}, "Knowledge updates"), h("option", {value:"contradiction_resolution"}, "Contradictions"));
  const root = page(head("WORK / RECORDED EXAMPLE", "Evidence", "E9b · 100 decisions · Q3 decision model", chip("Recorded", "pending")),
    h("div", {class:"evidence-toolbar"}, switcher, picker), content);
  root.classList.add("evidence-page");
  const analysis=h("details",{class:"disclosure evidence-analysis"},h("summary",{},"Open the experiment workbench · cases, filters and SQL"));
  analysis.append(...root.childNodes);root.append(resultsLibrary(cases),analysis);
  const filtered = () => cases.filter(r => type === "all" || r.question_type === type);
  const showCase = () => {view="Cases"; selected="N004"; type="all"; picker.value="all"; switcher.children[1].click();};
  function finding() {
    const rows = filtered();
    const groups = ["NEW-shown", "OFF"].map(label => {
      const group = rows.filter(r => r.oracle_label === label), yes = group.filter(r => r.readable_both).length;
      return {label, yes, total:group.length, rate:group.length ? Math.round(1000*yes/group.length)/10 : 0};
    });
    return h("div", {class:"evidence-stack"},
      h("div", {class:"evidence-stats"}, stat("Decisions", rows.length, "7 questions · 17 frozen nodes in the full run"), ...groups.map(g => stat(g.label, g.rate+"%", `${g.yes} of ${g.total} readable by both`))),
      panel("Does a new lead contain an answer?", "E9b", h("div", {class:"evidence-stack"},
        h("p", {}, "Two independent model readers checked whether the text behind each decision could answer its question."),
        ...groups.map(g => h("div", {class:"evidence-bar-row"}, h("span", {class:"mono"},g.label),
          h("div", {class:"bar", role:"img", "aria-label":`${g.label}: ${g.rate} percent, ${g.yes} of ${g.total}`},h("span",{style:`width:${g.rate}%`})),h("strong",{},g.rate+"%"))),
        h("p", {class:"hint"}, "Scale 0–100%. NEW-shown is the oracle’s new-lead label; OFF is the comparison group. Readable means both readers found answer-bearing text."),
        button("Inspect decision N004 →", showCase))),
      panel("A claim to examine", "Proposed", h("div", {},
        h("p", {}, "Novelty alone is not enough to establish that a lead contains useful evidence."),
        h("p", {class:"hint"}, "This development sample informs Q3’s local decision model. Two Claude readers are not human confirmation, and this selected sample does not establish a general success rate."))),
      h("details", {class:"disclosure"}, h("summary",{},"Source and limitations"),
        h("p",{},"Archived run: "+manifest.experiment_id),
        h("p",{class:"mono"},"Source commit: "+manifest.artifact_commit),
        h("p",{},"Imported directly from experiment files. No fresh walk, verified original runtime commit, or Avalanche snapshot.")));
  }
  function caseView() {
    const detail = h("div", {});
    const choose = h("select", {class:"control", "aria-label":"Decision", onchange:e => {selected=e.target.value; drawDetail();}});
    const input = h("input", {class:"control", type:"search", placeholder:"Search decisions", "aria-label":"Search decisions", value:search, oninput:e => {search=e.target.value; refill();}});
    let matches = [];
    function refill() {
      matches = filtered().filter(r => `${r.case_id} ${r.question} ${r.shown_text}`.toLowerCase().includes(search.toLowerCase()));
      if (!matches.some(r=>r.case_id===selected)) selected=matches[0]?.case_id;
      choose.replaceChildren(...matches.map(r=>h("option",{value:r.case_id},`${r.case_id} · ${r.oracle_label}`)));
      choose.value=selected||""; choose.disabled=!matches.length; drawDetail();
    }
    function drawDetail() {
      const row=matches.find(r=>r.case_id===selected);
      if (!row) {detail.replaceChildren(h("p",{class:"empty"},"No decisions match these filters."));return;}
      const index=matches.indexOf(row);
      const previous=button("← Previous",()=>{selected=matches[index-1].case_id;choose.value=selected;drawDetail();}); previous.disabled=index===0;
      const next=button("Next →",()=>{selected=matches[index+1].case_id;choose.value=selected;drawDetail();}); next.disabled=index===matches.length-1;
      detail.replaceChildren(panel(row.case_id+" · "+row.oracle_label, `${index+1} of ${matches.length}`, h("div",{class:"evidence-stack"},
        h("h2",{},row.question),h("p",{class:"hint"},`Node ${row.node_index} · Wave ${row.wave} · Jev score ${row.jev_p}`),
        h("h3",{},"What the readers were shown"),h("blockquote",{class:"evidence-quote"},row.shown_text),
        ...["a","b"].map(r=>panel("Reader "+r.toUpperCase(), row["reader_"+r]?"Answer found":"No answer found",h("p",{},row["reader_"+r+"_reason"]))),
        h("div",{class:"evidence-toolbar"},previous,next))));
    }
    refill(); return h("div",{class:"evidence-stack"},h("div",{class:"evidence-toolbar"},input,choose),detail);
  }
  function queryView() {
    const input=h("textarea",{class:"control mono",rows:8,"aria-label":"SQL query",spellcheck:"false"},QUERIES[0][1]);
    const status=h("p",{class:"hint",role:"status"},"Preparing query engine…");
    const error=h("p",{class:"note rose",role:"alert",hidden:true});
    const results=h("div",{});
    const run=button("Run query",execute);run.classList.add("primary");run.disabled=true;
    async function execute() {
      if(!engine||run.disabled)return;
      run.disabled=true;error.hidden=true;status.textContent="Running…";
      try {
        const result=await engine.query(input.value);
        results.replaceChildren(panel("Query results",`${result.rows.length} rows${result.truncated?" (first 200)":""}`,
          h("div",{class:"evidence-table",tabindex:0,"aria-label":"Query results"},table(result.columns,result.rows,row=>h("tr",{},row.map(value=>h("td",{},value))),"No rows match this query."))));
        status.textContent="Query complete. All 100 recorded cases are available.";
      } catch(e) {error.hidden=false;error.textContent=e.message;status.textContent="Query failed. The previous successful result is retained.";}
      finally {run.disabled=false;}
    }
    input.addEventListener("keydown",e=>{if(e.key==="Enter"&&(e.metaKey||e.ctrlKey)){e.preventDefault();execute();}});
    pendingEngine ||= import("./example/engine.js").then(m=>m.createQueryEngine(cases)).then(value=>{
      if(disposed){value.close();throw new Error("Evidence view closed");} engine=value;return value;
    }).catch(e=>{pendingEngine=null;throw e;});
    pendingEngine.then(()=>{if(disposed)return;run.disabled=false;execute();}).catch(e=>{if(disposed)return;error.hidden=false;error.textContent=e.message;status.textContent="Reopen Query to retry.";});
    return h("div",{class:"evidence-stack"},panel("Explore this run", "SQL", h("div",{class:"evidence-stack"},
      h("p",{class:"hint"},"Edit a SELECT over the cases table. Queries run in this browser against the recorded example."),
      h("div",{class:"evidence-toolbar"},QUERIES.map(([label,sql])=>button(label,()=>{input.value=sql;}))),input,
      h("div",{class:"evidence-toolbar"},run,h("span",{class:"hint"},"⌘ / Ctrl + Enter")),status,error,
      h("details",{class:"disclosure"},h("summary",{},"Available columns"),h("p",{class:"mono"},Object.keys(cases[0]).join(", "))))),results);
  }
  function render(){picker.hidden=view==="Query";content.replaceChildren(view==="Finding"?finding():view==="Cases"?caseView():queryView());}
  render();return root;
}

function resultsLibrary(cases) {
  const key="p8-explanation-drafts-v1";
  const seeds=[
    {title:"New does not always mean useful",question:"Does a new lead contain an answer?",takeaway:"Only 18 of 50 new-labeled leads contained answer-bearing text for both readers.",labels:["New-labeled","Comparison"],values:[36,10],unit:"%",evidence:"E9b: 18/50 NEW-shown and 5/50 OFF decisions were readable by both model readers.",limit:"Selected development sample; not a general success rate.",recorded:true},
    {title:"Where the promising leads fell short",question:"How often did a new-labeled lead fail the reading check?",takeaway:"32 of the 50 new-labeled leads were not readable by both readers. Open a case to see why.",labels:["Not readable by both","Readable by both"],values:[32,18],unit:"cases",evidence:"E9b: the 50 NEW-shown decisions, split by the conjunction of reader A and reader B.",limit:"A failed check does not establish that no answer exists elsewhere in the graph.",recorded:true},
    {title:"Agreement is not confirmation",question:"Did the two readers agree?",takeaway:"The readers agreed on 99 decisions. Agreement makes the judgement consistent, not necessarily correct.",labels:["Agreed","Disagreed"],values:[cases.filter(r=>r.reader_a===r.reader_b).length,cases.filter(r=>r.reader_a!==r.reader_b).length],unit:"cases",evidence:"E9b: comparison of the two recorded model-reader judgements over 100 decisions.",limit:"Both readers are models. No human confirmation was collected.",recorded:true}
  ];
  let drafts=[];try{drafts=JSON.parse(localStorage.getItem(key)||"[]");if(!Array.isArray(drafts))drafts=[];}catch{}
  const shelf=h("div",{class:"result-shelf","aria-label":"Results library",tabindex:0});
  const note=h("p",{class:"hint",role:"status"});
  const graphic=item=>h("div",{class:"result-graphic","aria-label":"Visual summary"},...item.labels.map((label,i)=>h("div",{},h("div",{class:"result-number"},String(item.values[i]),h("small",{},item.unit)),h("div",{class:"bar"},h("span",{style:`width:${Math.max(0,Math.min(100,100*item.values[i]/Math.max(1,...item.values)))}%`})),h("span",{},label))));
  function download(item){const url=URL.createObjectURL(new Blob([JSON.stringify({schema_version:1,...item},null,2)],{type:"application/json"}));const a=h("a",{href:url,download:"explanation.json"});a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
  function inspect(item){
    const d=h("dialog",{class:"result-dialog","aria-label":item.title});
    const close=()=>{d.close();d.remove();};d.addEventListener("cancel",e=>{e.preventDefault();close();});
    d.append(h("div",{class:"evidence-toolbar"},chip(item.recorded?"Recorded · E9b":"Researcher draft"),h("span",{class:"spacer"}),button("Close result",close)),h("span",{class:"kicker"},item.question),h("h1",{},item.title),graphic(item),h("p",{class:"result-takeaway"},item.takeaway),
      item.recorded?button("Follow a decision on the canvas →",()=>{close();openCanvas(cases);}):null,
      h("details",{class:"disclosure"},h("summary",{},"Evidence and source"),h("p",{},item.evidence)),h("details",{class:"disclosure"},h("summary",{},"What this does not establish"),h("p",{},item.limit)),button("Export explanation",()=>download(item)));
    document.body.append(d);d.showModal();
  }
  function draw(){shelf.replaceChildren(...[...drafts,...seeds].map(item=>h("article",{class:"result-card"},chip(item.recorded?"E9b · recorded perspective":"Local draft"),graphic(item),h("h2",{},item.title),h("p",{},item.takeaway),button("Open explanation →",()=>inspect(item)))));}
  function create(){
    const d=h("dialog",{class:"result-dialog","aria-label":"Create explanation"});
    const close=()=>{d.close();d.remove();};d.addEventListener("cancel",e=>{e.preventDefault();close();});
    const fields={};const field=(name,label,placeholder,multi=false)=>{const input=h(multi?"textarea":"input",{class:"control",required:true,placeholder,rows:3});fields[name]=input;return h("label",{class:"field"},h("span",{},label),input);};
    const error=h("p",{role:"alert"});
    const form=h("form",{class:"evidence-stack",onsubmit:e=>{
      e.preventDefault();const values=fields.values.value.split(",").map(s=>Number(s.trim()));const labels=fields.labels.value.split(",").map(s=>s.trim());
      if(values.length!==2||labels.length!==2||values.some(v=>!Number.isFinite(v)||v<0)){error.textContent="Enter two labels and two non-negative numbers, separated by commas.";return;}
      const item=Object.fromEntries(Object.entries(fields).map(([k,v])=>[k,v.value.trim()]));item.labels=labels;item.values=values;item.recorded=false;
      try{localStorage.setItem(key,JSON.stringify([item,...drafts]));drafts.unshift(item);}catch{error.textContent="Could not save in this browser. Export your explanation instead.";download(item);return;}
      draw();close();note.textContent="Draft saved in this browser. Open it to review or export it.";
    }},field("title","The result, in one sentence","What changed your understanding?"),field("question","Question investigated","What was the session trying to learn?"),field("takeaway","What the visual teaches","Explain the implication, not just the numbers",true),
      h("p",{class:"hint"},"Start with a two-part comparison. Values use one shared scale; write the unit explicitly."),field("labels","Two labels","Before, After"),field("values","Two values","12, 34"),field("unit","Unit","%, cases, seconds…"),field("evidence","Evidence and source","Session/run ID, source links, sample size, and how these numbers were obtained",true),field("limit","Limit or open question","What can’t this result establish?",true),error,h("button",{class:"btn primary",type:"submit"},"Save draft to library"));
    d.append(h("div",{class:"evidence-toolbar"},h("h2",{},"Create an explanation"),button("Cancel",close)),h("p",{},"Turn a session’s result into a visual claim. Review the numbers and evidence before sharing. Drafts stay in this browser; Export produces a portable JSON file."),form);document.body.append(d);d.showModal();
  }
  draw();
  return h("section",{class:"results-library"},head("RESEARCH / RESULTS LIBRARY","What did we learn?","Browse the big picture. Open a result to understand it; reveal the source when you want to check it.",button("Create explanation +",create)),h("p",{class:"hint"},"Three perspectives on one recorded experiment, plus your local drafts. Swipe horizontally or use the arrows."),h("div",{class:"evidence-toolbar"},button("← Previous cards",()=>shelf.scrollBy({left:-shelf.clientWidth,behavior:"smooth"})),button("Next cards →",()=>shelf.scrollBy({left:shelf.clientWidth,behavior:"smooth"}))),shelf,note);
}

function openCanvas(cases) {
  let step=0, picked=cases.find(r=>r.case_id==="N004")||cases[0];
  const steps=[
    ["Start with the question", "An agent needs evidence that answers a particular question. Something new can still be irrelevant.", "Question"],
    ["Look at what was actually shown", "The oracle calls this a new lead. Read the text: does it contain the answer the question asks for?", "Shown text"],
    ["Put the decision to the test", "Two model readers independently checked the shown text. Their reasons expose the gap between novelty and an answer.", "Reader checks"],
    ["Pull back to the whole experiment", "Each square below is one recorded decision. Select any square to follow its evidence. Filled squares passed both readers.", "Across the run"]
  ];
  const prior=document.activeElement;
  const overlay=h("dialog",{class:"evidence-canvas","aria-label":"Evidence explanation canvas"});
  const stage=h("div",{class:"canvas-stage"});
  const close=()=>{overlay.close();overlay.remove();prior?.focus();};
  overlay.addEventListener("cancel",e=>{e.preventDefault();close();});
  overlay.append(h("header",{class:"canvas-top"},h("div",{},h("span",{class:"kicker"},"PERCOLATE / EVIDENCE CANVAS"),h("strong",{},"When a new lead isn’t an answer")),h("span",{class:"spacer"}),chip("Recorded experiment"),button("Close canvas",close)),stage);
  document.body.append(overlay);overlay.showModal();
  function draw() {
    const [title,explanation]=steps[step];
    const nav=h("nav",{class:"canvas-steps","aria-label":"Explanation steps"},...steps.map(([name,,short],i)=>h("button",{class:i===step?"active":"","aria-current":i===step?"step":null,onclick:()=>{step=i;draw();}},h("span",{},String(i+1).padStart(2,"0")),short)));
    const intro=h("div",{class:"canvas-intro"},h("span",{class:"kicker"},`CHAPTER ${step+1} OF 4`),h("h1",{},title),h("p",{},explanation));
    const card=(label,content,active)=>h("article",{class:"canvas-node"+(active?" focused":"")},h("span",{class:"kicker"},label),content);
    const chain=h("div",{class:"canvas-chain"},
      card("01 / THE QUESTION",h("h2",{},picked.question),step===0),
      h("div",{class:"canvas-arrow","aria-hidden":"true"},"→"),
      card("02 / THE LEAD",h("div",{},chip(picked.oracle_label),h("p",{},step===0?"Open the next chapter to see the exact text the readers received.":picked.shown_text)),step===1),
      h("div",{class:"canvas-arrow","aria-hidden":"true"},"→"),
      card("03 / DOES IT ANSWER?",step<2?h("p",{},"Read the lead first. Then reveal the two independent judgements."):h("div",{},...["a","b"].map(r=>h("section",{},h("strong",{},`Reader ${r.toUpperCase()} · ${picked["reader_"+r]?"Answer found":"No answer found"}`),h("p",{},picked["reader_"+r+"_reason"])))),step===2));
    let visual=chain;
    if(step===3) {
      const groups=["NEW-shown","OFF"].map(label=>{
        const rows=cases.filter(r=>r.oracle_label===label), yes=rows.filter(r=>r.readable_both).length;
        return h("section",{class:"canvas-cohort"},h("div",{class:"canvas-cohort-head"},h("h2",{},label==="NEW-shown"?"Labeled new":"Comparison leads"),h("strong",{},`${yes} / ${rows.length}`)),h("p",{},"contained answer-bearing text for both readers"),h("div",{class:"canvas-dots"},...rows.map(row=>h("button",{class:(row.readable_both?"passed ":"")+(row.case_id===picked.case_id?"selected":""),"aria-label":`${row.case_id}: ${row.readable_both?"both readers found an answer":"not readable by both"}`,title:row.case_id,onclick:()=>{picked=row;draw();}},""))));
      });
      visual=h("div",{class:"canvas-map"},h("div",{class:"canvas-cohorts"},...groups,h("p",{class:"hint"},"One square = one decision. Filled = readable by both; outlined = not readable by both.")),card("SELECTED EVIDENCE · "+picked.case_id,h("div",{},h("h2",{},picked.question),chip(picked.oracle_label),h("p",{},picked.shown_text),button("Follow this decision →",()=>{step=0;draw();})),false));
    }
    const back=button("← Back",()=>{step--;draw();});back.disabled=step===0;
    const next=button(step===3?"Start again ↺":"Continue →",()=>{step=(step+1)%4;draw();});next.classList.add("primary");
    stage.replaceChildren(nav,intro,visual,h("footer",{class:"canvas-bottom"},h("p",{},step===3?"What this suggests: test answer-bearing evidence separately from novelty. This is a proposed interpretation, not a confirmed general result.":`Following ${picked.case_id} · Question → shown information → reader judgement`),h("div",{},back,next)),h("p",{class:"canvas-limit"},"E9b · 100 selected decisions, 7 questions, 17 frozen nodes. Two Claude readers; no human confirmation. This depicts recorded evidence, not a live agent trace."));
  }
  draw();
}
