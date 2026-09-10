"""Check authoring against the real HTTP shapes without paying for model calls."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "percolate_core/ui/static"
BOOT = r"""
import assert from 'node:assert/strict';
const storage=()=>{const m=new Map();return {getItem:k=>m.get(k)??null,setItem:(k,v)=>m.set(k,String(v)),removeItem:k=>m.delete(k)}};
globalThis.localStorage=storage();globalThis.sessionStorage=storage();
globalThis.window={dispatchEvent(){}};globalThis.CustomEvent=class {};
const session='11111111-1111-4111-8111-111111111111';
const suggestion={query:'TEXT "recall" FROM chunks LIMIT 5',explanation:'Find passages.',assumptions:[],requires_embedding:false};
const calls=[];let brokenSchema=false,content=JSON.stringify(suggestion),status=200;
globalThis.fetch=async(url,options)=>{
 if(url==='config.json')return Response.json({rest:'http://rest.test',core:'http://core.test',dev_token:false});
 const body=JSON.parse(options.body);calls.push({url,body});
 if(url.endsWith('/rpc/query'))return Response.json(brokenSchema?{mode:'error'}:{mode:'SCHEMA',schema:{doc:{derived:{relations:[{schema:'content',name:'resources',columns:body.p_query.includes('FROM')?[{name:'title',type:'text'}]:null}]}}}});
 if(url.endsWith('/rpc/create_session'))return Response.json({id:session,title:'Query suggestion',owner_id:session});
 if(url.endsWith('/chat'))return Response.json(status===200?{choices:[{message:{content:typeof content==='function'?content(body):content}}]}:{detail:[{msg:'Invalid request'}]},{status});
 throw Error('Unexpected request '+url);
};
"""


@unittest.skipUnless(shutil.which("node"), "node runs the browser authoring transport")
class QueryAssistantTest(unittest.TestCase):
    def run_js(self, source):
        script = BOOT + f"""
const api=await import({json.dumps((STATIC / 'api.js').as_uri())});
const assist=await import({json.dumps((STATIC / 'query-assist.js').as_uri())});
await api.loadConfig();
api.setToken('header.'+Buffer.from(JSON.stringify({{sub:session,exp:Date.now()/1000+3600}})).toString('base64url')+'.signature');
""" + source
        result = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_suggestion_uses_object_session_id_and_never_executes_the_draft(self):
        self.run_js("""
        const result=await assist.suggestQuery({mode:'suggest',description:'Find recalls',query:'SELECT old FROM draft'});
        assert.equal(result.query,suggestion.query);assert.equal(result.session,session);
        assert.deepEqual(calls.filter(c=>c.url.endsWith('/rpc/query')).map(c=>c.body.p_query),['SCHEMA','SCHEMA "p8ql"','SCHEMA "sql"']);
        const chat=calls.find(c=>c.url.endsWith('/chat')).body;
        assert.equal(chat.session_id,session);assert.equal(chat.model,'percolate_help');assert.equal(chat.stream,false);
        assert.equal(chat.response_format.json_schema.schema.type,'object');
        assert.ok(!chat.messages[0].content.includes('SELECT old FROM draft'));
        assert.equal(calls.length,5);
        """)

    def test_review_includes_draft_without_running_it(self):
        self.run_js("""
        await assist.suggestQuery({mode:'check',description:'Check columns',query:'SELECT name FROM content.resources'});
        const prompt=calls.find(c=>c.url.endsWith('/chat')).body.messages[0].content;
        assert.ok(prompt.includes('SELECT name FROM content.resources'));
        assert.ok(prompt.includes('Do not execute the candidate query'));
        assert.ok(calls.some(c=>c.body.p_query==='SCHEMA "sql" FROM content.resources'));
        assert.ok(prompt.includes('"name":"title"'));
        assert.ok(prompt.includes('columns:null means UNKNOWN'));
        assert.ok(!calls.some(c=>c.url.includes('sql_passthrough')));
        """)

    def test_missing_input_or_schema_stops_before_model_call(self):
        self.run_js("""
        await assert.rejects(assist.suggestQuery({mode:'suggest',description:' ',query:''}),/Describe/);
        await assert.rejects(assist.suggestQuery({mode:'check',description:'',query:' '}),/Write a query/);
        assert.equal(calls.length,0);
        brokenSchema=true;
        await assert.rejects(assist.suggestQuery({mode:'suggest',description:'Find recalls',query:''}),/schema is unavailable/);
        assert.ok(!calls.some(c=>c.url.endsWith('/chat')||c.url.endsWith('/rpc/create_session')));
        """)

    def test_new_sql_relations_get_actual_columns_and_revision_before_handoff(self):
        self.run_js("""
        let turn=0;
        content=body=>JSON.stringify({...suggestion,query:++turn===1?'SELECT name FROM content.resources LIMIT 5':'SELECT title FROM content.resources LIMIT 5'});
        const result=await assist.suggestQuery({mode:'suggest',description:'List my latest documents',query:''});
        assert.equal(result.query,'SELECT title FROM content.resources LIMIT 5');
        const turns=calls.filter(c=>c.url.endsWith('/chat'));
        assert.equal(turns.length,2);assert.equal(turns[0].body.session_id,turns[1].body.session_id);
        assert.ok(turns[1].body.messages[0].content.includes('"name":"title"'));
        assert.ok(calls.filter(c=>c.url.endsWith('/rpc/query')).every(c=>c.body.p_query.startsWith('SCHEMA')));
        """)

    def test_bad_output_and_runtime_errors_keep_inspectable_session(self):
        self.run_js("""
        for(const bad of ['not JSON',JSON.stringify({...suggestion,requires_embedding:'no'}),JSON.stringify({...suggestion,assumptions:[{}]})]){
          content=bad;
          await assert.rejects(assist.suggestQuery({mode:'suggest',description:'Find recalls',query:''}),e=>e.session===session&&/usable query/.test(e.message));
        }
        status=422;
        await assert.rejects(assist.suggestQuery({mode:'suggest',description:'Find recalls',query:''}),e=>e.session===session&&e.message==='Invalid request');
        """)

    def test_clarification_and_embedding_requirements_survive_parsing(self):
        self.run_js("""
        assert.equal(assist.parseSuggestion({...suggestion,query:'',explanation:'Which document?'}).query,'');
        assert.equal(assist.parseSuggestion({...suggestion,requires_embedding:true}).requires_embedding,true);
        assert.equal(assist.parseSuggestion({...suggestion,query:' SCHEMA '}).query,'SCHEMA');
        assert.equal(assist.parseSuggestion({...suggestion,query:"SELECT 'a;b' AS value; "}).query,"SELECT 'a;b' AS value");
        """)
