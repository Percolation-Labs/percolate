import base64,json,tempfile,threading,unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from percolate_core.query.connector_auth import ConnectorAuth,ConnectorAuthError
from percolate_core.query.mcp import build_server

U1='13290000-0000-0000-0000-000000000001';U2='13290000-0000-0000-0000-000000000002'
K1='13290000-0000-0000-0000-000000000101';K2='13290000-0000-0000-0000-000000000102'
RAW1='first-user-key-that-is-long-enough';RAW2='second-user-key-that-is-long-enough'
def claims(header):
 p=header.split('.')[1];return json.loads(base64.urlsafe_b64decode(p+'==='))
class Up:
 def __init__(self):self.active=True;self.error=None;self.calls=[]
 def rpc(self,name,body,auth=None,profile=None):
  self.calls.append((name,body,auth,profile))
  if name=='verify_api_key':
   if self.error:return None,self.error
   key=body['p_raw_key']
   if not self.active or key not in (RAW1,RAW2):return [],None
   return [{'user_id':U1 if key==RAW1 else U2,'key_id':K1 if key==RAW1 else K2,'scopes':['canvas:read','canvas:write','mcp:query'] if key==RAW1 else ['canvas:read']}],None
  return {'session':claims(auth)['sub']},None
class ConnectorTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.key=Path(self.tmp.name)/'key';self.key.write_text('a-private-deployment-secret-over-32-characters');self.key.chmod(0o600);self.up=Up();self.auth=ConnectorAuth(self.up,self.key,5)
 def tearDown(self):self.tmp.cleanup()
 def test_expired_access_renews_and_never_changes_user(self):
  with patch('time.time',return_value=1000):a=self.auth.authenticate('Bearer '+RAW1)
  with patch('time.time',return_value=1020):b=self.auth.authenticate('Bearer '+RAW1)
  self.assertEqual(claims(a.authorization)['exp'],1005);self.assertEqual(claims(b.authorization)['exp'],1025)
  self.assertEqual(claims(b.authorization)['sub'],U1);self.assertEqual(claims(b.authorization)['api_key_id'],K1)
  self.assertEqual(len(self.up.calls),2)
 def test_two_users_and_scopes_cannot_mix(self):
  a=self.auth.authenticate('Bearer '+RAW1);b=self.auth.authenticate('Bearer '+RAW2)
  self.assertNotEqual(a.user_id,b.user_id)
  self.assertTrue(a.allows('tools/call',{'name':'canvas','arguments':{'action':'query'}}))
  self.assertFalse(b.allows('tools/call',{'name':'canvas','arguments':{'action':'query'}}))
  self.assertFalse(a.allows('tools/call',{'name':'land_message_facts'}))
 def test_revocation_and_unavailable_identity_never_fall_back(self):
  self.auth.authenticate('Bearer '+RAW1);self.up.active=False
  with self.assertRaises(ConnectorAuthError) as c:self.auth.authenticate('Bearer '+RAW1)
  self.assertEqual(c.exception.status,401)
  self.up.error={'status':503}
  with self.assertRaises(ConnectorAuthError) as c:self.auth.authenticate('Bearer '+RAW1)
  self.assertEqual(c.exception.status,503)
 def test_http_uses_verified_identity_and_protects_discovery(self):
  with patch('percolate_core.query.mcp.Upstream',return_value=self.up):server=build_server('127.0.0.1',0,'http://unused',signing_key_file=str(self.key))
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  def rpc(method,params,key=None):
   req=Request(f'http://127.0.0.1:{server.server_port}/mcp',data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers={'Content-Type':'application/json',**({'Authorization':'Bearer '+key} if key else {})})
   return json.load(urlopen(req))
  try:
   with self.assertRaises(HTTPError) as c:rpc('initialize',{})
   self.assertEqual(c.exception.code,401)
   with patch.dict('os.environ',{'P8_CANVAS_ENABLED':'1'}):
    tools=rpc('tools/list',{},RAW2)['result']['tools'];self.assertEqual({t['name'] for t in tools},{'canvas','canvas_ui'})
    self.assertEqual(rpc('tools/call',{'name':'canvas_ui','arguments':{'action':'read'}},RAW2)['result']['structuredContent']['session'],U2)
    with self.assertRaises(HTTPError) as c:rpc('tools/call',{'name':'query','arguments':{'query':'SCHEMA "p8ql"'}},RAW2)
    self.assertEqual(c.exception.code,403)
  finally:server.shutdown();server.server_close();thread.join()
