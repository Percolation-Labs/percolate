import {claims,config,read,rpc} from './api.js';
import {READS} from './reads.js';
import {h,panel,status} from './ui.js';
import {page,head} from './views.js';
import {draftStore,sameInput} from './drafts.js';
import {SOURCE_DEFAULTS,sourcePackage,packageText} from './source-authoring.js';
import {suggestSource} from './source-assist.js';
import {HELP_AGENT} from './api.js';
import {apiSources} from './api-sources.js';
import {workspaceTabs,collectionWorkspace,contextualHelp} from './workspace.js';
const field=(label,input,hint)=>h('label',{class:'field'},h('span',{},label),input,hint?h('small',{class:'hint'},hint):null);
const error=e=>h('div',{class:'note rose',role:'alert'},e.message);

export async function sources(kind) { return kind === "files" ? fileSources() : apiSources(kind); }

async function fileSources() {
  const store=draftStore('data-source');
  let saved=store.read(), rows=[], agents=[], models=[], selected=null, busy=false;
  let id=saved.id||crypto.randomUUID(),revision=saved.revision||null;
  let workspace=null,collection=null;
  const form=h('div',{class:'form-stack'}),list=h('div',{class:'source-list'}),out=h('div',{role:'status'});
  const preview=h('div'),activity=h('div'),context=h('div',{class:'source-context'}),draftNote=h('span',{class:'hint'});
  const fields={};
  const text=(key,label,options={})=>{
    fields[key]=h(options.rows?'textarea':'input',{class:'control', 'aria-label':label,...options});
    return field(label,fields[key]);
  };
  const dropdown=(key,label,options)=>{
    fields[key]=h('select',{class:'control','aria-label':label},options.map(([value,label])=>h('option',{value},label)));
    return field(label,fields[key]);
  };
  const get=()=>({...SOURCE_DEFAULTS,...Object.fromEntries(Object.keys(SOURCE_DEFAULTS).map(k=>[k,fields[k].value])),
    chunk_tokens:Number(fields.chunk_tokens.value),overlap:Number(fields.overlap.value),
    partition_by:fields.partition_by.value.split(',').map(v=>v.trim()).filter(Boolean)});
  const queues=()=>({ingestQueue:fields.ingest_queue.value.trim(),workflowQueue:fields.workflow_queue.value.trim()});
  const remember=()=>{
    const clean=selected?.config.editor&&sameInput(get(),selected.config.editor.settings)&&sameInput(queues(),{ingestQueue:selected.config.editor.ingest_queue,workflowQueue:selected.config.editor.workflow_queue});
    draftNote.textContent=store.write({id,revision,settings:get(),queues:queues(),description:description.value,tab:activeTab})?(clean?'Saved':selected?'Unsaved changes · kept in this tab':'New draft · kept in this tab'):'This browser could not save the draft. Keep this page open.';
  };
  const clearPreview=()=>{preview.replaceChildren();out.replaceChildren();};
  const load=(s,q={})=>{
    for(const [key,node] of Object.entries(fields)) {
      const value=key==='ingest_queue'?(q.ingestQueue||config().ingestQueue||'ingest')
        :key==='workflow_queue'?(q.workflowQueue||config().workflowQueue||'http'):s[key]??SOURCE_DEFAULTS[key]??'';
      // Preserve an unavailable saved model/agent visibly; saving checks readiness.
      if(node.tagName==='SELECT' && ![...node.options].some(o=>o.value===String(value))) node.append(h('option',{value},value+' (unavailable)'));
      node.value=Array.isArray(value)?value.join(', '):value;
    }
    updateMode();
  };
  const modeHelp=h('p',{class:'document-help'});
  const textOptions=h('div',{class:'source-fields'},text('chunk_tokens','Chunk size in tokens',{type:'number',min:32,max:8000}),text('overlap','Chunk overlap',{type:'number',min:0,max:0.99,step:0.01}));
  const tableOptions=h('div',{class:'form-stack'},h('div',{class:'source-fields'},text('dataset_name','Dataset name'),dropdown('table_mode','Dataset writes',[['append','Append'],['replace','Replace']])),
    h('div',{class:'source-fields'},text('delimiter','CSV delimiter',{maxlength:1,placeholder:'Automatic'}),text('partition_by','Partition columns',{placeholder:'Optional, comma separated'})));
  const transformOptions=h('div',{class:'form-stack'},text('transform','What should the transformation produce?',{rows:4,placeholder:'Extract release blockers, owners and required checks from each handover.'}),
    dropdown('agent','Transformation agent',[['','Choose an agent']]),
    h('p',{class:'document-help'},'Optional. The agent receives this document’s passages and writes a structured result on its workflow run. Up to 80,000 characters per document.'),
    h('details',{},h('summary',{},'Output JSON schema'),text('output_schema_json','Transformation output schema',{rows:10,class:'control mono'})));
  function updateMode(){
    const mode=fields.mode.value;
    tableOptions.hidden=mode!=='tabular';textOptions.hidden=mode==='tabular';transformOptions.hidden=mode!=='text';
    fields.embedding_model.disabled=mode==='tabular';
    modeHelp.textContent=mode==='tabular'?'Convert tables to Parquet and register a dataset. Append adds files; replace changes the dataset’s current file set.':mode==='text'?'Parse documents into passages for search and optional AI transformation.':'Choose the parser from each file’s type. Use Text documents when you want an AI transformation.';
  }
  const manual=h('div',{role:'tabpanel',id:'source-manual-panel','aria-labelledby':'source-manual-tab'},form);
  form.append(h('div',{class:'source-fields'},text('name','Source name',{placeholder:'weekly-handovers'}),dropdown('mode','Data format',[['auto','Automatic by file type'],['text','Text documents'],['tabular','Tables (CSV, Excel, Parquet)']])),
    text('description','Purpose',{rows:2,placeholder:'What useful result should this source enable?'}),modeHelp,
    h('details',{},h('summary',{},'Parsing and indexing'),h('div',{class:'form-stack'},textOptions,tableOptions,
      dropdown('embedding_model','Semantic search model',[['','No embeddings · text search still available']]))),
    transformOptions,
    h('details',{},h('summary',{},'Worker queues'),h('div',{class:'source-fields'},text('ingest_queue','Ingestion queue'),text('workflow_queue','Agent queue'))));
  const description=h('textarea',{class:'control',rows:5,'aria-label':'Describe your data source',placeholder:'We upload weekly support handovers. Extract unresolved issues and who needs to act, with references to the original text.'},saved.description||'');
  const aiOut=h('div',{class:'suggestion-output','aria-live':'polite'}),aiStatus=h('p',{class:'document-help',role:'status'});
  const conversation=session=>h('a',{class:'btn',href:'#/chat',onclick:()=>{sessionStorage.setItem('p8-chat-agent',HELP_AGENT);sessionStorage.setItem('p8-chat-session',session);}},'Open conversation');
  const suggest=h('button',{class:'btn primary',onclick:async()=>{
    if(busy)return;busy=true;suggest.disabled=true;aiOut.replaceChildren();
    const contextId=id,requestDraft=JSON.stringify([get(),queues()]);
    try{
      const v=await suggestSource({description:description.value,current:get(),agents,models,id,queues:queues(),onStatus:s=>{aiStatus.textContent=s;}});
      if(contextId!==id)return;
      /* A question is not a failed suggestion, and is no longer delivered as
         one: browser-ui.md §7. */
      if(!v.settings){aiStatus.textContent='One more detail is needed.';
        aiOut.replaceChildren(h('article',{class:'suggestion-card'},h('p',{},v.needs_clarification),conversation(v.session)));return;}
      aiStatus.textContent='Review this proposal, then use it in the configuration editor.';
      aiOut.replaceChildren(h('article',{class:'suggestion-card'},h('h3',{},v.settings.name),h('p',{},v.explanation),
        h('ul',{},v.assumptions.map(a=>h('li',{},a))),h('details',{},h('summary',{},'Suggested settings'),h('pre',{class:'code suggestion-code'},JSON.stringify(v.settings,null,2))),
        h('div',{class:'form-actions'},h('button',{class:'btn primary',onclick:()=>{if(id!==contextId||JSON.stringify([get(),queues()])!==requestDraft){aiStatus.textContent='Your configuration changed. Request a new suggestion for the current draft.';return;}load(v.settings,queues());clearPreview();remember();switchTab('manual');fields.name.focus();}},'Apply suggestion'),conversation(v.session))));
    }catch(e){aiStatus.textContent='The suggestion could not be completed.';aiOut.replaceChildren(error(e));if(e.session)aiOut.append(conversation(e.session));}
    finally{busy=false;suggest.disabled=false;}
  }},'Suggest configuration');
  const ai=h('div',{class:'form-stack',role:'tabpanel',id:'source-ai-panel','aria-labelledby':'source-ai-tab'},
    h('p',{},'Describe where the data comes from and what you need it to become. AI drafts the parsing and transformation settings for you to review.'),
    field('Your ingestion task',description),h('p',{class:'document-help'},'Files and pasted text can run here today. External APIs and feeds need a connector; a suggestion does not connect them.'),suggest,aiStatus,aiOut);
  let activeTab=saved.tab||'manual';
  const tabs=h('div',{class:'query-tabs',role:'tablist','aria-label':'Configure data source'});
  const tabNodes={};
  function switchTab(tab){activeTab=tab;actions.hidden=tab!=='manual';manual.hidden=tab!=='manual';ai.hidden=tab!=='ai';for(const [k,n] of Object.entries(tabNodes)){n.setAttribute('aria-selected',String(k===tab));n.tabIndex=k===tab?0:-1;}if(workspace&&workspace.selected!==tab)workspace.show(tab);remember();}
  for(const [key,label] of [['manual','Configure manually'],['ai','Suggest with AI']]){
    const n=h('button',{id:'source-'+key+'-tab',role:'tab','aria-controls':'source-'+key+'-panel',onclick:()=>switchTab(key)},label);
    n.addEventListener('keydown',e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();const next=e.key==='Home'?'manual':e.key==='End'?'ai':activeTab==='ai'?'manual':'ai';switchTab(next);tabNodes[next].focus();}});
    tabNodes[key]=n;tabs.append(n);
  }
  for(const node of Object.values(fields))node.addEventListener('input',()=>{updateMode();clearPreview();remember();});
  fields.mode.addEventListener('change',()=>{
    updateMode();clearPreview();remember();
  });
  description.addEventListener('input',remember);
  const build=()=>{
    if(selected && !selected.config.editor) throw Error('This source has custom settings. Create a new source to author and export a complete package.');
    const s=get();
    if(s.mode!=='text'){s.transform='';s.agent='';}
    if(s.mode==='tabular')s.embedding_model='';
    if(s.agent&&!agents.includes(s.agent))throw Error('The selected agent is unavailable. Choose an available agent.');
    if(s.embedding_model&&!models.includes(s.embedding_model))throw Error('The selected embedding model is unavailable. Choose an available model.');
    return sourcePackage(id,s,queues());
  };
  const showPackage=manifest=>{preview.replaceChildren(h('h3',{},'Source and workflow'),h('pre',{class:'code package-code'},packageText(manifest)),h('p',{class:'document-help'},'The package contains configuration and workflow definitions. Provision its named agents, models and worker queues in the destination workspace. Uploaded data and credentials are not included.'));workspace?.show('package');};
  const save=h('button',{class:'btn primary',onclick:async()=>{
    if(save.disabled)return;save.disabled=true;
    try{
      const manifest=build(),source=manifest.sources[0],submittedId=id,submitted=JSON.stringify(get());
      const {ingest_workflow,workflow,...sourceConfig}=source.config;
      const result=await rpc('content','save_source',{p_id:id,p_name:source.name,p_config:sourceConfig,p_workflow:workflow,p_updated_at:revision});
      if(id!==submittedId)return;
      revision=result.rows.updated_at;selected=result.rows;remember();
      window.dispatchEvent(new Event('p8-definitions-changed'));
      out.replaceChildren(h('div',{class:'note'},'Saved '+source.name+'. '+(submitted===JSON.stringify(get())?'Upload a file to run its ingestion workflow.':'Your newer edits are still a draft.')),
        h('a',{class:'btn primary',href:'#/files',onclick:()=>{sessionStorage.setItem('p8-upload-channel',submittedId);sessionStorage.setItem('p8-open-upload','1');}},'Add data to this source'));
      await refresh();renderContext();showActivity(selected);workspace?.enable('records',true);collection.title.textContent=source.name;
    }catch(e){out.replaceChildren(error(e));}
    finally{save.disabled=false;}
  }},'Save source');
  const actions=h('div',{class:'form-actions source-actions'},save,
    h('button',{class:'btn',onclick:()=>{try{showPackage(build());}catch(e){out.replaceChildren(error(e));}}},'Preview package'),
    h('button',{class:'btn',onclick:()=>{try{const manifest=build();showPackage(manifest);const url=URL.createObjectURL(new Blob([packageText(manifest)],{type:'application/yaml'}));h('a',{href:url,download:'manifest.yaml'}).click();setTimeout(()=>URL.revokeObjectURL(url),1000);}catch(e){out.replaceChildren(error(e));}}},'Export package'),draftNote);
  function renderContext(){
    list.querySelectorAll('.source-card').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.sourceId===id)));
    context.replaceChildren();
    if(!selected)return;
    context.append(h('div',{class:'form-actions'},h('strong',{},selected.name),selected.kind==='file_upload'&&selected.enabled
      ?h('a',{class:'btn',href:'#/files',onclick:()=>{sessionStorage.setItem('p8-upload-channel',selected.id);sessionStorage.setItem('p8-open-upload','1');}},'Add data to this source'):null));
  }
  async function showActivity(source){
    const current=source.id;activity.replaceChildren(h('p',{},'Loading source activity…'));
    try{
      const {rows:resources}=await read(READS.sourceResources,'channel_id=eq.'+current+'&limit=10');
      const runs=await Promise.allSettled(resources.map(r=>read(READS.runs,'external_id=eq.ingest:'+r.id+'&limit=1')));
      if(selected?.id!==current)return;
      activity.replaceChildren(panel('Recent data','latest 10 uploads',h('div',{class:'form-stack'},resources.length?resources.map((r,i)=>{
        const run=runs[i].status==='fulfilled'?runs[i].value.rows[0]:null;
        return h('div',{class:'source-resource'},h('span',{},r.title||r.id),
          status(run?.status||r.status),run?h('a',{href:'#/run/'+run.id},'View result & steps')
            :h('span',{class:'hint'},runs[i].status==='rejected'?'Run unavailable':'No processing run'));
      }):h('p',{},'No data yet. Add a file or paste text to exercise this source.'))));
    }catch(e){if(selected?.id===current)activity.replaceChildren(error(e));}
  }
  const open=source=>{
    if(selected?.id===source.id){collection?.open(source.name);workspace?.show('records');showActivity(source);return;}
    // Keep a single recoverable unsaved draft when loading a saved configuration.
    store.write({id,revision,settings:get(),queues:queues(),description:description.value,tab:activeTab});
    draftStore('data-source-backup').write(store.read());restore.hidden=false;
    id=source.id;revision=source.updated_at;selected=source;
    load(source.config.editor?.settings||{...SOURCE_DEFAULTS,name:source.name,description:source.config.description||''},
      {ingestQueue:source.config.editor?.ingest_queue,workflowQueue:source.config.editor?.workflow_queue});
    clearPreview();aiOut.replaceChildren();aiStatus.textContent='';remember();switchTab('manual');renderContext();showActivity(source);
    if(!source.config.editor)out.replaceChildren(h('div',{class:'note'},'This source was configured outside this editor. Its current configuration is shown below. Create a new source to use the editor without replacing custom settings.'),h('pre',{class:'code suggestion-code'},JSON.stringify(source.config,null,2)));
    save.disabled=source.owner_id!==claims()?.sub || !source.config.editor;
    workspace?.enable('records',true);workspace?.show('records');collection?.open(source.name);
  };
  async function refresh(){
    try{rows=(await read(READS.dataSources)).rows.filter(r=>r.kind!=='http_pull');
      list.replaceChildren(...(rows.length?rows.map(s=>h('button',{class:'source-card','data-source-id':s.id,'aria-pressed':String(s.id===id),onclick:()=>open(s)},h('strong',{},s.name),h('span',{},s.config.description||s.kind.replaceAll('_',' ')),h('small',{},(s.enabled?'Enabled':'Disabled')+' · '+(s.visibility==='private'?'Private configuration':'Shared configuration')))):[h('p',{class:'library-empty'},'Create a source to give incoming data a repeatable process.')]));
    }catch(e){list.replaceChildren(error(e));}
  }
  const restore=h('button',{class:'btn',hidden:!draftStore('data-source-backup').read().id,onclick:()=>{
    const prior=draftStore('data-source-backup').read();if(!prior.id)return;
    id=prior.id;revision=prior.revision;selected=null;load(prior.settings,prior.queues);description.value=prior.description||'';
    clearPreview();activity.replaceChildren();renderContext();save.disabled=false;workspace?.enable('records',false);switchTab('manual');remember();collection?.open('Source draft',{expanded:true});
  }},'Restore previous draft');
  const fresh=()=>{draftStore('data-source-backup').write({id,revision,settings:get(),queues:queues(),description:description.value,tab:activeTab});restore.hidden=false;
    id=crypto.randomUUID();revision=null;selected=null;load(SOURCE_DEFAULTS);save.disabled=false;clearPreview();activity.replaceChildren();renderContext();aiOut.replaceChildren();aiStatus.textContent='';description.value='';workspace?.enable('records',false);switchTab('manual');remember();collection?.open('New file source',{expanded:true});fields.name.focus();};
  const results=await Promise.allSettled([read(READS.agentNames),read(READS.embeddingModels),refresh()]);
  if(results[0].status==='fulfilled')agents=results[0].value.rows.map(a=>a.name);else out.append(error(results[0].reason));
  if(results[1].status==='fulfilled')models=results[1].value.rows.map(m=>m.name);else out.append(error(results[1].reason));
  fields.agent.append(...agents.map(a=>h('option',{value:a},a)));fields.embedding_model.append(...models.map(m=>h('option',{value:m},m)));
  suggest.disabled=!agents.includes(HELP_AGENT);
  if(suggest.disabled)aiStatus.textContent='The Percolate help agent is unavailable. Configure it in Agents to enable suggestions.';
  load(saved.settings||SOURCE_DEFAULTS,saved.queues);switchTab(activeTab);
  selected=rows.find(s=>s.id===id)||null;if(selected){renderContext();showActivity(selected);save.disabled=selected.owner_id!==claims()?.sub||!selected.config.editor;}
  const library=h('div',{class:'source-library'},h('div',{class:'library-toolbar'},h('h3',{},'File & document sources'),h('button',{class:'btn',onclick:refresh},'Refresh')),list);
  actions.classList.add('workspace-actions');
  const exportButton=actions.querySelectorAll('button')[2];exportButton.classList.add('primary');
  const packageBody=h('div',{class:'form-stack'},h('div',{class:'form-actions'},h('button',{class:'btn',onclick:()=>{try{showPackage(build());}catch(e){preview.replaceChildren(error(e));}}},'Refresh preview'),exportButton),preview);
  for(const pane of [manual,ai]){pane.removeAttribute('role');pane.removeAttribute('aria-labelledby');}
 workspace=workspaceTabs({label:'File source workspace',initial:selected?'records':activeTab==='ai'?'ai':'manual',sections:[
    {key:'records',title:'Data & processing',content:h('div',{},context,activity),disabled:!selected},
    {key:'manual',title:'Configuration',content:h('div',{},actions,manual,contextualHelp('Draft recovery',restore))},
    {key:'ai',title:'Ask AI',content:ai},
    {key:'package',title:'Package',content:packageBody}],onChange:key=>{switchTab(key);if(key==='package'&&!preview.childElementCount){try{showPackage(build());}catch(e){preview.replaceChildren(error(e));}}}});
  collection=collectionWorkspace({label:'File source',library,detail:h('div',{},out,workspace.node)});
  if(selected)collection.open(selected.name,{focus:false});
  else if(saved.settings?.name)collection.open('Source draft',{expanded:true,focus:false});
  return page(head('Data Sources','File & document sources','Configure how uploaded documents become useful workflow evidence.',h('div',{class:'form-actions'},h('a',{class:'btn',href:'#/sources'},'API feeds'),h('button',{class:'btn primary',onclick:fresh},'New source'))),collection.node);
}
