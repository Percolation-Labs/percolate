"""Semantic exceptions: what each stage raises, what it sends Jev, and what the model reads.

No database and no model. The judged stages run against a stub that answers
from a table and records every request, so under test is the request shape
(one call for the whole question, one per hit), the thresholding and the
guard. Every structural detector is run on a planted result that must raise
it AND on a clean twin that must not: a detector that never fires and one
that always fires both pass a one-sided test.

The live case runs only with JEV_API_KEY set, on questions whose answer is
not in doubt; it proves the wiring, not the thresholds (evals/semantic_exceptions
measures those).
"""
import asyncio
import datetime as dt
import os
import unittest

from percolate_core.semantic_exceptions import (KINDS, Limits, SemanticExceptionError,
                                                SemanticExceptions, by_code)
from percolate_core.semantic_exceptions.catalogue import judged


def run(coro):
    return asyncio.run(coro)


class Ans:
    def __init__(self, p):
        self.p = p


class Res(dict):
    model, input_tokens = "jev-stub", 10


class StubJev:
    """Answers P(yes) from `table[qid]` (or a callable of state and qid), default 0."""

    def __init__(self, table=None):
        self.table, self.sent = table or {}, []

    async def ask(self, state, questions):
        self.sent.append((state, questions))
        out = Res()
        for qid in questions:
            v = self.table.get(qid, 0.0)
            out[qid] = Ans(v(state, qid) if callable(v) else v)
        return out


class Catalogue(unittest.TestCase):
    def test_every_judged_instruction_names_a_state_key_in_backticks(self):
        keys = {"question": "`question`", "values": "`passage`"}
        for k in KINDS:
            if k.judged:
                self.assertIn(keys[k.stage], k.instruction, k.code)
                self.assertIsNotNone(k.threshold, k.code)
                if k.needs:
                    self.assertIn(f"`{k.needs}`", k.instruction, k.code)

    def test_every_kind_tells_the_model_what_to_do(self):
        for k in KINDS:
            self.assertGreater(len(k.prompt.split()), 4, k.code)
            self.assertIn(k.severity, ("error", "warning", "positive"))


class Before(unittest.TestCase):
    def test_one_request_carries_every_question_kind(self):
        jev = StubJev({"NEGATION": 0.9, "COUNT": 0.2})
        rep = run(SemanticExceptions(jev).before("Which entries don't mention Lucy?"))
        self.assertEqual(len(jev.sent), 1)
        state, qs = jev.sent[0]
        self.assertEqual(state, {"question": "Which entries don't mention Lucy?"})
        expected = {k.code for k in judged("question") if k.needs is None}
        self.assertEqual(set(qs), expected)
        self.assertEqual(rep.codes, {"NEGATION"})
        self.assertEqual(rep.jev_requests, 1)

    def test_out_of_domain_is_asked_only_when_the_store_is_described(self):
        jev = StubJev({"OUT_OF_DOMAIN": 0.9})
        self.assertEqual(run(SemanticExceptions(jev).before("q")).codes, set())
        rep = run(SemanticExceptions(jev, store="Bram Stoker's Dracula").before("q"))
        self.assertEqual(jev.sent[-1][0]["store"], "Bram Stoker's Dracula")
        self.assertEqual(rep.codes, {"OUT_OF_DOMAIN"})

    def test_thresholds_and_disable(self):
        jev = StubJev({"NEGATION": 0.6, "COUNT": 0.6})
        sx = SemanticExceptions(jev, thresholds={"NEGATION": 0.7}, disable=["COUNT"])
        rep = run(sx.before("q"))
        self.assertEqual(rep.codes, set())
        self.assertNotIn("COUNT", jev.sent[0][1])

    def test_a_judged_stage_without_jev_says_so(self):
        with self.assertRaises(ValueError):
            run(SemanticExceptions().before("q"))


