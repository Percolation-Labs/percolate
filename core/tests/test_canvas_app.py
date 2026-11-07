import unittest
from percolate_core.query import canvas_app, canvas_tool

class Upstream:
    def __init__(self): self.calls=[]
    def rpc(self,name,body,auth,schema):
        self.calls.append((name,body,auth,schema))
        return {'session':'one','view':{'result':{'rows':[{'n':n} for n in range(20)]}}},None

class CanvasApp(unittest.TestCase):
    def test_read_keeps_full_rows_and_does_not_consume(self):
        up=Upstream();result=canvas_app.call(up,{'action':'read'},'Bearer person')
        self.assertEqual(len(result['structuredContent']['view']['result']['rows']),20)
        self.assertEqual(up.calls,[('canvas',{'p_action':'read','p_body':{}},'Bearer person','workflow')])
    def test_ui_cannot_query_or_consume(self):
        for action in ('query','consume','present','open','close'):
            up=Upstream();self.assertTrue(canvas_app.call(up,{'action':action},None)['isError']);self.assertEqual(up.calls,[])
    def test_ui_selection_forwards_identity(self):
        up=Upstream();body={'kind':'selection','result_set':'result','rows':[1],'columns':['source'],'nodes':['a']}
        canvas_app.call(up,{'action':'touch',**body},'Bearer person')
        self.assertEqual(up.calls,[('canvas',{'p_action':'touch','p_body':body},'Bearer person','workflow')])
    def test_resource_and_tool_are_linked(self):
        self.assertEqual(canvas_tool.TOOL['_meta']['ui']['resourceUri'],canvas_app.URI)
        resource=canvas_app.resource()['contents'][0]
        self.assertEqual(resource['mimeType'],'text/html;profile=mcp-app')
        self.assertEqual(resource['_meta']['ui']['csp']['connectDomains'],[])
        self.assertTrue('p8-token' not in resource['text'])
