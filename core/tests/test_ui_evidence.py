"""The optional recorded example serves only its explicit files, locally, and is off by default."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from percolate_core.ui.server import build_app


class EvidenceExample(unittest.TestCase):
    def test_disabled_without_operator_configuration(self):
        with patch.dict(os.environ, {}, clear=True), TestClient(build_app(), client=('127.0.0.1', 123)) as client:
            self.assertFalse(client.get('/config.json').json()['evidence_example'])
            self.assertEqual(client.get('/example/cases.json').status_code, 404)

    def test_only_named_example_files_are_served_to_loopback(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'cases.json').write_text('{"cases":[]}')
            Path(directory, 'private.txt').write_text('not an asset')
            with patch.dict(os.environ, {'P8_UI_EVIDENCE_EXAMPLE': directory}):
                with TestClient(build_app(), client=('127.0.0.1', 123)) as client:
                    response=client.get('/example/cases.json')
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(response.json(), {'cases': []})
                    self.assertEqual(response.headers['cache-control'], 'no-store')
                    self.assertEqual(client.get('/example/private.txt').status_code, 404)
                with TestClient(build_app(), client=('192.0.2.1', 123)) as client:
                    self.assertEqual(client.get('/example/cases.json').status_code, 404)
