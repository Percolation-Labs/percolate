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
from dataclasses import dataclass, field
from typing import Any

from pydantic import BaseModel

from ..contracts import AgentDeps, AgentSpec, RequestContext, ToolResult
from ..settings import Settings
from ..tools import ResolvedToolset, build_pydantic_ai_tools
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
        f"endpoint -- set OPENAI_BASE_URL and use an `openai:` model, which "
        f"needs no additional package. Original error: {err}"
    )


@dataclass(slots=True)
class ExecutionResult:
    """What one LLM turn produced, before any of it is persisted."""

    text: str | None = None
    output: Any = None
    tool_results: list[ToolResult] = field(default_factory=list)
    usage: dict[str, Any] = field(default_factory=dict)


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
        the runtime, per ``sequence.md``'s "tested only through the contract."
        """
        from pydantic_ai import Agent

        chosen = model or agent.model or self.settings.default_model
        try:
            return Agent(
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

    def output_type(self, agent: AgentSpec) -> Any:
        """Turn ``structured_output_schema`` (JSON Schema) into an output type.

        Presence of a schema is what makes ``chained_action`` reachable
        (``brief.md`` §2/§4), so this is not cosmetic: it decides whether a run
        can trigger a follow-on action at all.

        pydantic-ai's ``StructuredDict`` takes the JSON Schema directly, which
        is the whole conversion — no model generation, and deliberately no
        validation layer of our own on top. The schema in the row is the
        contract; pydantic-ai enforces it and retries the model against it,
        which is exactly the part of the job §5 says stays pydantic-ai's.
        """
        if not agent.structured_output_schema:
            return str
        from pydantic_ai.output import StructuredDict

        return StructuredDict(
            agent.structured_output_schema,
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
        """
        handler = None
        if on_event is not None:

            async def handler(ctx: Any, stream: Any) -> None:
                async for event in stream:
                    for mapped in map_stream_event(event):
                        await on_event(mapped)

        result = await pai_agent.run(
            user_prompt,
            message_history=message_history or None,
            deps=deps,
            event_stream_handler=handler,
        )
        return ExecutionResult(text=as_text(result.output), output=result.output)


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
            }
        ]
    return []
