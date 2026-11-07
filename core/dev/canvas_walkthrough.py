"""Scripted user/assistant rehearsal. Every answer is backed by live core MCP calls.

Run against the retained local workspace: python dev/canvas_walkthrough.py
The generated transcript labels user prompts as simulated, and records SQL/results.
No fixture rows are loaded by this script.
"""
import json
from pathlib import Path
from urllib.request import Request,urlopen
from canvas_call import call as canvas_rpc

SCHEMA_SQL="""select n.nspname as schema, count(*)::int as tables
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')
  and n.nspname not like 'pg_toast%'
group by n.nspname order by tables desc, schema limit 30"""
EDGES_SQL="""select ns.nspname||'.'||src.relname as source,
       nt.nspname||'.'||dst.relname as target, c.conname as relation
from pg_catalog.pg_constraint c
join pg_catalog.pg_class src on src.oid=c.conrelid
join pg_catalog.pg_namespace ns on ns.oid=src.relnamespace
join pg_catalog.pg_class dst on dst.oid=c.confrelid
join pg_catalog.pg_namespace nt on nt.oid=dst.relnamespace
where c.contype='f' and ns.nspname='workflow' and nt.nspname='workflow'
order by source,target,relation limit 100"""
ACTIVITY_SQL="""select step_key as step, count(*)::int as tasks
from workflow.tasks_api where queue='workspace-canvas'
group by step_key order by tasks desc,step_key limit 20"""

def mcp(name,args):
    cfg=json.loads(Path('.local/canvas-client.json').read_text())
    req=Request('http://127.0.0.1:8141/mcp',data=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':args}}).encode(),headers={'Authorization':'Bearer '+cfg['token'],'Content-Type':'application/json'})
    with urlopen(req,timeout=15) as response:result=json.load(response)['result']
    if result.get('isError'):raise RuntimeError(result['content'])
    return result['structuredContent']

if __name__=='__main__':
    out=Path('.local/canvas-walkthrough');out.mkdir(exist_ok=True)
    transcript=['# Core canvas conversation rehearsal','Simulated user prompts; actual caller-authenticated MCP/SQL results from the local core workspace. No example rows are inserted.']
    mcp('canvas',{'action':'open'})
    for prompt,caption,sql,control,options in [
        ('What tables are in this Percolate database? Group them by schema.','Tables by schema',SCHEMA_SQL,'plot',{'x':'schema','y':'tables','form':'bar'}),
        ('Now graph the relationships between the workflow tables.','Workflow foreign-key relationships',EDGES_SQL,'graph',{'source':'source','target':'target','relation':'relation'}),
        ('How much actual canvas work have we recorded? Plot its task types.','Recorded canvas tasks',ACTIVITY_SQL,'plot',{'x':'step','y':'tasks','form':'bar'}),
    ]:
        result=mcp('canvas',{'action':'query','statement':sql,'caption':caption});rid=result['view']['result']['id']
        full=canvas_rpc('read',{})['view']['result'];view=mcp('canvas',{'action':'view','control':control,'options':options})
        assert view['view']['result']['id']==rid
        transcript += ['\n**User (simulated):** '+prompt,'\n**Assistant:** Queried the live database and displayed '+control+' using saved result `'+rid+'`.','\n```sql\n'+sql+'\n```','\nReturned '+str(len(full['rows']))+' rows:\n```json\n'+json.dumps(full['rows'],indent=2)+'\n```']
        (out/(control+'-'+caption.split()[0].lower()+'.json')).write_text(json.dumps(full,indent=2))
    (out/'conversation.md').write_text('\n'.join(transcript)+'\n')
    print('PASS live schema, relationship and runtime-table queries; same-result plots/graph. Transcript: '+str(out/'conversation.md'))
