"""One suggestion contract, and nothing else allowed to implement it.

Run: python -m unittest discover -s tests -p test_suggestion_contract.py

`specs/agentic/browser-ui.md` §7 states what an assistant owes its caller, and
its own audit of six shipping assistants recorded that they did not all pay it:
five retried a malformed response and the query assistant threw on the first;
three carried `needs_clarification` as a field and three signalled a question by
returning an empty answer -- the same value they returned when they failed.

Those divergences were recorded rather than fixed, which is right for an audit
and wrong to leave: a rule six files implement six ways is a rule the seventh
implements a seventh way. `api.js:suggest()` is the one implementation, and the
last test here is the part that keeps it one -- a module that hand-rolls a
`/chat` request fails, by name.
"""
import json
import re
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
const calls=[];let replies=[],status=200;
globalThis.fetch=async(url,options)=>{
 if(url==='config.json')return Response.json({rest:'http://rest.test',core:'http://core.test',dev_token:false});
 const body=JSON.parse(options.body);calls.push({url,body});
 if(url.endsWith('/chat')){
  if(status!==200)return Response.json({detail:'the runtime refused this turn'},{status});
  const next=replies.shift();
  return Response.json({choices:[{message:{content:typeof next==='string'?next:JSON.stringify(next)}}]});
 }
 throw Error('Unexpected request '+url);
};
"""


@unittest.skipUnless(shutil.which("node"), "node runs the browser transport")
class SuggestionContractTest(unittest.TestCase):
    def run_js(self, source):
        script = BOOT + f"""
const api=await import({json.dumps((STATIC / 'api.js').as_uri())});
await api.loadConfig();
api.setToken('header.'+Buffer.from(JSON.stringify({{sub:session,exp:Date.now()/1000+3600}})).toString('base64url')+'.signature');
const SCHEMA={{type:'object',properties:{{answer:{{type:'string'}},needs_clarification:{{type:'string'}}}}}};
const ask=(o={{}})=>api.suggest({{name:'t',schema:SCHEMA,session,prompt:'p',
  answered:v=>typeof v.answer==='string'&&!!v.answer.trim(),...o}});
""" + source
        result = subprocess.run(["node", "--input-type=module", "-e", script],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_request_is_the_same_shape_for_every_assistant(self):
        self.run_js("""
        replies=[{answer:'a',needs_clarification:''}];
        const v=await ask();
        assert.equal(v.answer,'a');
        const body=calls[0].body;
        assert.equal(calls[0].url,'http://core.test/chat');
        assert.equal(body.model,'percolate_help');
        assert.equal(body.session_id,session);
        assert.equal(body.stream,false);
        assert.equal(body.response_format.json_schema.name,'t');
        assert.equal(body.response_format.json_schema.strict,true);
        assert.equal(calls.length,1,'one turn, no gratuitous retry');
        """)

    def test_an_invalid_answer_is_corrected_once_and_then_fails_whole(self):
        """§7: never a partially applied form. A second failure is a failure."""
        self.run_js("""
        replies=[{answer:'bad',needs_clarification:''},{answer:'good',needs_clarification:''}];
        const v=await ask({validate:x=>{if(x.answer==='bad')throw Error('the answer was bad');return x;}});
        assert.equal(v.answer,'good');
        assert.equal(calls.length,2);
        assert.match(calls[1].body.messages[0].content,/the answer was bad/,'the error goes back to the model');
        calls.length=0;replies=[{answer:'bad',needs_clarification:''},{answer:'bad',needs_clarification:''}];
        await assert.rejects(ask({validate:()=>{throw Error('still bad')}}),/still bad/);
        assert.equal(calls.length,2,'exactly one correction');
        """)

    def test_a_response_that_neither_answers_nor_asks_is_rejected(self):
        """The audit row three assistants could not tick."""
        self.run_js("""
        replies=[{answer:'',needs_clarification:''},{answer:'',needs_clarification:''}];
        await assert.rejects(ask(),/neither an answer nor a question/);
        assert.equal(calls.length,2);
        """)

    def test_a_question_is_returned_without_being_validated_as_an_answer(self):
        self.run_js("""
        replies=[{answer:'',needs_clarification:'Which endpoint?'}];
        const v=await ask({validate:()=>{throw Error('validate must not run on a question')}});
        assert.equal(v.needs_clarification,'Which endpoint?');
        assert.equal(calls.length,1);
        """)

    def test_a_refusal_is_not_retried(self):
        """A 4xx is the same 4xx on the second attempt; asking again costs time."""
        self.run_js("""
        status=403;replies=[{answer:'a',needs_clarification:''}];
        await assert.rejects(ask(),/refused this turn/);
        assert.equal(calls.length,1);
        """)

    def test_nothing_else_builds_a_chat_request(self):
        """The ratchet. A seventh copy of the loop fails here, by name.

        `access.js` is the exception and stays one: Chat is a streaming
        conversation with a person, not a structured suggestion, and it is the
        screen §7 is about the absence of.
        """
        allowed = {"api.js", "access.js"}
        offenders = sorted(p.name for p in STATIC.glob("*.js")
                           if p.name not in allowed and re.search(r'["\']\s*\+?\s*["\']?/chat', p.read_text()))
        self.assertEqual(
            offenders, [],
            f"{offenders} build their own /chat request. Call suggest() in api.js instead.")

    def test_every_assistant_declares_a_clarification_field(self):
        """A question needs somewhere to go that is not the answer's field."""
        for name in ("query-assist.js", "source-assist.js", "api-source-assist.js",
                     "schedule-assist.js", "agent-assist.js", "workflow-assist.js"):
            self.assertIn("needs_clarification", (STATIC / name).read_text(),
                          f"{name} has no clarification field, so a question arrives as a failure")


if __name__ == "__main__":
    unittest.main()
