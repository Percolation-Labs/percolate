import unittest
from percolate_core.query.canvas_tool import call

class Upstream:
    def __init__(self, rows=None, error=None):
        self.calls=[]; self.rows=rows if rows is not None else [{'source':'a','target':'b'}]; self.error=error
    def rpc(self, name, body, auth, schema):
        self.calls.append((name,body,auth,schema))
        if name=='sql_passthrough': return self.rows,self.error
        return {},None

class CanvasSQL(unittest.TestCase):
    def test_sql_uses_caller_then_presents_result(self):
        up=Upstream(); result=call(up,{'action':'query','statement':'select 1'},'Bearer caller')
        self.assertFalse(result.get('isError'))
        self.assertEqual(up.calls[0],('sql_passthrough',{'p_statement':'select 1'},'Bearer caller','aiq'))
        self.assertEqual(up.calls[1][1]['p_action'],'present')
        self.assertEqual(up.calls[1][1]['p_body']['columns'],['source','target'])
        self.assertTrue(all(c[2]=='Bearer caller' for c in up.calls))
    def test_denied_query_never_replaces_view(self):
        up=Upstream(error={'message':'permission denied'})
        self.assertTrue(call(up,{'action':'query','statement':'select secret'},'caller')['isError'])
        self.assertEqual(len(up.calls),1)
    def test_oversize_result_never_replaces_view(self):
        up=Upstream(rows=[{'x':1}]*501)
        self.assertTrue(call(up,{'action':'query','statement':'select x'},'caller')['isError'])
        self.assertEqual(len(up.calls),1)
