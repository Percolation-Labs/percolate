"""The Jev decision client: wire shape, failures, the join, and the live service.

The unit cases run the real client against an httpx MockTransport and read
what it sent. The live cases run only when JEV_API_KEY is set, and assert on
decisions whose answer is not in doubt -- they prove the wiring, not Jev.
"""
import asyncio
import json
import os
import unittest
from unittest.mock import patch

import httpx

from percolate_core.core.config import TerminalError
from percolate_core.core.credentials import CredentialRefused
from percolate_core.decide import ENDPOINT, MODEL, Choice, Jev, Noul, Score

OK = {"model": "jev-1.13.0",
      "answers": {"same": {"type": "noul", "noul": 0.98},
                  "rel": {"type": "choice", "choice": "same_as", "confidence": 1.0,
                          "probabilities": {"same_as": 1.0, "unrelated": 0.0}},
                  "sim": {"type": "score", "score": 1.99, "confidence": 0.99,
                          "legend": {"0": "none", "1": "weak", "2": "strong"},
                          "probabilities": {"0": 0.0, "1": 0.01, "2": 0.99}}},
      "usage": {"input_tokens": 475, "output_tokens": 80}}


def run(coro):
    return asyncio.run(coro)


class Recorder:
    """A transport that answers from a list and keeps every request."""

    def __init__(self, *responses):
        self.responses, self.sent = list(responses), []

    def __call__(self, request):
        self.sent.append(request)
        status, body, *headers = self.responses.pop(0)
        return httpx.Response(status, json=body, headers=headers[0] if headers else None)

    def client(self, **kw):
        return Jev(api_key="k", client=httpx.AsyncClient(transport=httpx.MockTransport(self)),
                   **kw)


class WireShape(unittest.TestCase):
    def test_one_request_carries_every_question_typed_and_the_pinned_model(self):
        t = Recorder((200, OK))
        r = run(t.client().ask({"a": 1}, {
            "same": Noul("same?", yes="identical", no="different"),
            "rel": Choice("how?", {"same_as": "same", "unrelated": None}),
            "sim": Score("how strong?", ["none", "weak", "strong"])}))
        sent = json.loads(t.sent[0].content)
        self.assertEqual(str(t.sent[0].url), ENDPOINT)
        self.assertEqual(t.sent[0].headers["authorization"], "Bearer k")
        self.assertEqual(sent["model"], MODEL)
        self.assertEqual(sent["questions"]["same"],
                         {"type": "noul", "instructions": "same?",
                          "criteria": {"true": "identical", "false": "different"}})
        self.assertEqual(sent["questions"]["rel"]["criteria"], {"same_as": "same", "unrelated": None})
        self.assertEqual(sent["questions"]["sim"]["criteria"], ["none", "weak", "strong"])
        self.assertEqual(r.model, "jev-1.13.0")
        self.assertEqual((r["same"].value, r["same"].p, r["same"].confidence), (0.98, 0.98, None))
        self.assertEqual((r["rel"].value, r["rel"].p), ("same_as", 1.0))
        self.assertEqual((r["sim"].value, r["sim"].p), (1.99, 0.99))
        self.assertEqual((r.input_tokens, r.output_tokens), (475, 80))

    def test_a_noul_without_criteria_sends_none(self):
        self.assertNotIn("criteria", Noul("q").wire())


