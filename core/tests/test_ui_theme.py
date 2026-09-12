"""Typography is a default, not a pile of per-component patches.

Run: python -m unittest discover -s tests -p test_ui_theme.py
No database, no browser. The live half -- does a paragraph actually set to a
readable line at 1440px, 1024px and 390px -- is a screenshot, because only a
browser can answer it.

What is guarded here is the shape that made the defect possible. `theme.css`
had accumulated nineteen separate `overflow-wrap: anywhere` declarations, each
added after somebody reported an overflow, and `.mono` -- ids, cron
expressions, model names, dot paths -- was not among them. It had `.lede`
defined twice in two typefaces at two measures, and four prose classes with
four different hand-written `max-width`es, one of which (`.note`) was missing,
so error banners set at 178 characters.

Every one of those is invisible in review: adding a twentieth declaration looks
like fixing a bug. So the file gets one wrapping default, one measure token and
one `.lede`, and this test is what makes the twentieth loud.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

THEME = Path(__file__).resolve().parents[1] / "percolate_core" / "ui" / "static" / "theme.css"


def _css() -> str:
    """The stylesheet with comments removed -- they discuss the rules by name."""
    return re.sub(r"/\*.*?\*/", "", THEME.read_text(), flags=re.S)


def _media_blocks(css: str) -> list[str]:
    """The bodies of every `@media` rule, found by counting braces rather than
    by splitting on the keyword: the first `@media` in this file is the dark
    palette at the top, so a split treats the whole stylesheet as conditional."""
    blocks, i = [], css.find("@media")
    while i != -1:
        depth, j = 0, css.find("{", i)
        k = j
        while k < len(css):
            depth += (css[k] == "{") - (css[k] == "}")
            if depth == 0:
                break
            k += 1
        blocks.append(css[j:k])
        i = css.find("@media", k)
    return blocks


class ThemeTypography(unittest.TestCase):
    def test_wrapping_is_declared_once(self):
        """One default on `body`, inherited. A second declaration is the habit."""
        found = re.findall(r"[^-\w](overflow-wrap|word-break)\s*:\s*([\w-]+)", _css())
        self.assertEqual(
            [v for _, v in found], ["anywhere"],
            "theme.css should carry exactly one wrapping declaration -- the default "
            "on `body`. A per-component one means the next component is exempt again; "
            "if a specific element must NOT break, give it `white-space: nowrap` and "
            "say why, next to `.data td.ident`.")

    def test_the_measure_is_one_token(self):
        """A prose cap is `var(--measure)`, so the value has one home."""
        css = _css()
        self.assertEqual(css.count("--measure:"), 1, "--measure is defined more than once")
        hand_written = re.findall(r"max-width:\s*[\d.]+ch", css)
        self.assertEqual(
            hand_written, [],
            f"prose measured in `ch` outside the token: {hand_written}. Use var(--measure).")

    def test_lede_resolves_one_way(self):
        """Defined twice, it rendered in two typefaces depending on an ancestor."""
        typed = [r for r in re.findall(r"([^{}]*)\{([^{}]*)\}", _css())
                 if ".lede" in r[0] and re.search(r"(^|;)\s*font(-family)?\s*:", r[1])]
        self.assertEqual(
            len(typed), 1,
            f"`.lede` is given a typeface by {len(typed)} rules: {[r[0].strip() for r in typed]}")

    def test_identifier_cells_hold_at_every_width(self):
        """The narrow rule and the wide one disagreed: the same cell broke on a
        desktop and refused to on a phone. One rule now, outside any media query."""
        css = _css()
        inside = "".join(_media_blocks(css))
        self.assertIn(".data td.mono", css, "the identifier exception is gone entirely")
        self.assertNotIn(
            ".data td.mono", inside,
            "`.data td.mono` is being redefined inside a media query -- that is "
            "the disagreement this rule was consolidated to end.")


if __name__ == "__main__":
    unittest.main()
