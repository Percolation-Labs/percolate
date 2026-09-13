"""The one seam between this runtime and Postgres.

Every read and write the runtime does goes through this protocol — which is what
makes ``sequence.md``'s Gate 7 discipline enforceable in code rather than by
convention: "the agent runtime is ... deliberately tested only through the
contract — if it needs something the REST/streaming contract doesn't expose,
that's a spec gap to fix, not a reason to let it reach around the contract into
the database directly."

Two implementations:

- ``PgRepository`` — the real one: ``*_api`` views for reads, ``SECURITY
  DEFINER`` functions for writes, every statement inside a transaction that has
  assumed ``authenticated`` and set ``request.jwt.claims``.
- ``percolate_core.agentic.testing.MemoryRepository`` — an in-memory stand-in, which is what
  makes the dummy end-to-end path runnable with no Postgres at all.

If a method here has no plausible SQL, that is a signal the schema is missing
something — file it as a spec gap, don't add a side channel.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any, Protocol, runtime_checkable
from uuid import UUID

from ...core import agent_document, identity
from ..contracts import AgentSpec, Message, Run, RunStatus, Session, ToolServer
from .client import PgClient

_QUALIFIED_NAME = re.compile(r"[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*", re.IGNORECASE)



@runtime_checkable
class Repository(Protocol):
    """The complete database surface of the agent runtime."""

    # --- agents & tool servers (config plane) -----------------------------
    async def get_agent(self, name: str) -> AgentSpec | None: ...
    async def get_agent_by_id(self, agent_id: UUID) -> AgentSpec | None: ...
    async def list_agents(self) -> list[AgentSpec]: ...
    async def upsert_agent(self, agent: AgentSpec) -> AgentSpec: ...
    async def upsert_agent_document(self, doc: dict[str, Any]) -> AgentSpec: ...
    async def translates_agent_documents(self) -> bool: ...
    async def get_tool_server(self, name: str) -> ToolServer | None: ...
    async def list_tool_servers(self) -> list[ToolServer]: ...
    async def upsert_tool_server(self, server: ToolServer) -> ToolServer: ...

    # --- sessions, runs, messages (conversation plane) --------------------
    async def create_session(self, session: Session) -> Session: ...
    async def get_session(self, session_id: UUID) -> Session | None: ...
    async def create_run(self, run: Run) -> Run: ...
    async def update_run(
        self,
        run_id: UUID,
        *,
        status: RunStatus | None = None,
        state: dict[str, Any] | None = None,
    ) -> Run: ...
    async def get_run(self, run_id: UUID) -> Run | None: ...
    async def child_runs(self, parent_run_id: UUID) -> list[Run]: ...
    async def append_messages(self, messages: list[Message]) -> list[Message]: ...
    async def session_messages(self, session_id: UUID) -> list[Message]: ...
    async def branch_messages(
        self, session_id: UUID, parent_run_id: UUID | None, limit: int | None = None
    ) -> list[Message]: ...
    async def message_count(self, session_id: UUID) -> int: ...

    # --- streaming --------------------------------------------------------
    async def notify(self, channel: str, payload: str) -> None: ...

    # --- borrowed from the neighbouring systems, never reimplemented ------
    async def has_quota_remaining(self, user_id: UUID | None, resource_kind: str) -> bool: ...
    async def call_chained_action(self, target: str, payload: dict[str, Any]) -> Any: ...
    async def start_workflow(
        self, name: str, payload: dict[str, Any], trace_id: str | None = None
    ) -> UUID: ...
    async def complete_task(self, task_id: UUID, output: dict[str, Any]) -> None: ...
    async def fail_task(self, task_id: UUID, error: dict[str, Any], terminal: bool) -> None: ...
    async def can_see_task(self, task_id: UUID) -> bool: ...


SESSION_COLUMNS = ("id", "owner_id", "agui_thread_id", "title", "created_at")
"""The columns of ``agentic.sessions`` this client reads back, named once.

It was written out twice -- in ``create_session`` and in ``get_session``, forty
lines apart -- when the scope work renamed ``user_id`` to ``owner_id``. One copy
was updated. The other was on the session-RESUME path, which no first turn
reaches, so every test that opened a conversation passed and
`X-P8-Session-Id` raised `KeyError: 'user_id'` as a bare 500.

