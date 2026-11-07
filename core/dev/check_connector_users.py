"""Disposable local-stack test: identity isolation, renewal, scope and revocation."""
import argparse,hashlib,json,secrets,subprocess,time
from uuid import uuid4
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--container',required=True,help='Disposable test database container; never a shared development database.')
parser.add_argument('--database',default='p8ci')
parser.add_argument('--db-user',default='p8')
parser.add_argument('--endpoint',required=True,help='Connector endpoint configured with --access-ttl 2.')
parser.add_argument('--authorization-file',type=Path,required=True,help='Full-scope existing user header file.')
options=parser.parse_args()
USER=str(uuid4())
first=options.authorization_file.read_text().strip().removeprefix('Bearer ')
second=secrets.token_urlsafe(40);readonly=secrets.token_urlsafe(40)
def sql(statement):
 r=subprocess.run(['docker','exec','-i',options.container,'psql','-U',options.db_user,'-d',options.database,'-v','ON_ERROR_STOP=1','-At'],input=statement,text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
def digest(raw):return hashlib.sha256(raw.encode()).hexdigest()
def call(key,name='canvas',args=None):
 req=Request(options.endpoint,data=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':args or {'action':'read'}}}).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
 with urlopen(req,timeout=10) as r:return json.load(r)['result']
sql(f"insert into rbac.users(id,email,status) values('{USER}','connector-isolation-{USER}@test.invalid','active') on conflict(id) do update set status='active';")
for raw,scopes in [(second,"'mcp:query','canvas:read','canvas:write'"),(readonly,"'canvas:read'")]:
 sql(f"insert into rbac.api_keys(user_id,label,key_hash,scopes) values('{USER}','connector regression','{digest(raw)}',array[{scopes}]);")
try:
 a=call(first,args={'action':'open'})['structuredContent'];b=call(second,args={'action':'open'})['structuredContent'];assert a['session']!=b['session']
 assert call(second,args={'action':'read','session':a['session']})['isError']
 rows=call(second,args={'action':'query','query':'workflow_runs','control':'cards','options':{'card_title':'status','card_fields':['runs']}})['structuredContent']['view']['result']['rows'];assert rows==[]
 time.sleep(3) # test server issues two-second access JWTs
 assert not call(second).get('isError'),'Stable connector key must work after earlier access JWT expires'
 assert not call(readonly).get('isError')
 try:call(readonly,name='query',args={'query':'SCHEMA "p8ql"'})
 except HTTPError as e:assert e.code==403
 else:raise AssertionError('Read-only key queried')
 sql(f"update rbac.api_keys set revoked_at=now() where key_hash='{digest(readonly)}'")
 try:call(readonly)
 except HTTPError as e:assert e.code==401
 else:raise AssertionError('Revoked key admitted')
 sql(f"update rbac.users set status='disabled' where id='{USER}'")
 try:call(second)
 except HTTPError as e:assert e.code==401
 else:raise AssertionError('Disabled user admitted')
 print('PASS real Percolate: two user sessions isolated, cross-user read denied, two-second access expiry renews, read-only scope enforced, revoke and disable immediate.')
finally:
 sql(f"update rbac.api_keys set revoked_at=now() where user_id='{USER}';update rbac.users set status='disabled' where id='{USER}';")
