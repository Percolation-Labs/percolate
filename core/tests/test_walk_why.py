"""`percolate walk why`: the audit and the per-document reasons, read from a walk's record alone.

The records here are written by hand in the engine's record format (version 1), each small enough to check by eye.
Every reason and every state has a case, and a record missing fields says so rather than guessing.
"""
import json
import tempfile
import unittest
from pathlib import Path

from percolate_core.walk import why as W


def wave(n, reads, fresh, expanded=None, opn=()):
    return {"wave": n, "reads": reads, "expanded_reads": reads if expanded is None else expanded, "judged": 0,
            "accepted": 0, "expanded": len(reads if expanded is None else expanded), "fresh": fresh,
            "singletons": 0.0, "open": list(opn)}


def clue(k, targets, p, w=1):
    decision = "unjudged" if p is None else "accepted" if p >= 0.5 else "rejected"
    return {"key": k, "kind": k.split(":")[0], "wave": w, "step": 1, "text": k, "targets": targets, "P": p,
            "decision": decision}


def record(**over):
    r = {
        "version": 1,
        "question": {"id": "q1", "text": "How long did the ladder take?"},
        "settings": {"gate": 0.5, "expand_all": True},
        "waves": [wave(1, [1, 2, 3], 0.4), wave(2, [4, 5], 0.2)],
        "clues": [
            clue("term:ladder", [6, 7], 0.57),       # accepted, still open: 6 and 7 unread
            clue("term:helping", [8], 0.53),         # accepted, still open, lower
            clue("term:moving", [9], 0.42),          # rejected, a near miss
            clue("term:wondering", [10], 0.2),       # rejected, far under
            clue("near:4", [11], None),              # never judged
            clue("next:5", [12], 0.9),               # travelled: 12 is queued
        ],
        "travelled": [{"key": "next:5", "kind": "next", "wave": 2, "step": 1, "P": 0.9, "born_wave": 2,
                       "born_step": 1, "rank": 1, "land": [12]}],
        "pending": [12],
        "open": {"term:ladder": {"P": 0.57, "wave": 1, "targets": [6, 7]},
                 "term:helping": {"P": 0.53, "wave": 2, "targets": [8]}},
        "rejected_open": {},
        "unjudged": 1,
        "reads": 5,
        "stop": {"reason": "waves", "detail": "2 waves"},
    }
    r.update(over)
    return r


class WhyEachReason(unittest.TestCase):
    def test_every_reason_and_its_letter(self):
        out = W.why(record(), gold=[1, 6, 8, 9, 10, 11, 12, 13])
        self.assertNotIn("1", out)  # read: no reason owed
        self.assertEqual(out["6"][:3], ["open", "term:ladder", 0.57])
        self.assertEqual(out["6"][3], "rank 1 of 2 open by P")
        self.assertEqual(out["8"][3], "rank 2 of 2 open by P")
        self.assertEqual(out["9"], ["rejected", "term:moving", 0.42])
        self.assertEqual(out["10"], ["rejected", "term:wondering", 0.2])
        self.assertEqual(out["11"][0], "unjudged")
        self.assertEqual(out["12"][0], "queued")
        self.assertEqual(out["13"][0], "never offered")
        self.assertEqual({W.LETTER[v[0]] for v in out.values()}, {"a", "b", "c", "?"})

    def test_ids_match_across_types(self):
        # gold from a command line is text; the record keeps the store's ids as JSON numbers
        self.assertEqual(W.why(record(), gold=["9"])["9"][0], "rejected")

    def test_open_beats_a_rejected_lead_to_the_same_document(self):
        r = record()
        r["clues"].append(clue("near:3", [6], 0.4))
        self.assertEqual(W.why(r, gold=[6])["6"][0], "open")

    def test_an_open_lead_whose_targets_are_all_read_is_not_open(self):
        r = record()
        r["open"]["term:done"] = {"P": 0.99, "wave": 1, "targets": [1, 2]}
        self.assertEqual(W.why(r, gold=[6])["6"][3], "rank 1 of 2 open by P")
        self.assertEqual([k for k, _, _ in W.audit(r)["open"]], ["term:ladder", "term:helping"])