class Failures(unittest.TestCase):
    def test_a_refused_key_fails_once(self):
        t = Recorder((401, {"detail": {"error_type": "authentication_error"}}))
        with self.assertRaises(TerminalError):
            run(t.client().ask("s", {"q": Noul("q")}))
        self.assertEqual(len(t.sent), 1)

    def test_a_malformed_question_fails_once_and_says_why(self):
        t = Recorder((400, {"detail": "Choice question must have at least one choice: q"}))
        with self.assertRaisesRegex(TerminalError, "at least one choice"):
            run(t.client().ask("s", {"q": Choice("q", {})}))
        self.assertEqual(len(t.sent), 1)

    def test_a_rate_limit_is_waited_out(self):
        t = Recorder((429, {"detail": "slow down"}, {"retry-after": "0"}), (200, OK))
        r = run(t.client().ask("s", {"same": Noul("q")}))
        self.assertEqual((len(t.sent), r["same"].p), (2, 0.98))

    def test_a_persistent_outage_stops_after_its_retries(self):
        t = Recorder(*[(503, {}, {"retry-after": "0"})] * 2)
        with self.assertRaises(RuntimeError):
            run(t.client(retries=1).ask("s", {"q": Noul("q")}))
        self.assertEqual(len(t.sent), 2)

    def test_an_answer_missing_a_question_is_refused(self):
        t = Recorder((200, {"model": "jev-1.13.0", "answers": {}}))
        with self.assertRaisesRegex(TerminalError, "without"):
            run(t.client().ask("s", {"q": Noul("q")}))

    def test_the_key_goes_nowhere_it_is_not_bound(self):
        with patch.dict(os.environ, {"JEV_API_KEY": "k", "P8_CREDENTIAL_ORIGINS": "{}"}):
            with self.assertRaises(CredentialRefused):
                run(Jev().ask("s", {"q": Noul("q")}))


class Join(unittest.TestCase):
    def test_one_request_per_left_row_and_keys_come_back_unchanged(self):
        def answer(request):
            qs = json.loads(request.content)["questions"]
            return httpx.Response(200, json={"model": MODEL, "answers": {
                qid: {"type": "noul", "noul": 0.9 if q["instructions"]["candidate"] == "x" else 0.1}
                for qid, q in qs.items()}})
        sent = []
        transport = httpx.MockTransport(lambda r: (sent.append(r), answer(r))[1])
        jev = Jev(api_key="k", client=httpx.AsyncClient(transport=transport))
        out = run(jev.join(["L0", "L1", "L2"],
                           [{"key with spaces": "x", "k2": "y"}, {}, {"k3": "x"}],
                           "Is `candidate` `record`?"))
        self.assertEqual(out, [{"key with spaces": 0.9, "k2": 0.1}, {}, {"k3": 0.9}])
        self.assertEqual(len(sent), 2)  # the row with no candidates costs nothing
        self.assertEqual(json.loads(sent[0].content)["state"], {"record": "L0"})


@unittest.skipUnless(os.environ.get("JEV_API_KEY"), "JEV_API_KEY not set")
class Live(unittest.TestCase):
    def jev(self):
        return Jev(api_key=os.environ["JEV_API_KEY"])

    def test_every_question_type_answers_from_the_pinned_version(self):
        async def go():
            async with self.jev() as jev:
                return await jev.ask(
                    {"a": {"name": "Intl. Business Machines Corp.", "hq": "Armonk, NY"},
                     "b": {"name": "IBM", "hq": "Armonk, New York"}},
                    {"same": Noul("Do `a` and `b` refer to the same real-world entity?"),
                     "rel": Choice("How is `a` related to `b`?",
                                   {"same_as": "the same entity",
                                    "part_of": "one is part of the other",
                                    "unrelated": "no meaningful relation"}),
                     "sim": Score("How strong is the evidence they are the same entity?",
                                  ["none", "weak", "strong"])})
        r = run(go())
        self.assertEqual(r.model, MODEL)
        self.assertGreater(r["same"].p, 0.8)
        self.assertEqual(r["rel"].value, "same_as")
        self.assertGreater(r["sim"].value, 1.5)

    def test_join_separates_a_match_from_a_namesake(self):
        async def go():
            async with self.jev() as jev:
                return await jev.join(
                    [{"name": "Apple Inc.", "industry": "consumer electronics",
                      "hq": "Cupertino, CA"}],
                    [{"match": {"name": "Apple", "ticker": "AAPL", "makes": "iPhone"},
                      "namesake": {"name": "Apple Corps Ltd", "founded_by": "The Beatles",
                                   "industry": "music"}}],
                    "Is `candidate` the same company as `record`?")
        (row,) = run(go())
        self.assertGreater(row["match"], 0.8)
        self.assertLess(row["namesake"], 0.2)


if __name__ == "__main__":
    unittest.main()
