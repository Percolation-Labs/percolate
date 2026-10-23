"""The thin layer around pydantic-ai's ``Agent`` (``brief.md`` §5, §5.1).

"The LLM-calling, tool-invoking, structured-output engine stays pydantic-ai's;
this layer's job is everything around that engine that pydantic-ai itself is
naturally silent on."

So this module is deliberately small. If it starts growing prompt templating,
retry policies, or tool logic, that is the layer stopping being thin — and each
of those is something the spec explicitly assigns elsewhere (data, the tool
server, or ``workflow-engine``).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

from pydantic import BaseModel

from .. import telemetry
from ..contracts import AgentDeps, AgentSpec, RequestContext, ToolResult
from ..settings import Settings
from ..tools import ResolvedToolset, build_pydantic_ai_tools
from . import budget as budget_usage
from .injection import build_instructions


# Which pip extra supplies which provider prefix. pydantic-ai raises a bare
# ImportError naming its own package ("Please install the `anthropic`
# package"), which is true and unhelpful here: the reader has a row in a
# database with `model` in it, not a pydantic-ai install to reason about. This
# maps the failure back to the thing they can act on.
#
# The prefixes NOT listed are the OpenAI-compatible ones -- openrouter,
# cerebras, xai, zai and any gateway -- which need no SDK of their own and so
# can never land here.
_PROVIDER_EXTRA = {
    "anthropic": "anthropic",
    "google": "google",
    "google-gla": "google",
    "google-vertex": "google",
    "groq": "groq",
    "mistral": "mistral",
    "cohere": "cohere",
    "huggingface": "huggingface",
    "bedrock": "bedrock",
}


def _missing_provider(model: Any, err: ImportError) -> ImportError:
    """Re-raise a provider ImportError as something a reader can act on."""
    name = model if isinstance(model, str) else getattr(model, "model_name", str(model))
    prefix = name.split(":", 1)[0] if isinstance(name, str) else ""
    extra = _PROVIDER_EXTRA.get(prefix)
    if not extra:
        return err
    return ImportError(
        f"the agent's model is '{name}', and the '{prefix}' provider is not "
        f"installed in this process. Install it with "
        f"`pip install 'percolate-core[providers]'` (the published image "
        f"carries every provider), or point the row at an OpenAI-compatible "
        f"endpoint -- set OPENAI_BASE_URL and use an `openai:` model, which is "
        f"then sent to the endpoint's /chat/completions and needs no additional "
        f"package. Original error: {err}"
    )


def gateway_model(model: Any) -> Any:
    """`openai:` behind OPENAI_BASE_URL means chat completions (REM-973).

    pydantic-ai's `openai:` prefix calls the Responses API (`/v1/responses`).
    OpenAI serves it; the OpenAI-compatible gateways the docs and the message
    above point people at mostly do not, so the documented recipe -- set
    OPENAI_BASE_URL, keep an `openai:` model -- failed every turn with
    `ModelHTTPError: status_code: 404` (found live in REM-957 against a
    chat-completions stub). Every such gateway serves /chat/completions, and so
    does OpenAI, so with a base URL set an `openai:` model is sent there as
    `openai-chat:`. A row that names `openai-chat:` or `openai-responses:`
    keeps exactly what it asked for. Without a base URL, or with OpenAI's own
    (get-percolate's compose file sets OPENAI_BASE_URL to
    https://api.openai.com/v1 by default), nothing changes.
    """
    base = os.environ.get("OPENAI_BASE_URL") or ""
    if (isinstance(model, str) and model.startswith("openai:") and base
            and urlsplit(base).hostname != "api.openai.com"):
        return "openai-chat:" + model.split(":", 1)[1]
    return model


@dataclass(slots=True)
class ExecutionResult:
    """What one LLM turn produced, before any of it is persisted."""

    text: str | None = None
    output: Any = None
    tool_results: list[ToolResult] = field(default_factory=list)
    usage: dict[str, Any] = field(default_factory=dict)
    # Fraction of the model's context window this turn occupied, as pydantic-ai
    # measured it against the model's declared window. None when the model
    # declares no window, or when nothing was streamed. `brief.md` §9 asked for
    # "message count vs. token estimate"; this is the estimate, and it is the
    # library's rather than one of ours built out of len().
    context_window_used: float | None = None


class AgentEngine:
    """Builds and runs one pydantic-ai agent from one ``agents`` row."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def build(
        self,
        agent: AgentSpec,
        toolset: ResolvedToolset,
        context: RequestContext,
        *,
        model: Any = None,
        on_tool_result: Any = None,
        headers: dict[str, str] | None = None,
        before_call: Any = None,
    ) -> Any:
        """Assemble a ``pydantic_ai.Agent`` from config alone.

        Every argument to the constructed agent traces to a column:
        ``instructions`` from ``system_prompt`` plus injected context,
        ``tools`` from resolved ``tool_servers`` references, ``output_type``
        from ``structured_output_schema``, ``model`` from ``agents.model`` (or
        the process default).

        ``model`` overrides the row — that is what makes the fake-model test
        path (``fakes.scripted_model``) possible without a special code path in
        the runtime, per phase gate 7: tested only through the contract.
        """
        from pydantic_ai import Agent

        chosen = gateway_model(model or agent.model or self.settings.default_model)
        try:
            pai_agent = Agent(
                chosen,
                instructions=build_instructions(agent, context),
                deps_type=AgentDeps,
                tools=build_pydantic_ai_tools(
                    toolset, on_result=on_tool_result, headers=headers, before_call=before_call
                ),
                output_type=self.output_type(agent),
                name=agent.name,
            )
        except ImportError as err:
            raise _missing_provider(chosen, err) from err
        if agent.structured_output_schema:
            pai_agent.output_validator(declared_output_check(agent.structured_output_schema))
        return pai_agent

    def output_type(self, agent: AgentSpec) -> Any:
        """Turn ``structured_output_schema`` (JSON Schema) into an output type.

        Presence of a schema is what makes ``chained_action`` reachable
        (``brief.md`` §2/§4), so this is not cosmetic: it decides whether a run
        can trigger a follow-on action at all.

        pydantic-ai's ``StructuredDict`` takes the JSON Schema directly and asks
        the model for it, but it ENFORCES only that the answer is a JSON object
        (REM-970): `{"verdict": 42}` against `required: [verdict, vessel]`,
        `verdict: string` finished as a successful turn. So the schema is asked
        for here and checked by ``declared_output_check``, which ``build``
        registers as the run's output validator: a reply that does not conform
        is sent back to the model with what was wrong, and a turn that never
        conforms fails.

        A schema that is not an object -- a workflow step's `output_schema:
        {type: array, ...}` arrives here as `response_format` -- is wrapped as
        `{value: <schema>}`, because StructuredDict refuses anything else with
        `Schema must be an object`, a configuration error the worker classified
        as worth retrying five times. The validator unwraps it, so the answer is
        the array the step declared.
        """
        schema = agent.structured_output_schema
        if not schema:
            return str
        check_declared_output(schema)
        from pydantic_ai.output import StructuredDict

        return StructuredDict(
            schema if _is_object(schema) else _wrapped(schema),
            name=f"{agent.name}_output",
        )

    async def execute(
        self,
        pai_agent: Any,
        user_prompt: str,
        message_history: list[Any],
        deps: AgentDeps,
        *,
        on_event: Any = None,
        budget: Any = None,
        run: Any = None,
    ) -> ExecutionResult:
        """Run one turn, streaming pydantic-ai's own events out as they happen.

        ``on_event`` receives already-mapped AG-UI events. Mapping here rather
        than in the caller keeps one rule true: every AG-UI event this system
        emits during generation corresponds to something pydantic-ai actually
        reported, so the stream cannot drift from what the model did.

        The stream is not the record. Rows are (``brief.md`` §4: ``runs.state``
        exists so "a resumed/observed run doesn't need in-memory server
        affinity") — a client that disconnects mid-run loses the deltas and
        nothing else, because the ``MESSAGE_PERSISTED`` checkpoint on the same
        channel lets it resume from the row.

        ``budget`` carries the delegation tree's allowance and what it has spent
        (``runtime/budget.py``). Passing ``usage`` seeded with the ancestors'
        spend is the over-the-wire form of pydantic-ai's own instruction to hand
        a delegate ``ctx.usage``: a limit applies to a sum, so a child that
        starts at zero makes the parent's limit bind one level of the tree.

        ``run`` supplies the ids. ``run_id`` and ``conversation_id`` are handed
        to pydantic-ai rather than left to be generated, so the ids in its spans
        are the ids in ``agentic.runs`` and ``agentic.sessions`` and a trace
        joins to a row without a lookup table.
        """
        # The handler is installed even with no `on_event`, because it is also
        # how the run context is reached: `context_window_used` lives on the
        # `RunContext` pydantic-ai hands the stream handler and is not on the
        # result. Without a handler there is no other way to read it, and
        # `persistence.needs_summarization` now wants it.
        window: dict[str, Any] = {}

        async def handler(ctx: Any, stream: Any) -> None:
            used = getattr(ctx, "context_window_used", None)
            if isinstance(used, float):
                # Highest of the turn, not the last: a turn that filled the
                # window and then had a tool return trimmed history still spent
                # the window, and the summarizer wants to know that.
                window["used"] = max(window.get("used", 0.0), used)
            async for event in stream:
                if on_event is None:
                    continue
                for mapped in map_stream_event(event):
                    await on_event(mapped)

        kwargs: dict[str, Any] = {}
        if budget is not None:
            if (limits := budget.usage_limits()) is not None:
                kwargs["usage_limits"] = limits
            if (seed := budget.seed_usage()) is not None:
                kwargs["usage"] = seed
        if run is not None:
            if getattr(run, "id", None) is not None:
                kwargs["run_id"] = str(run.id)
            if getattr(run, "session_id", None) is not None:
                kwargs["conversation_id"] = str(run.session_id)

        # The turn's own span WRAPS the model call rather than being annotated
        # beside it, so pydantic-ai's spans are its children and percolate's ids
        # sit on their common parent. A no-op when tracing is off.
        with telemetry.run_span(run) as span:
            result = await pai_agent.run(
                user_prompt,
                message_history=message_history or None,
                deps=deps,
                event_stream_handler=handler,
                **kwargs,
            )
            usage = budget_usage.usage_dict(_usage_of(result))
            telemetry.record_usage(span, usage)
        # `result.usage()` was dropped on the floor here, which left
        # `ExecutionResult.usage` declared and never written -- and left
        # `rbac.has_quota_remaining(user, 'llm_tokens')` gating every call on a
        # counter that nothing in this runtime increments. Capturing it does not
        # by itself close that loop (the SQL function is still owed), but it is
        # the half that has to exist first.
        return ExecutionResult(
            text=as_text(result.output),
            output=result.output,
            usage=usage,
            context_window_used=window.get("used"),
        )


