"""Small deterministic API for exercising cursor recovery; never external data.
Run in the dev network on port 8091. POST /advance changes a record and adds one.
POST /fail makes page 2 return 503 until restored; POST /restore clears that fault.
"""
import json
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qs,urlencode
rows=[{'id':'A','updated_at':'2026-09-10T10:00:00Z','state':' OPEN ','owner':{'name':'Maya'}},
      {'id':'B','updated_at':'2026-09-10T10:01:00Z','state':' OPEN ','owner':{'name':'Theo'}},
      {'id':'C','updated_at':'2026-09-10T10:02:00Z','state':' DONE ','owner':{'name':'Maya'}}]
fail=False
class API(BaseHTTPRequestHandler):
 def reply(self,status,data):
  raw=json.dumps(data).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def do_GET(self):
  global fail
  q=parse_qs(urlsplit(self.path).query);page=int(q.get('page',['1'])[0]);size=int(q.get('limit',['2'])[0]);since=q.get('since',[''])[0]
  if fail and page==2: self.reply(503,{'error':'fixture interruption'});return
  found=sorted((r for r in rows if r['updated_at']>=since),key=lambda r:r['updated_at']);start=(page-1)*size
  nxt='/records?'+urlencode({'page':page+1,'limit':size,'since':since}) if start+size<len(found) else None
  self.reply(200,{'items':found[start:start+size],'next':nxt})
 def do_POST(self):
  global fail
  path=urlsplit(self.path).path
  if path=='/advance':
   rows[0].update(state=' DONE ',updated_at='2026-09-10T10:03:00Z')
   if not any(r['id']=='D' for r in rows):rows.append({'id':'D','updated_at':'2026-09-10T10:04:00Z','state':' OPEN ','owner':{'name':'Nora'}})
  elif path=='/fail':fail=True
  elif path=='/restore':fail=False
  else:self.reply(404,{});return
  self.reply(200,{'ok':True})
 def log_message(self,*args):pass
ThreadingHTTPServer(('0.0.0.0',8091),API).serve_forever()
