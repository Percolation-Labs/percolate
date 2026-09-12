"""One database and one object store, whoever is asking.

Run: python -m unittest discover -s tests -p test_one_config.py

`P8_DSN` and `P8_DATABASE_URL` name the same thing, and three places read them
three ways: the pool in `core/identity.py` took `P8_DSN` first, the agent
runtime in `agentic/settings.py` took `P8_DATABASE_URL` first and fell back to
`postgresql://p8:p8@localhost:5500/p8agentic`, and `core/config.dsn()` required
`P8_DSN` alone and had no callers at all. A process that opens the core pool and
runs the agent runtime with both variables set gets TWO databases, and nothing
anywhere says so — which is the thing this file makes loud.

The silent default is the other half. `agent serve` restart-looped on `Connect
call failed ('127.0.0.1', 5500)` in a stack where every other service had
connected fine, because that runtime read one of the two names, found it unset,
and quietly used a database that was not there.

The S3 half is the same shape with one difference worth preserving: the three
readers disagreed about the endpoint default and the bucket, and they disagree
DELIBERATELY about what absence means — the Content Server raises, the lake
returns None. So the settings are shared and that policy is not, and both halves
are asserted here.
"""
import os
import unittest
from unittest.mock import patch

from percolate_core.core import ConfigError, s3
from percolate_core.core.config import dsn

BOTH = {"P8_DSN": "postgres://host/shared", "P8_DATABASE_URL": "postgres://host/specific"}


class OneDatabaseTest(unittest.TestCase):
    def test_two_variables_two_databases_one_answer(self):
        """The defect, written as a test: both set, pointing at different
        databases, and every reader has to name the same one."""
        with patch.dict(os.environ, BOTH, clear=False):
            from percolate_core.agentic.settings import Settings
            self.assertEqual(dsn(), "postgres://host/specific")
            self.assertEqual(Settings.from_env().database_url, dsn())

    def test_the_specific_name_wins_and_either_alone_is_enough(self):
        """`P8_DATABASE_URL` wins because it is the specific one: a deployment
        that sets it is pointing this process somewhere other than the shared
        DSN on purpose. Either name alone still works."""
        with patch.dict(os.environ, {"P8_DSN": "postgres://host/shared"}, clear=True):
            self.assertEqual(dsn(), "postgres://host/shared")
        with patch.dict(os.environ, {"P8_DATABASE_URL": "postgres://host/specific"}, clear=True):
            self.assertEqual(dsn(), "postgres://host/specific")

    def test_an_unset_database_is_a_failure_with_a_message_not_a_guess(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ConfigError) as caught:
                dsn()
        # Both names, because being told about one of two is how somebody sets
        # the other and reads the same error again.
        self.assertIn("P8_DATABASE_URL", str(caught.exception))
        self.assertIn("P8_DSN", str(caught.exception))
        self.assertNotIn("5500", str(caught.exception))

    def test_the_runtime_no_longer_carries_a_localhost_fallback(self):
        """The fallback is gone from the module, not just unreachable."""
        from pathlib import Path
        settings = Path(__file__).resolve().parents[1] / "percolate_core/agentic/settings.py"
        body = settings.read_text()
        self.assertNotIn("localhost:5500", body.replace("# ", "").split("database_url")[1][:400])


class OneObjectStoreTest(unittest.TestCase):
    ENV = {"P8_S3_ENDPOINT": "https://obj.test", "P8_S3_KEY": "k", "P8_S3_SECRET": "s",
           "P8_S3_REGION": "eu-west-1", "P8_BUCKET": "shared-bucket"}

    def test_every_reader_gets_the_same_endpoint_region_and_bucket(self):
        with patch.dict(os.environ, self.ENV, clear=True):
            from percolate_core.content import storage
            from percolate_core.lake.engine import lake
            settings, pond = s3(), lake()
            self.assertEqual(settings.endpoint, "https://obj.test")
            self.assertEqual(storage.bucket(), settings.bucket)
            self.assertEqual((pond.endpoint, pond.region, pond.bucket),
                             (settings.endpoint, settings.region, settings.bucket))

    def test_the_lake_keeps_its_own_bucket_and_its_own_answer_to_absence(self):
        """Two things that are NOT shared, on purpose: the lake reads
        `P8_LAKE_BUCKET` first, and a lake with no credentials is None rather
        than an error — a refine step over inline rows needs no object store."""
        from percolate_core.lake.engine import lake
        with patch.dict(os.environ, {**self.ENV, "P8_LAKE_BUCKET": "lake-bucket"}, clear=True):
            self.assertEqual(lake().bucket, "lake-bucket")
            self.assertEqual(s3().bucket, "shared-bucket")
        with patch.dict(os.environ, {"P8_S3_ENDPOINT": "https://obj.test"}, clear=True):
            self.assertIsNone(lake())

    def test_duckdb_gets_the_endpoint_in_the_shape_it_wants(self):
        """`s3_endpoint` takes a host, not a URL, and ssl is a separate setting.
        That conversion was open-coded in the reader this issue deleted."""
        with patch.dict(os.environ, {"P8_S3_ENDPOINT": "https://obj.test"}, clear=True):
            self.assertEqual(s3().host, "obj.test")
            self.assertTrue(s3().use_ssl)
        with patch.dict(os.environ, {"P8_S3_ENDPOINT": "http://localhost:9000"}, clear=True):
            self.assertEqual(s3().host, "localhost:9000")
            self.assertFalse(s3().use_ssl)


if __name__ == "__main__":
    unittest.main()
