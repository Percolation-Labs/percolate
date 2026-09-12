"""The API source assistant reads the endpoint before it designs for it.

Run: python -m unittest discover -s tests -p test_api_source_assist.py

The browser half of REM-24. `test_api_probe.py` asserts that the probe reports
what it read; this asserts that the report is what the model is given, that the
instruction which used to forbid discovery is gone, and that a probe which
failed reaches the prompt as a failure rather than as silence -- silence being
the state in which a model produces a confident dot path.

No model call and no network: `fetch` is stubbed, as in `test_query_assist.py`.
What is under test is the request this module builds, which is the part a live
turn cannot check anyway.
"""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "percolate_core/ui/static"
REPORT = {
    "url": "https://api.example.test/v1/items", "status": 200, "wire": "json",
    "kind": "records", "bytes": 900, "truncated": False,
    "observed": {"records_path": "results", "record_count": 5,
                 "fields": {"id": {"type": "int"}, "changed": {"type": "datetime"}},
                 "pagination": "next_url", "next_path": "next",
                 "evidence": "'next' holds a URL"},
    "inferred": {"watermark_field": "changed", "watermark_type": "timestamp",
                 "watermark_candidates": ["changed"], "id_path": "id", "id_candidates": ["id"]},
    "friction": ["No ETag or Last-Modified: a conditional GET cannot cheapen re-reads."],
}
BOOT = r"""
import assert from 'node:assert/strict';
const storage=()=>{const m=new Map();return {getItem:k=>m.get(k)??null,setItem:(k,v)=>m.set(k,String(v)),removeItem:k=>m.delete(k)}};
globalThis.localStorage=storage();globalThis.sessionStorage=storage();
globalThis.window={dispatchEvent(){}};globalThis.CustomEvent=class {};
const session='11111111-1111-4111-8111-111111111111';
const calls=[];let probeStatus=200,probeBody=REPORT;
const settings={name:'items',description:'d',url:'https://api.example.test/v1/items',params:{},headers:{},
 auth_type:'none',credential_ref:'',auth_header:'X-API-Key',records_path:'results',id_path:'id',
 watermark_type:'timestamp',watermark_field:'changed',watermark_param:'since',initial_watermark:'',
 overlap_seconds:60,pagination:'next_url',next_path:'next',page_param:'page',page_size_param:'per_page',
 page_size:100,max_pages:5,mappings:{}};
globalThis.fetch=async(url,options)=>{
 if(url==='config.json')return Response.json({rest:'http://rest.test',core:'http://core.test',content:'http://content.test',dev_token:false});
 const body=JSON.parse(options.body);calls.push({url,body});
 if(url.endsWith('/probe'))return Response.json(probeStatus===200?probeBody:{detail:'refused: '+probeBody},{status:probeStatus});
 if(url.endsWith('/rpc/create_session'))return Response.json({id:session,title:'API source suggestion',owner_id:session});
 if(url.endsWith('/chat'))return Response.json({choices:[{message:{content:JSON.stringify(
   {configuration_json:JSON.stringify(settings),explanation:'e',assumptions:['a']})}}]});
 throw Error('Unexpected request '+url);
};
const prompt=()=>calls.find(c=>c.url.endsWith('/chat')).body.messages[0].content;
"""


@unittest.skipUnless(shutil.which("node"), "node runs the browser authoring transport")
class APISourceAssistantTest(unittest.TestCase):
    def run_js(self, source):
        script = ("const REPORT=" + json.dumps(REPORT) + ";\n" + BOOT + f"""
const api=await import({json.dumps((STATIC / 'api.js').as_uri())});
const assist=await import({json.dumps((STATIC / 'api-source-assist.js').as_uri())});
await api.loadConfig();
api.setToken('header.'+Buffer.from(JSON.stringify({{sub:session,exp:Date.now()/1000+3600}})).toString('base64url')+'.signature');
const id='fdb52392-3136-4d0a-bed5-a103bc7f1bc9';
""" + source)
        result = subprocess.run(["node", "--input-type=module", "-e", script],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_endpoint_is_read_once_and_the_report_is_what_the_model_gets(self):
        self.run_js("""
        const v=await assist.suggestAPI({description:'Keep items current',sample:'',current:{},id,queue:'ingest',
          url:'https://api.example.test/v1/items'});
        const probes=calls.filter(c=>c.url.endsWith('/probe'));
        assert.equal(probes.length,1,'exactly one probe request');
        assert.equal(probes[0].url,'http://content.test/probe','the probe runs on the content service');
        assert.equal(probes[0].body.url,'https://api.example.test/v1/items');
        assert.ok(prompt().includes('"records_path":"results"'),'observed record path reaches the model');
        assert.ok(prompt().includes('never a path that is not in observed.fields'));
        assert.equal(v.observed.observed.records_path,'results','the report comes back for the screen');
        """)

    def test_the_instruction_that_forbade_discovery_is_gone(self):
        self.run_js("""
        await assist.suggestAPI({description:'Keep items current',sample:'',current:{},id,queue:'ingest',
          url:'https://api.example.test/v1/items'});
        assert.ok(!prompt().includes('Do not claim to browse or discover arbitrary APIs'));
        assert.ok(prompt().includes('overrides any example contract'),'observation beats the hardcoded example');
        """)

    def test_what_cannot_be_observed_is_named_rather_than_guessed(self):
        self.run_js("""
        await assist.suggestAPI({description:'Keep items current',sample:'',current:{},id,queue:'ingest',
          url:'https://api.example.test/v1/items'});
        // A response does not show which request parameter filters by the
        // watermark. The prompt has to say so, or the model fills it in.
        assert.ok(prompt().includes('watermark_param is in neither and cannot be'));
        assert.ok(prompt().includes('confirm'),'inferred fields are flagged as needing confirmation');
        """)

    def test_a_failed_probe_reaches_the_prompt_as_a_failure(self):
        self.run_js("""
        probeStatus=400;probeBody='Use an HTTP(S) endpoint without embedded credentials or a fragment.';
        const v=await assist.suggestAPI({description:'Keep items current',sample:'',current:{},id,queue:'ingest',
          url:'https://api.example.test/v1/items#fragment'});
        assert.ok(prompt().includes('The endpoint could not be inspected'));
        assert.ok(prompt().includes('do not produce paths you cannot support'));
        assert.ok(v.probeError.includes('embedded credentials'),'the reason reaches the screen too');
        assert.equal(v.observed,null);
        """)

    def test_no_endpoint_is_a_stated_absence_not_a_silent_one(self):
        self.run_js("""
        await assist.suggestAPI({description:'Keep items current',sample:'',current:{},id,queue:'ingest'});
        assert.equal(calls.filter(c=>c.url.endsWith('/probe')).length,0);
        assert.ok(prompt().includes('No endpoint was inspected'));
        """)

    def test_an_authenticated_probe_sends_a_reference_and_never_a_value(self):
        self.run_js("""
        await assist.suggestAPI({description:'Keep items current',sample:'',current:{},id,queue:'ingest',
          url:'https://api.example.test/v1/items',
          auth:{auth_type:'bearer',credential_ref:'ITEMS_TOKEN',auth_header:'X-API-Key'}});
        const sent=calls.find(c=>c.url.endsWith('/probe')).body;
        assert.equal(sent.credential_ref,'ITEMS_TOKEN');
        assert.deepEqual(Object.keys(sent).sort(),['auth_header','auth_type','credential_ref','url']);
        """)


if __name__ == "__main__":
    unittest.main()
