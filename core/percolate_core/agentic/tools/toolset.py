"""The bridge from canonical tools into pydantic-ai.

``brief.md`` §5: the runtime is "a thin, opinionated layer around pydantic-ai's
own ``Agent`` — the LLM-calling, tool-invoking, structured-output engine stays
pydantic-ai's". This module is the narrowest part of that layer: it hands
pydantic-ai a list of tool definitions whose implementations are pure
forwarding.
"""

from __future__ import annotations

from typing import Any

from ..contracts import ToolInvocation, ToolResult
from .registry import ResolvedToolset, invoke


def build_pydantic_ai_tools(
    toolset: ResolvedToolset,
    on_result: Any = None,
    headers: dict[str, str] | None = None,
    before_call: Any = None,
) -> list[Any]:
    """Wrap each canonical tool as a pydantic-ai ``Tool`` built from its schema.

    Every wrapper does exactly four things — ask ``before_call`` what headers
    this particular call should carry (which is where a delegation gets its
    ``tool_call`` row written *before* dispatch, so the child run can point back
    at it), forward the arguments to ``registry.invoke``, hand the result to
    ``on_result`` (how the runtime derives citations from what the tools
    actually returned, ``brief.md`` §5.3), and return the content to the model.
    No tool logic, by construction.

    ``ToolResult.is_error`` is *not* raised as an exception: the spec wants a
    failed call to reach the model as an ordinary observation it can react to
    (``brief.md`` §5.2), so the error text is the return value and the row keeps
    ``is_error``/``error_kind``.
    """
    from pydantic_ai.tools import Tool

    tools: list[Any] = []
    for canonical in toolset.tools:
        tools.append(
            Tool.from_schema(
                function=_forwarder(toolset, canonical.name, on_result, headers, before_call),
                name=canonical.name,
                description=canonical.description,
                json_schema=canonical.input_schema or {"type": "object", "properties": {}},
                # takes_ctx purely to read the model's own tool_call_id: it is
                # what the AG-UI TOOL_CALL_START carries, so without it the
                # streamed event and the persisted record of the same call
                # cannot be tied together by a client.
                takes_ctx=True,
            )
        )
    return tools


def _forwarder(
    toolset: ResolvedToolset,
    tool_name: str,
    on_result: Any,
    headers: dict[str, str] | None = None,
    before_call: Any = None,
) -> Any:
    """Build one forwarding callable. Deliberately trivial — see module docstring."""

    async def _call(ctx: Any, **kwargs: Any) -> Any:
        call_headers = dict(headers or {})
        call_id = getattr(ctx, "tool_call_id", "") or ""
        if before_call is not None:
            call_id, call_headers = await before_call(tool_name, kwargs, call_id)
        result: ToolResult = await invoke(
            toolset,
            ToolInvocation(call_id=call_id, tool_name=tool_name, arguments=kwargs),
            call_headers,
        )
        if on_result is not None:
            await on_result(result)
        return result.content

    _call.__name__ = tool_name
    return _call
