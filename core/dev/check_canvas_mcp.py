"""Live check: caller-authenticated MCP to core RPC to saved canvas state."""
import json
from urllib.request import Request, urlopen
from canvas_call import call
from pathlib import Path

cfg=json.loads(Path('.local/canvas-client.json').read_text())
def mcp(method, params=None):
    req=Request('http://127.0.0.1:8141/mcp',data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or {}}).encode(),headers={'Authorization':'Bearer '+cfg['token'],'Content-Type':'application/json'})
    with urlopen(req) as response: value=json.load(response)
    assert 'error' not in value,value
    return value['result']
def tool(name,arguments):
    result=mcp('tools/call',{'name':name,'arguments':arguments})
    assert not result.get('isError'),result
    return result['structuredContent']
assert any(t['name']=='canvas' for t in mcp('tools/list')['tools'])
tool('canvas',{'action':'open'})
state=tool('canvas',{'action':'query','query':'workflow_steps','caption':'Example workflow steps'})
result=state['view']['result']['id']
call('touch',{'kind':'selection','result_set':result,'columns':['step','tasks'],'rows':[0]})
view=tool('canvas',{'action':'view','control':'plot'})
assert view['view']['result']['id']==result
assert view['since_last_call'][0]['rows']==[0]
call('touch',{'kind':'selection','result_set':result,'columns':['step','tasks'],'rows':[1]})
query=tool('query',{'query':'SCHEMA "p8ql"'})
assert query['canvas']['since_last_call'][0]['rows']==[1]
assert call('read',{})['view']['result']['id']==result
print('PASS: MCP tool discovery, caller identity, same-result plot and touches on canvas and query calls.')