class AuditState(unittest.TestCase):
    def state(self, **over):
        return W.audit(record(**over))["state"]

    def judged(self, **over):
        # the same walk with its one unjudged clue (near:4) left out: every lead it raised was judged
        r = record(**over)
        r["clues"] = [c for c in r["clues"] if c["P"] is not None]
        return W.audit(r)["state"]

    def test_warm(self):
        self.assertTrue(self.state().startswith("warm"))

    def test_cold_with_leads_open(self):
        self.assertEqual(self.state(waves=[wave(1, [1, 2, 3, 4, 5], 0.01)]), "cold, accepted leads open")

    def test_cold_with_nothing_open_is_the_certificate(self):
        self.assertEqual(self.judged(waves=[wave(1, [1, 2, 3, 4, 5], 0.0)], open={}),
                         "cold, no accepted lead open (certificate)")

    def test_an_unjudged_lead_to_unread_documents_bars_the_certificate(self):
        self.assertEqual(self.state(waves=[wave(1, [1, 2, 3, 4, 5], 0.0)], open={}),
                         "cold, no accepted lead open, but 1 unjudged leads still point at unread documents "
                         "(no certificate)")

    def test_a_walk_that_judged_no_clue_is_unknown(self):
        # an offline run with no verdict file: every clue unjudged, so nothing could be accepted or left open
        r = record(open={}, stop={"reason": "dry", "detail": ""})
        for c in r["clues"]:
            c["P"], c["decision"] = None, "unjudged"
        self.assertTrue(W.audit(r)["state"].startswith("unknown: no clue was judged"))

    def test_a_last_wave_that_expanded_nothing_is_unknown_not_cold(self):
        # sally's case A: after the first wave the walk read only search fill, 0 fresh over 0 expanded
        self.assertTrue(self.state(waves=[wave(1, [1, 2], 0.19), wave(2, [3, 4, 5], None, expanded=[])],
                                   open={}).startswith("unknown"))

    def test_ran_dry(self):
        self.assertEqual(self.judged(stop={"reason": "dry", "detail": "nothing left to read after wave 2"}, open={}),
                         "ran dry after wave 2; no accepted lead open (certificate)")

    def test_an_empty_wave_after_the_last_read_is_not_the_one_judged(self):
        self.assertEqual(self.judged(waves=[wave(1, [1, 2, 3, 4, 5], 0.4), wave(2, [], None, expanded=[])],
                                    stop={"reason": "dry", "detail": ""}, open={}),
                         "ran dry after wave 1; no accepted lead open (certificate)")

    def test_ran_dry_on_a_wave_that_expanded_nothing_is_still_unknown(self):
        self.assertTrue(self.state(waves=[wave(1, [1], None, expanded=[])],
                                   stop={"reason": "dry", "detail": ""}).startswith("unknown"))

    def test_near_misses_are_rejected_leads_under_the_gate_still_pointing_at_unread(self):
        r = record()
        r["clues"].append(clue("term:read", [1], 0.45))  # its target is read: not a near miss
        self.assertEqual(W.audit(r)["near misses"], [["term:moving", 0.42, 1]])


class MissingFields(unittest.TestCase):
    def test_a_record_without_temperatures_says_so(self):
        r = record(waves=[{"wave": 1, "reads": [1, 2, 3, 4, 5]}])
        self.assertEqual(W.audit(r)["state"], "missing: the record holds no per-wave temperature")
        self.assertEqual(W.audit(r)["last wave fresh"], "missing")

    def test_absent_fields_print_as_missing(self):
        r = record()
        for k in ("open", "pending", "unjudged", "clues"):
            del r[k]
        a = W.audit(r)
        self.assertEqual(a["missing"], ["clues", "open"])
        for k in ("open", "queued", "unjudged", "judged", "near misses"):
            self.assertEqual(a[k], "missing", k)
        text = W.render(W.explain(r))
        self.assertIn("accepted leads still open: missing", text)
        self.assertIn("missing from the record: clues, open", text)


class Render(unittest.TestCase):
    def test_render_and_load(self):
        r = record()
        text = W.render(W.explain(r, gold=[6, 9, 13]))
        self.assertIn("state at the stop: warm", text)
        self.assertIn("term:ladder  P 0.57, leaves 2 unread", text)
        self.assertIn("0 of 3 evidence documents read", text)
        self.assertIn("- 9 (b) rejected: term:moving, 0.42", text)
        self.assertIn("- 13 (a) never offered", text)
        self.assertLess(text.index("- 6 (c)"), text.index("- 13 (a)"))  # ids in number order, not text order
        self.assertIn("at P 0.35 to 0.5 still point", text)
        with tempfile.TemporaryDirectory() as d:
            one, many = Path(d, "one.json"), Path(d, "many.jsonl")
            one.write_text(json.dumps(r, indent=1))
            many.write_text(json.dumps(r) + "\n" + json.dumps(record(question={"id": "q2", "text": "?"})) + "\n")
            self.assertEqual([x["question"]["id"] for x in W.load(one)], ["q1"])
            self.assertEqual([x["question"]["id"] for x in W.load(many)], ["q1", "q2"])


class GoldFromAQuestionsFile(unittest.TestCase):
    """`--gold` takes the sample's own questions file, so a reader names no ids (REM-1206)."""

    def why(self, gold_file, text):
        from typer.testing import CliRunner
        from percolate_core.cli import app
        with tempfile.TemporaryDirectory() as d:
            rec, gold = Path(d, "walk.json"), Path(d, gold_file)
            rec.write_text(json.dumps(record()))
            gold.write_text(text)
            return CliRunner().invoke(app, ["walk", "why", str(rec), "--gold", str(gold)])

    def test_json_lines_with_qid_and_gold(self):
        rows = [{"qid": "q0", "question": "?", "gold": [1]}, {"qid": "q1", "question": "?", "gold": [6, 9, 13]}]
        out = self.why("questions.jsonl", "".join(json.dumps(q) + "\n" for q in rows))
        self.assertEqual(out.exit_code, 0, out.output)
        self.assertIn("0 of 3 evidence documents read", out.output)
        self.assertIn("- 9 (b) rejected: term:moving, 0.42", out.output)

    def test_one_line_is_a_question_not_a_map(self):
        out = self.why("questions.jsonl", json.dumps({"id": "q1", "text": "?", "gold": [6, 9, 13]}) + "\n")
        self.assertEqual(out.exit_code, 0, out.output)
        self.assertIn("0 of 3 evidence documents read", out.output)

    def test_a_question_the_file_lacks_is_refused(self):
        out = self.why("questions.jsonl", json.dumps({"qid": "q9", "gold": [1]}) + "\n")
        self.assertEqual(out.exit_code, 2)  # a usage error; the message's box wraps at the terminal's width
        self.assertIn("holds no evidence", out.output)


if __name__ == "__main__":
    unittest.main()
