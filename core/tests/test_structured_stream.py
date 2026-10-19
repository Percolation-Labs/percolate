"""A structured answer reaches a streaming client.

An agent with a `structured_output_schema` answers through pydantic-ai's output
tool, not through text parts, and the stream mapper only turned text parts into
TEXT_MESSAGE_CONTENT. So `POST /chat` with `stream: true` against the sample's
own `harbourmaster` returned a 200 whose events carried no answer at all --
RUN_FINISHED(result=null) -- while `stream: false` returned the JSON. Found by
running the agents page against a fresh compose stack.

The model here is pydantic-ai's FunctionModel with a stream function, as
`percolate_core.agentic.testing.scripted_model` uses, so the real streaming
path runs; only the model is fake.

Run: python -m unittest discover -s tests -p test_structured_stream.py
"""

from __future__ import annotations

import asyncio
import json
import unittest

from percolate_core.agentic import authoring
from percolate_core.agentic.contracts import ChatRequest, InboundMessage, RequestContext
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository, scripted_model

ANSWER = {"vessel": "Aurora Kestrel", "verdict": "two deficiencies"}


def structured_model():
    from pydantic_ai.models.function import DeltaToolCall, FunctionModel

    async def stream(messages, info):
        # The output tool is how pydantic-ai asks for a structured answer; its
        # name is pydantic-ai's to choose, so it is read rather than assumed.
        yield {0: DeltaToolCall(name=info.output_tools[0].name,
                                json_args=json.dumps(ANSWER), tool_call_id="out-1")}

    return FunctionModel(stream_function=stream)


def run(agent_doc, model):
    async def go():
        repo = MemoryRepository()
        await repo.upsert_agent(authoring.from_json_schema(agent_doc))
        sequencer = TurnSequencer(repo, Settings.from_env())
        result = await sequencer.run_turn(
            ChatRequest(model=agent_doc["name"],
                        messages=[InboundMessage(role="user", content="cited for?")]),
            RequestContext(tenant="t"),
            model=model,
        )
        return result, sequencer.sink.events

    return asyncio.run(go())


def text_of(events):
    return "".join(e.delta for e in events if e.type == "TEXT_MESSAGE_CONTENT")


class StructuredAnswerStreams(unittest.TestCase):
    DOC = {"type": "object", "name": "harbourmaster", "description": "Answer.",
           "properties": {"vessel": {"type": "string"}, "verdict": {"type": "string"}},
           "required": ["vessel", "verdict"]}

    def test_the_answer_is_on_the_stream(self):
        result, events = run(self.DOC, structured_model())
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(json.loads(text_of(events)), ANSWER)

    def test_start_content_end_in_order_once(self):
        _, events = run(self.DOC, structured_model())
        kinds = [e.type for e in events if e.type.startswith("TEXT_MESSAGE")]
        self.assertEqual(kinds, ["TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT",
                                 "TEXT_MESSAGE_END"])

    def test_streamed_text_matches_what_was_persisted(self):
        result, events = run(self.DOC, structured_model())
        assistant = [m for m in result.messages if m.role == "assistant"][0]
        self.assertEqual(text_of(events), assistant.content)

    def test_a_plain_agent_is_not_sent_twice(self):
        doc = {"type": "object", "name": "plain", "description": "Be brief.",
               "properties": {}}
        _, events = run(doc, scripted_model(reply="hello there friend"))
        self.assertEqual(text_of(events), "hello there friend")
        self.assertEqual(
            sum(e.type == "TEXT_MESSAGE_START" for e in events), 1)


if __name__ == "__main__":
    unittest.main()
