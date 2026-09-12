import {h,panel,status} from './ui.js';
import {read,rpc,config,claims} from './api.js';
import {READS} from './reads.js';
import {page,head} from './views.js';
import {draftStore,sameInput} from './drafts.js';
import {API_CHOICES,API_DEFAULTS,GITHUB_EXAMPLE,recentNewsExample,apiSourcePackage,apiPackageText} from './api-source-authoring.js';
import {suggestAPI} from './api-source-assist.js';
import {HELP_AGENT} from './query-assist.js';
import {workspaceTabs,collectionWorkspace,contextualHelp} from './workspace.js';
const field=(name,node,hint)=>h('label',{class:'field'},h('span',{},name),node,hint?h('small',{class:'hint'},hint):null);
const error=e=>h('div',{class:'note rose',role:'alert'},e.message);
const jsonFields=new Set(['params','headers','mappings']);
const numberFields=new Set(['page_size','max_pages','overlap_seconds']);
export async function apiSources(requestedId){
 const store=draftStore('api-source'),saved=store.read();
 let id=saved.id||crypto.randomUUID(),revision=saved.revision||null,selected=null,rows=[],progress=null;
 let activeTab=saved.tab||'manual',aiBusy=false,running=false,pollTimer=null,lastRun=null;
 let workspace=null,collection=null,editRevision=0;
 const fields={},list=h('div',{class:'source-list'}),out=h('div',{role:'status'}),preview=h('div'),activity=h('div',{class:'source-activity',role:'region','aria-label':'Ingestion results',tabindex:-1}),context=h('div',{class:'source-context'}),draftNote=h('span',{class:'hint'});
 const input=(key,label,opts={},hint)=>{fields[key]=h(opts.rows?'textarea':'input',{class:'control','aria-label':label,...opts});return field(label,fields[key],hint);};
 // The values come from API_CHOICES; only the wording and its order live here.
 // A value with no wording yet is still offered, under its own name, and wording
 // for a value the contract no longer admits is dropped.
 const choices=(key,labels)=>[...Object.keys(labels).filter(v=>API_CHOICES[key].includes(v)),...API_CHOICES[key].filter(v=>!(v in labels))].map(v=>[v,labels[v]??v]);
 const dropdown=(key,label,options)=>{fields[key]=h('select',{class:'control','aria-label':label},options.map(([value,label])=>h('option',{value},label)));return field(label,fields[key]);};
 const raw=()=>Object.fromEntries(Object.entries(fields).map(([k,v])=>[k,v.value]));
 const settings=()=>{const s={};for(const [k,v] of Object.entries(fields)){if(k==='queue')continue;try{s[k]=jsonFields.has(k)?JSON.parse(v.value||'{}'):numberFields.has(k)?Number(v.value):v.value;}catch(_){throw Error(k+' is not valid JSON. Use an object with double-quoted names and values.');}}return s;};
 const remember=()=>{
  let clean=false;
  try{const source=build().sources[0];clean=!!selected&&source.name===selected.name&&sameInput(source.config.api,selected.config.api)&&sameInput(source.config.editor,selected.config.editor)&&source.config.description===selected.config.description;}catch(_){}
  draftNote.textContent=store.write({id,revision,raw:raw(),tab:activeTab,description:description.value,sample:sample.value,probeUrl:probeUrl.value})?(clean?'Saved':selected?'Unsaved changes · kept in this tab':'New draft · kept in this tab'):'Draft storage is unavailable; keep this page open.';
 };
 const changes=()=>{editRevision++;preview.replaceChildren();out.replaceChildren();remember();};
 const load=(s,queue=config().ingestQueue||'ingest')=>{for(const [k,node] of Object.entries(fields)){const v=k==='queue'?queue:s[k]??API_DEFAULTS[k];node.value=jsonFields.has(k)?JSON.stringify(v,null,2):v??'';}updateControls();};
 const connection=h('div',{class:'form-stack'},
   h('div',{class:'source-fields'},input('name','Source name',{placeholder:'github-issues'}),input('url','API endpoint',{type:'url',placeholder:'https://api.example.com/records'})),
   input('description','What will this feed support?',{rows:2,placeholder:'Keep a current issue feed for a repeatable triage workflow.'}),
   h('div',{class:'source-fields'},input('records_path','Records path',{},'Use $ for a top-level array, or a dot path such as data.items.'),input('id_path','Stable record ID',{},'The same ID updates the existing record rather than creating a duplicate.')));
 const watermark=h('div',{class:'form-stack'},
   dropdown('watermark_type','Watermark type',choices('watermark_type',{timestamp:'Updated timestamp',number:'Increasing number',none:'No incremental filter'})),
   h('div',{class:'source-fields'},input('watermark_field','Watermark field',{},'Field in each record, for example updated_at.'),input('watermark_param','Watermark request parameter',{},'API filter parameter, for example since.')),
   h('div',{class:'source-fields'},input('initial_watermark','Start from',{placeholder:'Optional ISO timestamp with timezone'}),input('overlap_seconds','Overlap in seconds',{type:'number',min:0,max:604800})),
   h('p',{class:'document-help'},'Timestamp overlap re-reads a short window to catch boundary updates. Records are deduplicated by ID. Progress advances after all pages complete.'));
 const paging=h('div',{class:'form-stack'},dropdown('pagination','Pagination',choices('pagination',{link_header:'HTTP Link header (rel=next)',next_url:'Next URL in response',page_token:'Page token in response',page:'Page numbers',none:'Single response'})),
   h('div',{class:'source-fields'},input('next_path','Next URL or token path'),input('page_param','Page or token parameter')),
   h('div',{class:'source-fields'},input('page_size','Records per page',{type:'number',min:1,max:1000}),input('page_size_param','Page size parameter')),
   input('max_pages','Maximum pages per run',{type:'number',min:1,max:100},'A capped run saves its next page. Pull again to continue without advancing the watermark early.'));
 const authentication=h('div',{class:'form-stack'},dropdown('auth_type','Authentication',choices('auth_type',{none:'No authentication',bearer:'Bearer token',header:'API key header'})),
   h('div',{class:'source-fields'},input('credential_ref','Credential reference',{placeholder:'GITHUB_TOKEN'}),input('auth_header','Authentication header',{placeholder:'X-API-Key'})),
   h('p',{class:'document-help'},'Use a credential name, never its value. The worker must have that credential and allow it for this API origin.'));
 const mappings=h('div',{class:'form-stack'},input('mappings','Record transformations',{rows:8,class:'control mono'},'Map output names to source fields, for example {"issue_id":"id","author":"user.login"}. Optional casts: {"path":"state","cast":"lowercase"}. An empty object keeps all fields.'),
   h('p',{class:'document-help'},'Each record retains its original JSON and transformed data. Use a subsequent query or workflow to act on the ingested records.'));
 const manual=h('div',{class:'form-stack',role:'tabpanel',id:'api-manual-panel','aria-labelledby':'api-manual-tab'},connection,
   h('details',{open:true},h('summary',{},'Incremental progress'),watermark),
   h('details',{},h('summary',{},'Pagination and page budget'),paging),
   h('details',{},h('summary',{},'Authentication'),authentication),
   h('details',{},h('summary',{},'Transform records'),mappings),
   h('details',{},h('summary',{},'Request parameters and worker'),h('div',{class:'form-stack'},input('params','Query parameters',{rows:4,class:'control mono'}),input('headers','Request headers',{rows:3,class:'control mono'}),input('queue','Ingestion queue'))));
 function updateControls(){
  const wm=fields.watermark_type.value;
  fields.watermark_field.disabled=fields.watermark_param.disabled=fields.initial_watermark.disabled=wm==='none';fields.overlap_seconds.disabled=wm!=='timestamp';
  fields.next_path.disabled=!['next_url','page_token'].includes(fields.pagination.value);fields.page_param.disabled=!['page','page_token'].includes(fields.pagination.value);
  fields.credential_ref.disabled=fields.auth_type.value==='none';fields.auth_header.disabled=fields.auth_type.value!=='header';
 }
 const description=h('textarea',{class:'control',rows:4,'aria-label':'Describe your API ingestion',placeholder:'Connect to our support API, pull issues updated since the last run, and map their owner and status.'},saved.description||'');
 const sample=h('textarea',{class:'control mono',rows:6,'aria-label':'API response example',placeholder:'Optional: paste a small response example or the relevant API contract. Remove credentials and personal data.'},saved.sample||'');
 /* The endpoint is asked for FIRST, because it is what makes the difference
    between a configuration read off a response and one guessed from a
    description. Empty is still allowed -- the assistant then says so rather
    than producing paths it cannot support. */
 const probeUrl=h('input',{class:'control mono',type:'url','aria-label':'Endpoint to inspect',placeholder:'https://api.example.com/v1/items',value:saved.probeUrl||saved.api?.url||''});
 const aiStatus=h('p',{class:'document-help',role:'status'}),aiOut=h('div',{'aria-live':'polite'});
 const chat=session=>h('a',{class:'btn',href:'#/chat',onclick:()=>{sessionStorage.setItem('p8-chat-agent',HELP_AGENT);sessionStorage.setItem('p8-chat-session',session);}},'Open conversation');
 const suggest=h('button',{class:'btn primary',onclick:async()=>{
  if(aiBusy)return;aiBusy=true;suggest.disabled=true;aiOut.replaceChildren();const sourceId=id;
  try{let current;try{current=settings();}catch(_){current=raw();}
   const requestRevision=editRevision;
   const v=await suggestAPI({description:description.value,sample:sample.value,current,id,queue:fields.queue.value,
    url:probeUrl.value||fields.url.value,
    auth:{auth_type:fields.auth_type.value,credential_ref:fields.credential_ref.value,auth_header:fields.auth_header.value},
    onStatus:t=>{aiStatus.textContent=t;}});if(id!==sourceId)return;
   aiStatus.textContent=v.settings?'Review this configuration before saving or pulling data.':'More API detail is needed.';
   aiOut.replaceChildren(h('article',{class:'suggestion-card'},h('p',{},v.explanation),
    /* What was read, beside what was proposed. The operator is being asked to
       trust a record path; showing the response it came out of is the cheapest
       way for them to check it, and the friction list is where the endpoint's
       own problems -- no change timestamp, array fields, a page that was
       truncated -- get said out loud instead of being designed around. */
    v.observed?h('details',{},h('summary',{},'What the endpoint returned'),
     h('ul',{},h('li',{},'Records at '+v.observed.observed?.records_path+' — '+(v.observed.observed?.record_count??0)+' read, '+Object.keys(v.observed.observed?.fields||{}).length+' fields'),
      h('li',{},'Pagination: '+(v.observed.observed?.pagination||'unknown')+' — '+(v.observed.observed?.evidence||'')),
      ...(v.observed.friction||[]).map(f=>h('li',{},f)))):null,
    v.probeError?h('p',{class:'note rose'},'The endpoint could not be inspected: '+v.probeError):null,
    h('ul',{},v.assumptions.map(a=>h('li',{},a))),
    v.settings?h('details',{},h('summary',{},'Suggested API configuration'),h('pre',{class:'code suggestion-code'},JSON.stringify(v.settings,null,2))):null,
    h('div',{class:'form-actions'},v.settings?h('button',{class:'btn primary',onclick:()=>{if(id!==sourceId||editRevision!==requestRevision){aiStatus.textContent='Your configuration changed. Request a new suggestion to review the current draft.';return;}load(v.settings,fields.queue.value);changes();switchTab('manual');fields.name.focus();}},'Apply suggestion'):null,chat(v.session))));
  }catch(e){aiOut.replaceChildren(error(e));aiStatus.textContent='Could not finish this proposal.';if(e.session)aiOut.append(chat(e.session));}
  finally{aiBusy=false;suggest.disabled=false;}
 }},'Suggest API configuration');
 const ai=h('div',{class:'form-stack',role:'tabpanel',id:'api-ai-panel','aria-labelledby':'api-ai-tab'},
  h('p',{},'Give the endpoint and describe the result you need. The endpoint is read once, and the record path, pagination and field names come from that response rather than from a guess. AI proposes the incremental filter and record transformations on top of it.'),
  field('Endpoint to inspect',probeUrl),
  h('p',{class:'document-help'},'One GET, from this deployment, identifying itself. Authentication uses the credential reference configured under Authentication — never a pasted value. Leave it empty to work from documentation alone.'),
  field('Your API ingestion task',description),
  h('details',{},h('summary',{},'Add a response example or API contract'),sample),suggest,aiStatus,aiOut);
 const tabs=h('div',{class:'query-tabs',role:'tablist','aria-label':'API source authoring'}),tabNodes={};
 function switchTab(tab){activeTab=tab;manual.hidden=tab!=='manual';ai.hidden=tab!=='ai';actions.hidden=tab!=='manual';for(const [k,n] of Object.entries(tabNodes)){n.setAttribute('aria-selected',String(k===tab));n.tabIndex=k===tab?0:-1;}if(workspace&&workspace.selected!==tab)workspace.show(tab);remember();}
 for(const [key,label] of [['manual','Configure API'],['ai','Suggest with AI']]){const n=h('button',{id:'api-'+key+'-tab',role:'tab','aria-controls':'api-'+key+'-panel',onclick:()=>switchTab(key)},label);n.addEventListener('keydown',e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();const next=e.key==='Home'?'manual':e.key==='End'?'ai':activeTab==='manual'?'ai':'manual';switchTab(next);tabNodes[next].focus();}});tabNodes[key]=n;tabs.append(n);}
 for(const node of Object.values(fields))node.addEventListener('input',()=>{updateControls();changes();});description.addEventListener('input',remember);sample.addEventListener('input',remember);probeUrl.addEventListener('input',remember);
 const build=()=>apiSourcePackage(id,settings(),fields.queue.value);
 const showPackage=m=>{preview.replaceChildren(h('h3',{},'API source and ingestion workflow'),h('pre',{class:'code package-code'},apiPackageText(m)),h('p',{class:'document-help'},'This package includes the current draft configuration. It starts with fresh progress in another workspace; configure its named queue and credential references there.'));workspace?.show('package');};
 const save=h('button',{class:'btn primary',onclick:async()=>{if(save.disabled)return;save.disabled=true;try{
  const m=build(),c=m.sources[0].config,sourceId=id,submittedRevision=editRevision;const {rows:receipt}=await rpc('content','save_api_source',{p_id:id,p_name:m.sources[0].name,p_config:{description:c.description,api:c.api,editor:c.editor},p_queue:fields.queue.value,p_updated_at:revision});
  if(id!==sourceId)return;selected=receipt;revision=receipt.updated_at;remember();window.dispatchEvent(new Event('p8-definitions-changed'));await refresh();renderContext();
  out.replaceChildren(h('div',{class:'note'},submittedRevision===editRevision?'Saved. Open Records & progress to pull data.':'Saved the submitted version. Your newer edits are still a draft.'));workspace?.enable('records',true);collection.title.textContent=receipt.name;await showActivity();
 }catch(e){out.replaceChildren(error(e));}finally{save.disabled=false;}}},'Save source');
 const actions=h('div',{class:'form-actions source-actions'},save,h('button',{class:'btn',onclick:()=>{try{showPackage(build());}catch(e){out.replaceChildren(error(e));}}},'Preview package'),
  h('button',{class:'btn',onclick:()=>{try{const m=build();showPackage(m);const url=URL.createObjectURL(new Blob([apiPackageText(m)],{type:'application/yaml'}));h('a',{href:url,download:'manifest.yaml'}).click();setTimeout(()=>URL.revokeObjectURL(url),1000);}catch(e){out.replaceChildren(error(e));}}},'Export package'),draftNote);
 async function pull(e){e.currentTarget.disabled=true;const button=e.currentTarget,sourceId=selected.id;
  const references=draftStore('source-pull:'+sourceId),ref=references.read().reference||'api-'+crypto.randomUUID();references.write({reference:ref});
  try{const {rows:run}=await rpc('content','start_source_pull',{p_source_id:sourceId,p_external_id:ref});references.clear();lastRun=run;out.replaceChildren(h('a',{class:'btn primary',href:'#/run/'+run},'Open ingestion run'));await showActivity();}
  catch(e){out.replaceChildren(error(e));}finally{button.disabled=false;}
 }
 function renderContext(){
  list.querySelectorAll('.source-card').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.sourceId===id)));
  context.replaceChildren();if(!selected)return;
  const owned=selected.owner_id===claims()?.sub;
  context.append(h('div',{class:'form-actions'},h('button',{class:'btn primary',disabled:!owned||running,onclick:pull},running?'Pull in progress…':progress?.next_url?'Continue pull':'Pull now'),h('button',{class:'btn',onclick:showActivity},'Refresh progress'),
   h('a',{class:'btn',href:'#/schedules/'+selected.config.ingest_workflow},'Schedule workflow'),lastRun?h('a',{class:'btn',href:'#/run/'+lastRun},'Open latest run'):null),
   progress?h('p',{class:'source-progress-summary'},progress.total_records+' stored records · '+(progress.next_url?'More pages available':progress.watermark?'Updated through '+progress.watermark:'First pull in progress')):null,
   h('p',{class:'document-help'},'Pull uses the saved configuration. Save any changes first. Each pull is an inspectable workflow run.'));
 }
 async function showActivity(){clearTimeout(pollTimer);if(!selected)return;const sourceId=selected.id;
  try{
   const [s,records,runs]=await Promise.allSettled([read(READS.apiSourceState,'source_id=eq.'+sourceId),read(READS.apiSourceRecords,'source_id=eq.'+sourceId+'&limit=10'),read(READS.sourceRuns,'workflow_def_id=in.('+ (await read(READS.definitions,'name=eq.'+selected.config.ingest_workflow)).rows.map(d=>d.id).join(',') +')&limit=5')]);
   if(selected?.id!==sourceId)return;
   progress=s.status==='fulfilled'?s.value.rows[0]:null;running=runs.status==='fulfilled'&&runs.value.rows.some(r=>r.status==='running');if(runs.status==='fulfilled'&&runs.value.rows.length)lastRun=runs.value.rows[0].id;renderContext();
   if(running)pollTimer=setTimeout(()=>{if(activity.isConnected&&selected?.id===sourceId)showActivity();},2000);
   const count=progress?.total_records??0;
   activity.replaceChildren(panel('Ingestion progress','saved on the source',h('div',{class:'form-stack'},
    s.status==='rejected'?error(s.reason):h('div',{},h('p',{},count+' stored records · '+(progress?.next_url?'More pages available':progress?.last_completed_at?'Last pull completed':'Not pulled yet')),
      h('p',{},'Committed watermark: '+(progress?.watermark||'Not advanced yet')),progress?.pending_watermark?h('p',{},'Watermark in progress: '+progress.pending_watermark):null,
      h('p',{class:'document-help'},progress?.next_url?'Continue the pull to finish pagination. The committed watermark is preserved until the final page.':'Stable record IDs prevent overlap from creating duplicates.')),
    runs.status==='rejected'?error(runs.reason):contextualHelp('Recent pulls',...runs.value.rows.map(r=>h('div',{class:'source-resource'},h('span',{},new Date(r.created_at).toLocaleString()),status(r.status),h('a',{href:'#/run/'+r.id},'View run & receipt')))),
    h('details',{},h('summary',{},'Reset progress'),h('p',{class:'document-help'},'Replay from the configured starting watermark. Existing records are kept and deduplicated. Wait for any active pull to finish.'),h('button',{class:'btn',onclick:async()=>{try{await rpc('content','reset_source_progress',{p_source_id:sourceId});out.replaceChildren(h('p',{},'Progress reset. The next pull starts from the configured initial watermark.'));await showActivity();}catch(e){out.replaceChildren(error(e));}}},'Reset watermark and page checkpoint')))),
    panel('Recent records','latest 10 changed records',h('div',{class:'form-stack'},records.status==='rejected'?error(records.reason):records.value.rows.length?records.value.rows.map(r=>h('details',{},h('summary',{},r.external_id+' · '+(r.data.title||r.data.name||r.watermark||'record')),h('pre',{class:'code suggestion-code'},JSON.stringify(r.data,null,2)),h('details',{},h('summary',{},'Original API record'),h('pre',{class:'code suggestion-code'},JSON.stringify(r.raw,null,2))))):h('p',{},'Records will appear after a successful page is ingested.'))));
  }catch(e){activity.replaceChildren(error(e));}
 }
 const backup=()=>draftStore('api-source-backup').write({id,revision,raw:raw(),description:description.value,sample:sample.value,tab:activeTab});
 function open(s){
  if(selected?.id===s.id){collection?.open(s.name);workspace?.show('records');showActivity();return;}
  backup();id=s.id;revision=s.updated_at;selected=s;progress=null;running=false;lastRun=null;load({...s.config.api,name:s.name,description:s.config.description},s.config.editor?.queue);save.disabled=s.owner_id!==claims()?.sub;changes();aiOut.replaceChildren();switchTab('manual');renderContext();showActivity();workspace?.enable('records',true);workspace?.show('records');collection?.open(s.name);}
 let searchText=sessionStorage.getItem('p8-api-source-search')||'';
 const filterList=()=>list.querySelectorAll('.source-card').forEach(row=>{row.hidden=!row.textContent.toLowerCase().includes(searchText.toLowerCase());});
 async function refresh(){try{rows=(await read(READS.dataSources)).rows.filter(r=>r.kind==='http_pull');list.replaceChildren(...(rows.length?rows.map(s=>h('button',{class:'source-card','data-source-id':s.id,'aria-pressed':String(s.id===id),onclick:()=>open(s)},h('strong',{},s.name),h('span',{},s.config.description||s.config.api?.url||'API source'),h('small',{},s.config.api?.watermark_type? s.config.api.watermark_type+' watermark · '+s.config.api.pagination:'Custom configuration'))):[h('p',{class:'library-empty'},'Connect an API to start a feed that resumes where it left off.')]));filterList();}catch(e){list.replaceChildren(error(e));}}
 function fresh(example=API_DEFAULTS){backup();id=crypto.randomUUID();revision=null;selected=null;progress=null;running=false;lastRun=null;load(example);save.disabled=false;changes();activity.replaceChildren();aiOut.replaceChildren();renderContext();workspace?.enable('records',false);switchTab('manual');collection?.open('New API source',{expanded:true});fields.name.focus();}
 const restore=h('button',{class:'btn',onclick:()=>{const v=draftStore('api-source-backup').read();if(!v.id)return;id=v.id;revision=v.revision;for(const [k,n] of Object.entries(fields))n.value=v.raw?.[k]??'';description.value=v.description||'';sample.value=v.sample||'';selected=rows.find(r=>r.id===id)||null;save.disabled=!!selected&&selected.owner_id!==claims()?.sub;updateControls();changes();switchTab(v.tab||'manual');renderContext();workspace?.enable('records',!!selected);collection?.open(selected?.name||'API source draft',{expanded:true});switchTab('manual');if(selected)showActivity();}},'Restore previous draft');
 await refresh();
 load(API_DEFAULTS);if(saved.raw)for(const [k,n] of Object.entries(fields))n.value=saved.raw[k]??n.value;updateControls();switchTab(activeTab);
 if(requestedId&&requestedId!==id){const target=rows.find(r=>r.id===requestedId);if(target)open(target);}
 selected=rows.find(r=>r.id===id)||null;if(selected){save.disabled=selected.owner_id!==claims()?.sub;renderContext();showActivity();}
 try{suggest.disabled=!(await read(READS.agentNames)).rows.some(a=>a.name===HELP_AGENT);if(suggest.disabled)aiStatus.textContent='Configure the Percolate help agent to enable suggestions.';}catch(e){aiStatus.textContent=e.message;suggest.disabled=true;}
 const examples=contextualHelp('Examples & help',
  h('p',{},'Choose a starting point, then review its connection, pagination and watermark before pulling data.'),
  h('div',{class:'form-actions'},h('button',{class:'btn',onclick:()=>fresh(GITHUB_EXAMPLE)},'GitHub issues example'),h('button',{class:'btn',onclick:()=>fresh(recentNewsExample())},'News API example'),h('a',{href:'#/help'},'How data sources work')));
 const newSource=h('button',{class:'btn primary',onclick:()=>fresh()},'New API source');
 const library=h('div',{class:'source-library'},h('div',{class:'library-toolbar'},h('h3',{},'API feeds'),h('button',{class:'btn',onclick:refresh},'Refresh')),list);
 const search=h('input',{class:'control',type:'search','aria-label':'Find API feed',placeholder:'Find an API feed…',value:searchText});
 search.addEventListener('input',()=>{searchText=search.value;sessionStorage.setItem('p8-api-source-search',searchText);filterList();});
 library.firstElementChild.after(search);
 actions.classList.add('workspace-actions');
 const manualBody=h('div',{},actions,examples,manual,contextualHelp('Draft recovery',restore));
 const exportButton=actions.querySelectorAll('button')[2];exportButton.classList.add('primary');
 const packageBody=h('div',{class:'form-stack'},h('div',{class:'form-actions'},h('button',{class:'btn',onclick:()=>{try{showPackage(build());}catch(e){preview.replaceChildren(error(e));}}},'Refresh preview'),exportButton),preview);
 for(const pane of [manual,ai]){pane.removeAttribute('role');pane.removeAttribute('aria-labelledby');}
 workspace=workspaceTabs({label:'API source workspace',initial:selected?'records':activeTab==='ai'?'ai':'manual',sections:[
  {key:'records',title:'Records & progress',content:h('div',{},context,activity),disabled:!selected},
  {key:'manual',title:'Configuration',content:manualBody},
  {key:'ai',title:'Ask AI',content:ai},
  {key:'package',title:'Package',content:packageBody}],onChange:key=>{switchTab(key);if(key==='package'&&!preview.childElementCount){try{showPackage(build());}catch(e){preview.replaceChildren(error(e));}}}});
 collection=collectionWorkspace({label:'API feed',library,detail:h('div',{},out,workspace.node)});
 if(selected)collection.open(selected.name,{focus:false});
 else if(saved.raw?.name)collection.open('API source draft',{expanded:true,focus:false});
 return page(head('Data Sources','API feeds','Keep external records current for your workflows.',h('div',{class:'form-actions'},h('a',{class:'btn',href:'#/sources/files'},'File & document sources'),newSource)),collection.node);
}
