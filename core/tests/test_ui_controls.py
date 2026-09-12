"""An icon cannot ship without a name, and one icon set has one home.

Run: python -m unittest discover -s tests -p test_ui_controls.py

The failure this guards is invisible in a screenshot. An icon button with no
accessible name looks finished to everyone who can see it, and is an unlabelled
control to everyone who cannot -- and the way it gets in is that adding an icon
inline is cheaper than sharing one. There were three icon sets in this app
(`index.html`'s nav map, `access.js`'s four-entry rail set, and nothing
anywhere else) which is what "cheaper inline" looks like after a while.

The second half is the rule about which actions may be icons at all. An icon is
for a control whose worst outcome is that you press it again; `revoke`, `grant`
and `Cancel run` keep their words, and this asserts that they still do rather
than leaving it to the next person to remember.
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "percolate_core/ui/static"
SCREENS = tuple(sorted(p.name for p in STATIC.glob("*.js") if p.name != "ui.js"))


BOOT = r"""
import assert from 'node:assert/strict';
/* The eight DOM calls `h` and `icon` make, and nothing else: this is testing a
   component, not a browser. */
const el = () => {
  const a = {};
  return { __a: a, __k: [], nodeType: 1,
    setAttribute(k, v) { a[k] = String(v); },
    getAttribute(k) { return a[k] ?? null; },
    append(...k) { this.__k.push(...k); },
    addEventListener() {},
    set className(v) { a.class = v; },
    set innerHTML(v) { a.html = v; } };
};
globalThis.document = { createElement: el, createElementNS: el,
                        createTextNode: (t) => ({ nodeType: 3, t }) };
"""



@unittest.skipUnless(shutil.which("node"), "node runs the browser component")
class IconActionTest(unittest.TestCase):
    def run_js(self, source):
        script = BOOT + f"""
const ui=await import({json.dumps((STATIC / 'ui.js').as_uri())});
""" + source
        result = subprocess.run(["node", "--input-type=module", "-e", script],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_label_is_the_accessible_name_and_the_tooltip(self):
        """One argument fills both, so they cannot drift apart or be omitted."""
        self.run_js("""
        const b=ui.iconAction('play','Start a run of nightly');
        assert.equal(b.getAttribute('aria-label'),'Start a run of nightly');
        assert.equal(b.getAttribute('data-tip'),b.getAttribute('aria-label'));
        assert.equal(b.getAttribute('type'),'button');
        assert.throws(()=>ui.iconAction('play',''),/accessible name/);
        assert.throws(()=>ui.iconAction('play'),/accessible name/);
        """)

    def test_every_icon_a_screen_asks_for_exists(self):
        """A typo in an icon name used to fall back to a grid square, silently."""
        used = set()
        for name in SCREENS:
            text = (STATIC / name).read_text()
            used |= set(re.findall(r"""icon(?:Action)?\(\s*['"]([a-zA-Z]+)['"]""", text))
        icons = set(re.findall(r"^  ([a-zA-Z]+):", (STATIC / "ui.js").read_text(), re.M))
        self.assertTrue(used, "no screen uses an icon -- the selector is wrong")
        self.assertEqual(used - icons, set(), f"icons used but not defined: {used - icons}")

    def test_no_screen_carries_its_own_icon_set(self):
        """Three sets is how a vocabulary stops being one."""
        offenders = [n for n in SCREENS
                     if re.search(r"""['"]<(path|rect|circle) """, (STATIC / n).read_text())]
        self.assertEqual(
            offenders, [],
            f"{offenders} define SVG paths inline. Add the icon to ICONS in ui.js instead.")

    def test_consequential_actions_still_say_what_they_do(self):
        """Destructive or access-changing controls are words, by rule."""
        views, access = (STATIC / "views.js").read_text(), (STATIC / "access.js").read_text()
        for text, word in ((views, "Cancel run"), (access, "revoke"), (access, "grant")):
            self.assertIn(f'"{word}")', text,
                          f"'{word}' should be a labelled button, not an icon")
        self.assertNotIn("iconAction(\"trash", views)


if __name__ == "__main__":
    unittest.main()
