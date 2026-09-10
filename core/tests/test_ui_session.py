"""Exercise session recovery at the shared browser transport, without a server."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

API = (Path(__file__).resolve().parents[1] / "percolate_core/ui/static/api.js").as_uri()
BOOT = r"""
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
const storage = () => {const data = new Map(); return {getItem:k=>data.get(k)??null,setItem:(k,v)=>data.set(k,String(v)),removeItem:k=>data.delete(k)};};
globalThis.localStorage=storage();globalThis.sessionStorage=storage();
const events=[];
globalThis.window={dispatchEvent:e=>events.push(e.type)};
globalThis.CustomEvent=class {constructor(type){this.type=type;}};
let signs=0, hold=null;
Object.defineProperty(globalThis,'crypto',{configurable:true,value:{subtle:{
 importKey:(...a)=>webcrypto.subtle.importKey(...a),
 sign:async(...a)=>{signs++;if(hold)await hold;return webcrypto.subtle.sign(...a);}
}}});
const jwt = (exp) => ['header',Buffer.from(JSON.stringify({sub:'11111111-1111-1111-1111-111111111111',role:'authenticated',exp})).toString('base64url'),'signature'].join('.');
const calls=[];let replies=[];
const setup=async(dev=true)=>{
 globalThis.fetch=async(url,options)=>{
  if(url==='config.json')return new Response(JSON.stringify({rest:'http://rest.test',core:'http://core.test',dev_token:dev,dev_secret:dev?'public-test-fixture':''}));
  calls.push(options);return new Response('{}',{status:replies.shift()||200});
 };
 await api.loadConfig();
};
"""

@unittest.skipUnless(shutil.which("node"), "node runs the browser data layer")
class BrowserSessionTest(unittest.TestCase):
    def run_js(self, source):
        script = BOOT + f"\nconst api=await import({json.dumps(API)});\n" + source
        result = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_expired_dev_session_renews_once_for_concurrent_requests(self):
        self.run_js("""
        await setup();api.setToken(jwt(1));
        await Promise.all([api.authFetch('http://rest.test'),api.authFetch('http://core.test')]);
        assert.equal(signs,1);assert.equal(calls.length,2);assert.equal(api.sessionState(),'active');
        assert.equal(calls[0].headers.get('Authorization'),calls[1].headers.get('Authorization'));
        assert.equal(api.claims().sub,'11111111-1111-1111-1111-111111111111');
        """)

    def test_production_expiry_requires_sign_in_without_sending_a_request(self):
        self.run_js("""
        await setup(false);api.setToken(jwt(1));
        await assert.rejects(api.authFetch('http://rest.test'),api.SessionError);
        assert.equal(signs,0);assert.equal(calls.length,0);assert.ok(events.includes('p8-auth-required'));
        """)

    def test_401_retries_once_but_permission_denial_does_not(self):
        self.run_js("""
        await setup();api.setToken(jwt(Math.floor(Date.now()/1000)+3600));replies=[401,200];
        await api.authFetch('http://rest.test',{method:'POST',body:'{}'});
        assert.equal(signs,1);assert.equal(calls.length,2);assert.equal(calls[1].body,'{}');
        replies=[403];const denied=await api.authFetch('http://rest.test');
        assert.equal(denied.status,403);assert.equal(calls.length,3);assert.equal(signs,1);
        replies=[401,401];await assert.rejects(api.authFetch('http://rest.test'),api.SessionError);
        assert.equal(calls.length,5);
        """)

    def test_sign_out_during_renewal_cannot_restore_the_old_account(self):
        self.run_js("""
        await setup();api.setToken(jwt(1));let release;hold=new Promise(r=>release=r);
        const pending=api.renewSession();api.setToken('');release();
        await assert.rejects(pending,/account changed/);assert.equal(api.token(),'');
        """)

    def test_current_session_does_not_renew_or_repeat_network_failures(self):
        self.run_js("""
        await setup();api.setToken(jwt(Math.floor(Date.now()/1000)+3600));
        await api.authFetch('http://rest.test');assert.equal(signs,0);
        let attempts=0;globalThis.fetch=async()=>{attempts++;throw new Error('offline')};
        await assert.rejects(api.authFetch('http://rest.test',{method:'POST',body:'{}'}),/offline/);
        assert.equal(attempts,1);assert.equal(signs,0);
        """)
