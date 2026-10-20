#!/usr/bin/env python3
"""A version bump moves every versioned reference, or changes nothing (REM-254).

    python3 .github/scripts/test_bump_extension_version.py

Against a throwaway git repository holding the files the bump edits, with the
two generators replaced by stubs that can be told to fail. The real generators
take minutes and need the specs; what is under test is the bump's own promise,
which a stub that fails on cue exercises exactly.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).resolve().parent / "bump_extension_version.py"
# Run from dev/check.sh inside the pre-push hook, GIT_DIR points at the pushing repository.
CLEAN = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
# The sql directory's path, joined here rather than written out: a literal
# `extension/percolate/sql/percolate--<v>.sql` in this file is what the bump moves and what
# dev/references.sh resolves, and a fixture is neither a live reference nor a path that exists.
SQL_PATH = "extension/percolate/" + "sql/"

BUILD_SQL = """\
import os, pathlib, re, sys
root = pathlib.Path(__file__).resolve().parents[2]
v = re.search(r"default_version = '([^']+)'", (root / "extension/percolate/percolate.control").read_text()).group(1)
sql = root / "extension/percolate/sql"
(sql / f"percolate--{v}.sql").write_text("-- built\\n")
(sql / f"percolate--0.2.5--{v}.sql").write_text("-- upgrade\\n")
if os.environ.get("BUMP_TEST_FAIL") == "build":
    sys.exit("build-sql stub: failing on cue, after writing")
"""

WRITE_UPGRADES = """\
import os, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
(root / "extension/percolate_parser/sql/percolate_parser--0.2.5--new.sql").write_text("-- parser\\n")
if os.environ.get("BUMP_TEST_FAIL") == "upgrades":
    sys.exit("write-upgrades stub: failing on cue, after the old base script was deleted")
"""

MANIFEST = """\
# percolate--0.1.0.sql in a comment is history and never moves
volumeMounts:
  - name: extension-sql
    mountPath: /usr/share/postgresql/19/extension/percolate--0.2.5.sql
    subPath: percolate--0.2.5.sql
"""


def sh(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True, env=env or CLEAN).stdout


class Bump(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="bump-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        root = self.root = self.tmp / "tree"
        files = {
            "extension/percolate/percolate.control": "comment = 'percolate'\ndefault_version = '0.2.5'\n",
            "extension/percolate_parser/percolate_parser.control": "default_version = '0.2.5'\n",
            "extension/percolate_parser/Cargo.toml": '[package]\nname = "percolate_parser"\nversion = "0.2.5"\n',
            "extension/percolate_parser/Cargo.lock": '[[package]]\nname = "percolate_parser"\nversion = "0.2.5"\n',
            "extension/percolate/contract.json": '{\n  "extension": "0.2.5",\n  "enums": {}\n}\n',
            SQL_PATH + "percolate--0.2.5.sql": "-- 0.2.5\n",
            SQL_PATH + "percolate--0.2.4--0.2.5.sql": "-- upgrade to 0.2.5\n",
            "extension/percolate_parser/sql/percolate_parser--0.2.4--0.2.5.sql": "-- parser upgrade\n",
            "extension/percolate/build-sql.py": BUILD_SQL,
            "extension/percolate_parser/write-upgrades.py": WRITE_UPGRADES,
            "k8s/kind/manifests/postgres.yaml": MANIFEST,
            "specs/tables/source/page.html": '<a href="../../' + SQL_PATH + 'percolate--0.2.5.sql">sql</a>\n',
            "research-notes/results/graph.json": '{"f": "' + SQL_PATH + 'percolate--0.2.5.sql"}\n',
        }
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (root / "dev/lib").mkdir(parents=True)
        shutil.copy(REPO / "dev/lib/python.sh", root / "dev/lib/python.sh")
        for cmd in (["init", "-q", "-b", "main"], ["config", "user.name", "test"],
                    ["config", "user.email", "test@example.com"], ["add", "-A"], ["commit", "-qm", "seed"]):
            sh("git", *cmd, cwd=root)
        # A yaml module the stub interpreter can import, so the test does not depend on PyYAML.
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        (self.stubs / "yaml.py").write_text("")

    def bump(self, **env):
        run = {**CLEAN, "PERCOLATE_BUMP_ROOT": str(self.root), "PY": sys.executable,
               "PYTHONPATH": str(self.stubs), **env}
        return subprocess.run([sys.executable, str(SCRIPT), "patch"], cwd=self.root, env=run,
                              capture_output=True, text=True)

    def status(self):
        return sh("git", "status", "--porcelain", cwd=self.root)

    def test_a_bump_moves_every_path_reference_and_leaves_history_alone(self):
        done = self.bump()
        self.assertEqual(done.returncode, 0, done.stderr)
        read = lambda name: (self.root / name).read_text()
        self.assertIn("default_version = '0.2.6'", read("extension/percolate/percolate.control"))
        self.assertIn('"extension": "0.2.6"', read("extension/percolate/contract.json"))
        self.assertIn("percolate--0.2.6.sql", read("specs/tables/source/page.html"))
        self.assertIn("percolate--0.2.5.sql", read("research-notes/results/graph.json"))
        self.assertIn("percolate--0.1.0.sql", read("k8s/kind/manifests/postgres.yaml"))
        self.assertEqual(read("k8s/kind/manifests/postgres.yaml").count("percolate--0.2.6.sql"), 2)
        sql = sorted(p.name for p in (self.root / "extension/percolate/sql").iterdir())
        self.assertEqual(sql, ["percolate--0.2.5--0.2.6.sql", "percolate--0.2.6.sql"])

    def test_a_generator_failing_midway_leaves_git_status_clean(self):
        for stage in ("build", "upgrades"):
            with self.subTest(stage=stage):
                failed = self.bump(BUMP_TEST_FAIL=stage)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn("back as it was", failed.stderr)
                self.assertEqual(self.status(), "", failed.stderr)

    def test_an_interpreter_without_yaml_refuses_before_writing(self):
        (self.stubs / "yaml.py").unlink()
        refused = self.bump(PYTHONPATH="", PY=str(self.stubs / "no-python"))
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("nothing was changed", refused.stderr)
        self.assertEqual(self.status(), "")

    def test_a_tree_without_the_kind_manifest_still_bumps(self):
        # Percolation-Labs/percolate carries no k8s/: the kind stack stays in
        # the private deployment repository. Every other reference still moves.
        sh("git", "rm", "-q", "k8s/kind/manifests/postgres.yaml", cwd=self.root)
        sh("git", "commit", "-qm", "no kind manifest", cwd=self.root)
        done = self.bump()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("not in this tree", done.stdout)
        read = lambda name: (self.root / name).read_text()
        self.assertIn("default_version = '0.2.6'", read("extension/percolate/percolate.control"))
        self.assertIn("percolate--0.2.6.sql", read("specs/tables/source/page.html"))

    def test_a_rule_that_no_longer_matches_refuses_before_writing(self):
        (self.root / "k8s/kind/manifests/postgres.yaml").write_text("volumeMounts: []\n")
        sh("git", "commit", "-qam", "manifest without a mount", cwd=self.root)
        refused = self.bump()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("mountPath", refused.stderr)
        self.assertEqual(self.status(), "")


if __name__ == "__main__":
    unittest.main()
