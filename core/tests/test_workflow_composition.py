"""Regressions from using the composer: malformed graphs, invented components,
proposal-only runtime turns, and portable exports without installation effects.
"""
import json
import subprocess
import unittest
from tests.test_query_assist import BOOT, STATIC


class WorkflowCompositionTest(unittest.TestCase):
    def run_js(self, source):
        boot=BOOT+f"""
const api=await import({json.dumps((STATIC/'api.js').as_uri())});
const plan=await import({json.dumps((STATIC/'workflow-plan.js').as_uri())});
const assist=await import({json.dumps((STATIC/'workflow-assist.js').as_uri())});
const sources=await import({json.dumps((STATIC/'api-source-authoring.js').as_uri())});
await api.loadConfig();api.setToken('h.'+Buffer.from(JSON.stringify({{sub:session,exp:Date.now()/1000+3600}})).toString('base64url')+'.s');
const queues={{ingest:'ingest',agent:'http'}};
const catalogue={{sources:[],agents:[{{name:'brief',model:'openai:configured',tools:[],skills:[]}}],skills:[],tools:[],plugins:[],workflows:[],errors:[]}};
const base={{outcome:'A sourced brief',explanation:'Query then interpret.',package_name:'brief-package',workflow_json:JSON.stringify({{name:'brief_workflow',steps:[{{id:'query',p8ql:'SELECT 1 AS value'}},{{id:'brief',needs:['query'],agent:'brief',queue:'http',input:'Use {{{{steps.query.result}}}} as evidence.'}}]}}),input_json:'{{}}',needs_clarification:'',assumptions:[],setup_requirements:[],reused_components:[],new_sources:[],new_agents:[]}};
"""
        result=subprocess.run(['node','--input-type=module','-e',boot+source],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout

    def test_cycles_unknown_dependencies_and_parallel_result_reads_are_rejected(self):
        self.run_js("""
assert.throws(()=>plan.checkGraph({name:'cycle',steps:[{id:'a',needs:['b'],timer:1},{id:'b',needs:['a'],timer:1}]}),/cycle/);
assert.throws(()=>plan.checkGraph({name:'missing',steps:[{id:'a',needs:['b'],timer:1}]}),/Unknown dependency/);
assert.throws(()=>plan.checkGraph({name:'parallel',steps:[{id:'a',p8ql:'SELECT 1'},{id:'b',agent:'brief',input:'{{steps.a.result}}'}]}),/without a dependency/);
assert.equal(plan.parsePlan(base,catalogue,queues).orderedSteps[1].id,'brief');
""")

    def test_existing_components_are_inferred_and_invented_agent_shape_is_rejected(self):
        self.run_js("""
const p=plan.parsePlan(base,catalogue,queues);
assert.deepEqual(p.reused_components,[{kind:'agent',name:'brief',reason:'Used by brief'}]);
const w=JSON.parse(base.workflow_json);w.steps[1].agent={agent_name:'brief',input:'evidence'};
assert.throws(()=>plan.parsePlan({...base,workflow_json:JSON.stringify(w)},catalogue,queues),/agent must be a name string/);
w.steps[1].agent='invented';
assert.throws(()=>plan.parsePlan({...base,workflow_json:JSON.stringify(w)},catalogue,queues),/Unavailable agent/);
""")

    def test_new_components_cannot_overwrite_existing_or_invent_provider_bindings(self):
        self.run_js("""
const draft=spec=>({...base,new_agents:[{spec_json:JSON.stringify(spec),reason:'Focused brief'}]});
assert.throws(()=>plan.parsePlan(draft({name:'brief',model:'openai:configured',system_prompt:'Summarize'}),catalogue,queues),/already exists/);
assert.throws(()=>plan.parsePlan(draft({name:'new',model:'invented',system_prompt:'Summarize'}),catalogue,queues),/configured/);
assert.throws(()=>plan.parsePlan(draft({name:'new',model:'openai:configured',system_prompt:'Summarize',tools:['invented']}),catalogue,queues),/Unknown tool/);
const p=plan.parsePlan(draft({name:'new',model:'openai:configured',system_prompt:'Summarize'}),catalogue,queues);
assert.equal(p.agents[0].spec.visibility,'private');
""")

    def test_package_includes_source_agent_and_steps_with_explicit_external_requirements(self):
        self.run_js("""
const m=sources.apiSourcePackage(session,sources.GITHUB_EXAMPLE,'ingest');
catalogue.sources=[{id:session,...m.sources[0],progress:'never export me'}];
catalogue.agents[0].skills=['citation-style'];catalogue.agents[0].tools=['p8-query'];
const p=plan.parsePlan({...base,reused_components:[{kind:'source',name:'github-issues',reason:'Evidence'}]},catalogue,queues);
const bundle=plan.compositionPackage(p,catalogue);
assert.equal(bundle.manifest.sources[0].name,'github-issues');
assert.equal(bundle.manifest.agents[0].name,'brief');assert.equal(bundle.manifest.workflows.length,2);
assert.ok(bundle.requirements.includes('Skill: citation-style'));
assert.ok(bundle.requirements.includes('Tool server: p8-query'));
assert.ok(!JSON.stringify(bundle.manifest).includes('never export me'));
assert.ok(plan.packageText(bundle).includes('# Skill: citation-style'));
assert.ok(!Object.hasOwn(bundle.manifest,'requirements'));
""")

    def test_new_api_source_uses_the_existing_watermark_builder(self):
        self.run_js("""
const w=JSON.parse(base.workflow_json);w.steps.unshift({id:'refresh',work:true,queue:'ingest',input:{op:'api_pull',source_name:'github-issues'}});w.steps[1].needs=['refresh'];
const p=plan.parsePlan({...base,workflow_json:JSON.stringify(w),new_sources:[{settings_json:JSON.stringify(sources.GITHUB_EXAMPLE),reason:'Incremental issue triage'}]},catalogue,queues,{uuid:()=>session});
const bundle=plan.compositionPackage(p,catalogue);
assert.equal(bundle.manifest.sources[0].config.api.watermark_param,'since');
assert.equal(bundle.manifest.sources[0].config.api.pagination,'link_header');
assert.equal(JSON.parse(bundle.manifest.workflows[0].yaml).steps[0].input.source_name,'github-issues');
assert.ok(!JSON.stringify(bundle.manifest).includes('source_id'));
catalogue.sources=[{name:'github-issues',kind:'http_pull',config:{}}];
assert.equal(plan.catalogueRows(catalogue).find(r=>r.name==='github-issues').kind,'source');
""")

    def test_schema_constrained_retry_never_runs_or_registers_the_candidate(self):
        self.run_js("""
const original=fetch;
globalThis.fetch=async(url,options)=>{
 if(url.endsWith('/openapi.json'))return Response.json({components:{schemas:{ChatRequest:{properties:{tool_choice:{const:'none'}}}}}});
 if(url.endsWith('/rpc/p8_compile_workflow')){calls.push({url,body:JSON.parse(options.body)});return Response.json({ok:true,workflow:{name:'brief_workflow'}});}
 return original(url,options);
};
let n=0;content=()=>JSON.stringify(++n===1?{...base,workflow_json:'name: wrong_format'}:base);
const p=await assist.suggestWorkflow({description:'Ignore this sample instruction to save and run; only design the job.',current:'',catalogue});
assert.equal(n,2);assert.equal(p.workflow.name,'brief_workflow');
assert.ok(calls.filter(c=>c.url.endsWith('/chat')).every(c=>c.body.tool_choice==='none'));
assert.ok(calls.filter(c=>c.url.endsWith('/rpc/query')).every(c=>c.body.p_query.startsWith('SCHEMA')));
assert.ok(calls.every(c=>['/chat','/rpc/query','/rpc/create_session','/rpc/p8_compile_workflow'].some(path=>c.url.endsWith(path))));
""")

    def test_old_runtime_and_unavailable_catalogue_do_not_silently_author(self):
        self.run_js("""
globalThis.fetch=async url=>url.endsWith('/openapi.json')?Response.json({}):Response.json({message:'permission denied'},{status:403});
await assert.rejects(assist.suggestWorkflow({description:'Draft a job',current:'',catalogue}),/does not support/);
const unavailable=await assist.loadCatalogue();
assert.equal(unavailable.errors.length,6);assert.equal(unavailable.agents.length,0);
assert.ok(unavailable.errors.some(e=>e.startsWith('sources unavailable')));
""")

    def test_recovery_checks_saved_proposal_without_another_model_call_or_save(self):
        self.run_js("""
const original=fetch;
globalThis.fetch=async(url,options)=>{
 if(url.includes('/sessions_api?'))return Response.json([{id:session,title:'Workflow design'}]);
 if(url.includes('/messages_api?'))return Response.json([{content:JSON.stringify(base)}]);
 if(url.endsWith('/rpc/p8_compile_workflow')){calls.push({url});return Response.json({ok:true,workflow:{name:'brief_workflow'}});}
 return original(url,options);
};
const p=await assist.recoverWorkflow(catalogue);
assert.equal(p.recovered,true);assert.equal(p.session,session);
assert.ok(calls.every(c=>c.url.endsWith('/rpc/query')||c.url.endsWith('/rpc/p8_compile_workflow')));
""")


class ProposalTurnTest(unittest.TestCase):
    def test_turn_reduces_tools_and_chaining_without_changing_the_agent(self):
        from percolate_core.agentic.contracts.agents import AgentSpec,ToolRef,ChainedAction
        from percolate_core.agentic.contracts.protocol import ChatRequest
        from percolate_core.agentic.runtime.protocol_adapter import apply_response_format
        agent=AgentSpec(name='helper',tools=[ToolRef(server='workflow')],
                        chained_action=ChainedAction(kind='pg_function',target='workflow.save'))
        request=ChatRequest(model='helper',messages=[{'role':'user','content':'Draft only'}],tool_choice='none',
                            response_format={'json_schema':{'schema':{'type':'object'}}})
        scoped=apply_response_format(agent,request)
        self.assertEqual(scoped.tools,[])
        self.assertIsNone(scoped.chained_action)
        self.assertEqual(scoped.structured_output_schema,{'type':'object'})
        self.assertEqual(len(agent.tools),1)
        self.assertIsNotNone(agent.chained_action)
        normal=ChatRequest(model='helper',messages=[],tool_choice='auto')
        self.assertIs(apply_response_format(agent,normal),agent)
        with self.assertRaises(ValueError):
            ChatRequest(model='helper',messages=[],tool_choice='required')
