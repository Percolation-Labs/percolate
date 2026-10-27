"""Walkthrough step 3, a real miss explained, without a model (REM-1206).

The article's step walks BEAM's ladder question (1M:22) on Percolate and asks `percolate walk why`: the answer sits
behind an accepted lead, `term:ladder` at P 0.57, that higher leads kept outranking until the walk stopped. BEAM's
text is CC BY-SA and stays out of this repository, so the fixture here is a hand-made conversation with the same
shape: one seed raises `ladder` beside four leads Jev likes a little more, each of those raises another, and the two
messages that answer the question are reachable only through `ladder`.

The test replays the walk from a verdict file with no fallback, as `--offline` does, so it asks no model, and then
runs `percolate walk why` with `--gold` on the questions file, as the block does.
"""
import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from typer.testing import CliRunner

from percolate_core.cli import app
from percolate_core.walk.deciders import Recorder, Replay
from percolate_core.walk.engine import Settings, walk
from percolate_core.walk.store import MemoryStore

DOCS = [
    # sitting a: the shelves project; sitting b: unrelated cooking, which search mixes in
    (1, "a", 0, "Planning the garage shelves on a budget", ["ladder", "budget", "drill"], [2]),
    (2, "a", 1, "My budget is 400 pounds; here is my checklist", ["budget", "checklist"], [1]),
    (3, "a", 2, "Which drill is safest for masonry?", ["drill", "safety"], [2]),
    (4, "a", 3, "The checklist says I have spent 140 so far", ["checklist", "spent"], [3]),
    (5, "a", 4, "Safety precautions for drilling overhead", ["safety", "precautions"], [4]),
    (6, "a", 5, "I spent extra on precautions: goggles and gloves", ["spent", "precautions"], [5]),
    (7, "a", 6, "Do I need a 3-meter ladder for the shelves?", ["ladder", "shelves"], [6]),
    (8, "a", 7, "My neighbour can lend me a ladder for the garage", ["ladder", "garage"], [7]),
    (11, "b", 0, "A risotto needs patience", ["risotto"], [12]),
    (12, "b", 1, "Stir the stock in slowly", ["stock"], [11]),
    (13, "b", 2, "Parmesan goes in at the end", ["parmesan"], [12]),
    (14, "b", 3, "Serve it in warm bowls", ["bowls"], [13]),
]
# BEAM's files say qid and question, as samples/beam/questions.jsonl does.
QUESTION = {"qid": "ladder", "question": "How should I sequence my budget, tools and ladder for the shelves?",
            "gold": [7, 8], "search": [1, 11, 12, 13, 14, 2, 3, 4, 5, 6, 7, 8]}
P = {"term:budget": 0.6, "term:drill": 0.6, "term:checklist": 0.59, "term:safety": 0.59, "term:spent": 0.58,
     "term:precautions": 0.58, "term:ladder": 0.57}
# The step's settings (--policy best --seeds-only), scaled to twelve messages: the best clue a step, three reads a
# wave, and search's first read the only seed.
SMALL = dict(k=1, seeds=1, per_wave=1, wave=3, policy="best", expand_all=False)


async def jev_stand_in(question, clues):
    """Accepts the project's terms, `ladder` a little less than the rest, and rejects every other lead."""
    return {k: P.get(k, 0.2) for k in clues}


class AMissExplained(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        with (self.d / "docs.jsonl").open("w") as f:
            for i, s, pos, text, terms, near in DOCS:
                f.write(json.dumps({"id": i, "sitting": s, "pos": pos, "text": text, "terms": terms,
                                    "nearest": near}) + "\n")
        self.q = {**QUESTION, "id": QUESTION["qid"], "text": QUESTION["question"]}
        (self.d / "questions.jsonl").write_text(json.dumps(self.q) + "\n")  # the store's own form
        (self.d / "beam-questions.jsonl").write_text(json.dumps(QUESTION) + "\n")  # the sample's, for --gold
        # The sample's verdict file: what Jev said on the first run, so the reader's run asks nobody.
        rec = Recorder(jev_stand_in)
        asyncio.run(walk(MemoryStore(self.d), self.q, rec, Settings(waves=3, **SMALL)))
        rec.save(self.d / "verdicts.json")

    def step(self, waves):
        """The block, as the CLI's defaults would run it on BEAM but with SMALL's reads: the walk replayed from the
        verdict file with no fallback (`--offline`), its record written, then `percolate walk why` on that record."""
        replay = Replay(self.d / "verdicts.json")
        rec = asyncio.run(walk(MemoryStore(self.d), self.q, replay, Settings(waves=waves, **SMALL)))
        (self.d / "ladder.json").write_text(json.dumps(rec, default=str))
        why = CliRunner().invoke(app, ["walk", "why", str(self.d / "ladder.json"),
                                       "--gold", str(self.d / "beam-questions.jsonl")])
        self.assertEqual(why.exit_code, 0, why.output)
        return replay, why.output

    def test_the_answer_is_behind_an_open_lead_ranked_too_low(self):
        replay, why = self.step(waves=2)
        self.assertEqual((replay.asked, replay.missing), (0, 0))  # every clue from the file: no model, nothing unjudged
        self.assertIn("0 of 2 evidence documents read", why)
        self.assertIn("- 7 (c) open: term:ladder, 0.57, rank 2 of 2 open by P", why)
        self.assertIn("- 8 (c) open: term:ladder, 0.57, rank 2 of 2 open by P", why)
        self.assertIn("state at the stop: warm", why)

    def test_one_more_wave_travels_it_so_the_lead_was_right_and_late(self):
        _, why = self.step(waves=3)
        self.assertIn("1 of 2 evidence documents read", why)
        self.assertIn("- 8 (c) queued", why)
        self.assertNotIn("(b) rejected", why)

if __name__ == "__main__":
    unittest.main()