class Values(unittest.TestCase):
    HITS = [{"id": i, "content": f"passage {i}"} for i in range(4)]

    def test_one_request_per_hit_and_conflicts_with_the_next(self):
        def pointer(state, qid):
            return 0.9 if state["passage"] == "passage 1" else 0.1

        def conflict(state, qid):
            return 0.95 if state["passage"] == "passage 0" and qid == "CONFLICT:2" else 0.0
        jev = StubJev({"POINTER": pointer, "CONFLICT:1": conflict, "CONFLICT:2": conflict})
        rep = run(SemanticExceptions(jev, values_top=3, conflict_top=3)
                  .values("q", self.HITS))
        self.assertEqual(len(jev.sent), 3)
        self.assertEqual({q for q in jev.sent[0][1] if q.startswith("CONFLICT")},
                         {"CONFLICT:1", "CONFLICT:2"})
        self.assertFalse(any(q.startswith("CONFLICT") for q in jev.sent[2][1]))
        by = {(r.code, r.evidence["id"]) for r in rep.raised}
        self.assertEqual(by, {("POINTER", 1), ("CONFLICT", 0)})
        self.assertEqual([r.evidence.get("other") for r in rep.raised if r.code == "CONFLICT"], [2])


def codes(hits, **kw):
    limits = kw.pop("limits", Limits())
    return SemanticExceptions(limits=limits).after(hits, **kw).codes


class Result(unittest.TestCase):
    """Each detector: planted case raises it, clean twin does not."""

    def scores(self, *s):
        return [{"id": i, "score": v} for i, v in enumerate(s)]

    def test_empty(self):
        self.assertIn("EMPTY", codes([]))
        self.assertNotIn("EMPTY", codes(self.scores(0.5)))

    def test_truncated_at_limit(self):
        self.assertIn("TRUNCATED_AT_LIMIT", codes(self.scores(.9, .8, .7), limit=3))
        self.assertNotIn("TRUNCATED_AT_LIMIT", codes(self.scores(.9, .8), limit=3))
        self.assertNotIn("TRUNCATED_AT_LIMIT", codes(self.scores(.9, .8, .7), limit=3, total=3))

    def test_too_broad_and_starved(self):
        self.assertIn("TOO_BROAD", codes(self.scores(.9), total=5000))
        self.assertNotIn("TOO_BROAD", codes(self.scores(.9), total=50))
        self.assertIn("STARVED_BY_FILTER", codes(self.scores(.9), limit=10, filtered=True))
        self.assertNotIn("STARVED_BY_FILTER", codes(self.scores(.9), limit=10))

    def test_absolute_score_thresholds_are_off_until_set(self):
        flat = self.scores(.801, .800, .800, .799, .799)
        self.assertNotIn("FLAT_SCORES", codes(flat))
        self.assertNotIn("LOW_BEST_SCORE", codes(self.scores(.1, .05)))
        lim = Limits(flat_spread=0.01, low_score=0.3)
        self.assertIn("FLAT_SCORES", codes(flat, limits=lim))
        self.assertNotIn("FLAT_SCORES", codes(self.scores(.9, .8, .7, .6), limits=lim))
        self.assertIn("LOW_BEST_SCORE", codes(self.scores(.1, .05), limits=lim))
        self.assertNotIn("LOW_BEST_SCORE", codes(self.scores(.5, .05), limits=lim))

    def test_strong_single_hit_and_cliff(self):
        self.assertIn("STRONG_SINGLE_HIT", codes(self.scores(.95, .60, .59, .58, .57)))
        cliff = codes(self.scores(.90, .89, .88, .50, .49, .48))
        self.assertIn("SCORE_CLIFF", cliff)
        self.assertNotIn("STRONG_SINGLE_HIT", cliff)
        even = codes(self.scores(.90, .85, .80, .75, .70))
        self.assertFalse({"SCORE_CLIFF", "STRONG_SINGLE_HIT"} & even)

    def test_cliff_says_where_to_cut(self):
        rep = SemanticExceptions().after(self.scores(.90, .89, .88, .50, .49, .48))
        self.assertEqual([r.evidence["keep"] for r in rep.raised if r.code == "SCORE_CLIFF"], [3])

    def test_single_source(self):
        same = [{"id": i, "source": "Seward"} for i in range(3)]
        self.assertIn("SINGLE_SOURCE", codes(same))
        mixed = same + [{"id": 9, "source": "Mina"}]
        self.assertNotIn("SINGLE_SOURCE", codes(mixed))
        partial = same + [{"id": 9}]
        self.assertNotIn("SINGLE_SOURCE", codes(partial))

    def test_time_skew(self):
        hits = [{"id": i, "time": 100 + i} for i in range(3)]
        self.assertIn("TIME_SKEW", codes(hits, time_range=(0, 1000)))
        spread = [{"id": i, "time": 300 * i} for i in range(3)]
        self.assertNotIn("TIME_SKEW", codes(spread, time_range=(0, 1000)))
        self.assertNotIn("TIME_SKEW", codes(hits))

    def test_duplicates_and_versions(self):
        self.assertIn("DUPLICATES", codes([{"id": 1, "content": "a"}, {"id": 2, "content": "a"}]))
        self.assertNotIn("DUPLICATES", codes([{"id": 1, "content": "a"}, {"id": 2, "content": "b"}]))
        self.assertIn("VERSION_PILE_UP", codes([{"id": 1, "document": "d"}, {"id": 2, "document": "d"}]))
        self.assertNotIn("VERSION_PILE_UP", codes([{"id": 1, "document": "d"}, {"id": 2, "document": "e"}]))

    def test_per_hit_fields(self):
        d = dt.datetime
        self.assertIn("SUPERSEDED", codes([{"id": 1, "superseded_by": 2}]))
        self.assertNotIn("SUPERSEDED", codes([{"id": 1, "superseded_by": None}]))
        self.assertIn("RETRACTED", codes([{"id": 1, "retracted": True}]))
        self.assertNotIn("RETRACTED", codes([{"id": 1, "retracted": False}]))
        self.assertIn("MISSING_PROVENANCE", codes([{"id": 1, "provenance": None}]))
        self.assertNotIn("MISSING_PROVENANCE", codes([{"id": 1}]))
        future = [{"id": 1, "time": d(1893, 11, 6), "recorded_at": d(1893, 5, 3)}]
        self.assertIn("FUTURE_DATED", codes(future))
        late = [{"id": 1, "time": d(1893, 5, 3), "recorded_at": d(1893, 11, 6)}]
        self.assertNotIn("FUTURE_DATED", codes(late))
        self.assertNotIn("RECORDING_LAG", codes(late))
        self.assertIn("RECORDING_LAG", codes(late, limits=Limits(recording_lag=dt.timedelta(days=30))))
        self.assertIn("EMBEDDING_MISMATCH",
                      codes([{"id": 1, "embedding_model": "a"}], embedding_model="b"))
        self.assertNotIn("EMBEDDING_MISMATCH",
                         codes([{"id": 1, "embedding_model": "b"}], embedding_model="b"))

    def test_facet_unanswered(self):
        c = codes([], parts={"who": [{"id": 1}], "when": []})
        self.assertIn("FACET_UNANSWERED", c)
        self.assertNotIn("EMPTY", c)
        self.assertNotIn("FACET_UNANSWERED", codes([{"id": 1}], parts={"who": [{"id": 1}]}))


