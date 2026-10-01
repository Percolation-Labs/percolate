"""The resolver turns a page of Jev answers into the right database calls.

No database and no model: `as_service` yields a connection that records what
it was sent and answers `aiq.resolution_candidates` from a fixture, and the
model is a stub returning fixed probabilities. Under test is the policy --
which answer becomes a promotion, which a distinction, which nothing -- and the
paging, which is where a resolver silently stops early or loops.
"""
import asyncio
import json
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

from percolate_core import resolve as module
from percolate_core.worker import TerminalError

SPEC = {"op": "resolve", "claimed_kind": "company", "question": "Same company?",
        "accept": 0.8, "reject": 0.2}

# soft id -> (name, {node: p}). n9 is proposed for D and refused by the database.
PAGE = {
    "00000000-0000-7000-8000-00000000000a": ("Intel Corporation", {"n1": 0.95, "n2": 0.05}),
    "00000000-0000-7000-8000-00000000000b": ("Koss Corp", {"n3": 0.1, "n4": 0.5}),
    "00000000-0000-7000-8000-00000000000c": ("Twin Holdings", {"n5": 0.9, "n6": 0.85}),
    "00000000-0000-7000-8000-00000000000d": ("Nobody Ltd", {}),
}


def rows(page):
    out = []
    for sid, (name, props) in page.items():
        base = {"soft_id": sid, "candidate_node_id": "c" + sid[-1], "name": name, "attrs": {}}
        if not props:
            out.append({**base, "node_id": None, "node_key": None, "summary": None})
        for node in props:
            out.append({**base, "node_id": node, "node_key": node, "summary": node.upper()})
    return out


class Conn:
    def __init__(self, pages, refuse=()):
        self.pages, self.refuse, self.calls = list(pages), set(refuse), []

    async def fetch(self, sql, *args):
        self.calls.append(("fetch", args))
        return self.pages.pop(0) if self.pages else []

    async def execute(self, sql, *args):
        if any(a in self.refuse for a in args):
            raise RuntimeError("refused")
        self.calls.append((sql.split("(")[0].replace("select ", ""), args))


class StubJev:
    model, requests, input_tokens = "jev-test", 0, 0

    def __init__(self, page):
        self.page = page

    async def join(self, left, candidates, question):
        self.requests += 1
        by_name = {name: props for name, props in self.page.values()}
        return [{k: by_name[l["name"]][k] for k in c} for l, c in zip(left, candidates)]


def run(conn, spec=SPEC, page=PAGE):
    @asynccontextmanager
    async def fake():
        yield conn
    with patch.object(module, "as_service", fake):
        return asyncio.run(module.resolve(spec, {}, jev=StubJev(page)))


class Policy(unittest.TestCase):
    def test_each_answer_becomes_the_right_write(self):
        conn = Conn([rows(PAGE)])
        r = run(conn)
        writes = [(fn, a[:2]) for fn, a in conn.calls if fn != "fetch"]
        self.assertIn(("aiq.promote_soft_node", ("00000000-0000-7000-8000-00000000000a", "n1")), writes)
        self.assertIn(("aiq.record_distinct", ("cb", "n3")), writes)
        # promoted A records nothing distinct; B's 0.5 and both of C stay open
        self.assertNotIn(("aiq.record_distinct", ("ca", "n2")), writes)
        self.assertFalse([w for w in writes if w[1][1] in ("n4", "n5", "n6")])
        self.assertEqual({k: r[k] for k in ("candidates", "promoted", "distinct", "undecided",
                                             "ambiguous", "nothing_to_propose", "pages")},
                         {"candidates": 4, "promoted": 1, "distinct": 1, "undecided": 1,
                          "ambiguous": 1, "nothing_to_propose": 1, "pages": 1})

    def test_every_write_is_attributed_and_tiered(self):
        conn = Conn([rows(PAGE)])
        run(conn)
        for fn, args in conn.calls:
            if fn == "fetch":
                continue
            self.assertEqual(args[2], "percolate-core:resolve:jev-test")
            self.assertEqual(args[3], "decision_model")
            ev = json.loads(args[4])
            self.assertEqual((ev["model"], ev["question"], ev["accept"]), ("jev-test", "Same company?", 0.8))

    def test_pages_by_keyset_until_empty(self):
        conn = Conn([rows(PAGE), rows({"00000000-0000-7000-8000-0000000000ff": ("Late Co", {})})])
        r = run(conn)
        fetches = [a for fn, a in conn.calls if fn == "fetch"]
        self.assertEqual([f[2] for f in fetches],
                         [None, "00000000-0000-7000-8000-00000000000d",
                          "00000000-0000-7000-8000-0000000000ff"])
        self.assertEqual((r["pages"], r["candidates"]), (2, 5))

    def test_a_refused_write_is_counted_and_does_not_stop_the_page(self):
        conn = Conn([rows(PAGE)], refuse={"n1"})
        r = run(conn)
        self.assertEqual((r["promoted"], r["not_written"], r["distinct"]), (0, 1, 1))


class Required(unittest.TestCase):
    def test_question_and_both_thresholds_are_the_authors(self):
        for missing in ("question", "accept", "reject"):
            spec = {k: v for k, v in SPEC.items() if k != missing}
            with self.assertRaisesRegex(TerminalError, missing):
                run(Conn([]), spec)

    def test_thresholds_must_be_ordered(self):
        with self.assertRaisesRegex(TerminalError, "reject < accept"):
            run(Conn([]), {**SPEC, "accept": 0.2, "reject": 0.8})


if __name__ == "__main__":
    unittest.main()
