"""Live regression for the three issues reported from Claude's tool calls."""
from canvas_walkthrough import mcp
from canvas_call import call
first=mcp('canvas',{'action':'open'})
opened=mcp('canvas',{'action':'open'})
assert opened['session_action']=='resumed' and opened['session']==first['session']
q=mcp('canvas',{'action':'query','query':'workflow_runs','control':'cards','options':{'card_title':'status','card_fields':['runs']}})
assert q['view']['control']=='cards' and q['selection'] is None
rid=q['view']['result']['id']
call('touch',{'kind':'selection','result_set':rid,'rows':[0],'columns':['status','runs']})
q=mcp('canvas',{'action':'query','statement':'select 1 as amount, \'one\' as label','control':'plot','options':{'x':'label','y':'amount','form':'bar'}})
assert q['view']['control']=='plot' and q['selection'] is None
assert not any(t['kind']=='selection' for t in q['since_last_call'])
before=call('read',{})
try:
 mcp('canvas',{'action':'query','query':'workflow_runs','control':'graph'})
except RuntimeError:pass
else:raise AssertionError('Invalid graph accepted')
after=call('read',{})
assert after['view']==before['view'] and after['version']==before['version']
print('PASS MCP: explicit resume, query cards, SQL query plot, fresh selection, no stale touches, invalid view rollback.')
