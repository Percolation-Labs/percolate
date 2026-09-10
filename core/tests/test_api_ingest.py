import os
import unittest
from unittest.mock import patch
import httpx
from percolate_core.ingest.api import APIConfig,at,first_url,next_page,map_record,request_headers,timestamp,compare_value
from percolate_core.worker.templates import TerminalError


class APIIngestTest(unittest.TestCase):
 def test_timestamp_overlap_is_sent_in_utc(self):
  c=APIConfig(url='https://example.test/items',params={'state':'all'},overlap_seconds=60)
  url=httpx.URL(first_url(c,'2026-09-10T11:00:00+01:00'))
  self.assertEqual(url.params['since'],'2026-09-10T09:59:00Z')
  self.assertEqual(url.params['state'],'all')
  with self.assertRaises(TerminalError): timestamp('2026-09-10T11:00:00')

 def test_numeric_watermarks_do_not_use_lexicographic_order(self):
  self.assertGreater(compare_value('10','number'),compare_value('9','number'))
  with self.assertRaises(TerminalError):compare_value('NaN','number')

 def test_record_mapping_renames_and_casts_without_changing_original(self):
  row={'id':1,'owner':{'name':' Maya '},'amount':'2.5','flag':'false'}
  self.assertEqual(map_record(row,{'owner':{'path':'owner.name','cast':'trim'},'amount':{'path':'amount','cast':'number'},'flag':{'path':'flag','cast':'boolean'}}),{'owner':'Maya','amount':2.5,'flag':False})
  self.assertEqual(row['owner']['name'],' Maya ')
  with self.assertRaises(TerminalError):map_record(row,{'missing':'other.id'})
  with self.assertRaises(TerminalError):map_record(row,{'id':{'path':'id','cast':'eval'}})

 def test_missing_record_path_is_not_an_empty_success(self):
  with self.assertRaises(TerminalError):at({'items':[]},'data.items')
  self.assertEqual(at({'data':{'items':[]}},'$.data.items'),[])

 def test_link_pagination_follows_only_the_configured_origin(self):
  c=APIConfig(url='https://example.test/items')
  def response(n):return httpx.Response(200,headers={'Link':f'<{n}>; rel="next"'},request=httpx.Request('GET',c.url))
  self.assertEqual(next_page(c,response('?page=2'),[],2),'https://example.test/items?page=2')
  with self.assertRaises(TerminalError):next_page(c,response('https://other.test/items'),[],2)

 def test_body_cursor_needs_explicit_end_and_page_numbers_need_short_page(self):
  c=APIConfig(url='https://example.test/items',pagination='page_token',page_param='cursor',next_path='next')
  r=httpx.Response(200,request=httpx.Request('GET',c.url))
  self.assertIn('cursor=abc',next_page(c,r,{'next':'abc'},2))
  self.assertIsNone(next_page(c,r,{'next':None},0))
  with self.assertRaises(TerminalError):next_page(c,r,{},0)
  c.pagination='page';c.page_param='page';c.page_size=2
  self.assertIn('page=2',next_page(c,r,[],2));self.assertIsNone(next_page(c,r,[],1))

 def test_credentials_are_origin_bound_and_never_literal_headers(self):
  c=APIConfig(url='https://example.test/items',auth_type='bearer',credential_ref='API_TEST_KEY')
  with patch.dict(os.environ,{'API_TEST_KEY':'fixture-only','P8_INGEST_CREDENTIAL_ORIGINS':'{}'}):
   with self.assertRaises(TerminalError):request_headers(c)
  with patch.dict(os.environ,{'API_TEST_KEY':'fixture-only','P8_INGEST_CREDENTIAL_ORIGINS':'{"API_TEST_KEY":["https://example.test"]}'}):
   self.assertEqual(request_headers(c)['Authorization'],'Bearer fixture-only')
  with self.assertRaises(TerminalError):request_headers(APIConfig(url=c.url,headers={'Authorization':'literal'}))
  with self.assertRaises(TerminalError):request_headers(APIConfig(url=c.url+'?access_token=literal'))