def _usage_of(result: Any) -> Any:
    """``result.usage()`` without letting its absence fail a completed turn.

    It is a method on the run result today. It has been an attribute before, and
    a turn whose model call succeeded and whose deltas already reached the client
    must not be reported as failed because an accounting accessor moved.
    """
    usage = getattr(result, "usage", None)
    if usage is None:
        return None
    try:
        return usage() if callable(usage) else usage
    except Exception:  # noqa: BLE001 -- see the docstring
        return None


# The key a non-object declared output is wrapped under (see output_type).
WRAPPED = "value"


def _is_object(schema: dict[str, Any]) -> bool:
    kind = schema.get("type")
    return kind == "object" or (kind is None and "properties" in schema)


def _wrapped(schema: dict[str, Any]) -> dict[str, Any]:
    return {"type": "object", "properties": {WRAPPED: schema}, "required": [WRAPPED],
            "additionalProperties": False}


class DeclaredOutputInvalid(ValueError):
    """A declared output that is not a JSON Schema at all. Raised before any model
    call, so a turn is never spent on it, and never worth retrying."""


def check_declared_output(schema: Any) -> None:
    if not isinstance(schema, dict):
        raise DeclaredOutputInvalid(f"the declared output is not a JSON Schema object: {schema!r}")
    from jsonschema import exceptions, validators

    try:
        validators.validator_for(schema).check_schema(schema)
    except exceptions.SchemaError as err:
        raise DeclaredOutputInvalid(f"the declared output is not a valid JSON Schema: {err.message}") from err


