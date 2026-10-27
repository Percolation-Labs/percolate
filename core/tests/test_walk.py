"""The clue walk: what it reads, what it records, and that a recorded walk replays without a model.

The fixture is a small store built in a temporary directory: two sittings of eight messages, a few shared terms,
and nearest-meaning lists. The decider is a rule, so every expectation can be worked out by hand. The walk itself
was checked read for read against the BEAM study's recorded walk of question 1M:22 (6 waves, 1,130 verdicts, the
same travels and the same leads open at the stop); that fixture is BEAM's data and too large to ship here.
"""
import asyncio
import json
import tempfile
import unittest
from pathlib import Path

import httpx
from typer.testing import CliRunner

from percolate_core.cli import app
from percolate_core.decide import Jev
from percolate_core.walk.deciders import CHUNK, Recorder, Refused, Replay, jev
from percolate_core.walk.engine import TASK, Settings, walk
from percolate_core.walk.store import MemoryStore

DOCS = [
    # sitting a: the ladder thread; sitting b: unrelated cooking
    (1, "a", 0, "I need to repaint the hallway ceiling", ["hallway", "ceiling"], [2]),
    (2, "a", 1, "Is a 3-meter ladder necessary for the ceiling?", ["ladder", "ceiling"], [1]),
    (3, "a", 2, "My budget for the hallway is 400 pounds", ["budget", "hallway"], [4]),
    (4, "a", 3, "Moving the vanity needs two people", ["moving", "vanity"], [3]),
    (5, "a", 4, "The ladder rental shop opens at nine", ["ladder", "rental"], [2]),
    (6, "a", 5, "Paint dries in four hours", ["paint"], [1]),
    (7, "a", 6, "I rented the ladder for the weekend", ["ladder", "rental"], [5]),
    (8, "a", 7, "Remember to tape the edges", ["paint"], [6]),
    (11, "b", 0, "A risotto needs patience", ["risotto"], [12]),
    (12, "b", 1, "Stir the stock in slowly", ["stock"], [11]),
    (13, "b", 2, "Parmesan goes in at the end", ["parmesan"], [12]),
    (14, "b", 3, "Rest it for two minutes", ["rest"], [13]),
    (15, "b", 4, "Serve it in warm bowls", ["bowls"], [14]),
    (16, "b", 5, "Leftovers make good arancini", ["arancini"], [11]),
    (17, "b", 6, "Fry them until golden", ["fry"], [16]),
    (18, "b", 7, "Salt at the end", ["salt"], [17]),
]
QUESTION = {"id": "q1", "text": "What do I need to get the ladder sorted for the ceiling?", "gold": [2, 5, 7],
            "search": [1, 11, 12, 13, 14, 15, 16, 17, 18, 3, 4, 6, 8, 2, 5, 7]}
SMALL = dict(waves=3, wave=4, k=1, seeds=1, per_wave=1, policy="best", expand_all=False)


def fixture(d: Path) -> Path:
    with (d / "docs.jsonl").open("w") as f:
        for i, s, pos, text, terms, near in DOCS:
            f.write(json.dumps({"id": i, "sitting": s, "pos": pos, "text": text, "terms": terms,
                                "nearest": near}) + "\n")
    (d / "questions.jsonl").write_text(json.dumps(QUESTION) + "\n")
    return d


async def rule(question, clues):
    """Yes to the terms 'ladder' and 'ceiling', no to every other lead."""
    return {k: 0.9 if k in ("term:ladder", "term:ceiling") else 0.2 for k in clues}


