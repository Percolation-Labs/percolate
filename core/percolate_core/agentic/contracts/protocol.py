"""The two wire protocols, deliberately asymmetric (``brief.md`` §5.1 item 2).

Inbound: an OpenAI-chat-completions-*shaped* request — "not because this system
is calling OpenAI specifically, but because that shape is the de facto common
denominator most existing clients and SDKs already speak, so nothing upstream
needs a bespoke client just to talk to this runtime."

Outbound: AG-UI events — this system's richer wire protocol on the way out.

The one structural claim worth checking at review time: **nested delegation
needs no new event types**. A delegation is a ``tool_call`` message whose tool
happens to be another agent, so the sub-agent's whole streamed turn is exactly
the payload of a ``ToolCallStart``/``ToolCallEnd`` pair in the parent's stream,
correlated by the sub-run's own ``runId``. A client renders "delegating to agent
B" as an in-progress tool call without the protocol knowing delegation exists.
"""

from __future__ import annotations

import json
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

# --------------------------------------------------------------------------
# Inbound — OpenAI chat-completions shape
# --------------------------------------------------------------------------


class InboundMessage(BaseModel):
    role: Literal["system", "user", "assistant", "tool"]
    content: str | None = None
    tool_call_id: str | None = None

    @field_validator("content", mode="before")
    @classmethod
    def _serialise_structured_content(cls, v: Any) -> Any:
        """Accept an object or a list here and render it as JSON text.

        THE CENTRAL CASE, not a convenience. A workflow's `agent:` step is
        almost always fed the step before it -- `input:
        '{{steps.retrieve.result}}'` is the documented idiom and the one the
        compiler's own error message recommends -- and a p8ql step's result is
        a JSON *object*: `{"mode": "SEARCH", "rows": [...]}`. Sent as-is that
        was a 422 on `Input should be a valid string`, so the documented way to
        hand retrieved passages to an agent could not be written at all.

        The alternative was to make every author serialise it themselves in the
        template, which pushes a JSON encoder into a YAML document and gets the
        escaping wrong in a way that only shows up on the row containing a
        quote. Doing it once, here, at the boundary where the shape is known,
        is the cheaper half.

        Anything already a string is passed through untouched -- an ordinary
        chat client is unaffected, and a caller who wants specific formatting
        still gets exactly what they sent.
        """
        if v is None or isinstance(v, str):
            return v
        if isinstance(v, (dict, list)):
            return json.dumps(v, ensure_ascii=False)
        return v


class ChatRequest(BaseModel):
    """What a client POSTs. ``model`` names an *agent*, not an LLM.

    That reuse is the point: an off-the-shelf OpenAI-shaped client can drive
    this runtime by putting an agent name where it would normally put a model
    name, with no bespoke fields. The LLM actually used comes from the
    ``agents`` row.
    """

    model: str = Field(description="The agents.name to run.")
    messages: list[InboundMessage]
    stream: bool = Field(
        default=False,
        description=(
            "SSE of AG-UI events when true; one OpenAI completion object when "
            "false. FALSE IS THE DEFAULT BECAUSE IT IS OPENAI'S -- this shape "
            "is borrowed whole, and a borrowed shape with a different default "
            "cannot be driven by a stock client. It defaulted to true, and "
            "rejected false outright, until an `agent:` workflow step -- which "
            "sets no stream key and reads choices.0.message.content -- turned "
            "out never to have been able to complete on any deployment."
        ),
    )
    session_id: UUID | None = Field(
        default=None,
        description=(
            "AG-UI threadId. May also be sent as the X-P8-Session-Id header, "
            "which is the route an off-the-shelf OpenAI client has to take "
            "since that shape has nowhere to put a thread id. A new session is "
            "created when neither is present."
        ),
    )
    tools: list[dict[str, Any]] | None = Field(
        default=None,
        description=(
            "Client-declared tools are accepted by the shape but NOT honoured: "
            "an agent's tool surface is whatever tool_servers its row points "
            "at (brief.md §5.2, zero built-in and zero caller-supplied tools)."
        ),
    )
    tool_choice: Literal['none', 'auto'] | None = Field(
        default=None,
        description=(
            "'none' narrows this turn to a response: no tool bindings or "
            "chained action. It never changes the stored agent. 'auto' or omitting it "
            "keeps the agent's configured behaviour. Caller-supplied tools "
            "still cannot widen an agent's capabilities."
        ),
    )
    response_format: dict[str, Any] | None = Field(
        default=None,
        description=(
            "OpenAI's own shape -- {'type': 'json_schema', 'json_schema': "
            "{'name': ..., 'schema': {...}}} -- and UNLIKE `tools` it IS "
            "honoured, because a shape is a request about this turn's answer "
            "rather than an attempt to widen what the agent may do. It "
            "overrides the row's structured_output_schema for one turn and "
            "changes nothing durable. This is how a workflow `agent:` step's "
            "`output_schema:` reaches the model instead of only judging it "
            "afterwards."
        ),
    )


