import {rpc,read} from './api.js';
import {READS} from './reads.js';
import {h} from './ui.js';
import {contextualHelp} from './workspace.js';
import {draftStore} from './drafts.js';
import {loadCatalogue,suggestWorkflow,recoverWorkflow} from './workflow-assist.js';
import {catalogueRows,compositionPackage,packageText} from './workflow-plan.js';

const message=(text,error=false)=>h('div',{class:'note'+(error?' rose':''),role:error?'alert':'status'},text);
const pretty=v=>JSON.stringify(v,null,2);
const download=(name,text)=>{
  const url=URL.createObjectURL(new Blob([text],{type:'application/yaml'}));
  h('a',{href:url,download:name}).click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};
export async function workflowComposer({getDraft,applyDraft,showDefinition}) {
  const storage=draftStore('workflow-composition'),saved=storage.read();
  let catalogue=await loadCatalogue(),selected=new Set(saved.selected || []),plan=null,applied=saved.applied || null;
  let revision=0,busy=false,controller=null,conversation=null;
  const request=h('textarea',{class:'control',rows:3,'aria-label':'Describe the workflow',
    placeholder:'Keep an API feed current, query the changes and ask an agent to produce a sourced brief…'},saved.description || '');
  const status=h('div',{'aria-live':'polite'}),review=h('div'),packagePane=h('div'),componentList=h('div',{class:'component-catalogue'});
  const search=h('input',{class:'control',type:'search','aria-label':'Search workflow components',placeholder:'Search sources, agents, plugins, skills or workflows'});
  const count=h('span',{class:'sub'});
  function persist() {storage.write({description:request.value,selected:[...selected],applied});}
  const snapshot=()=>JSON.stringify({draft:getDraft(),request:request.value,selected:[...selected].sort(),revision});
  request.addEventListener('input',()=>{revision++;persist();});
  function paintCatalogue() {
    const rows=catalogueRows(catalogue),matches=rows.filter(r=>(r.name+' '+r.kind+' '+r.description).toLowerCase().includes(search.value.toLowerCase()));
    count.textContent=rows.length+' available · '+selected.size+' selected';
    componentList.replaceChildren(...catalogue.errors.map(e=>message(e,true)),
      ...matches.map(r=>{
        const key=r.kind+':'+r.name;
        const checkbox=h('input',{type:'checkbox',checked:selected.has(key),'aria-label':'Include '+r.kind+' '+r.name,
          onchange:()=>{checkbox.checked?selected.add(key):selected.delete(key);revision++;persist();count.textContent=rows.length+' available · '+selected.size+' selected';}});
        return h('label',{class:'component-option'},checkbox,h('span',{},h('strong',{},r.name),h('span',{class:'sub'},r.kind+' · '+r.description)));
      }),...(!matches.length?[h('p',{class:'sub'},'No matching components in the available catalogue.')]:[]));
  }
  search.addEventListener('input',paintCatalogue);paintCatalogue();
  const stop=h('button',{class:'btn',hidden:true,onclick:()=>controller?.abort()},'Stop waiting');
  const progress=text=>status.replaceChildren(message(text),...(conversation?[h('a',{href:'#/chat/'+conversation},'Inspect AI conversation')]:[]));
  const catalogueHelp=contextualHelp('Browse workspace components',h('p',{class:'sub'},'AI considers the available catalogue. Select components to steer the design.'),
    h('div',{class:'workspace-actions'},search,count,h('button',{class:'btn',onclick:async e=>{
      e.currentTarget.disabled=true;try{catalogue=await loadCatalogue();revision++;paintCatalogue();}finally{e.currentTarget.disabled=false;}
    }},'Refresh catalogue')),componentList);
  const ask=h('button',{class:'btn primary',onclick:async()=>{
    if (busy) return;busy=true;ask.disabled=true;const before=snapshot();review.replaceChildren();
    controller=new AbortController();conversation=null;stop.hidden=false;progress('Reading workspace components…');
    try {
      catalogue=await loadCatalogue();paintCatalogue();
      const next=await suggestWorkflow({description:request.value,current:getDraft().yaml,selected:[...selected],catalogue,signal:controller.signal,
        onSession:id=>{conversation=id;},onStatus:progress});
      plan=next;plan.snapshot=before;
      renderPlan();
      if (plan.workflow) {requestPanel.open=false;review.scrollIntoView({block:'start',behavior:'smooth'});}
      status.replaceChildren();
    } catch(e) {status.replaceChildren(message(e.name==='AbortError'?'Stopped waiting. The AI turn may still complete; inspect its conversation in Chat.':e.message,e.name!=='AbortError'),
      ...(e.session || conversation?[h('a',{href:'#/chat/'+(e.session || conversation)},'Inspect AI conversation')]:[]));}
    finally{busy=false;ask.disabled=false;stop.hidden=true;}
  }},'Suggest a workflow');
  const examples=[
    ['Feed to brief','Refresh an existing API news source using its watermark, query the latest 8 articles, then use an available agent to produce a sourced brief and recommended follow-ups. Reuse workspace components and package the job.'],
    ['Propose a new agent','Use an existing API source and propose a new focused briefing agent. Refresh the feed, query the latest records, and give the agent that evidence to return a summary, source links and next steps. Package all the definitions.'],
    ['New API workflow','Propose a public GitHub issues source with incremental watermarks and field mappings, then query open issues and use an available agent for a triage brief. Package the source and workflow.']];
  const recover=h('button',{class:'btn',onclick:async()=>{
    if (busy) {progress('Stop waiting for the current request before recovering a previous design.');return;}
    recover.disabled=true;ask.disabled=true;busy=true;const before=snapshot();review.replaceChildren();
    progress('Looking for a completed design and checking its components…');
    try {
      catalogue=await loadCatalogue();paintCatalogue();
      plan=await recoverWorkflow(catalogue);plan.snapshot=before;renderPlan();requestPanel.open=false;
      status.replaceChildren(message('Recovered a previous AI design and compiled it against this workspace. Review its outcome and components against your current request before applying it.'));
    } catch(e){status.replaceChildren(message(e.message,true));}
    finally{recover.disabled=false;ask.disabled=false;busy=false;}
  }},'Recover last completed design');
  const requestPanel=h('details',{class:'contextual-help workflow-request',open:true},h('summary',{},'Describe the job'),
    h('p',{},'Combine data sources, queries and agents into work you can run again and share as a package.'),request,
    h('div',{class:'workspace-actions'},ask,stop,...examples.map(([label,text])=>h('button',{class:'btn',onclick:()=>{
      request.value=text;revision++;persist();request.focus();
    }},label))),catalogueHelp,
    contextualHelp('Previous AI designs',h('p',{class:'sub'},'If you left the page or stopped waiting, review a completed proposal from your recent workflow-design conversations. It will be checked again before you can apply it.'),recover));

  function receiptRows(p) {
    const rows=h('div',{class:'composition-components'});
    const receipts=p.receipts ||= {};
    for (const component of [...p.sources.map(s=>({kind:'source',name:s.settings.name,definition:s.settings,reason:s.reason,value:s})),
      ...p.agents.map(a=>({kind:'agent',name:a.spec.name,definition:a.spec,reason:a.reason,value:a}))]) {
      const key=component.kind+':'+component.name;
      const update=(text,disabled)=>{
        for (const pane of [review,packagePane]) {
          for (const el of pane.querySelectorAll('[data-component-status]')) if(el.dataset.componentStatus===key) el.textContent=text;
          for (const el of pane.querySelectorAll('[data-create-component]')) if(el.dataset.createComponent===key) el.disabled=disabled;
        }
      };
      const note=h('span',{class:'sub',role:'status','data-component-status':key},receipts[key] || 'Not created');
      const button=h('button',{class:'btn','data-create-component':key,disabled:!!receipts[key],onclick:async()=>{
        update('Creating '+component.kind+'…',true);
        try {
          const contract=component.kind==='source'?READS.dataSources:READS.agents;
          const existing=(await read(contract)).rows.find(r=>r.name===component.name);
          if (existing) throw Error('A '+component.kind+' with this name now exists. Refresh the design to reuse it; it has not been changed.');
          let result;
          if (component.kind==='source') {
            const s=component.value,c=s.manifest.sources[0].config;
            result=await rpc('content','save_api_source',{p_id:s.id,p_name:s.settings.name,
              p_config:{description:c.description,api:c.api,editor:c.editor},p_queue:c.editor.queue,p_updated_at:null});
          } else {
            // A newly created agent can supply its initial bindings together.
            // Existing agents are never passed to this upsert.
            result=await rpc('agentic','upsert_agent',{p_spec:component.value.spec});
          }
          receipts[key]='Created '+component.kind+' '+component.name;
          update(receipts[key],true);persist();
        } catch(e){update(e.message,false);}
      }},'Create '+component.kind);
      rows.append(h('section',{class:'composition-component'},
        h('div',{class:'workspace-actions'},h('strong',{},component.name),h('span',{class:'chip'},'New '+component.kind),button),
        h('p',{class:'sub'},component.reason),note,contextualHelp('Review '+component.kind+' definition',h('pre',{class:'composition-code'},pretty(component.definition)))));
    }
    return rows;
  }
  function renderPlan() {
    review.replaceChildren();
    if (!plan.workflow) {review.append(message(plan.needs_clarification),h('p',{},plan.explanation));return;}
    const p=plan,notice=h('div');
    const apply=h('button',{class:'btn primary',onclick:()=>{
      if (snapshot()!==p.snapshot) {notice.replaceChildren(message('Your draft or request changed after this proposal. Suggest again to include those edits.',true));return;}
      applied=p;applied.appliedYaml=pretty(p.workflow);applied.receipts ||= {};
      applyDraft(applied.appliedYaml,p.input);persist();paintPackage();
      apply.disabled=true;
      notice.replaceChildren(message('Composition applied to your local draft. Create any missing components, then validate and save the workflow.'),
        receiptRows(applied),h('button',{class:'btn primary',onclick:showDefinition},'Review definition & save'));
    }},'Apply to draft');
    const isApplied=p===applied && p.appliedYaml===getDraft().yaml;
    if (isApplied) {
      apply.disabled=true;apply.textContent='Applied to draft';
      notice.replaceChildren(receiptRows(p),h('button',{class:'btn primary',onclick:showDefinition},'Review definition & save'));
    }
    review.append(h('div',{class:'workspace-actions'},h('span',{class:'chip'},isApplied?'Composition draft':'Compiled · not saved'),apply,
      h('a',{class:'btn',href:'#/chat/'+p.session},'AI conversation')),
      h('h2',{},p.outcome),
      h('ol',{class:'composition-flow','aria-label':'Proposed workflow steps'},p.orderedSteps.map(step=>{
        const kind=['work','p8ql','sql','agent','workflow','matrix','rest','embed','signal','timer'].find(k=>Object.hasOwn(step,k));
        const label=kind==='work'?'Refresh source · '+step.input.source_name:kind==='agent'?'Agent · '+step.agent:
          kind==='workflow'?'Workflow · '+step.workflow:['sql','p8ql'].includes(kind)?'Query':kind;
        return h('li',{},h('strong',{},step.id),h('span',{},label),h('span',{class:'sub'},step.needs?.length?'After '+step.needs.join(', '):'Starts with the run'));
      })),
      notice,contextualHelp('Why this flow',h('p',{},p.explanation)),
      contextualHelp('Component choices · '+p.reused_components.length+' reused · '+(p.sources.length+p.agents.length)+' new',
        ...p.reused_components.map(r=>h('p',{},h('strong',{},r.name),h('span',{class:'chip'},'Reuse '+r.kind),' '+r.reason)),
        ...p.sources.map(s=>h('p',{},h('strong',{},s.settings.name),' · New API source · '+s.reason)),
        ...p.agents.map(a=>h('p',{},h('strong',{},a.spec.name),' · New agent · '+a.reason))),
      contextualHelp('Inputs, assumptions & setup',h('pre',{class:'composition-code'},pretty(p.input)),
        ...[...p.assumptions,...p.setup_requirements].map(text=>h('p',{},text))),
      contextualHelp('Review proposed definition',h('pre',{class:'composition-code'},pretty(p.workflow))));
  }
  function paintPackage() {
    packagePane.replaceChildren();
    if (!applied) {packagePane.append(message('Design and apply a workflow composition to review its reusable package.'));return;}
    if (applied.appliedYaml!==getDraft().yaml) {packagePane.append(message('The definition has changed since this composition was applied. Ask AI to check the current draft before exporting its components.'));return;}
    try {
      const bundle=compositionPackage(applied,applied.catalogue);
      const count=(n,name)=>n+' '+name+(n===1?'':'s');
      packagePane.append(h('div',{class:'workspace-actions'},h('h2',{},bundle.manifest.name),
        h('button',{class:'btn primary',onclick:()=>download(bundle.manifest.name+'.yaml',packageText(bundle))},'Export package')),
        h('p',{},applied.outcome),h('p',{class:'sub'},[count(bundle.manifest.sources?.length || 0,'source'),count(bundle.manifest.agents?.length || 0,'agent'),count(bundle.manifest.workflows.length,'workflow')].join(' · ')+'. Queries are included in workflow steps.'),
        contextualHelp('Create proposed components in this workspace',receiptRows(applied)),
        h('h3',{},'Destination requirements'),h('ul',{},bundle.requirements.map(r=>h('li',{},r))),
        ...(bundle.setupNotes.length?[contextualHelp('Additional setup notes from the design',...bundle.setupNotes.map(r=>h('p',{},r)))]:[]),
        h('p',{class:'sub'},'Export includes definitions and this requirements list. It contains no records or run history. Named plugin, tool and skill capabilities must already be available at the destination. Installing can replace definitions with matching names; review them first.'),
        contextualHelp('Package manifest',h('pre',{class:'composition-code'},packageText(bundle))));
    } catch(e){packagePane.append(message('Cannot export package: '+e.message,true));}
  }
  paintPackage();
  if (applied?.appliedYaml===getDraft().yaml) {plan=applied;renderPlan();requestPanel.open=false;}
  return {node:h('div',{class:'workflow-composer'},requestPanel,status,review),packagePane,
    changed(){paintPackage();},
    async beforeSave() {
      if (!applied || applied.appliedYaml!==getDraft().yaml) return;
      const fresh=await loadCatalogue();
      if (fresh.errors.length) throw Error('Cannot check workflow components: '+fresh.errors.join('; '));
      const missing=[...applied.sources.filter(s=>!fresh.sources.some(r=>r.name===s.settings.name)).map(s=>'source '+s.settings.name),
        ...applied.agents.filter(a=>!fresh.agents.some(r=>r.name===a.spec.name)).map(a=>'agent '+a.spec.name)];
      if (missing.length) throw Error('Create the proposed '+missing.join(', ')+' first. Open Package → Create proposed components.');
    }};
}
