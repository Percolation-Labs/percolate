"""Continue the scripted rehearsal using a node actually clicked in the browser."""
import json
from pathlib import Path
from canvas_walkthrough import mcp, EDGES_SQL
from canvas_call import call
out=Path('.local/canvas-walkthrough')
touch=json.loads((out/'graph-selection.json').read_text())
node=touch['nodes'][0]
# Quote the value as SQL data; identifiers remain fixed by this recipe.
value="'"+node.replace("'","''")+"'"
sql='select * from ('+EDGES_SQL+') edges where source='+value+' or target='+value
result=mcp('canvas',{'action':'query','statement':sql,'caption':'Relationships of '+node})
full=call('read',{})['view']['result']
mcp('canvas',{'action':'view','control':'graph','options':{'source':'source','target':'target','relation':'relation'}})
with (out/'conversation.md').open('a') as f:
    f.write('\n**User (simulated, after clicking a node):** Show only relationships involving the table I selected.\n\n**Assistant:** Your canvas selection was `'+node+'`. The live follow-up query returned '+str(len(full['rows']))+' relationships, now displayed as a graph.\n\n```sql\n'+sql+'\n```\n\n```json\n'+json.dumps(full['rows'],indent=2)+'\n```\n')
print('PASS selected node '+node+' drove a real SQL follow-up: '+str(len(full['rows']))+' relationships.')
