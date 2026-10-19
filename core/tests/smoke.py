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
import json
import sys
from pathlib import Path
from typing import Any

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
from percolate_core.core import samples

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


async def check_the_loader_sends_the_document_and_translates_nothing() -> None:
    """brief.md §6.1: one translation, in the database, and no loader has one.

    THE TWO DIALECTS LOOK ALIKE AND THE WRONG ONE USED TO FAIL SILENTLY. What
    authors an agent -- the docs, a pydantic class, a sample, a package manifest
    -- writes a JSON Schema document, where the prompt is `description` and the
    contract is `properties`. The row spells those `system_prompt` and
    `structured_output_schema`.

    This file used to assert that THIS loader translated, and that assertion
    passed while `p8-subsystems/packages/apply.py` -- which knew a different
    dialect and not this one -- installed the same extractor with an empty
    prompt. Three loaders, three mappings, and `upsert_agent` dropping whatever
    it did not recognise (REM-70). So the assertion is now the opposite one, and
    it is the one that composes: the loader hands the document over UNCHANGED,
    and `agentic.upsert_agent` translates it for every tool at once.
    """
    doc = {
        "type": "object",
        "name": "harbourmaster",
        "description": "You answer questions about the fleet.",
        "model": "openai:gpt-4o-mini",
        "category": "extractor",
        "skills": ["house-style"],
        "properties": {"verdict": {"type": "string"}},
        "required": ["verdict"],
    }

    class FakeConn:
        """Records what reached the database, which is the whole assertion."""

        def __init__(self) -> None:
            self.sent: list[Any] = []

        async def execute(self, sql: str, *args: Any) -> None:
            self.sent.append((sql, args))

    conn = FakeConn()
    plugin = {"name": "harbour", "version": "1.0.0", "agents": [dict(doc)]}
    await samples.apply_plugin(conn, plugin)

    assert len(conn.sent) == 1, conn.sent
    sql, args = conn.sent[0]
    assert "agentic.apply_plugin" in sql, sql
    sent = json.loads(args[0])["agents"][0]
    assert sent == doc, (
        "the loader changed the agent document on the way to the database. It is "
        f"the database's to translate now (brief.md §6.1): {sent}"
    )
    # And nothing of the document was lost before it left -- `category` is what
    # makes an agent an extractor, and pydantic does not model it.
    assert sent["category"] == "extractor" and sent["skills"] == ["house-style"]

    # THE IN-PROCESS MAPPING STILL AGREES WITH THE DATABASE'S ON THIS DOCUMENT.
    # `authoring.from_json_schema` is kept for what needs no database at all
    # (`from_model_class`, the in-memory twin), so the two must not disagree
    # about the two keys that carry meaning. The database's half is asserted in
    # `p8-subsystems/dev/tests/agentic/05-agent-document.sql` against the same
    # document shape; these are the mappings, not the copies.
    spec = authoring.from_json_schema(doc)
    assert spec.system_prompt == doc["description"], spec.system_prompt
    assert spec.structured_output_schema == {
        "type": "object",
        "properties": {"verdict": {"type": "string"}},
        "required": ["verdict"],
    }, spec.structured_output_schema

    # A nested model's `$defs` travels with the contract: a stored `$ref`
    # pointing at definitions nobody kept is a schema no provider can validate.
    nested = authoring.from_json_schema(
        {
            "name": "n",
            "description": "d",
            "properties": {"claim": {"$ref": "#/$defs/Claim"}},
            "$defs": {"Claim": {"type": "object", "properties": {"t": {"type": "string"}}}},
        }
    )
    assert (nested.structured_output_schema or {}).get("$defs"), nested.structured_output_schema
    assert "$defs" in authoring.to_json_schema(nested), "the round trip drops $defs"


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
    await check_the_loader_sends_the_document_and_translates_nothing()
    check_every_model_provider_we_ship_can_be_constructed()
    await check_citations_come_from_tools_not_the_model()
    await check_quota_denial_is_terminal_not_a_crash()
    await check_window_is_bounded()
    await check_a_sub_run_does_not_inherit_its_parents_history()
    print("smoke: 10 checks passed")


if __name__ == "__main__":
    asyncio.run(main())
