import { config, token, read, rpc, authFetch } from "./api.js";
import { READS } from "./reads.js";
import { h, status } from "./ui.js";
import { page, head } from "./views.js";
import {collectionWorkspace} from "./workspace.js";

async function contentRequest(path, options = {}) {
  const endpoint = (config().content || "").replace(/\/$/, "");
  if (!endpoint) throw new Error("Set the Content Server address in Settings to upload or download files.");
  const response = await authFetch(endpoint + path, options);
  if (!response.ok) {
    let body;
    try { body = await response.json(); } catch (_) { body = {}; }
    throw new Error(typeof body.detail === "string" ? body.detail : "The file service could not complete this request (" + response.status + ").");
  }
  return response;
}
const field = (label, input) => h("label", {class:"field"}, h("span", {}, label), input);
const message = text => h("p", {class:"document-help"}, text);
const error = e => h("div", {class:"note rose",role:"alert"}, e.message);
const shortDate = value => new Date(value).toLocaleDateString(undefined,{day:"numeric",month:"short",year:"numeric"});

export async function files() {
  let resources = [], channels = [], selected = sessionStorage.getItem("p8-files-selected"), search = sessionStorage.getItem("p8-files-search") || "", editing = false, mode = "file";
  let collection = null;
  const list = h("div", {class:"document-list"});
  const aside = h("aside", {class:"document-panel", "aria-label":"Document details"});
  const notice = h("div", {role:"status"});
  const counter = h("span", {class:"library-count"});
  const query = h("input", {class:"control library-search", type:"search", "aria-label":"Search documents", placeholder:"Search your documents…", value:search});
  const uploadTitle = h("input", {class:"control", "aria-label":"Document title", placeholder:"Document title (optional)",value:sessionStorage.getItem("p8-file-title") || ""});
  const note = h("textarea", {class:"control", rows:9, "aria-label":"Document text", placeholder:"Paste a note, a handover, or source material…"},sessionStorage.getItem("p8-file-note") || "");
  const file = h("input", {type:"file", "aria-label":"Document file"});
  const channel = h("select", {class:"control", "aria-label":"Upload channel"});
  const uploadOut = h("div",{role:"status"});
  uploadTitle.addEventListener("input",() => sessionStorage.setItem("p8-file-title",uploadTitle.value));
  note.addEventListener("input",() => sessionStorage.setItem("p8-file-note",note.value));
  file.addEventListener("change",() => {
    if (!uploadTitle.value && file.files[0]) { uploadTitle.value=file.files[0].name; sessionStorage.setItem("p8-file-title",uploadTitle.value); }
  });

  function renderList() {
    const visible = resources.filter(r => (r.title || r.id).toLowerCase().includes(search.toLowerCase()));
    counter.textContent = resources.length + (resources.length === 50 ? " recent documents" : " documents");
    list.replaceChildren(...(visible.length ? visible.map(r => h("button",{
      class:"document-row", "aria-pressed":String(r.id===selected), onclick:() => inspect(r)},
      h("span", {class:"file-icon","aria-hidden":"true"}, r.title?.includes(".") ? r.title.split(".").pop().slice(0,4) : "doc"),
      h("span", {class:"document-label"}, h("span", {class:"document-name"},r.title || "Untitled document"),
        h("span", {class:"document-meta"},shortDate(r.ingested_at)+" · "+(r.visibility === "private" ? "Only you" : r.visibility))),
      status(r.status))) : [h("div",{class:"library-empty"},search ? "No documents match your search." : "Your library starts here. Add a file or paste a note to make it available to your agents.")]));
  }
  query.addEventListener("input",() => {search=query.value;sessionStorage.setItem("p8-files-search",search);renderList();});
  function welcome() {
    aside.replaceChildren(h("div",{class:"form-stack"},h("span",{class:"kicker"},"From source to answer"),
      h("h3",{},"Give your agents something to work with"),
      message("Add a document once, then search its contents and use it as evidence in Chat."),
      h("button",{class:"btn primary",onclick:composer},"Add a document"),
      message("Your uploads are private to you. Select a document to see its processing status and source text.")));
  }
  async function inspect(resource, {open = true} = {}) {
    if(open)collection?.open(resource.title||"Untitled document");
    selected=resource.id;sessionStorage.setItem("p8-files-selected",selected);editing=false;renderList();
    aside.replaceChildren(h("div",{class:"form-stack"},message("Loading document…")));
    const [chunks,runs] = await Promise.allSettled([
      read(READS.resourceChunks,"resource_id=eq."+resource.id+"&limit=20"),
      read(READS.runs,"external_id=eq.ingest:"+resource.id+"&limit=5")]);
    if (selected!==resource.id || editing) return;
    const run = runs.status === "fulfilled" ? runs.value.rows[0] : null;
    const records = chunks.status === "fulfilled" ? chunks.value.rows : [];
    aside.replaceChildren(h("div",{class:"document-panel-head"},h("h3",{},"Document details"),
      h("button",{class:"btn ghost","aria-label":"Close document details",onclick:()=>{selected=null;sessionStorage.removeItem("p8-files-selected");renderList();welcome();collection?.close();}},"Close")),
      h("div",{class:"form-stack"},h("strong",{class:"document-title"},resource.title || "Untitled document"),status(resource.status),
        h("dl",{class:"document-facts"},h("dt",{},"Visibility"),h("dd",{},resource.visibility==="private"?"Only you":resource.visibility),
          h("dt",{},"Added"),h("dd",{},shortDate(resource.ingested_at)),h("dt",{},"Source passages"),h("dd",{},chunks.status==="fulfilled" ? records.length+(records.length===20?"+":"") : "Unavailable")),
        run ? h("div",{class:"form-stack",style:"padding:0"},h("h4",{},"Processing"),
          h("a",{href:"#/run/"+run.id},"View ingestion run · "+run.status),
          run.status === "succeeded" ? message("The configured processing steps have completed.") : message("Open the run to follow indexing or inspect a failed step."))
          : runs.status === "rejected" ? error(runs.reason) : message("No processing run is visible for this document."),
        h("div",{class:"form-actions"},h("button",{class:"btn",onclick:async e=>{
          e.target.disabled=true;
          try {
            const response=await contentRequest("/files/"+resource.id);
            const url=URL.createObjectURL(await response.blob());
            h("a",{href:url,download:(resource.title||"document").replace(/[\\/]/g,"_")}).click();
            setTimeout(()=>URL.revokeObjectURL(url),1000);
          } catch(e) {notice.replaceChildren(error(e));}
          finally{e.target.disabled=false;}
        }},"Download original"),h("button",{class:"btn",onclick:()=>{
          sessionStorage.setItem("p8-query-draft","SELECT id, resource_id, content FROM content.resource_chunks WHERE resource_id = '"+resource.id+"' LIMIT 20");
          location.hash="#/query";
        }},"Explore passages")),
        chunks.status === "rejected" ? error(chunks.reason) : h("details",{class:"disclosure"},h("summary",{},"Source preview"),
          h("div",{class:"form-stack",style:"padding:1rem 0 0"},records.length ? records.map(c=>h("div",{},
            h("p",{class:"document-id"},c.id),h("p",{class:"document-preview"},c.content))) : message("Source passages will appear here after parsing."))),
        h("details",{class:"disclosure"},h("summary",{},"Technical details"),h("div",{class:"form-stack",style:"padding:1rem 0 0"},
          h("p",{class:"document-id"},resource.id),h("pre",{class:"code",style:"white-space:pre-wrap;overflow-wrap:anywhere"},JSON.stringify(resource.metadata,null,2))))));
  }
  async function refresh() {
    try {
      const {rows}=await read(READS.resources,"limit=50");
      resources=rows;renderList();
      const current=resources.find(r=>r.id===selected);
      if(current&&!editing) await inspect(current,{open:false});
      else if(selected&&!current){selected=null;sessionStorage.removeItem("p8-files-selected");}
    }catch(e){list.replaceChildren(h("div",{class:"form-stack"},error(e)));}
  }
  const upload = h("button",{class:"btn primary",onclick:async()=>{
    upload.disabled=true;upload.textContent="Uploading…";
    try{
      if(!token()) throw new Error("Sign in before adding a document.");
      const target=channels.find(c=>c.id===channel.value);
      if(!target) throw new Error("No upload channel is available. Check the ingestion setup in Settings.");
      const body=mode==="file"?file.files[0]:new Blob([note.value],{type:"text/markdown; charset=utf-8"});
      if(!body?.size) throw new Error(mode==="file"?"Choose a file first.":"Paste some text first.");
      const name=uploadTitle.value.trim()||(mode==="file"?body.name:"note.md");
      const response=await contentRequest("/files",{method:"POST",body,headers:{"Content-Type":body.type||"application/octet-stream","X-P8-Title-Utf8":encodeURIComponent(name),"X-P8-Channel":target.name}});
      const receipt=await response.json();
      selected=receipt.resource_id;editing=false;
      collection?.open(name,{expanded:true});
      uploadTitle.value="";note.value="";file.value="";
      sessionStorage.removeItem("p8-file-title");sessionStorage.removeItem("p8-file-note");
      notice.replaceChildren(h("div",{class:"note"},"“"+name+"” was added to your library. Processing has started."));
      await refresh();
    }catch(e){uploadOut.replaceChildren(error(e));}
    finally{upload.disabled=false;upload.textContent="Add to library";}
  }},"Add to library");
  function composer() {
    collection?.open("Add document",{expanded:true});
    editing=true;selected=null;sessionStorage.removeItem("p8-files-selected");renderList();uploadOut.replaceChildren();
    const source=h("div");
    const fileButton=h("button",{onclick:()=>choose("file")},"Upload file");
    const textButton=h("button",{onclick:()=>choose("text")},"Paste text");
    function choose(next){
      mode=next;fileButton.setAttribute("aria-pressed",String(mode==="file"));textButton.setAttribute("aria-pressed",String(mode==="text"));
      source.replaceChildren(mode==="file"?h("div",{class:"file-drop"},h("strong",{},"Choose a document"),message("Keep the original, make its contents searchable."),file):note);
    }
    choose(mode);
    aside.replaceChildren(h("div",{class:"document-panel-head"},h("h3",{},"Add to your library"),
      h("button",{class:"btn ghost",onclick:()=>{editing=false;welcome();collection?.close();}},"Cancel")),
      h("div",{class:"form-stack"},h("div",{class:"segmented","aria-label":"Document source"},fileButton,textButton),source,
        field("Title",uploadTitle),
        h("details",{class:"disclosure"},h("summary",{},"Processing options"),h("div",{class:"form-stack"},field("Upload channel",channel),message("The channel chooses parsing and indexing. It may use its configured model provider."))),
        message("Private to you. You can inspect the source and its processing run after upload."),
        !config().content?h("a",{href:"#/settings"},"Configure the file service in Settings"):null,
        h("div",{class:"workspace-actions"},upload),uploadOut));
    const actions=aside.querySelector(".workspace-actions");aside.querySelector(".form-stack").prepend(actions);
  }
  const loadChannels=async()=>{
    try{
      /* The shared tier is `rbac.shared_org_id()`, a derived v5 uuid that is
         the same in every deployment -- not "the org whose slug is shared",
         which is a convention this screen was asserting on its own. A rename,
         or a second org somebody slugged the same way, and the upload channel
         list silently becomes somebody else's. */
      const [{rows},{rows:sharedOrg}]=await Promise.all([read(READS.uploadChannels),rpc("rbac","shared_org_id",{})]);
      const shared=typeof sharedOrg==="string"?sharedOrg:sharedOrg?.shared_org_id;
      channels=rows.filter(c=>c.org_id===shared);
      channel.replaceChildren(...channels.map(c=>h("option",{value:c.id},c.name)));
      const preferred=channels.find(c=>c.id===sessionStorage.getItem("p8-upload-channel")) || channels.find(c=>c.name==="ui-documents");if(preferred)channel.value=preferred.id;
    }catch(e){notice.replaceChildren(error(e));}
  };
  await Promise.all([refresh(),loadChannels()]);if(!selected)welcome();
  if(sessionStorage.getItem("p8-open-upload")){sessionStorage.removeItem("p8-open-upload");composer();}
  const library=h('section',{class:'library-panel','aria-label':'Document library'},
    h('header',{class:'library-heading'},h('h3',{},'Documents'),counter),
    h('div',{class:'library-toolbar'},query,h('button',{class:'btn',onclick:refresh},'Refresh')),list);
  collection=collectionWorkspace({label:'Document',library,detail:aside});
  if(editing)collection.open('Add document',{expanded:true,focus:false});
  else if(selected)collection.open(resources.find(r=>r.id===selected)?.title||'Document',{focus:false});
  const node=page(head('Files','Your documents','Read source material, follow processing and explore its evidence.',h('button',{class:'btn primary',onclick:composer},'Add document')),notice,collection.node);
  node.classList.add('files-page');
  return node;
}
