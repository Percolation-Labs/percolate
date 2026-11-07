import unittest
from percolate_core.query.renderers import normalize_renderer, describe_renderer
from percolate_core.query import canvas_tool

class RendererTests(unittest.TestCase):
    def test_explicit_card_layout_normalizes_and_returns(self):
        request=normalize_renderer({'action':'query','renderer':{'type':'cards','title':'name','fields':['status']}})
        self.assertEqual(request['options'],{'card_title':'name','card_fields':['status']})
        doc=describe_renderer({'view':{'control':'cards','options':request['options']}})
        self.assertEqual(doc['view']['renderer'],{'type':'cards','title':'name','fields':['status']})

    def test_bad_renderer_is_rejected_before_database_query(self):
        class NoCalls:
            def rpc(self,*args,**kwargs):raise AssertionError('Invalid renderer reached database')
        for renderer in ({'type':'cards'}, {'type':'plot','x':'name','y':'count'}, {'type':'graph','source':'a'}, {'type':'html'}, {'type':'table','title':'name'}, {'type':'cards','title':'name','fields':[{}]}):
            result=canvas_tool.call(NoCalls(),{'action':'query','statement':'select 1','renderer':renderer},None)
            self.assertTrue(result['isError'])

    def test_no_conflicting_configuration_and_legacy_is_preserved(self):
        with self.assertRaises(ValueError):normalize_renderer({'action':'view','control':'plot','renderer':{'type':'table'}})
        original={'action':'view','control':'plot','options':{'x':'name','y':'count','form':'bar'}}
        self.assertEqual(normalize_renderer(original),original)
