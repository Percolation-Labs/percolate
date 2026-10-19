"""An agent's declared output is enforced at the turn (REM-970).

pydantic-ai's StructuredDict asks the model for the declared JSON Schema but
enforces only that the answer is a JSON object. So `{"verdict": 42}` against
`required: [verdict, vessel]`, `verdict: string` finished as a successful turn
(found live in REM-957), and an `output_schema` that is a top-level array, as a
workflow step may declare, failed in the runtime with `Schema must be an
object`, which the worker classified as worth retrying five times.

The model here is pydantic-ai's FunctionModel with a stream function, as in
test_structured_stream, so the real streaming and output-validation path runs.

Run: python -m unittest discover -s tests -p test_a_declared_output_is_enforced.py
"""

from __future__ import annotations

import asyncio
import json
import unittest

from percolate_core.agentic import authoring
from percolate_core.agentic.contracts import ChatRequest, InboundMessage, RequestContext
from percolate_core.agentic.runtime.engine import DeclaredOutputInvalid
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository

DOC = {"type": "object", "name": "harbourmaster", "description": "Answer.",
       "properties": {"vessel": {"type": "string"}, "verdict": {"type": "string"}},
       "required": ["vessel", "verdict"]}
GOOD = {"vessel": "Aurora Kestrel", "verdict": "two deficiencies"}


def scripted(*answers):
    """A model that answers through the output tool, one scripted answer per call, and counts the calls."""
    from pydantic_ai.models.function import DeltaToolCall, FunctionModel

    calls = []

    async def stream(messages, info):
        calls.append(messages)
        answer = answers[min(len(calls), len(answers)) - 1]
        yield {0: DeltaToolCall(name=info.output_tools[0].name, json_args=json.dumps(answer),
                                tool_call_id=f"out-{len(calls)}")}

    return FunctionModel(stream_function=stream), calls


def run(model, doc=DOC, response_format=None):
    async def go():
        repo = MemoryRepository()
        await repo.upsert_agent(authoring.from_json_schema(doc))
        sequencer = TurnSequencer(repo, Settings.from_env())
        try:
            result = await sequencer.run_turn(
                ChatRequest(model=doc["name"], response_format=response_format,
                            messages=[InboundMessage(role="user", content="cited for?")]),
                RequestContext(tenant="t"),
                model=model,
            )
        except Exception as err:  # noqa: BLE001 -- a refused turn may surface as a raise
            return None, err
        return result, None

    return asyncio.run(go())


def answer_text(result):
    return result.messages[-1].content if result and result.messages else None


class ADeclaredOutputIsEnforced(unittest.TestCase):

    def test_a_conforming_answer_passes_once(self):
        model, calls = scripted(GOOD)
        result, err = run(model)
        self.assertIsNone(err)
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(json.loads(answer_text(result)), GOOD)
        self.assertEqual(len(calls), 1)

    def test_a_wrong_type_is_sent_back_and_the_corrected_answer_kept(self):
        model, calls = scripted({"vessel": "Aurora Kestrel", "verdict": 42}, GOOD)
        result, err = run(model)
        self.assertIsNone(err)
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(json.loads(answer_text(result)), GOOD)
        self.assertEqual(len(calls), 2, "the model is asked again")
        self.assertIn("does not match the declared output", json.dumps(
            [str(m) for m in calls[1]]), "with what was wrong")

    def test_an_answer_that_never_conforms_fails_the_turn(self):
        model, calls = scripted({"verdict": 42})
        result, err = run(model)
        failed = err is not None or (result is not None and result.run.status != "succeeded")
        self.assertTrue(failed, "a turn whose answer never conforms does not succeed")
        self.assertGreater(len(calls), 1, "after the model was asked again")

    def test_a_top_level_array_is_asked_for_and_returned_as_an_array(self):
        rows = [{"section": "intro"}, {"section": "method"}]
        array = {"type": "array", "items": {"type": "object", "required": ["section"],
                                            "properties": {"section": {"type": "string"}}}}
        model, calls = scripted({"value": rows})
        result, err = run(model, response_format={"type": "json_schema",
                                                  "json_schema": {"name": "plan", "schema": array}})
        self.assertIsNone(err, f"an array schema is taken, not refused: {err!r}")
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(json.loads(answer_text(result)), rows, "the answer is the array, unwrapped")

    def test_an_array_whose_items_do_not_conform_is_sent_back(self):
        array = {"type": "array", "items": {"type": "integer"}}
        model, calls = scripted({"value": ["one"]}, {"value": [1]})
        result, err = run(model, response_format={"type": "json_schema",
                                                  "json_schema": {"name": "n", "schema": array}})
        self.assertIsNone(err)
        self.assertEqual(json.loads(answer_text(result)), [1])
        self.assertEqual(len(calls), 2)

    def test_a_schema_that_is_not_a_schema_is_refused_at_push(self):
        bad = dict(DOC, properties={"vessel": {"type": "banana"}})
        with self.assertRaises(DeclaredOutputInvalid):
            authoring.from_json_schema(bad)

    def test_a_request_schema_that_is_not_a_schema_never_reaches_the_model(self):
        model, calls = scripted(GOOD)
        result, err = run(model, response_format={"type": "json_schema",
                                                  "json_schema": {"name": "x", "schema": {"type": "banana"}}})
        failed = err is not None or (result is not None and result.run.status != "succeeded")
        self.assertTrue(failed)
        self.assertEqual(len(calls), 0, "no turn is spent on a configuration error")


if __name__ == "__main__":
    unittest.main()
