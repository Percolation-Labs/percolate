"""Not a test suite — the harness for exercising the shell by hand.

``meta/skills/spec-driven-development`` §2/§4 is explicit that a large test suite
written before the thing has been used is backwards, and that the ~10% worth
keeping later are the ones protecting a *stated guarantee* against quiet
regression. So this file is small on purpose, and each check corresponds to a
sentence in the brief rather than to a function in the code.

Run: ``uv run python tests/smoke.py``
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from percolate_core.agentic import authoring
from percolate_core.agentic.contracts import ChatRequest, InboundMessage, RequestContext, ToolServer
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import (
    MemoryRepository,
    install_fake_providers,
    retrieval_rows,
    scripted_model,
)
from percolate_core.agentic.tools import sync_server

AGENT = """
type: object
name: researcher
description: You are a research agent. Answer only from retrieved sources.
tools:
  - server: p8-query
properties: {}
context_policy:
  window_messages: 20
  summarize_after_messages: 40
"""


async def _seeded() -> tuple[MemoryRepository, TurnSequencer]:
    repo = MemoryRepository()
    install_fake_providers(
        mcp_tools={"semantic_search": {"rows": retrieval_rows()}}, openapi_tools={}
    )
    await repo.upsert_tool_server(ToolServer(name="p8-query", kind="mcp", url="http://x/mcp", emits_citations=True))
    server = await repo.get_tool_server("p8-query")
    assert server is not None
    await sync_server(repo, server)
    await repo.upsert_agent(authoring.load("agent.yaml", text=AGENT))
    return repo, TurnSequencer(repo, Settings.from_env())


FIELDS = {"name", "system_prompt", "tools", "context_policy", "structured_output_schema"}


def check_the_document_round_trips() -> None:
    """brief §6: an agent is fully serializable — nothing imperative survives.

    If a field stops round-tripping, an agent silently loses part of itself on
    the way through the database, which is the quiet failure the format exists
    to make impossible.
    """
    spec = authoring.load("agent.yaml", text=AGENT)
    again = authoring.load("agent.yaml", text=authoring.to_yaml(spec))
    assert spec.model_dump(include=FIELDS) == again.model_dump(include=FIELDS)


def check_a_code_authored_agent_is_the_same_document() -> None:
    """brief §6 / p8k8's convention: the prompt is the docstring, not a key.

    This is the claim that makes the format worth having — a pydantic model and
    a YAML file are the same artifact, so "authored in code, deployed as data"
    needs no export step. If `model_json_schema()` ever stops matching, the
    convention has quietly become a translation.
    """
    from pydantic import BaseModel, ConfigDict

    class Support(BaseModel):
        """You triage incident questions for the support desk."""

        model_config = ConfigDict(
            json_schema_extra={
                "name": "support",
                "model": "openai:gpt-4.1-mini",
                "tools": [{"server": "p8-rag", "tools": ["post_rpc_search_chunks"]}],
            }
        )
        claim: str

    spec = authoring.from_model_class(Support)
    assert spec.name == "support"
    assert spec.system_prompt == "You triage incident questions for the support desk."
    assert spec.tools[0].server == "p8-rag"
    assert (spec.structured_output_schema or {}).get("properties", {}).keys() == {"claim"}


async def check_citations_come_from_tools_not_the_model() -> None:
    """brief §5.3: provenance by construction — "what did the agent's context
    actually contain when it answered", never what the model claims it used.

    The fake model is instructed to say something with no citations in it at
    all; the citations must still appear, derived from the tool response.
    """
    _repo, sequencer = await _seeded()
    result = await sequencer.run_turn(
        ChatRequest(model="researcher", messages=[InboundMessage(role="user", content="hi")]),
        RequestContext(),
        model=scripted_model(reply="I made this up.", call_tool="semantic_search"),
    )
    assistant = result.messages[-1]
    assert assistant.role == "assistant"
    assert len(assistant.citations) == 2, assistant.citations
    kinds = {c.kind for c in assistant.citations}
    assert kinds == {"chunk", "node"}, kinds


async def check_quota_denial_is_terminal_not_a_crash() -> None:
    """brief §5.1: a denied quota check ends the run as ``quota_exceeded`` with
    whatever already exists preserved — "a quota cutoff is an expected outcome
    this system plans for, not a crash".
    """
    repo, sequencer = await _seeded()
    repo.quota_allowed = False
    result = await sequencer.run_turn(
        ChatRequest(model="researcher", messages=[InboundMessage(role="user", content="hi")]),
        RequestContext(),
        model=scripted_model(),
    )
    assert result.run.status == "quota_exceeded"
    assert [r.name for r in result.trace][-1] == "finish"


async def check_window_is_bounded() -> None:
    """brief §3/§5.1: the adapter reloads a bounded window, never the whole
    session — and, since delegation exists, only this run's branch of the tree.
    A regression here is silent: the runtime keeps working, it just quietly
    sends an unbounded (or someone else's) history to the model.
    """
    repo, sequencer = await _seeded()
    agent = await repo.get_agent("researcher")
    assert agent is not None
    from percolate_core.agentic.contracts import Message, Run, Session

    session = await repo.create_session(Session())
    run = await repo.create_run(Run(session_id=session.id, agent_id=agent.id))
    await repo.append_messages(
        [
            Message(session_id=session.id, run_id=run.id, role="user", content=str(i))
            for i in range(50)
        ]
    )
    window = await sequencer.persistence.reload_window(session.id, agent, run)
    assert len(window) == 20, len(window)
    assert window[-1].content == "49"


async def check_a_sub_run_does_not_inherit_its_parents_history() -> None:
    """brief §5.1: a window is scoped to a run's *branch* of the delegation tree.

    The failure this protects against is silent and was real: a session-scoped
    window handed a delegated sub-agent the parent's rows — including the
    `tool_call` row representing its own invocation — and the sub-agent
    happily reasoned about them. Nothing errors when this regresses; the
    sub-agent just quietly sees a conversation that is not its own.
    """
    repo, sequencer = await _seeded()
    agent = await repo.get_agent("researcher")
    assert agent is not None

    from percolate_core.agentic.contracts import Message, Run, Session

    session = await repo.create_session(Session())
    parent = await repo.create_run(Run(session_id=session.id, agent_id=agent.id))
    child = await repo.create_run(
        Run(session_id=session.id, agent_id=agent.id, parent_run_id=parent.id, depth=1)
    )
    await repo.append_messages(
        [
            Message(session_id=session.id, run_id=parent.id, role="user", content="parent turn"),
            Message(session_id=session.id, run_id=child.id, role="user", content="child turn"),
        ]
    )

    child_window = await sequencer.persistence.reload_window(session.id, agent, child)
    assert [m.content for m in child_window] == ["child turn"], child_window

    parent_window = await sequencer.persistence.reload_window(session.id, agent, parent)
    assert [m.content for m in parent_window] == ["parent turn"], parent_window


async def main() -> None:
    check_the_document_round_trips()
    check_a_code_authored_agent_is_the_same_document()
    await check_citations_come_from_tools_not_the_model()
    await check_quota_denial_is_terminal_not_a_crash()
    await check_window_is_bounded()
    await check_a_sub_run_does_not_inherit_its_parents_history()
    print("smoke: 6 checks passed")


if __name__ == "__main__":
    asyncio.run(main())
