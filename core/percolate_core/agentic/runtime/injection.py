"""Component 4 — instruction/context injection (``brief.md`` §5.1 item 4).

Ambient context comes from the *request*, not the conversation: current
date/time, tenant, request-scoped metadata. Keeping it out of ``messages`` is
the point — "so it never has to be replayed, summarized, or accidentally dropped
by the persistence adapter's context policy, since it was never conversation
content to begin with."

The requirement the spec is explicit about: **one defined, uniform mechanism
every agent can rely on, not a per-agent convention.**
"""

from __future__ import annotations

from ..contracts import AgentDeps, AgentSpec, RequestContext


def render_context_block(context: RequestContext) -> str:
    """Render ambient context as a compact block for the system prompt.

    One of the two supported injection routes (the other is typed ``deps``).
    Both exist because the spec names both; an agent that needs the model to
    *reason* about the date wants it in the prompt, while an agent whose tools
    need the tenant wants it in ``deps`` where the model cannot corrupt it.

    Shell: real, and deliberately boring — the format is a contract clients will
    end up depending on, so it should be reviewed as text, not discovered later.
    """
    lines = [
        f"current_time: {context.now.isoformat()}",
        f"locale: {context.locale}",
    ]
    if context.tenant:
        lines.append(f"tenant: {context.tenant}")
    for key, value in sorted(context.extra.items()):
        lines.append(f"{_one_line(key)}: {_one_line(value)}")
    return "\n".join(lines)


def _one_line(value: object) -> str:
    """A context value is one line of text and cannot be anything else.

    ``context.extra`` is every unrecognised ``x-p8-*`` REQUEST HEADER
    (``contracts/context.py``), so its contents are chosen by whoever made the
    call -- a browser page on a CORS-allowed origin, or anything between. They
    were rendered straight into the block below, whose only delimiter is the
    ``<context>`` tag ``build_instructions`` wraps it in.

    Two things that buys an attacker, and both are closed here rather than by
    hoping the model notices: a newline invents further ``key: value`` lines
    that read exactly like context the runtime supplied, and a literal
    ``</context>`` ends the block early so everything after it is no longer
    labelled as data at all. Whitespace collapses to single spaces and angle
    brackets are escaped; the current_time/locale/tenant lines above are the
    runtime's own and are left alone.
    """
    return (" ".join(str(value).split())
            .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def build_instructions(agent: AgentSpec, context: RequestContext) -> str:
    """The system prompt actually sent: the agent's own prompt plus context.

    Note what is *not* here: any runtime-authored instruction about tools, output
    format, or delegation. pydantic-ai already generates those from the tool
    definitions and the output schema; adding our own would be the runtime
    growing behaviour that agents cannot override with data (``brief.md`` §5.2).
    """
    block = render_context_block(context)
    if not agent.system_prompt:
        return f"<context>\n{block}\n</context>"
    return f"{agent.system_prompt}\n\n<context>\n{block}\n</context>"


def build_deps(agent: AgentSpec, context: RequestContext, session_id=None, run_id=None) -> AgentDeps:
    """The typed half — pydantic-ai's own ``deps`` at invocation time."""
    return AgentDeps(
        context=context, session_id=session_id, run_id=run_id, agent_name=agent.name
    )