def wcodes(rounds, **kw):
    return SemanticExceptions().walk(rounds, **kw).codes


class Walk(unittest.TestCase):
    def test_loop_versus_converged(self):
        first = {"found": [1, 2], "opened": ["q1"]}
        self.assertIn("LOOP", wcodes([first, {"found": [1], "opened": ["q2"]}]))
        self.assertIn("CONVERGED", wcodes([first, {"found": [1], "opened": []}]))
        fresh = wcodes([first, {"found": [3], "opened": ["q2"]}])
        self.assertFalse({"LOOP", "CONVERGED"} & fresh)

    def test_frontier_explosion(self):
        grow = [{"found": [i], "opened": [f"a{i}", f"b{i}"], "closed": []} for i in range(3)]
        self.assertIn("FRONTIER_EXPLOSION", wcodes(grow))
        steady = [{"found": [i], "opened": [f"a{i}"], "closed": [f"a{i}"]} for i in range(3)]
        self.assertNotIn("FRONTIER_EXPLOSION", wcodes(steady))

    def test_dead_end_and_orphans(self):
        r = [{"found": [1], "opened": ["q1", "q2"], "closed": ["q1"], "unanswered": ["q2"]}]
        self.assertIn("DEAD_END", wcodes(r))
        self.assertNotIn("ORPHANED_QUESTIONS", wcodes(r))
        self.assertIn("ORPHANED_QUESTIONS", wcodes(r, stopped=True))
        done = [{"found": [1], "opened": ["q1"], "closed": ["q1"]}]
        self.assertFalse({"DEAD_END", "ORPHANED_QUESTIONS"} & wcodes(done, stopped=True))

    def test_diminishing_returns_and_budget(self):
        dim = [{"found": list(range(10)), "opened": ["a"]},
               {"found": list(range(10, 14)), "opened": ["b"]},
               {"found": [14], "opened": ["c"]}]
        self.assertIn("DIMINISHING_RETURNS", wcodes(dim))
        flat = [{"found": list(range(i * 5, i * 5 + 5)), "opened": ["x"]} for i in range(3)]
        self.assertNotIn("DIMINISHING_RETURNS", wcodes(flat))
        spend = [{"found": [1], "spent": 9}]
        self.assertIn("BUDGET_NEARLY_SPENT", wcodes(spend, budget=10))
        self.assertNotIn("BUDGET_NEARLY_SPENT", wcodes(spend, budget=20))


