#!/usr/bin/env python3
"""The semantic-exception kinds the database raises are core's, word for word.

    dev/semantic-exceptions.py           # list each kind and whether it agrees
    dev/semantic-exceptions.py --check   # non-zero if any copy differs (CI)

aiq.result_exceptions (specs/ai-query-layer/schema.sql §8z) raises the result
kinds only the store can raise honestly, and it carries their code, stage,
severity and prompt so a caller reading the envelope needs nothing else. Those
are a copy of core's catalogue, and a copy is a thing that falls behind. This
reads the rows between the SQL's `semantic-exception kinds` markers and compares
each with `by_code()` in core/percolate_core/semantic_exceptions/catalogue.py,
loaded from the file so no install of core is needed.
"""
from __future__ import annotations

import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SQL = ROOT / "specs/ai-query-layer/schema.sql"
CATALOGUE = ROOT / "core/percolate_core/semantic_exceptions/catalogue.py"
ROW = re.compile(r"\('([A-Z_]+)',\s*'([a-z]+)',\s*'([a-z]+)',\s*'((?:[^']|'')*)'\)")


def sql_kinds() -> list[tuple[str, str, str, str]]:
    text = SQL.read_text()
    m = re.search(r"-- semantic-exception kinds: begin\n(.*?)-- semantic-exception kinds: end",
                  text, re.S)
    if not m:
        sys.exit(f"{SQL.relative_to(ROOT)}: no semantic-exception kinds markers")
    rows = [(c, st, sev, p.replace("''", "'")) for c, st, sev, p in ROW.findall(m.group(1))]
    if not rows:
        sys.exit(f"{SQL.relative_to(ROOT)}: markers hold no kinds")
    return rows


def catalogue():
    spec = importlib.util.spec_from_file_location("catalogue", CATALOGUE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["catalogue"] = mod   # dataclasses resolves annotations through it
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    cat = catalogue()
    bad = 0
    for code, stage, severity, prompt in sql_kinds():
        try:
            k = cat.by_code(code)
        except KeyError:
            print(f"DIFFERS  {code}: not in core's catalogue")
            bad += 1
            continue
        diffs = [f"{name}: sql {ours!r} core {theirs!r}"
                 for name, ours, theirs in (("stage", stage, k.stage),
                                            ("severity", severity, k.severity),
                                            ("prompt", prompt, k.prompt)) if ours != theirs]
        print(("DIFFERS  " if diffs else "agrees   ") + code + "".join(f"\n    {d}" for d in diffs))
        bad += bool(diffs)
    return 1 if bad and "--check" in sys.argv else 0


if __name__ == "__main__":
    sys.exit(main())