def declared_output_check(schema: dict[str, Any]) -> Any:
    """The output validator that makes a declared output a contract (REM-970).

    Unwraps a non-object answer, checks it against the schema the agent or the
    request declared, and on a mismatch raises ModelRetry with every violation,
    so the model is asked again with what was wrong; pydantic-ai fails the turn
    once its retries are spent. The check is full JSON Schema, which the
    workflow engine's own shape check (types, required, properties, enum,
    items, additionalProperties) is a subset of, so an answer this accepts the
    step that asked for it accepts too.
    """
    from jsonschema import validators
    from pydantic_ai import ModelRetry

    wrapped = not _is_object(schema)
    validator = validators.validator_for(schema)(schema)

    def check(output: Any) -> Any:
        value = output.get(WRAPPED) if wrapped and isinstance(output, dict) else output
        errors = sorted(validator.iter_errors(value), key=lambda e: list(e.absolute_path))
        if errors:
            raise ModelRetry("The answer does not match the declared output: " + "; ".join(
                (".".join(str(p) for p in e.absolute_path) or "(the answer)") + ": " + e.message
                for e in errors[:10]))
        return value

    return check


def as_text(output: Any) -> str:
    """Render one turn's output as the text that gets persisted and returned.

    NOT ``str()``, which is what this was. When an agent declares a
    ``structured_output_schema`` pydantic-ai hands back a dict or a model, and
    ``str()`` of a dict is a **Python repr** -- single quotes, `None`, `True` --
    which is not JSON and cannot be parsed by anything downstream. So the one
    feature whose entire purpose is a machine-readable answer produced the one
    encoding no machine reads:

        {'vessel': 'Meridian Dawn', 'verdict': 'pending survey'}

    It reached `agentic.messages.content`, it came back through
    `choices.0.message.content`, and a workflow `agent:` step carrying the same
    `output_schema` then failed with `output_schema was declared, but the
    result is not JSON` -- the engine correctly refusing its own output.

    A plain string stays exactly as it is: an ordinary conversational agent has
    no schema, its output is already text, and quoting it would be a change to
    every answer this system has ever given.
    """
    if isinstance(output, str):
        return output
    if isinstance(output, BaseModel):
        return output.model_dump_json()
    if isinstance(output, (dict, list)):
        # `default=str` so a uuid or a datetime the model produced serialises
        # rather than raising -- a turn that ran is not thrown away over an
        # encoder's opinion of a value the caller can read perfectly well.
        return json.dumps(output, ensure_ascii=False, default=str)
    return str(output)


