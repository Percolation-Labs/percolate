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

    def test_the_client_keeps_a_running_total_for_metering(self):
        t = Recorder((200, OK), (200, OK))
        jev = t.client()
        run(jev.ask_many([("s", {"same": Noul("q")})] * 2))
        self.assertEqual((jev.requests, jev.input_tokens, jev.output_tokens), (2, 950, 160))

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


STANDIN = {"name": "standin", "endpoint": "http://host.docker.internal:8790/v1/decide", "model": "standin",
           "credential_ref": "STANDIN_API_KEY"}


class AnyDecider(unittest.TestCase):
    """P8_DECIDER: the endpoint, the model and the credential's name come from a claims.deciders row."""

    def test_a_decider_row_sets_where_the_request_goes_what_it_names_and_which_key_it_sends(self):
        seen = []

        def answer(request):
            seen.append(request)
            return httpx.Response(200, json={"model": "standin/claude-sonnet",
                                             "answers": {"q": {"type": "noul", "noul": 0.9}}})

        jev = Jev.for_decider(STANDIN, client=httpx.AsyncClient(transport=httpx.MockTransport(answer)))
        with patch.dict(os.environ, {"STANDIN_API_KEY": "local", "JEV_API_KEY": "not-this-one",
                                     "P8_CREDENTIAL_ORIGINS": '{"STANDIN_API_KEY": ["http://host.docker.internal:8790"]}'}):
            r = run(jev.ask("s", {"q": Noul("q")}))
        self.assertEqual(str(seen[0].url), STANDIN["endpoint"])
        self.assertEqual(json.loads(seen[0].content)["model"], "standin")
        self.assertEqual(seen[0].headers["authorization"], "Bearer local")
        self.assertEqual((r.model, r["q"].p), ("standin/claude-sonnet", 0.9))

    def test_the_rows_credential_is_bound_like_any_other(self):
        with patch.dict(os.environ, {"STANDIN_API_KEY": "local",
                                     "P8_CREDENTIAL_ORIGINS": '{"STANDIN_API_KEY": ["https://elsewhere.example"]}'}):
            with self.assertRaises(CredentialRefused):
                run(Jev.for_decider(STANDIN).ask("s", {"q": Noul("q")}))

    def test_a_row_without_its_endpoint_is_refused(self):
        with self.assertRaisesRegex(ValueError, "endpoint"):
            Jev.for_decider({"model": "m", "credential_ref": "K"})

    def test_configured_asks_the_database_which_decider(self):
        class Conn:
            async def fetchrow(self, sql, name):
                self.sql, self.name = sql, name
                return STANDIN | {}

        conn = Conn()
        jev = run(Jev.configured(conn))
        self.assertIn("claims.default_decider()", conn.sql)
        self.assertIsNone(conn.name)
        self.assertEqual((jev.endpoint, jev.model, jev.credential),
                         (STANDIN["endpoint"], "standin", "STANDIN_API_KEY"))

    def test_jev_is_still_the_default(self):
        jev = Jev()
        self.assertEqual((jev.endpoint, jev.model, jev.credential), (ENDPOINT, MODEL, "JEV_API_KEY"))


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


def echo(p=0.5, tokens=10):
    """A transport that answers every question it is sent with `p`, and keeps the requests."""
    sent = []

    def answer(request):
        body = json.loads(request.content)
        sent.append(body)
        return httpx.Response(200, json={
            "model": MODEL, "answers": {qid: {"type": "noul", "noul": p} for qid in body["questions"]},
            "usage": {"input_tokens": tokens, "output_tokens": 1}})
    return answer, sent


def echo_client(**kw):
    answer, sent = echo()
    return Jev(api_key="k", client=httpx.AsyncClient(transport=httpx.MockTransport(answer)), **kw), sent


class Batching(unittest.TestCase):
    """Jev is called in batches: a serial loop is refused, a wave is not, and a wave is split at the cap."""

    def test_a_loop_of_single_requests_is_refused_on_the_fourth(self):
        jev, sent = echo_client()

        async def loop():
            for i in range(10):
                await jev.ask({"i": i}, {"q": Noul("q")})
        with self.assertRaisesRegex(TerminalError, "Jev is called in batches"):
            run(loop())
        self.assertEqual(len(sent), 3, "three requests go out one at a time; the fourth is refused before it is sent")

    def test_a_loop_over_ask_many_of_one_is_refused_too(self):
        jev, _ = echo_client()

        async def loop():
            for i in range(10):
                await jev.ask_many([({"i": i}, {"q": Noul("q")})])
        with self.assertRaisesRegex(TerminalError, "ask_many"):
            run(loop())

    def test_a_wave_of_a_hundred_requests_never_trips_it_wave_after_wave(self):
        jev, sent = echo_client()

        async def waves():
            for w in range(5):
                got = await jev.ask_many([({"w": w, "i": i}, {"q": Noul("q")}) for i in range(100)])
                self.assertEqual(len(got), 100)
        run(waves())
        self.assertEqual(len(sent), 500)

    def test_serial_ok_lets_a_one_shot_caller_through(self):
        jev, sent = echo_client(serial_ok=True)

        async def loop():
            for i in range(6):
                await jev.ask({"i": i}, {"q": Noul("q")})
        run(loop())
        self.assertEqual(len(sent), 6)

    def test_requests_more_than_a_second_apart_are_not_a_loop(self):
        jev, sent = echo_client()
        clock = iter(range(0, 1000, 5))  # every reading 5 s after the last

        async def loop():
            for i in range(6):
                await jev.ask({"i": i}, {"q": Noul("q")})
        with patch("percolate_core.decide.time.monotonic", lambda: next(clock)):
            run(loop())
        self.assertEqual(len(sent), 6)

    def test_a_wave_is_split_at_sixty_questions_keeping_ids_order_and_tokens(self):
        jev, sent = echo_client()
        qs = {f"k{i:03d}": Noul(f"q{i}") for i in range(150)}
        [r] = run(jev.ask_many([("s", qs)]))
        self.assertEqual([len(b["questions"]) for b in sent], [60, 60, 30])
        self.assertEqual([k for b in sent for k in b["questions"]], list(qs))
        self.assertEqual(list(r.answers), list(qs))
        self.assertEqual((r.input_tokens, r.output_tokens), (30, 3))
        self.assertEqual(jev.requests, 3)

    def test_a_wave_is_split_at_the_byte_cap(self):
        from percolate_core.decide import split
        qs = {f"k{i}": Noul("x" * 5000) for i in range(10)}
        parts = split(qs)
        self.assertTrue(all(len(json.dumps({k: q.wire() for k, q in p.items()})) <= 24_000 + 100 for p in parts))
        self.assertEqual(len(parts), 3)
        self.assertEqual([k for p in parts for k in p], list(qs))

    def test_the_walk_decider_sends_the_same_requests_as_before_all_at_once(self):
        from percolate_core.walk.deciders import jev as walk_jev
        jev, sent = echo_client()
        clues = {f"clue{i:03d}": f"text {i}" for i in range(130)}
        got = run(walk_jev(jev)({"text": "who?"}, clues))
        self.assertEqual(set(got), set(clues))
        keys = sorted(clues)
        before = [{f"c{x}": {"type": "noul", "instructions": clues[k]} for x, k in enumerate(keys[i:i + 60])}
                  for i in range(0, len(keys), 60)]
        self.assertEqual([b["questions"] for b in sent], before)
        self.assertEqual(jev._alone, 0, "a wave of three requests is one call, not three")
