"""The UI's read contracts are shared, complete, and served.

Run: python -m unittest discover -s tests -p test_ui_reads.py
No database, no browser, no provider. The live half -- do these reads actually
return 200 against a deployment -- is `dev/ui_reads.py` and the Surface screen,
because only a real database can answer it.

What is guarded here is the structure that made the live check possible at all.
Five screens shipped asking PostgREST for columns no view has (`structured_
output`, `transport`, `name`, `created_at`, `event`) while the in-app audit
reported every object reachable, because each side wrote its own query: the
screen a projection, the audit a bare `limit=1`. Nothing could have caught that
except running the screen's own query, and nothing ran it.

So: projections live in reads.js, screens read through `read()`, and the audit
executes the same contract. A screen that goes back to hand-writing a
projection puts itself outside the audit again -- silently, and that is the
regression this file exists to make loud.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

from percolate_core.ui.server import ASSETS

STATIC = Path(__file__).resolve().parents[1] / "percolate_core" / "ui" / "static"

# The data layer and the contract table. Every OTHER module is a screen, found
# rather than listed: a rule that names the two files that existed when it was
# written is a rule the next screen is exempt from, which is how the first five
# broken projections got in.
PLUMBING = {"api.js", "reads.js", "ui.js", "md.js"}
SCREENS = tuple(sorted(p.name for p in STATIC.glob("*.js") if p.name not in PLUMBING))


def _node_json(script: str) -> object:
    out = subprocess.run(["node", "--input-type=module", "-e", script],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


class ReadContractTest(unittest.TestCase):
    def test_every_imported_module_is_served(self):
        """A module missing from ASSETS 404s and takes the whole page with it.

        `reads.js` was one edit away from being exactly that: a new module the
        page imports and the server does not list.
        """
        imported = set()
        for path in STATIC.iterdir():
            if path.suffix not in (".js", ".html"):
                continue
            imported |= set(re.findall(r'(?:from|import)\s+"\./([\w.-]+\.js)"', path.read_text()))
        self.assertTrue(imported, "found no module imports at all -- did the pattern rot?")
        for module in sorted(imported):
            with self.subTest(module=module):
                self.assertIn(module, ASSETS, f"{module} is imported but not served")

    def test_screens_do_not_hand_write_projections(self):
        """The projection belongs to the contract the audit runs, or to nobody.

        A `select=` inside a screen file is a read that Surface and
        `dev/ui_reads.py` cannot execute, which is the exact shape of the bug
        this whole arrangement removed.
        """
        for name in SCREENS:
            with self.subTest(screen=name):
                body = (STATIC / name).read_text()
                offenders = [line.strip() for line in body.splitlines() if "select=" in line]
                self.assertEqual(offenders, [], f"{name} hand-writes a projection: {offenders}")

    def test_reads_js_imports_nothing(self):
        """It is data, and `dev/ui_reads.py` imports it with a bare node.

        One `import` of api.js here (which touches localStorage at module
        scope) and the headless audit stops running -- in CI, quietly, while
        the browser still works.
        """
        body = (STATIC / "reads.js").read_text()
        self.assertNotIn("\nimport ", "\n" + body)


@unittest.skipUnless(shutil.which("node"), "node reads reads.js; nothing else should try")
class ContractTableTest(unittest.TestCase):
    """Read the table with the runtime that owns the syntax, never a regex."""

    @classmethod
    def setUpClass(cls):
        uri = (STATIC / "reads.js").as_uri()
        cls.table = _node_json(
            f"import({json.dumps(uri)}).then((m) => "
            "console.log(JSON.stringify({reads: m.READS, probes: m.PROBES})))")

    def test_every_contract_is_complete(self):
        for key, c in self.table["reads"].items():
            with self.subTest(contract=key):
                self.assertIn("screen", c, "Surface prints this; a read with no screen has no owner")
                self.assertIn(c["schema"], ("workflow", "rbac", "agentic", "content", "aiq"))
                self.assertTrue(c["view"], "a contract names one view")
                self.assertIsInstance(c.get("q"), str, "q is a string, empty for a whole-row read")
                self.assertNotIn("limit=", c["q"], f"{key}: the bound is the screen's, not the contract's")

    def test_no_contract_is_dead(self):
        """A contract no screen uses is a claim the audit makes on nobody's behalf."""
        body = "".join((STATIC / name).read_text() for name in SCREENS)
        for key in self.table["reads"]:
            with self.subTest(contract=key):
                self.assertIn(f"READS.{key}", body, f"{key} is audited and never read")

    def test_existence_probes_say_why(self):
        """These cannot count towards 'the screens work', so they must justify themselves."""
        for p in self.table["probes"]:
            with self.subTest(probe=p["view"]):
                self.assertTrue(p.get("why"), "an existence-only probe states why no screen reads it")


if __name__ == "__main__":
    unittest.main()
