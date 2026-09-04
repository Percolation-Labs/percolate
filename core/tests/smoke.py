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
from percolate_core.agentic.contracts import (
    AgentSpec,
    ChatRequest,
    InboundMessage,
    RequestContext,
    ToolServer,
)
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


def check_a_schema_document_becomes_a_row_with_its_prompt() -> None:
    """agents.md: `description` is the system prompt, `properties` the output.

    THE TWO DIALECTS LOOK ALIKE AND THE WRONG ONE FAILS SILENTLY. Everything
    that authors an agent -- these docs, a pydantic class, the sample -- writes
    a JSON Schema document. `agentic.upsert_agent` takes the ROW, where those
    two keys are `system_prompt` and `structured_output_schema`, and ignores
    what it does not recognise. Hand it the document directly and it returns
    success and stores an agent with an empty prompt and no output contract: it
    exists, resolves by name, and can do nothing.

    That shipped in the harbour sample and nothing caught it, because every
    stage reported success. This asserts the translation both ways round the
    only place it is written down.
    """
    doc = {
        "type": "object",
        "name": "harbourmaster",
        "description": "You answer questions about the fleet.",
        "model": "openai:gpt-4o-mini",
        "properties": {"verdict": {"type": "string"}},
        "required": ["verdict"],
    }
    # Asserted through the sample loader's translation rather than through
    # `authoring.from_json_schema` alone. The mapping was always correct; what
    # was missing was anything CALLING it on the way to apply_plugin, so a test
    # of the mapping would have passed while the sample shipped a mute agent.
    from percolate_core.core.samples import _agent_to_row

    row = _agent_to_row(doc)
    # .get(), not [], so a translation that did nothing fails with the sentence
    # rather than a KeyError the reader has to interpret.
    assert row.get("system_prompt") == doc["description"], (
        f"the document was not translated -- system_prompt is "
        f"{row.get('system_prompt')!r}, so this agent would upsert mute"
    )
    assert row.get("structured_output_schema"), "properties were dropped -- mute agent"
    assert row["structured_output_schema"]["required"] == ["verdict"]
    assert "description" not in row and "properties" not in row, row.keys()

    # Keys the schema document carries that AgentSpec does not model are kept:
    # `skills` is a real column, and dropping it is the same silent loss in a
    # different place.
    with_skills = _agent_to_row({**doc, "skills": ["house-style"]})
    assert with_skills["skills"] == ["house-style"], with_skills.get("skills")

    # A document already in the row dialect is passed through untouched, so an
    # author who spells the row keys is taken at their word.
    already = {"name": "x", "system_prompt": "spelled the row way"}
    assert _agent_to_row(already) == already


def check_every_model_provider_we_ship_can_be_constructed() -> None:
    """`model` is a column, so it must not be limited by what got installed.

    The image shipped `pydantic-ai-slim[openai]` while every documented example
    said `anthropic:claude-sonnet-5`. A correct row therefore reached the
    runtime and came back as `ImportError: Please install the anthropic
    package` inside an otherwise-200 stream -- a packaging decision surfacing
    as a request-time failure.

    Constructing an Agent is enough to prove the provider imports: it resolves
    the model and then complains about credentials, which is a different
    exception and the one we want. No network, no key.
    """
    from pydantic_ai import Agent

    models = [
        "openai:gpt-4o-mini",
        "anthropic:claude-sonnet-4-5",
        "google:gemini-2.0-flash",
        "groq:llama-3.3-70b-versatile",
        "mistral:mistral-small-latest",
        "cohere:command-r",
        "huggingface:meta-llama/Llama-3.3-70B-Instruct",
        "bedrock:anthropic.claude-3-5-sonnet-20241022-v2:0",
    ]
    for model in models:
        try:
            Agent(model)
        except ImportError as err:  # the failure this check exists for
            raise AssertionError(
                f"{model}: provider not installed -- {err}. "
                f"`all` must include the `providers` extra."
            ) from err
        except Exception:
            pass  # missing credentials or region: the provider loaded, which is the point


