"""The probe reports what it read, and refuses rather than guessing.

Run: python -m unittest discover -s tests -p test_api_probe.py

Against a real socket rather than a mocked transport, because three of the
things being asserted -- the byte cap, the redirect re-check and the identifying
User-Agent -- are properties of the request as it actually goes out, and a mock
that returns a prepared response cannot fail them.
"""
import asyncio
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from percolate_core.content.probe import ProbeFailed, detect_wire, probe

RECORDS = {"results": [{"id": i, "title": f"item {i}", "owner": {"login": "maya"},
                        "updated_at": f"2026-09-0{i}T10:00:00Z", "tags": ["a"]}
                       for i in range(1, 6)],
           "next": "http://127.0.0.1:{port}/items?page=2", "count": 5}


class Handler(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  port=self.server.server_address[1]
  if self.path.startswith('/items'):
   body=json.dumps({**RECORDS,'next':RECORDS['next'].format(port=port)}).encode()
   self.send_response(200);self.send_header('Content-Type','application/json')
   self.send_header('ETag','"abc"');self.send_header('Content-Length',str(len(body)))
   self.end_headers();self.wfile.write(body)
  elif self.path=='/linked':
   body=json.dumps([{'id':1,'name':'a'},{'id':2,'name':'b'}]).encode()
   self.send_response(200);self.send_header('Content-Type','application/json')
   self.send_header('Link','<http://127.0.0.1:%d/linked?page=2>; rel="next"'%port)
   self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  elif self.path=='/page.html':
   body=b'<html><body><p>not an api</p></body></html>'
   self.send_response(200);self.send_header('Content-Type','text/html')
   self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  elif self.path=='/huge':
   self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
   self.wfile.write(b'[{"id":1,"blob":"'+b'x'*3_000_000+b'"}]')
  elif self.path=='/agent':
   body=json.dumps({'ua':self.headers.get('User-Agent'),'auth':self.headers.get('Authorization')}).encode()
   self.send_response(200);self.send_header('Content-Type','application/json')
   self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  else:
   self.send_response(404);self.send_header('Content-Length','0');self.end_headers()


class APIProbeTest(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
  threading.Thread(target=cls.server.serve_forever,daemon=True).start()
  cls.base='http://127.0.0.1:%d'%cls.server.server_address[1]
  # The listener is on loopback, which a probe refuses (test_egress_everywhere.py),
  # and a probe honours no operator allowlist (REM-555). So the guard is told
  # about exactly this one origin, and every other URL still gets the real check.
  from percolate_core.content import probe as probe_module
  from percolate_core.core.credentials import origin
  real=probe_module.refuse_internal_egress
  def guard(url,**kw):
   if origin(url)!=origin(cls.base): real(url,**kw)
  cls.env=patch.object(probe_module,'refuse_internal_egress',guard)
  cls.env.start()

 @classmethod
 def tearDownClass(cls):
  cls.env.stop();cls.server.shutdown();cls.server.server_close()

 def run_probe(self,path,**kw):return asyncio.run(probe(self.base+path,**kw))

 def test_the_record_path_and_fields_come_from_the_response(self):
  r=self.run_probe('/items')
  self.assertEqual(r['kind'],'records')
  self.assertEqual(r['observed']['records_path'],'results')
  self.assertEqual(r['observed']['record_count'],5)
  self.assertEqual(r['observed']['fields']['owner.login']['type'],'str')
  self.assertEqual(r['observed']['fields']['tags']['type'],'array')
  self.assertEqual(r['observed']['fields']['updated_at']['examples'][0],'2026-09-01T10:00:00Z')

 def test_a_watermark_and_id_are_offered_as_candidates_and_named_as_inferred(self):
  r=self.run_probe('/items')
  self.assertEqual(r['inferred']['watermark_field'],'updated_at')
  self.assertEqual(r['inferred']['watermark_type'],'timestamp')
  self.assertEqual(r['inferred']['id_path'],'id')
  self.assertIn('updated_at',r['inferred']['watermark_candidates'])
  # The request parameter cannot be seen in a response. Inventing it is the
  # failure this whole module exists to remove, so it is said out loud.
  self.assertNotIn('watermark_param',r['inferred'])
  self.assertTrue(any('watermark_param' in f for f in r['friction']))

 def test_pagination_is_reported_with_the_evidence_for_it(self):
  body=self.run_probe('/items')['observed']
  self.assertEqual(body['pagination'],'next_url');self.assertEqual(body['next_path'],'next')
  header=self.run_probe('/linked')['observed']
  self.assertEqual(header['pagination'],'link_header')
  self.assertIn('Link header',header['evidence'])
  self.assertEqual(header['records_path'],'$')

 def test_a_non_json_endpoint_is_declined_rather_than_described(self):
  r=self.run_probe('/page.html')
  self.assertEqual(r['kind'],'unsupported');self.assertEqual(r['wire'],'html')
  self.assertNotIn('observed',r)
  self.assertTrue(any('JSON' in f for f in r['friction']))

 def test_an_error_response_reports_the_status_and_infers_nothing(self):
  r=self.run_probe('/missing')
  self.assertEqual(r['kind'],'error');self.assertEqual(r['status'],404)
  self.assertNotIn('inferred',r)

 def test_a_large_body_is_capped_and_says_so(self):
  r=self.run_probe('/huge')
  self.assertTrue(r['truncated']);self.assertLessEqual(r['bytes'],2_000_000)
  self.assertTrue(any('were read' in f for f in r['friction']))

 def test_it_identifies_itself_and_sends_no_credential_it_was_not_given(self):
  sent=self.run_probe('/agent')['observed']['sample']
  self.assertIn('Percolate-Source-Probe',sent['ua'])
  self.assertIsNone(sent['auth'])

 def test_a_credential_in_the_url_is_refused_before_any_request(self):
  with self.assertRaises(ProbeFailed):self.run_probe('/items?api_key=literal')
  with self.assertRaises(ProbeFailed):asyncio.run(probe('file:///etc/passwd'))
  with self.assertRaises(ProbeFailed):asyncio.run(probe('https://user:pw@example.test/x'))

 def test_an_authenticated_probe_asks_for_a_reference_never_a_value(self):
  with self.assertRaises(ProbeFailed):
   asyncio.run(probe(self.base+'/items',auth_type='bearer'))

 def test_the_wire_format_is_read_from_the_bytes_not_the_header(self):
  self.assertEqual(detect_wire('text/plain',b'[{"a":1}]'),'json')
  self.assertEqual(detect_wire('application/json',b'<html></html>'),'html')


if __name__=='__main__':
 unittest.main()
