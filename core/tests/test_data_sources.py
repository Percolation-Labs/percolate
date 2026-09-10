"""Source authoring contracts: executable policies, portable packages and AI repair."""
import json
import subprocess
import unittest
from pathlib import Path
from tests.test_query_assist import BOOT, STATIC
from percolate_core.ingest.policy import resolve


class DataSourceTest(unittest.TestCase):
    def run_js(self, source):
        boot=BOOT+f"""
const api=await import({json.dumps((STATIC/'api.js').as_uri())});
const author=await import({json.dumps((STATIC/'source-authoring.js').as_uri())});
const sourceAssist=await import({json.dumps((STATIC/'source-assist.js').as_uri())});
await api.loadConfig();api.setToken('header.'+Buffer.from(JSON.stringify({{sub:session,exp:Date.now()/1000+3600}})).toString('base64url')+'.signature');
"""
        r=subprocess.run(['node','--input-type=module','-e',boot+source],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout

    def test_source_package_is_loader_compatible_and_uses_bound_resource_argument(self):
        out=self.run_js("""
const m=author.sourcePackage(session,{...author.SOURCE_DEFAULTS,name:'handovers',mode:'text',transform:'Find blockers',agent:'operations_brief'}, {ingestQueue:'ingest-ui',workflowQueue:'ui-workflows'});
const w=JSON.parse(m.workflows[0].yaml);
assert.equal(m.sources[0].config.ingest_workflow,w.name);
assert.deepEqual(w.steps[1].sql,{function:'source_passages',args:['{{run.resource_id}}']});
assert.equal(w.steps[2].queue,'ui-workflows');
assert.equal(w.steps[2].output_schema.type,'object');
assert.ok(!Object.hasOwn(m,'agents')); // no plugin pruning or embedded provider keys
console.log(author.packageText(m));
""")
        import yaml
        manifest=yaml.safe_load(out)
        _,policy=resolve('text/markdown','handover.md',manifest['sources'][0]['config']['ingest_policy'])
        self.assertEqual(policy.mode,'text')
        self.assertEqual(policy.chunking.target_tokens,700)

    def test_tabular_policy_matches_the_real_ingestion_worker(self):
        out=self.run_js("""
const m=author.sourcePackage(session,{...author.SOURCE_DEFAULTS,name:'sales',mode:'tabular',dataset_name:'sales',partition_by:['region'],delimiter:','});
assert.equal(JSON.parse(m.workflows[0].yaml).steps.length,1);
console.log(JSON.stringify(m.sources[0].config.ingest_policy));
""")
        _,policy=resolve('text/csv','sales.csv',json.loads(out))
        self.assertEqual(policy.mode,'tabular')
        self.assertEqual(policy.table.partition_by,['region'])

    def test_invalid_combinations_are_rejected_before_save_or_export(self):
        self.run_js("""
const make=s=>author.sourcePackage(session,{...author.SOURCE_DEFAULTS,name:'sample',...s});
assert.throws(()=>make({name:'bad name'}),/name/);
assert.throws(()=>make({chunk_tokens:0}),/Chunk size/);
assert.throws(()=>make({overlap:1}),/Overlap/);
assert.throws(()=>make({mode:'tabular',embedding_model:'demo'}),/Parquet/);
assert.throws(()=>make({mode:'auto',transform:'Extract',agent:'brief'}),/Text documents/);
assert.throws(()=>make({mode:'text',transform:'Extract',agent:'brief',output_schema_json:'{bad'}),/valid JSON/);
""")

    def test_ai_repairs_invalid_configuration_without_saving_or_running_it(self):
        self.run_js("""
let n=0;
content=()=>JSON.stringify({settings:{...author.SOURCE_DEFAULTS,name:'handover',mode:++n===1?'auto':'text',transform:'Extract blockers',agent:'brief'},explanation:'Ingest, then extract.',assumptions:[]});
const v=await sourceAssist.suggestSource({description:'Find blockers in uploaded notes',current:author.SOURCE_DEFAULTS,agents:['brief'],models:[],id:session,queues:{}});
assert.equal(v.settings.mode,'text');assert.equal(n,2);
assert.ok(calls.every(c=>c.url.endsWith('/chat')||c.url.endsWith('/rpc/create_session')));
assert.ok(calls.at(-1).body.messages[0].content.includes('failed validation'));
""")

    def test_unavailable_ai_agent_does_not_become_a_saved_configuration(self):
        self.run_js("""
content=JSON.stringify({settings:{...author.SOURCE_DEFAULTS,name:'handover',mode:'text',transform:'Extract',agent:'invented'},explanation:'Extract.',assumptions:[]});
await assert.rejects(sourceAssist.suggestSource({description:'Extract',current:{},agents:['brief'],models:[],id:session,queues:{}}),/unavailable/);
""")

    def test_drafts_are_account_scoped_and_workflow_handoff_preserves_inputs(self):
        self.run_js(f"""
const drafts=await import({json.dumps((STATIC/'drafts.js').as_uri())});
const alice=drafts.draftStore('source');alice.write({{name:'alice draft'}});
api.setToken('h.'+Buffer.from(JSON.stringify({{sub:'bob',exp:Date.now()/1000+3600}})).toString('base64url')+'.s');
assert.deepEqual(drafts.draftStore('source').read(),{{}});
alice.write({{name:'alice async'}});assert.deepEqual(drafts.draftStore('source').read(),{{}});
sessionStorage.setItem('p8-workflow-draft','old workflow');sessionStorage.setItem('p8-workflow-input','{{"question":"old"}}');
drafts.stageWorkflow('new query');
assert.equal(sessionStorage.getItem('p8-workflow-draft-backup'),'old workflow');
assert.equal(sessionStorage.getItem('p8-workflow-input-backup'),'{{"question":"old"}}');
assert.equal(sessionStorage.getItem('p8-workflow-input'),'{{}}');
assert.ok(drafts.sameInput({{b:2,a:1}},{{a:1,b:2}}));
""")


class APISourceAuthoringTest(unittest.TestCase):
    def run_js(self, source):
        script=BOOT+f"""
const api=await import({json.dumps((STATIC/'api.js').as_uri())});
const author=await import({json.dumps((STATIC/'api-source-authoring.js').as_uri())});
const assist=await import({json.dumps((STATIC/'api-source-assist.js').as_uri())});
await api.loadConfig();api.setToken('h.'+Buffer.from(JSON.stringify({{sub:session,exp:Date.now()/1000+3600}})).toString('base64url')+'.s');
"""+source
        result=subprocess.run(['node','--input-type=module','-e',script],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        return result.stdout

    def test_package_uses_portable_name_and_matches_worker_contract(self):
        out=self.run_js("""
const m=author.apiSourcePackage(session,author.GITHUB_EXAMPLE,'ingest-ui');
const w=JSON.parse(m.workflows[0].yaml);
assert.deepEqual(w.steps[0].input,{op:'api_pull',source_name:'github-issues'});
assert.equal(w.steps[0].queue,'ingest-ui');assert.equal(m.sources[0].kind,'http_pull');
assert.ok(!JSON.stringify(m).includes('pending_watermark'));
console.log(author.apiPackageText(m));
""")
        import yaml
        from percolate_core.ingest.api import APIConfig
        m=yaml.safe_load(out)
        c=APIConfig.model_validate(m['sources'][0]['config']['api'])
        self.assertEqual(c.watermark_param,'since')
        self.assertEqual(c.pagination,'link_header')

    def test_invalid_contract_cannot_be_exported_or_used_as_a_proposal(self):
        self.run_js("""
const make=s=>author.apiSourcePackage(session,{...author.GITHUB_EXAMPLE,...s});
assert.throws(()=>make({cursor:'invented'}),/Unknown/);
assert.throws(()=>make({url:'https://a.test/?token=secret'}),/credential/);
assert.throws(()=>make({headers:{Authorization:'secret'}}),/credential/);
assert.throws(()=>make({auth_type:'bearer',credential_ref:'literal-token'}),/credential/);
assert.throws(()=>make({initial_watermark:'2026-09-10T12:00:00'}),/timezone/);
assert.throws(()=>make({watermark_type:'number',initial_watermark:'NaN'}),/number/);
assert.throws(()=>make({mappings:{x:{path:'x',cast:'eval'}}}),/Mapping/);
assert.throws(()=>make({max_pages:0}),/max_pages/);
assert.throws(()=>make({params:{filter:{nested:true}}}),/parameter/);
""")

    def test_ai_repairs_proposal_and_makes_no_ingestion_calls(self):
        self.run_js("""
let n=0;
content=()=>JSON.stringify({configuration_json:JSON.stringify({...author.GITHUB_EXAMPLE,max_pages:++n===1?0:2}),explanation:'Keep issues current for triage.',assumptions:[]});
const result=await assist.suggestAPI({description:'Track issues',current:{},id:session,queue:'ingest-ui'});
assert.equal(result.settings.max_pages,2);assert.equal(n,2);
assert.ok(calls.every(c=>c.url.endsWith('/chat')||c.url.endsWith('/rpc/create_session')));
assert.ok(calls.at(-1).body.messages[0].content.includes('validation error'));
""")

    def test_unknown_api_requests_contract_instead_of_inventing_a_source(self):
        self.run_js("""
content=JSON.stringify({configuration_json:'',explanation:'Provide the endpoint and response example.',assumptions:[]});
const result=await assist.suggestAPI({description:'Connect our internal API',current:{},id:session,queue:'ingest-ui'});
assert.equal(result.settings,null);
""")