class ReportAndGuard(unittest.TestCase):
    def test_prompt_puts_errors_first_and_counts_what_it_leaves_out(self):
        jev = StubJev({"NEGATION": 0.9, "COMPARISON": 0.99, "ALIAS": 0.8, "CAUSAL_WHY": 0.7})
        rep = run(SemanticExceptions(jev).before("q"))
        text = rep.to_prompt(show=2)
        lines = text.splitlines()
        self.assertIn("ERROR NEGATION", lines[1])
        self.assertIn("COMPARISON", lines[2])
        self.assertIn("and 2 more", lines[3])
        self.assertEqual(SemanticExceptions().after([{"id": 1}]).to_prompt(), "")

    def test_one_line_per_kind_however_many_hits_raise_it(self):
        rep = SemanticExceptions().after([{"id": i, "retracted": True} for i in range(3)])
        self.assertEqual(len(rep.raised), 3)
        self.assertIn("RETRACTED (3 results)", rep.to_prompt())

    def test_strict_guard_refuses_before_searching(self):
        called = []

        async def search(question, limit=10):
            called.append(question)
            return [{"id": 1, "score": .9}]
        jev = StubJev({"DECOMPOSITION_REQUIRED": 0.97})
        g = SemanticExceptions(jev).guard(search, strict=True)
        with self.assertRaises(SemanticExceptionError) as e:
            run(g("How many letters did Mina write, and what did Van Helsing think of the bat?"))
        self.assertEqual(called, [])
        self.assertIn("DECOMPOSITION_REQUIRED", str(e.exception))

    def test_lenient_guard_searches_and_reports_both_stages(self):
        async def search(question, limit=10):
            return [{"id": i, "score": 1 - i / 10} for i in range(limit)]
        jev = StubJev({"COUNT": 0.9})
        hits, rep = run(SemanticExceptions(jev).guard(search)("How many?", limit=3))
        self.assertEqual(len(hits), 3)
        self.assertEqual(rep.codes, {"COUNT", "TRUNCATED_AT_LIMIT"})

    def test_guard_without_jev_runs_the_structural_stage_only(self):
        async def search(question, limit=10):
            return []
        hits, rep = run(SemanticExceptions().guard(search)("anything"))
        self.assertEqual(rep.codes, {"EMPTY"})


@unittest.skipUnless(os.environ.get("JEV_API_KEY"), "live: needs JEV_API_KEY")
class Live(unittest.TestCase):
    def test_unmistakable_questions(self):
        from percolate_core.decide import Jev

        async def go():
            async with Jev(api_key=os.environ["JEV_API_KEY"]) as jev:
                sx = SemanticExceptions(jev)
                neg = await sx.before("Which diary entries do not mention Lucy at all?")
                plain = await sx.before("What did Jonathan Harker eat at the inn in Bistritz?")
                return neg, plain
        neg, plain = run(go())
        self.assertIn("NEGATION", neg.codes)
        self.assertNotIn("NEGATION", plain.codes)
        self.assertEqual(neg.jev_requests, 1)


if __name__ == "__main__":
    unittest.main()