# --------------------------------------------------------------------------
# Outbound — AG-UI events
# --------------------------------------------------------------------------


class AGUIEvent(BaseModel):
    """Base for every streamed event. ``run_id`` is what correlates a sub-agent's
    events to the parent's in-progress tool call."""

    type: str
    run_id: UUID | None = None
    thread_id: UUID | None = None


class RunStarted(AGUIEvent):
    type: Literal["RUN_STARTED"] = "RUN_STARTED"
    agent_name: str | None = None
    parent_run_id: UUID | None = None


class TextMessageStart(AGUIEvent):
    type: Literal["TEXT_MESSAGE_START"] = "TEXT_MESSAGE_START"
    message_id: UUID | None = None


class TextMessageContent(AGUIEvent):
    type: Literal["TEXT_MESSAGE_CONTENT"] = "TEXT_MESSAGE_CONTENT"
    message_id: UUID | None = None
    delta: str = ""


class TextMessageEnd(AGUIEvent):
    type: Literal["TEXT_MESSAGE_END"] = "TEXT_MESSAGE_END"
    message_id: UUID | None = None


class ToolCallStart(AGUIEvent):
    type: Literal["TOOL_CALL_START"] = "TOOL_CALL_START"
    tool_call_id: str = ""
    tool_name: str = ""
    child_run_id: UUID | None = Field(
        default=None, description="Set when this 'tool' is a delegated agent."
    )


class ToolCallEnd(AGUIEvent):
    type: Literal["TOOL_CALL_END"] = "TOOL_CALL_END"
    tool_call_id: str = ""
    is_error: bool = False
    error_kind: str | None = None


# Not defined here, deliberately: TOOL_CALL_ARGS (argument deltas) and
# STATE_SNAPSHOT (a mirror of ``runs.state``). Both are real AG-UI events and
# both would be speculative — nothing in this runtime streams tool arguments
# token by token, and nothing writes ``runs.state`` yet. They arrive when
# something needs them.


class RunFinished(AGUIEvent):
    type: Literal["RUN_FINISHED"] = "RUN_FINISHED"
    status: str = "succeeded"
    result: Any = None


class RunError(AGUIEvent):
    type: Literal["RUN_ERROR"] = "RUN_ERROR"
    status: str = "failed"
    message: str = ""


def to_sse(event: AGUIEvent | dict[str, Any]) -> str:
    """Render one event as an SSE frame — models and relayed dicts alike.

    One function because there are two sources: events this process built, and
    events it read off the ``NOTIFY`` channel that another process built. A
    second renderer for the second case is how a wire format quietly acquires
    two dialects.
    """
    if isinstance(event, dict):
        payload = json.dumps(event, default=str)
        return f"event: {event.get('type', 'message')}\ndata: {payload}\n\n"
    return f"event: {event.type}\ndata: {event.model_dump_json()}\n\n"
