"""Exercise the real source API, workflow queue and checkpointed ingestion worker.
Run against the explicit local fixture from percolate's dev/tests/content/api_fixture.py.
"""
import json,sys,time,uuid,urllib.request,urllib.error
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
from ui_reads import token
AUTH={'Authorization':'Bearer '+token(),'Content-Type':'application/json'}
REST='http://localhost:5611'
def request(path,body=None,schema='content'):
 headers={**AUTH,('Content-Profile' if body is not None else 'Accept-Profile'):schema}
 r=urllib.request.Request(REST+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
 try:
  with urllib.request.urlopen(r,timeout=30) as res:return json.load(res)
 except urllib.error.HTTPError as e:raise RuntimeError(e.read().decode()) from None
def fixture(op):
 with urllib.request.urlopen(urllib.request.Request('http://localhost:5619/'+op,data=b'',method='POST')) as res:return json.load(res)
def wait(run,limit=30):
 for _ in range(limit*4):
  row=request('/runs_api?id=eq.'+run,schema='workflow')[0]
  if row['status']!='running':
   if row['status']!='succeeded':raise AssertionError(row)
   return row
  time.sleep(.25)
 raise AssertionError('Run did not finish: '+run)
def main():
 source=str(uuid.uuid4());name='ui-api-watermark-'+source[:8]
 cfg={'url':'http://p8-dev-api-fixture:8091/records','params':{},'headers':{},'auth_type':'none','credential_ref':'','auth_header':'X-API-Key',
  'records_path':'items','id_path':'id','watermark_type':'timestamp','watermark_field':'updated_at','watermark_param':'since','initial_watermark':'','overlap_seconds':60,
  'pagination':'next_url','next_path':'next','page_param':'page','page_size_param':'limit','page_size':2,'max_pages':1,
  'mappings':{'record_id':'id','status':{'path':'state','cast':'trim'},'owner':'owner.name'}}
 request('/rpc/save_api_source',{'p_id':source,'p_name':name,'p_config':{'description':'Controlled API test: pagination, restart, overlap and updates.','api':cfg,'editor':{'version':1,'kind':'api','queue':'ingest-ui'}},'p_queue':'ingest-ui'})
 def pull():return request('/rpc/start_source_pull',{'p_source_id':source,'p_external_id':'probe-'+str(uuid.uuid4())})
 def state():return request('/source_state?source_id=eq.'+source)[0]
 run1=pull();wait(run1);s=state();assert s['total_records']==2 and s['next_url'] and s['watermark'] is None,s
 fixture('fail');run2=pull()
 # Verify an HTTP failure left page 1 and its checkpoint intact.
 for _ in range(40):
  tasks=request('/tasks_api?run_id=eq.'+run2,schema='workflow')
  if tasks and tasks[0].get('error'):break
  time.sleep(.25)
 else:raise AssertionError('The fixture did not produce a visible failure')
 s=state();assert s['total_records']==2 and s['watermark'] is None and s['next_url'],s
 fixture('restore');wait(run2);s=state();assert s['total_records']==3 and s['watermark']=='2026-09-10T10:02:00Z' and s['next_url'] is None,s
 run3=pull();wait(run3);s=state();assert s['total_records']==3 and s['last_receipt']['unchanged']==2 and s['last_receipt']['inserted']==0,s
 fixture('advance');run4=pull();wait(run4);s=state();assert s['next_url'] and s['watermark']=='2026-09-10T10:02:00Z',s
 run5=pull();wait(run5);s=state();assert s['total_records']==4 and s['watermark']=='2026-09-10T10:04:00Z',s
 assert s['last_receipt']['updated']==1 and s['last_receipt']['inserted']==1,s
 records=request('/source_records?source_id=eq.'+source+'&external_id=eq.A');a=records[0]
 assert a['raw']['state']==' DONE ' and a['data']['status']=='DONE' and a['data']['owner']=='Maya',a
 run6=pull();wait(run6);s=state();assert s['total_records']==4 and s['last_receipt']['unchanged']==2 and s['last_receipt']['inserted']==0,s
 print(json.dumps({'source_id':source,'source':name,'runs':[run1,run2,run3,run4,run5,run6],'watermark':s['watermark'],'records':s['total_records'],'checks':'page cap, HTTP failure recovery, overlap dedup, one update plus one insert, original and transformed records, stable replay'},indent=2))
if __name__=='__main__':main()
