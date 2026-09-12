import {apiSourcePackage} from './api-source-authoring.js';
import {checkToolBindings} from './agent-authoring.js';

const object = v => v && typeof v === 'object' && !Array.isArray(v);
const strings = v => Array.isArray(v) && v.every(x => typeof x === 'string');
const kinds = {source:'sources',agent:'agents',workflow:'workflows',plugin:'plugins',skill:'skills',tool:'tools'};
const actions = ['sql','p8ql','agent','work','rest','embed','matrix','signal','timer','workflow'];
const json = (text, label) => {
  let v; try { v=JSON.parse(text); } catch (_) { throw Error(label+' must be valid JSON.'); }
  if (!object(v)) throw Error(label+' must be an object.');
  return v;
};

export function checkGraph(workflow) {
  if (!object(workflow) || !/^[a-z][a-z0-9_-]*$/i.test(workflow.name || '') || !Array.isArray(workflow.steps) || !workflow.steps.length)
    throw Error('A workflow needs a name and at least one step.');
  const steps=new Map();
  for (const step of workflow.steps) {
    if (!step.id || steps.has(step.id)) throw Error('Every step needs a unique id.');
    if (actions.filter(k=>Object.hasOwn(step,k)).length!==1) throw Error(step.id+': choose exactly one action.');
    if (step.needs!==undefined && !strings(step.needs)) throw Error(step.id+': needs must be a list of step ids.');
    steps.set(step.id,step);
  }
  const visiting=new Set(),done=new Set();
  function visit(id) {
    if (!steps.has(id)) throw Error('Unknown dependency: '+id);
    if (visiting.has(id)) throw Error('Dependency cycle at '+id+'.');
    if (done.has(id)) return;
    visiting.add(id); for (const dep of steps.get(id).needs || []) visit(dep);
    visiting.delete(id);done.add(id);
  }
  for (const id of steps.keys()) visit(id);
  // A templated result must come from a predecessor, not a parallel step.
  const ancestors=id=>new Set((steps.get(id).needs || []).flatMap(dep=>[dep,...ancestors(dep)]));
  for (const step of workflow.steps) for (const match of JSON.stringify(step).matchAll(/\{\{steps\.([\w-]+)\./g)) {
    if (!ancestors(step.id).has(match[1])) throw Error(step.id+' reads '+match[1]+' without a dependency on it.');
  }
  return [...done].map(id=>steps.get(id));
}

export function catalogueRows(catalogue) {
  return Object.entries(kinds).flatMap(([kind,key])=>(catalogue[key] || []).map(row=>({...row,kind,
    description:row.description || row.config?.description || (kind==='source'?row.kind:kind==='agent'?row.model:kind==='workflow'?'Saved workflow · '+row.step_count+' steps':'')})));
}

function agentSpec(spec, catalogue) {
  const allowed=['name','model','system_prompt','tools','skills','structured_output_schema'];
  if (Object.keys(spec).some(k=>!allowed.includes(k))) throw Error('Agent proposals may contain only '+allowed.join(', ')+'.');
  if (!/^[a-z][a-z0-9_]*$/i.test(spec.name || '') || !spec.system_prompt?.trim()) throw Error('A new agent needs a name and a prompt.');
  if (!catalogue.agents.some(a=>a.model===spec.model)) throw Error('Use a model already configured on a visible agent.');
  if (spec.skills!==undefined && !strings(spec.skills)) throw Error('Agent skills must be a list of names.');
  for (const skill of spec.skills || []) if (!catalogue.skills.some(s=>s.name===skill)) throw Error('Unknown skill: '+skill);
  /* The same rule `agentic.upsert_agent` applies, from the same function, so a
     proposal this screen accepts is not one the database then refuses. It used
     to accept a bare server name here and in agent-authoring, which the
     database has never accepted. */
  checkToolBindings(spec.tools);
  for (const binding of spec.tools || []) {
    const name=binding.server;
    const server=catalogue.tools.find(t=>t.name===name);
    if (!server) throw Error('Unknown tool server: '+name);
    if (binding.tools) {
      const known=(server.cached_tools || []).map(t=>t.name || t.function?.name);
      for (const tool of binding.tools) if (!known.includes(tool)) throw Error('Unknown tool: '+name+'/'+tool);
    }
  }
  if (spec.structured_output_schema!==undefined && !object(spec.structured_output_schema)) throw Error('Agent output schema must be an object.');
  return {...spec,visibility:'private'};
}

export function parsePlan(content,catalogue,queues,{uuid=()=>crypto.randomUUID()}={}) {
  const v=typeof content==='string'?json(content,'Proposal'):content;
  if (!object(v) || ['outcome','explanation','package_name','workflow_json','input_json','needs_clarification'].some(k=>typeof v[k]!=='string')
      || ['assumptions','setup_requirements'].some(k=>!strings(v[k]))
      || ['reused_components','new_sources','new_agents'].some(k=>!Array.isArray(v[k]))) throw Error('The assistant returned an incomplete workflow proposal.');
  if (v.needs_clarification.trim()) return {...v,workflow:null};
  const workflow=json(v.workflow_json,'Workflow'),input=json(v.input_json,'Example input');
  const orderedSteps=checkGraph(workflow);
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(v.package_name)) throw Error('Choose a lowercase package name, up to 64 characters.');
  if (catalogue.plugins.some(p=>p.name===v.package_name)) throw Error('Choose a new package name so an existing plugin is not replaced.');
  const refs=new Map();
  function reuse(kind,name,reason) {
    if (!kinds[kind] || !catalogue[kinds[kind]].some(r=>r.name===name)) throw Error('Unavailable '+kind+': '+name);
    refs.set(kind+':'+name,{kind,name,reason});
  }
  for (const r of v.reused_components) {
    if (typeof r.reason!=='string') throw Error('Explain why each component is reused.');
    reuse(r.kind,r.name,r.reason);
  }
  const sources=[],agents=[];
  for (const s of v.new_sources) {
    if (typeof s.reason!=='string') throw Error('Explain why each new source is needed.');
    const settings=json(s.settings_json,'Source settings'),id=uuid();
    if (catalogue.sources.some(c=>c.name===settings.name) || sources.some(c=>c.settings.name===settings.name)) throw Error('Source already exists: '+settings.name+'. Reuse it unchanged.');
    sources.push({id,settings,reason:s.reason,manifest:apiSourcePackage(id,settings,queues.ingest)});
  }
  for (const a of v.new_agents) {
    if (typeof a.reason!=='string') throw Error('Explain why each new agent is needed.');
    const spec=agentSpec(json(a.spec_json,'Agent definition'),catalogue);
    if (catalogue.agents.some(c=>c.name===spec.name) || agents.some(c=>c.spec.name===spec.name)) throw Error('Agent already exists: '+spec.name+'. Reuse it unchanged.');
    agents.push({spec,reason:a.reason});
  }
  const knownQueues=new Set(['none',queues.ingest,queues.agent,...(catalogue.workflowSchema?.schema.doc?.derived?.queues || []).map(q=>typeof q==='string'?q:q.name || q.queue)]);
  function inspect(step) {
    if (step.queue && !knownQueues.has(step.queue)) throw Error('Unknown worker queue: '+step.queue);
    if (step.agent && typeof step.agent!=='string') throw Error((step.id || 'matrix child')+': agent must be a name string, e.g. "agent":"operations_brief". Put "input" alongside "agent", not inside it. Return workflow_json as JSON text, never YAML.');
    if (step.agent && !agents.some(a=>a.spec.name===step.agent)) reuse('agent',step.agent,'Used by '+(step.id || 'matrix child'));
    if (step.workflow) reuse('workflow',step.workflow,'Called as a child workflow');
    if (step.work) {
      const source=step.input?.source_name;
      if (step.input?.op!=='api_pull' || !source) throw Error('Custom work requires a known handler. Use the configured api_pull source handler or request its contract.');
      if (!sources.some(s=>s.settings.name===source)) {
        reuse('source',source,'Refreshed by '+(step.id || 'matrix child'));
        if (catalogue.sources.find(s=>s.name===source)?.kind!=='http_pull') throw Error(source+' is not an API pull source.');
      }
    }
    if (step.matrix?.template) inspect(step.matrix.template);
  }
  for (const step of workflow.steps) inspect(step);
  return {...v,workflow,input,orderedSteps,sources,agents,reused_components:[...refs.values()]};
}

export function compositionPackage(plan,catalogue) {
  const requirements=new Set(),sources=[],agents=[],workflows=new Map();
  requirements.add('Installation permissions for the included sources, workflows and agents/plugins.');
  const addWorkflow=w=>workflows.set(w.name,w);
  const addAgent=a=>{
    agents.push(Object.fromEntries(['name','model','system_prompt','tools','skills','structured_output_schema'].filter(k=>a[k]!=null).map(k=>[k,a[k]])));
    requirements.add('Provider credentials for '+a.model);
    for (const s of a.skills || []) requirements.add('Skill: '+s);
    for (const t of a.tools || []) requirements.add('Tool server: '+(typeof t==='string'?t:t.server));
    if (a.plugin) requirements.add('Plugin capabilities used by '+a.name+': '+a.plugin);
  };
  const addSource=s=>{
    // Rebuild API settings through the same secret-aware builder as Data Sources.
    let source;
    if (s.kind==='http_pull') {
      const m=apiSourcePackage(s.id,{name:s.name,description:s.config.description || '',...s.config.api},s.config.editor?.queue || 'ingest');
      source=m.sources[0];m.workflows.forEach(addWorkflow);
      if (s.config.api.auth_type!=='none') requirements.add('Worker credential: '+s.config.api.credential_ref+' (configure for the API origin)');
    } else {
      source={name:s.name,kind:s.kind,config:Object.fromEntries(['description','ingest_policy','editor','ingest_workflow','workflow'].filter(k=>s.config[k]!=null).map(k=>[k,s.config[k]]))};
      if (s.config.workflow) addWorkflow({name:s.config.workflow.name,yaml:JSON.stringify(s.config.workflow,null,2)});
      else if (s.config.ingest_workflow) requirements.add('Source workflow: '+s.config.ingest_workflow);
    }
    sources.push(source);
  };
  for (const r of plan.reused_components) {
    const row=catalogue[kinds[r.kind]].find(x=>x.name===r.name);
    if (!row) throw Error('Package component unavailable: '+r.kind+' '+r.name);
    if (r.kind==='source') addSource(row);
    else if (r.kind==='agent') addAgent(row);
    else requirements.add(r.kind+': '+r.name+(r.kind==='workflow'?' (definition must be installed separately)':''));
  }
  for (const s of plan.sources) addSource({id:s.id,...s.manifest.sources[0]});
  for (const a of plan.agents) addAgent(a.spec);
  addWorkflow({name:plan.workflow.name,yaml:JSON.stringify(plan.workflow,null,2)});
  for (const w of workflows.values()) for (const step of JSON.parse(w.yaml).steps) {
    if (step.queue) requirements.add('Worker queue: '+step.queue);
    if (step.matrix?.template?.queue) requirements.add('Worker queue: '+step.matrix.template.queue);
  }
  if (sources.length) requirements.add('Choose the source owner when installing; records and ingestion progress are not exported.');
  return {manifest:{name:plan.package_name,version:'0.1.0',description:plan.outcome,requires:'percolate >= 0.2.0',
    ...(sources.length?{sources}:{}),...(agents.length?{agents}:{}),workflows:[...workflows.values()]},requirements:[...requirements],setupNotes:plan.setup_requirements};
}

export function packageText(bundle) {
  return '# '+bundle.manifest.name+'\n# Destination requirements:\n'+bundle.requirements.map(r=>'# '+r.replaceAll('\n',' ')).join('\n')+
    ((bundle.setupNotes || []).length?'\n# Additional setup notes from the design:\n'+bundle.setupNotes.map(r=>'# '+r.replaceAll('\n',' ')).join('\n'):'')+'\n\n'+JSON.stringify(bundle.manifest,null,2)+'\n';
}