class Walk(unittest.TestCase):
    def setUp(self):
        self.dir = fixture(Path(tempfile.mkdtemp()))
        self.store = MemoryStore(self.dir)

    def walk(self, decide=rule, **kw):
        return asyncio.run(walk(self.store, QUESTION, decide, Settings(**{**SMALL, **kw})))

    def test_an_accepted_clue_is_travelled_and_a_rejected_one_is_not(self):
        rec = self.walk()
        read = {x for w in rec["waves"] for x in w["reads"]}
        # Search's first read is 1, the ceiling; its term clue 'ceiling' leads to 2, and 2's term 'ladder' to 5 and 7.
        self.assertTrue({2, 5, 7} <= read, read)
        travelled = {t["key"] for t in rec["travelled"]}
        self.assertIn("term:ceiling", travelled)
        rejected = {c["key"] for c in rec["clues"] if c["decision"] == "rejected"}
        self.assertFalse(travelled & rejected)

    def test_the_record_holds_every_clue_with_its_targets_and_fate(self):
        rec = self.walk()
        self.assertEqual(rec["task"], TASK)
        for c in rec["clues"]:
            self.assertEqual(set(c), {"key", "kind", "wave", "step", "text", "targets", "P", "decision"})
            self.assertTrue(c["targets"])
        hallway = next(c for c in rec["clues"] if c["key"] == "term:hallway")
        self.assertEqual((hallway["P"], hallway["decision"], hallway["targets"]), (0.2, "rejected", [3]))
        self.assertEqual(rec["reads"], sum(len(w["reads"]) for w in rec["waves"]))
        seen = set()
        for w in rec["waves"]:  # a read is expanded in its own wave or, if it came last, in the next
            seen |= set(w["reads"])
            self.assertTrue(set(w["expanded_reads"]) <= seen)

    def test_a_recorded_walk_replays_offline_read_for_read(self):
        rec = Recorder(rule)
        first = self.walk(rec)
        rec.save(self.dir / "verdicts.json")
        replay = Replay(self.dir / "verdicts.json")
        again = self.walk(replay)
        self.assertEqual([w["reads"] for w in again["waves"]], [w["reads"] for w in first["waves"]])
        self.assertEqual(again["clues"], first["clues"])
        self.assertEqual((replay.asked, replay.missing), (0, 0))

    def test_a_clue_the_file_lacks_is_unjudged_offline_and_never_accepted(self):
        (self.dir / "verdicts.json").write_text(json.dumps({"model": "m", "task": TASK, "verdicts": {}}))
        replay = Replay(self.dir / "verdicts.json")
        rec = self.walk(replay)
        self.assertGreater(rec["unjudged"], 0)
        self.assertEqual(rec["travelled"], [])
        self.assertEqual({c["decision"] for c in rec["clues"]}, {"unjudged"})
        self.assertEqual(replay.missing, rec["unjudged"])

    def test_verdicts_given_under_another_task_are_refused(self):
        (self.dir / "verdicts.json").write_text(json.dumps({"model": "m", "task": "another wording", "verdicts": {}}))
        with self.assertRaises(Refused):
            Replay(self.dir / "verdicts.json")

    def test_a_walk_that_runs_out_of_reads_says_so(self):
        rec = self.walk(waves=10, wave=8)
        self.assertEqual(rec["stop"]["reason"], "dry")
        self.assertEqual(len({x for w in rec["waves"] for x in w["reads"]}), len(DOCS))

    def test_explore_draws_from_rejected_clues_too(self):
        rec = self.walk(policy="explore", k=2, waves=4)
        self.assertTrue(any(t["rank"] == "drawn" for t in rec["travelled"]))
        self.assertEqual(rec, self.walk(policy="explore", k=2, waves=4))  # seeded by the question: repeatable


class Jev_(unittest.TestCase):
    def test_clues_go_to_jev_in_key_order_and_chunks_with_the_question_and_task(self):
        sent = []

        def answer(request):
            body = json.loads(request.content)
            sent.append(body)
            return httpx.Response(200, json={"model": "jev-1.13.0", "usage": {},
                                             "answers": {k: {"type": "noul", "noul": 0.7} for k in body["questions"]}})

        client = Jev(api_key="k", client=httpx.AsyncClient(transport=httpx.MockTransport(answer)))
        clues = {f"term:t{i:03}": f"lead {i}" for i in range(CHUNK + 5)}
        got = asyncio.run(jev(client)({"id": "q", "text": "the question"}, dict(reversed(list(clues.items())))))
        self.assertEqual(got, {k: 0.7 for k in clues})
        self.assertEqual([len(b["questions"]) for b in sent], [CHUNK, 5])
        self.assertEqual(sent[0]["state"], {"question": "the question", "task": TASK})
        self.assertEqual(sent[0]["questions"]["c0"], {"type": "noul", "instructions": "lead 0"})


class Command(unittest.TestCase):
    def test_walk_run_prints_the_waves_and_writes_the_record(self):
        d = fixture(Path(tempfile.mkdtemp()))
        rec = Recorder(rule)
        asyncio.run(walk(MemoryStore(d), QUESTION, rec, Settings(waves=3, policy="best", expand_all=False)))
        rec.save(d / "verdicts.json")
        out = CliRunner().invoke(app, ["walk", "run", "--fixture", str(d), "--question", "q1", "--verdicts",
                                       str(d / "verdicts.json"), "--offline", "--policy", "best", "--waves", "3",
                                       "--seeds-only", "--record", str(d / "walk.json")])
        self.assertEqual(out.exit_code, 0, out.output)
        self.assertIn("evidence: walk  search alone", out.output)
        # the fixture's search order ends with all three, and the walk reads all sixteen documents
        self.assertRegex(out.output, r"of 3\s+3 of 3")
        self.assertIn("0 asked of Jev, 0 missing", out.output)
        self.assertEqual(json.loads((d / "walk.json").read_text())["question"]["id"], "q1")

    def test_offline_without_verdicts_is_refused(self):
        d = fixture(Path(tempfile.mkdtemp()))
        out = CliRunner().invoke(app, ["walk", "run", "--fixture", str(d), "--question", "q1", "--offline"])
        self.assertEqual(out.exit_code, 2)
        self.assertIn("--offline needs --verdicts", out.output + (out.stderr if out.stderr_bytes is not None else ""))


if __name__ == "__main__":
    unittest.main()