def map_stream_event(event: Any) -> list[dict[str, Any]]:
    """pydantic-ai stream event → zero or more AG-UI-shaped payloads.

    Deliberately returns plain dicts of *fields*, not built AG-UI models: the
    caller owns ``run_id``/``thread_id``/``message_id``, which this function has
    no business knowing. Nested delegation needs no special case here at all
    (``brief.md`` §5.1 item 2) — a delegated call is a ``FunctionToolCallEvent``
    like any other, and the child's own events arrive on the same session
    channel tagged with the child's ``run_id``.
    """
    from pydantic_ai.messages import (
        FunctionToolCallEvent,
        FunctionToolResultEvent,
        PartDeltaEvent,
        PartStartEvent,
        TextPart,
        TextPartDelta,
    )

    if isinstance(event, PartStartEvent) and isinstance(event.part, TextPart):
        return [{"kind": "text_start"}, {"kind": "text_delta", "delta": event.part.content}]
    if isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
        return [{"kind": "text_delta", "delta": event.delta.content_delta}]
    if isinstance(event, FunctionToolCallEvent):
        return [
            {
                "kind": "tool_start",
                "tool_call_id": event.part.tool_call_id,
                "tool_name": event.part.tool_name,
            }
        ]
    if isinstance(event, FunctionToolResultEvent):
        return [
            {
                "kind": "tool_end",
                "tool_call_id": event.part.tool_call_id,
                "tool_name": getattr(event.part, "tool_name", ""),
                # A RetryPromptPart has no outcome and is a failure too: the
                # model is being told to try again.
                "is_error": getattr(event.part, "outcome", "failed") == "failed",
            }
        ]
    return []
