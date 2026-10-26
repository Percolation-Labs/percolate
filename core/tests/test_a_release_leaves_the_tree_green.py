"""A release leaves dev/check-version.sh and dev/check-releases.sh green.

0.1.9, 0.1.10 and 0.1.11 each published and left three hand edits undone -- the
README image pins, the spent version, the RELEASES.md row -- and every PR in the
repository was red until somebody made them (REM-150). release.yml now writes
that tail with `.github/scripts/after_release.py`, and decides the next number
with `bump_version.py release`, which counts from the latest tag because the
tail leaves the tree one patch ahead.

Each test builds a throwaway repository with the real scripts and gates in it,
so the proof is the gates themselves going red without the tail and green with
it -- not a reading of what the script writes.
"""
import importlib.util
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
# Split, so this file is not itself a pin dev/check-version.sh reads.
IMAGE = "percolationlabs/percolate-core" + ":"


def run(cwd, *cmd, check=True):
    return subprocess.run(cmd, cwd=cwd, check=check, capture_output=True, text=True)


class Tree:
    def __init__(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        for rel in ("dev/check-version.sh", "dev/check-releases.sh",
                    ".github/scripts/bump_version.py", ".github/scripts/after_release.py"):
            (self.dir / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, self.dir / rel)
        run(self.dir, "git", "init", "-q", "-b", "main")
        run(self.dir, "git", "config", "user.email", "t@example.com")
        run(self.dir, "git", "config", "user.name", "t")

    def write(self, rel, text):
        (self.dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.dir / rel).write_text(text)

    def version(self, v):
        self.write("pyproject.toml", f'[project]\nname = "percolate-core"\nversion = "{v}"\n')
        self.write("percolate_core/__init__.py", f'__version__ = "{v}"\n')
        self.write("uv.lock", f'version = 1\n\n[[package]]\nname = "percolate-core"\nversion = "{v}"\nsource = {{ editable = "." }}\n')

    def commit(self, msg):
        run(self.dir, "git", "add", "-A")
        run(self.dir, "git", "commit", "-qm", msg)
        return run(self.dir, "git", "rev-parse", "--short", "HEAD").stdout.strip()

    def tag(self, v):
        run(self.dir, "git", "tag", "-a", f"v{v}", "-m", v)

    def gate(self, name):
        return run(self.dir, f"dev/{name}", check=False)

    def read(self, rel):
        return (self.dir / rel).read_text()

    def bump_module(self):
        spec = importlib.util.spec_from_file_location(
            "bump_version_under_test", self.dir / ".github/scripts/bump_version.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


RELEASES = """# Releases

## Published versions

| Version | Tag | Commit | GitHub Release |
| -- | -- | -- | -- |
{rows}
Prose about the releases.
"""


class TheTailOfARelease(unittest.TestCase):
    def setUp(self):
        self.t = Tree()
        self.addCleanup(self.t.close)
        t = self.t
        # 0.1.11, published and fully accounted for.
        t.version("0.1.11")
        t.write("README.md", f"content: {{ image: {IMAGE}0.1.11 }}\nagent: {{ image: {IMAGE}0.1.11 }}\n")
        t.write("RELEASES.md", RELEASES.format(rows=""))
        t.write("CHANGELOG.md", "# Changelog\n\n## 0.1.11\n\nNotes.\n")
        sha11 = t.commit("0.1.11")
        t.tag("0.1.11")
        # 0.1.12 opens with its notes, and is then released.
        t.version("0.1.12")
        t.write("RELEASES.md", RELEASES.format(rows=f"| 0.1.11 | `v0.1.11` | `{sha11}` | yes |\n"))
        t.write("CHANGELOG.md",
                "# Changelog\n\n## 0.1.12 (unreleased)\n\n**Not published.** No tag yet,\n"
                "and nothing here can be installed.\n\n### A fix\n\nWhat it fixed.\n\n"
                "## 0.1.11\n\nNotes.\n")
        t.commit("0.1.12: bump")
        t.tag("0.1.12")
        # And then somebody's PR lands on top of the release, as it always does.
        t.write("feature.txt", "unrelated work\n")
        t.commit("somebody's next PR")

    def test_without_the_tail_both_gates_are_red(self):
        version = self.t.gate("check-version.sh")
        self.assertNotEqual(version.returncode, 0)
        self.assertIn("not 0.1.12", version.stderr)
        releases = self.t.gate("check-releases.sh")
        self.assertNotEqual(releases.returncode, 0)
        self.assertIn("v0.1.12 is published and RELEASES.md does not mention it", releases.stderr)

    def test_the_tail_turns_both_gates_green(self):
        out = run(self.t.dir, "python3", ".github/scripts/after_release.py", "0.1.12")
        self.t.commit("0.1.12: the tail")

        for gate in ("check-version.sh", "check-releases.sh"):
            result = self.t.gate(gate)
            self.assertEqual(result.returncode, 0, f"{gate}\n{result.stdout}{result.stderr}")

        self.assertEqual(self.t.read("README.md").count(IMAGE + "0.1.12"), 2)
        self.assertIn('version = "0.1.13"', self.t.read("pyproject.toml"))
        self.assertIn('__version__ = "0.1.13"', self.t.read("percolate_core/__init__.py"))
        # The image installs with `uv export --locked`, which refuses a lock
        # whose own version is behind pyproject's (REM-1151).
        self.assertIn('name = "percolate-core"\nversion = "0.1.13"', self.t.read("uv.lock"))
        changelog = self.t.read("CHANGELOG.md")
        self.assertIn("## 0.1.12\n\n### A fix", changelog)
        self.assertNotIn("Not published", changelog)
        self.assertIn("paragraph in RELEASES.md saying why 0.1.12 exists", out.stdout)

    def test_a_second_run_writes_nothing(self):
        run(self.t.dir, "python3", ".github/scripts/after_release.py", "0.1.12")
        self.t.commit("0.1.12: the tail")
        out = run(self.t.dir, "python3", ".github/scripts/after_release.py", "0.1.12")
        self.assertIn("nothing to write", out.stdout)
        self.assertEqual(run(self.t.dir, "git", "status", "--porcelain").stdout, "")

    def test_the_tail_refuses_a_version_that_is_not_tagged(self):
        result = run(self.t.dir, "python3", ".github/scripts/after_release.py", "0.1.13", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v0.1.13 is not tagged", result.stderr)


class TheNumberAReleasePublishes(unittest.TestCase):
    """bump_version.py release <part>, which counts from the latest tag."""

    def setUp(self):
        self.t = Tree()
        self.addCleanup(self.t.close)
        self.t.version("0.1.12")
        self.t.commit("0.1.12")
        self.t.tag("0.1.12")

    def decide(self, part, pypi=False):
        module = self.t.bump_module()
        with mock.patch.object(module, "on_pypi", return_value=pypi) as asked, \
                mock.patch("sys.argv", ["bump_version.py", "release", part]):
            module.main()
        return module.read_version(), asked

    def test_a_tagged_tree_bumps(self):
        self.assertEqual(self.decide("minor")[0], "0.2.0")

    def test_a_minor_release_steps_over_the_patch_the_tail_opened(self):
        self.t.version("0.1.13")
        self.t.commit("the tail")
        version, asked = self.decide("minor")
        self.assertEqual(version, "0.2.0")
        asked.assert_called_once_with("0.1.13")

    def test_a_patch_release_publishes_the_patch_the_tail_opened(self):
        self.t.version("0.1.13")
        self.t.commit("the tail")
        self.assertEqual(self.decide("patch")[0], "0.1.13")

    def test_an_unfinished_release_is_retried_by_dispatching_the_same_bump(self):
        self.t.version("0.2.0")
        self.t.commit("0.2.0: bump")
        version, asked = self.decide("minor")
        self.assertEqual(version, "0.2.0")
        asked.assert_not_called()

    def test_a_tree_set_further_ahead_by_hand_is_kept(self):
        self.t.version("1.0.0")
        self.t.commit("1.0.0 by hand")
        self.assertEqual(self.decide("minor")[0], "1.0.0")

    def test_bumping_past_a_half_published_version_is_refused(self):
        self.t.version("0.1.13")
        self.t.commit("0.1.13: bump")
        with self.assertRaises(SystemExit):
            self.decide("minor", pypi=True)
        self.assertEqual(self.t.bump_module().read_version(), "0.1.13")


if __name__ == "__main__":
    unittest.main()