A tuple of column names is exactly the kind of fact that has one home or drifts.
"""


class PgRepository:
    """Repository over real Postgres, through the same surface any client has.

    Every write goes through a ``SECURITY DEFINER`` function in
    ``specs/agentic/schema.sql``; every read goes through an ``*_api`` view with
    RLS applied. There is no base-table write grant to reach for even if this
    class wanted one — the schema's own load-time invariant check fails if one
    is ever added, so "the runtime has no privileged backdoor" (``brief.md`` §5)
    is enforced by the database rather than by this file's good behaviour.
    """

    def __init__(self, client: PgClient, claims: Mapping[str, Any] | None = None) -> None:
        # The verified token payload, kept whole and handed to every
        # transaction as it arrived. Holding only the user id is what let the
        # agent runtime drop `orgs` and act across every org the user belongs
        # to -- see PgClient.as_user.
        self.client = client
        self.claims = claims

    @property
    def user_id(self) -> UUID | None:
        """The caller's id, for the places that need a value rather than RLS
        (a ``RequestContext``, the quota check). Derived, never stored beside
        the claims, so the two cannot disagree."""
        sub = (self.claims or {}).get("sub")
        return UUID(str(sub)) if sub else None

    # --- agents & tool servers -------------------------------------------

    async def get_agent(self, name: str) -> AgentSpec | None:
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow(
                "select * from agentic.agents_api where name = $1", name
            )
        return _agent(row)

    async def get_agent_by_id(self, agent_id: UUID) -> AgentSpec | None:
        """Used to resolve ``summarizer_agent_id`` (``brief.md`` §3)."""
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow("select * from agentic.agents_api where id = $1", agent_id)
        return _agent(row)

    async def list_agents(self) -> list[AgentSpec]:
        async with self.client.as_user(self.claims) as conn:
            rows = await conn.fetch("select * from agentic.agents_api order by name")
        return [a for a in (_agent(r) for r in rows) if a is not None]

    async def upsert_agent(self, agent: AgentSpec) -> AgentSpec:
        """The applying end of ``brief.md`` §6 — a migration calls this.

        Gated on ``rbac.has_permission(uid, 'agents', 'update')`` inside the
        function, not here: an authorization check the client performs is a
        suggestion, one the database performs is a rule.

        ``exclude_unset`` is the load-bearing word, and omitting it was a
        silent, total data-loss bug on the most ordinary edit there is.
        ``agentic.upsert_agent`` decides column by column on **the presence of
        the key** — "AN OMITTED KEY MEANS LEAVE IT ALONE, NOT SET IT TO THE
        DEFAULT", which that function's own comment records as found by doing
        it. But ``model_dump()`` is not sparse: it emits every field of the
        model, so ``AgentSpec(name="x", model="openai:gpt-5")`` sent
        ``system_prompt: ""`` and ``tools: []`` as *present* keys, and the
        guard the schema was careful to build could not tell "not mentioned"
        from "explicitly emptied". Changing an agent's model left it with no
        prompt and no tools — still existing, still resolving by name, and able
        to do nothing.

        Worth keeping in mind: the fields this model does NOT carry
        (``audience``, ``category``, ``tags``, ``skills``, ``plugin``) were the
        only ones that survived, because absent from the model meant absent
        from the payload. The half that was modelled was the half that was lost.
        """
        payload = agent.model_dump(
            mode="json", exclude={"id", "created_at", "updated_at"}, exclude_unset=True
        )
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow("select * from agentic.upsert_agent($1::jsonb)", payload)
        result = _agent(row)
        assert result is not None
        return result

    async def upsert_agent_document(self, doc: dict[str, Any]) -> AgentSpec:
        """An agent as the DOCUMENT it was authored as, sent to the database whole.

        `brief.md` §6.1: `agentic.agent_document_to_row` is the one translation
        and `upsert_agent` calls it, so a client that parses a document into an
        `AgentSpec` and sends the model's fields is translating a second time --
        and it loses, in this process and without a word, every column
        `AgentSpec` does not model. That is not hypothetical: `category`,
        `audience`, `tags` and `skills` are real columns, an extractor is defined
        by `category: extractor`, and `percolate agent push` dropped all four on
        the way through pydantic. The document has them; this sends the document.

        No `exclude_unset` question to get wrong either: the keys present are the
        ones the author wrote, which is exactly what `upsert_agent`'s
        "an omitted key means leave it alone" rule wants to be told.

        Against an extension older than the translation this would install an
        agent with an empty prompt and report success, so the caller asks first
        (`core.agent_document.assert_translates`).
        """
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow("select * from agentic.upsert_agent($1::jsonb)", doc)
        result = _agent(row)
        assert result is not None
        return result

    async def translates_agent_documents(self) -> bool:
        """Whether this database maps a document onto columns, or drops half of it.

        Asked, not assumed, because the difference is silent: an extension that
        predates `agentic.agent_document_to_row` stores the document's row keys,
        ignores `description` and `properties`, and reports success. One SQL
        string, in `core.agent_document`, so the client and the sample loader ask
        the same question.
        """
        async with self.client.as_user(self.claims) as conn:
            return bool(await conn.fetchval(agent_document.SUPPORTS_SQL))

    async def get_tool_server(self, name: str) -> ToolServer | None:
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow(
                "select * from agentic.tool_servers_api where name = $1", name
            )
        return _tool_server(row)

    async def list_tool_servers(self) -> list[ToolServer]:
        async with self.client.as_user(self.claims) as conn:
            rows = await conn.fetch("select * from agentic.tool_servers_api order by name")
        return [s for s in (_tool_server(r) for r in rows) if s is not None]

    async def upsert_tool_server(self, server: ToolServer) -> ToolServer:
        """Registration *and* re-sync land here (``brief.md`` §5.2).

        ``cached_tools`` is written by the caller having already discovered them
        — this method never fetches anything itself, which is what keeps
        discovery a rare, scheduled operation rather than a per-run one.

        ``exclude_unset`` for the same reason as ``upsert_agent``, and here the
        schema names this exact failure: ``cached_tools`` is preserved when the
        key is absent because erasing it was a bug fixed "one function away and
        not here". A dense ``model_dump()`` reintroduced it from this side —
        ``ToolServer(name="p8-query", kind="mcp", url=...)`` sent
        ``cached_tools: []`` as a present key, wiping the discovered toolset
        **and** stamping ``synced_at = now()``, claiming a fetch that never
        happened. ``surface.sql`` excludes ``synced_at`` from the write contract
        for precisely that reason; this is the path that got around it.
        """
        payload = server.model_dump(
            mode="json", exclude={"id", "created_at", "updated_at"}, exclude_unset=True
        )
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow(
                "select * from agentic.upsert_tool_server($1::jsonb)", payload
            )
        result = _tool_server(row)
        assert result is not None
        return result

    # --- sessions, runs, messages ----------------------------------------

    async def create_session(self, session: Session) -> Session:
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow("select * from agentic.create_session($1)", session.title)
        return Session(**{k: row[k] for k in SESSION_COLUMNS})

    async def get_session(self, session_id: UUID) -> Session | None:
        """``select * from agentic.sessions_api where id = $1``.

        RLS does the authorization: another user's session simply is not there,
        so "does not exist" and "is not yours" are one answer — which is the
        answer a caller should get anyway.

        ``owner_id``, NOT ``user_id``. The scope work renamed the column and
        this line was the one site the rename missed, so resuming a session --
        `X-P8-Session-Id`, the documented multi-turn path -- raised
        `KeyError: 'user_id'` and came back as a bare 500. It survived because
        the sibling `create_session` was fixed and this was not: the same
        literal tuple, twice, forty lines apart, with only one of them reached
        by a first turn.
        """
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow("select * from agentic.sessions_api where id = $1", session_id)
        if row is None:
            return None
        return Session(**{k: row[k] for k in SESSION_COLUMNS})

    async def create_run(self, run: Run) -> Run:
        """``agentic.start_run(...)`` — which derives more than it is told.

        ``depth``, ``parent_span_id`` and an inherited ``trace_id`` are computed
        *in the function* from ``parent_run_id``, not passed in: the delegation
        tree and the span tree are the same tree (``brief.md`` §7), and letting a
        client assert its own depth or parent span would let the two drift.
        """
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow(
                "select * from agentic.start_run($1, $2, $3, $4, $5, $6, $7, $8)",
                run.agent_name,
                run.session_id,
                run.parent_run_id,
                run.delegated_by_message_id,
                run.trace_id,
                run.span_id,
                run.trigger_kind,
                run.workflow_task_id,
            )
        return _run(row)

    async def update_run(
        self,
        run_id: UUID,
        *,
        status: RunStatus | None = None,
        state: dict[str, Any] | None = None,
    ) -> Run:
        """``agentic.finish_run(...)``. ``quota_exceeded`` arrives here like any
        other terminal status, leaving partial rows untouched (``brief.md`` §5.1)."""
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow(
                "select * from agentic.finish_run($1, $2, $3::jsonb)", run_id, status, state
            )
        return _run(row)

    async def get_run(self, run_id: UUID) -> Run | None:
        async with self.client.as_user(self.claims) as conn:
            row = await conn.fetchrow("select * from agentic.runs_api where id = $1", run_id)
        return _run(row) if row else None

    async def child_runs(self, parent_run_id: UUID) -> list[Run]:
        """One hop, deliberately.

        The recursive walk of a whole delegation tree belongs to
        ``ai-query-layer``'s GRAPH mode (``brief.md`` §4), and ``sequence.md``'s
        Gate 3 tests it that way. A recursive CTE here would be this runtime
        growing a second graph-query mechanism.
        """
        async with self.client.as_user(self.claims) as conn:
            rows = await conn.fetch(
                "select * from agentic.runs_api where parent_run_id = $1 order by created_at",
                parent_run_id,
            )
        return [_run(r) for r in rows]

    async def append_messages(self, messages: list[Message]) -> list[Message]:
        """One RPC, one transaction (``sequence.md`` Gate 2).

        Both granularities come through this one call (``brief.md`` §2): two rows
        for the fast path, the full ``user → tool_call → tool_response → …``
        sequence for the slow path. Insert order is preserved by the function, so
        ``seq`` reflects conversation order rather than however Postgres felt
        like evaluating the set.
        """
        # A tool result is a string this runtime did not compose, and may carry
        # U+0000 (REM-146); the pool's jsonb encoder replaces it on the way in.
        payload = [
            m.model_dump(mode="json", include={
                "id", "run_id", "session_id", "role", "content", "tool_calls",
                "tool_call_id", "is_error", "error_kind", "citations",
            })
            for m in messages
        ]
        async with self.client.as_user(self.claims) as conn:
            rows = await conn.fetch("select * from agentic.persist_turn($1::jsonb)", payload)
        return [_message(r) for r in rows]

    async def session_messages(self, session_id: UUID) -> list[Message]:
        """Everything, ordered — for inspection and for the summarizer.

        Not what the runtime calls before a turn: that is
        ``persistence.reload_window``, which asks for a bounded window. Loading a
        whole session unconditionally is the behaviour ``brief.md`` §5.1 rules
        out, and having the unbounded read live under an obviously different name
        is most of what stops it being called by accident.
        """
        async with self.client.as_user(self.claims) as conn:
            rows = await conn.fetch(
                "select * from agentic.messages_api where session_id = $1 order by seq",
                session_id,
            )
        return [_message(r) for r in rows]

    async def branch_messages(
        self, session_id: UUID, parent_run_id: UUID | None, limit: int | None = None
    ) -> list[Message]:
        """The messages of one branch of the delegation tree, plus the summary.

        "Branch" is the set of runs sharing a parent: null for the top-level
        conversation, a specific run id for everything one delegation spawned.
        This is what a window is built from — see ``persistence.reload_window``
        for why a session-wide read is the wrong unit once delegation exists.

        ``limit`` bounds the read itself. Without it the "bounded window" was
        bounded only in memory: the whole branch was fetched and then sliced, so
        a long conversation paid an ever-growing read on every turn to send the
        model a fixed number of messages. The caller passes a superset of its
        policy bound — tool rows interleave with turns, and the slice, not this
        query, decides what the model sees.
        """
        async with self.client.as_user(self.claims) as conn:
            rows = await conn.fetch(
                """
                select * from (
                    select m.* from agentic.messages_api m
                      join agentic.runs_api r on r.id = m.run_id
                     where m.session_id = $1
                       and r.parent_run_id is not distinct from $2
                       -- Scheduled runs share a session with the conversation
                       -- but are not turns in it: a summarizer's own input and
                       -- output must never come back as the next turn's history.
                       and r.trigger_kind = 'interactive'
                     order by m.seq desc
                     limit $3
                ) recent
                union all
                -- The session's one rolling summary belongs to every window by
                -- design, and is never subject to the limit.
                select m.* from agentic.messages_api m
                 where m.session_id = $1 and m.role = 'summary'
                 order by seq
                """,
                session_id,
                parent_run_id,
                limit if limit is not None else 500,
            )
        return [_message(r) for r in rows]

    async def message_count(self, session_id: UUID) -> int:
        async with self.client.as_user(self.claims) as conn:
            return await conn.fetchval(
                "select count(*) from agentic.messages_api where session_id = $1", session_id
            )

    # No Python upsert_summary: the summary row is written by the chained
    # action (`agentic.apply_summary`), which is a Postgres function the runtime
    # calls by name. A second, Python-side way to write the same row would be a
    # second place for that rule to drift.

    # --- streaming --------------------------------------------------------

    async def notify(self, channel: str, payload: str) -> None:
        """Publish one AG-UI event on the session's channel (``brief.md`` §4).

        The ``messages`` trigger publishes ``MESSAGE_PERSISTED`` checkpoints on
        the same channel; live deltas and durable checkpoints share one stream on
        purpose, so a reconnecting client resumes from rows rather than from
        whatever an in-memory buffer still held.
        """
        if len(payload.encode()) > 7900:
            raise ValueError(
                "NOTIFY payload exceeds Postgres' 8000-byte limit — send a row "
                "reference and let the relay read it back (workflow-engine's "
                "payload_ref discipline)"
            )
        async with self.client.as_user(self.claims) as conn:
            await conn.execute("select pg_notify($1, $2)", channel, payload)

    # --- neighbouring systems --------------------------------------------

    async def has_quota_remaining(self, user_id: UUID | None, resource_kind: str) -> bool:
        """``rbac.has_quota_remaining()`` — ``user-rbac/spec.md`` §7.

        GAP, unchanged: that function is described in the spec's prose and does
        not exist in its ``schema.sql``. Until it does, this returns True rather
        than defining a local copy — a second quota mechanism living here is
        exactly the duplication ``spec-driven-development`` §5 forbids, and a
        silent local implementation would make the gap invisible.
        """
        async with self.client.as_user(self.claims) as conn:
            exists = await conn.fetchval(
                "select to_regprocedure('rbac.has_quota_remaining(uuid, text)') is not null"
            )
            if not exists:
                return True
            return await conn.fetchval(
                "select rbac.has_quota_remaining($1, $2)", user_id, resource_kind
            )

    async def start_workflow(
        self, name: str, payload: dict[str, Any], trace_id: str | None = None
    ) -> UUID:
        """``select workflow.start_workflow($1, $2::jsonb, null, $3)``.

        The runtime's only way of asking for background work (``brief.md`` §3):
        no scheduler of its own, no queue of its own — an ordinary workflow run,
        which then gets ``workflow-engine``'s retries, rate limits and
        observability for free. The trace id is propagated, never restarted.
        """
        async with self.client.as_user(self.claims) as conn:
            return await conn.fetchval(
                "select workflow.start_workflow($1, $2::jsonb, null, $3)",
                name,
                payload,
                trace_id,
            )

    async def complete_task(self, task_id: UUID, output: dict[str, Any]) -> None:
        """``select workflow.complete_task($1, $2::jsonb)``, as the ``worker`` role.

        ``brief.md`` §3: "the runtime ... calls ``complete_task(task_id,
        output)`` itself once the run and any ``chained_action`` it fires
        finish. No bespoke integration between the two systems."

        The role switch is the integration detail that sentence hides:
        ``complete_task`` is granted to ``worker``, not ``authenticated``,
        because in ``workflow-engine``'s role model whoever completes a task is
        a worker. It runs on a ``worker`` login (``P8_WORKER_DSN``), not this
        caller's connection: that connection logs in as ``authenticator``, which
        cannot become ``worker``. See ``core.identity.as_task_worker``.
        """
        async with identity.as_task_worker() as conn:
            await conn.execute("select workflow.complete_task($1, $2::jsonb)", task_id, output)

    async def fail_task(self, task_id: UUID, error: dict[str, Any], terminal: bool) -> None:
        """``select workflow.fail_task($1, $2::jsonb, $3)``, as ``worker``, like
        ``complete_task`` and for the same reason. ``terminal`` is the engine's
        "do not retry"; `task_outcome.failure_is_terminal` decides it."""
        async with identity.as_task_worker() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, $3)", task_id, error, terminal)

    async def can_see_task(self, task_id: UUID) -> bool:
        """Whether this caller can see the task, through ``workflow.tasks_api``.

        The view is filtered by row-level security to the runs the caller may
        access, so "no" covers both a task that does not exist and one that
        belongs to someone else. ``/internal/run`` asks this before it accepts a
        run that will complete the task.
        """
        async with self.client.as_user(self.claims) as conn:
            return bool(await conn.fetchval(
                "select exists (select 1 from workflow.tasks_api where id = $1)", task_id))

    async def call_chained_action(self, target: str, payload: dict[str, Any]) -> Any:
        """``select <target>($1::jsonb)`` for ``kind = 'pg_function'`` (``brief.md`` §8).

        The signature is fixed: ``<target>(jsonb) -> jsonb``. The result is
        persisted as an ordinary ``tool_response`` row, so it has to be JSON —
        a function returning a composite type cannot even be decoded here.

        ``target`` is a schema-qualified function name from the agent row, not
        user input, but it is still validated against ``pg_proc`` before being
        interpolated — a config table is not a trust boundary you get to skip.
        """
        # Two gates before a name from a config table is interpolated into SQL:
        # it must look like a qualified identifier, and it must already exist as
        # a function of exactly this signature. The existence check alone is
        # probably sufficient; a config table is still not a trust boundary you
        # get to skip, and this is the one statement in the runtime built by
        # string concatenation.
        if not _QUALIFIED_NAME.fullmatch(target):
            raise LookupError(f"chained action {target!r} is not a qualified function name")
        async with self.client.as_user(self.claims) as conn:
            known = await conn.fetchval(
                "select to_regprocedure($1) is not null", f"{target}(jsonb)"
            )
            if not known:
                raise LookupError(f"chained action {target}(jsonb) does not exist")
            return await conn.fetchval(f"select {target}($1::jsonb)", payload)


# --- row → contract mapping ----------------------------------------------
#
# Straight, boring, and in one place: a mapping that drifts silently is how a
# column stops being read without anything failing.


def _agent(row: Any) -> AgentSpec | None:
    if row is None:
        return None
    return AgentSpec(
        id=row["id"],
        name=row["name"],
        system_prompt=row["system_prompt"],
        model=row["model"],
        tools=row["tools"],
        structured_output_schema=row["structured_output_schema"],
        chained_action=row["chained_action"],
        summarizer_agent_id=row["summarizer_agent_id"],
        context_policy=row["context_policy"] or {},
        created_at=row["created_at"],
    )


def _tool_server(row: Any) -> ToolServer | None:
    if row is None:
        return None
    return ToolServer(
        id=row["id"],
        name=row["name"],
        kind=row["kind"],
        url=row["url"],
        credential_ref=row["credential_ref"],
        emits_citations=row["emits_citations"],
        serves_agents=row["serves_agents"],
        cached_tools=row["cached_tools"],
        synced_at=row["synced_at"],
    )


def _run(row: Any) -> Run:
    return Run(
        id=row["id"],
        session_id=row["session_id"],
        agent_id=row["agent_id"],
        owner_id=row["owner_id"],
        parent_run_id=row["parent_run_id"],
        delegated_by_message_id=row["delegated_by_message_id"],
        trigger_kind=row["trigger_kind"],
        workflow_task_id=row["workflow_task_id"],
        trace_id=row["trace_id"],
        span_id=row["span_id"],
        parent_span_id=row["parent_span_id"],
        depth=row["depth"],
        state=row["state"],
        status=row["status"],
        created_at=row["created_at"],
        finished_at=row["finished_at"],
    )


def _message(row: Any) -> Message:
    return Message(
        id=row["id"],
        run_id=row["run_id"],
        session_id=row["session_id"],
        role=row["role"],
        content=row["content"],
        tool_calls=row["tool_calls"],
        tool_call_id=row["tool_call_id"],
        is_error=row["is_error"],
        error_kind=row["error_kind"],
        citations=row["citations"],
        seq=row["seq"],
        created_at=row["created_at"],
    )