def check_our_vocabularies_match_the_published_contract() -> None:
    """The stated guarantee: this package is a CLIENT of the schema, not its author.

    A closed vocabulary — the roles a message may have, the statuses a run may
    reach, the kinds a tool server may be — belongs to the database, because a
    deployment may run several of these services, or none, or somebody else's
    worker in another language against the same Postgres. The moment the
    authoritative list of run statuses is a ``Literal`` in this package, every
    other client has to import this package or guess.

    So the extension publishes the contract (``percolate.enums()``/``percolate.types``), and
    ``percolate_core/contract.json`` is that contract exported at a version. The
    ``Literal``s below are still hand-written — this check is what makes that
    safe rather than authoritative. When it fails, the schema is right and this
    package is behind; the fix is here, never there.

    Refresh the artifact from a live database with, in the p8-subsystems tree:

        dev/contract-export.py --psql '<psql cmd>'
        cp extension/percolate/contract.json <here>/percolate_core/contract.json
    """
    import json
    from typing import Literal, get_args, get_origin

    from percolate_core.agentic.contracts import conversation, tools

    path = Path(__file__).resolve().parents[1] / "percolate_core" / "contract.json"
    if not path.exists():
        raise AssertionError(
            f"{path.name} is missing — this package cannot check itself against "
            "the schema it is a client of. Export it from the p8-subsystems tree."
        )
    contract = json.loads(path.read_text())

    # Keyed by the database column the alias mirrors, because that is the join
    # the reader has to make anyway, and writing it down is what turns "these
    # look similar" into "these are the same vocabulary".
    bound = {
        ("agentic", "messages", "role"): conversation.Role,
        ("agentic", "runs", "status"): conversation.RunStatus,
        ("agentic", "runs", "trigger_kind"): conversation.TriggerKind,
        ("agentic", "messages", "error_kind"): tools.ToolErrorKind,
        ("agentic", "tool_servers", "kind"): tools.ToolServerKind,
    }

    published = {
        (e["schema"], e["table"], e["column"]): set(e["admits"] or [])
        for e in contract["enums"] if e["enforced_by"] == "check"
    }

    for key, alias in bound.items():
        assert get_origin(alias) is Literal, f"{key}: not a Literal"
        ours = set(get_args(alias))
        theirs = published.get(key)
        if theirs is None:
            raise AssertionError(
                f"{'.'.join(key)} is not in the published contract, but this "
                f"package defines a Literal for it. Either the column was "
                f"renamed or the constraint was dropped — ask percolate.enums()."
            )
        if ours != theirs:
            extra, missing = sorted(ours - theirs), sorted(theirs - ours)
            raise AssertionError(
                f"{'.'.join(key)}: this package and the database disagree.\n"
                f"  we admit and it refuses: {extra or '-'}\n"
                f"  it admits and we lack:   {missing or '-'}\n"
                f"The database is right: a value only we believe in is refused "
                f"at the write, and one only it believes in is a row we cannot "
                f"represent."
            )

    # The other direction, which is the one that catches drift: a vocabulary the
    # database enforces on a table this package writes to, with nothing here
    # bound to it. Reported rather than failed — most columns legitimately need
    # no Python type — but it is how a new constraint becomes visible instead of
    # arriving as a failed INSERT in production.
    writes_to = {"agentic"}
    unbound = sorted(
        ".".join(k) for k in published
        if k[0] in writes_to and k not in bound
    )
    if unbound:
        print(f"  note: {len(unbound)} agentic vocabularies have no Literal here: "
              f"{', '.join(unbound)}")


def check_a_partial_write_mentions_only_what_it_sets() -> None:
    """``agentic.upsert_agent``'s guarantee, from this side of the wire.

    That function decides column by column on the PRESENCE OF THE KEY — an
    omitted key means leave it alone, never set it to the default — and its
    comment records that the obvious spelling was "a silent, total data-loss
    bug ... found by doing it".

    The guard is only worth as much as the payload that reaches it, and
    ``model_dump()`` is dense: it emits every field, so a partial edit arrived
    claiming ``system_prompt: ""`` and ``tools: []`` as things the caller had
    asked for. Measured against a live database before this was fixed: changing
    only an agent's model took its system prompt from 61 characters to 0, and
    returned success.

    Checked here rather than against Postgres because the defect is entirely on
    this side — the payload either mentions a field the caller never set, or it
    does not — and a check needing a database is a check that does not run.
    """
    partial = AgentSpec(name="probe", model="openai:gpt-4.1-mini")
    payload = partial.model_dump(
        mode="json", exclude={"id", "created_at", "updated_at"}, exclude_unset=True
    )
    assert set(payload) == {"name", "model"}, (
        f"a partial AgentSpec must mention only what was set, got {sorted(payload)}. "
        "Every extra key overwrites a column the caller never spoke about."
    )

    server = ToolServer(name="probe", kind="mcp", url="http://x/mcp")
    spayload = server.model_dump(
        mode="json", exclude={"id", "created_at", "updated_at"}, exclude_unset=True
    )
    assert "cached_tools" not in spayload, (
        "a ToolServer that never set cached_tools must not mention them: the key's "
        "presence erases a discovered toolset AND stamps synced_at, claiming a "
        "fetch that never happened."
    )


async def main() -> None:
    check_the_document_round_trips()
    check_our_vocabularies_match_the_published_contract()
    check_a_partial_write_mentions_only_what_it_sets()
    check_a_code_authored_agent_is_the_same_document()
    check_a_schema_document_becomes_a_row_with_its_prompt()
    check_every_model_provider_we_ship_can_be_constructed()
    await check_citations_come_from_tools_not_the_model()
    await check_quota_denial_is_terminal_not_a_crash()
    await check_window_is_bounded()
    await check_a_sub_run_does_not_inherit_its_parents_history()
    print("smoke: 10 checks passed")


if __name__ == "__main__":
    asyncio.run(main())
