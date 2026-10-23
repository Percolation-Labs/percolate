"""Round-trip verification against a real LLM: stream in, rows out, and back.

Every other script here *demonstrates*. This one *asserts*, because the
questions it answers are the ones that go wrong silently:

  A. Streaming — does the event stream describe what actually happened?
  B. Persistence — is exactly the right set of things stored, and nothing else?
  C. Tree — do the delegation tree, span tree and message rows agree?
  D. Round trip — does reloading those rows reconstruct the same conversation?
  G. Mounting — does the router behave identically inside a host app?
  H. Resume — can a client come back to a conversation and be remembered?
  F. Isolation — can another user see any of it?
  E. Background — does a scheduled run complete its own workflow task?

The persistence rule under test (brief.md §2, and the reason B is the longest
section): **user and assistant messages are stored, tool_call/tool_response
rows are stored only for delegations, and retrieval results are not stored at
all.** RAG output is volatile scratch inside an agentic loop -- it is re-fetched
on the next turn, it would dominate the table, and keeping it would make the
window reload replay stale context. What survives a retrieval is its
*provenance*: `messages.citations`, derived mechanically from the rows the tool
actually returned (§5.3). Citations without payloads is the whole design.

Usage:  . dev/env.sh && uv run python dev/verify.py
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import httpx

from percolate_core.agentic.contracts import (
    AgentSpec,
    ChatRequest,
    ContextPolicy,
    InboundMessage,
    RequestContext,
    Session,
)
from percolate_core.agentic.db import PgClient, PgRepository
from percolate_core.agentic.runtime import EventSink, channel
from percolate_core.agentic.runtime.chained_action import CHAINED_CALL_ID
from percolate_core.agentic.runtime.delegation import TOOL_PREFIX
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings

PASS, FAIL = "\033[32m  ok  \033[0m", "\033[31m FAIL \033[0m"
failures: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    print(f"{PASS if condition else FAIL} {label}{f' — {detail}' if detail else ''}")
    if not condition:
        failures.append(label)


async def drain(queue: asyncio.Queue) -> list[dict[str, Any]]:
    events = []
    while not queue.empty():
        events.append(queue.get_nowait())
    return events


async def preflight() -> None:
    """Refuse to run against a process that is not running this code.

    A stale server fails in the shape of a bug — a tool that "returned an
    unexpected keyword argument", a run stuck in `running` — and costs far more
    to diagnose than to prevent.
    """
    from percolate_core.agentic import build_fingerprint

    expected = build_fingerprint()
    async with httpx.AsyncClient(timeout=5) as http:
        for name, url in (
            ("api", "http://127.0.0.1:8080/_build"),
            ("gateway", "http://127.0.0.1:8765/_build"),
        ):
            try:
                got = (await http.get(url)).json()["build"]
            except Exception as exc:  # noqa: BLE001 - any failure is "not reachable"
                print(f"{FAIL} {name} is not reachable at {url} — {type(exc).__name__}")
                sys.exit(1)
            if got != expected:
                print(
                    f"{FAIL} {name} is running build {got}, this tree is {expected} — "
                    "restart it (./dev/stack.sh up, and the serve process)"
                )
                sys.exit(1)
    print(f"{PASS} api and gateway are running this build ({expected})")


async def main() -> None:
    await preflight()
    settings = Settings.from_env()
    client = PgClient(settings)
    await client.connect()
    repo = PgRepository(client, {"sub": str(UUID(settings.user_id))})

    session = await repo.create_session(Session(title="verify"))
    queue: asyncio.Queue = asyncio.Queue()
    listener = await client.listen(channel(session.id), queue)

    print(f"\n=== A/B/C/D: one turn — retrieval + delegation (session {session.id}) ===")
    sequencer = TurnSequencer(repo, settings, sink=EventSink(repo))
    result = await sequencer.run_turn(
        ChatRequest(
            model="researcher",
            messages=[
                InboundMessage(
                    role="user", content="What caused the outage, and what are the follow-ups?"
                )
            ],
            session_id=session.id,
        ),
        RequestContext(user_id=repo.user_id),
    )
    await asyncio.sleep(1.5)  # let the child run's NOTIFYs land
    events = await drain(queue)

    messages = await repo.session_messages(session.id)
    # Every run in the session, not one hop of children: a sub-agent may itself
    # delegate, and a test that assumes depth 1 fails the day the model chooses
    # to go deeper — which is exactly the day you want it not to.
    async with client.as_user(repo.claims) as conn:
        run_rows = await conn.fetch(
            "select id from agentic.runs_api where session_id = $1", session.id
        )
    runs = {r["id"] for r in run_rows}
    parent, children = result.run, await repo.child_runs(result.run.id)

    # --- A. streaming ----------------------------------------------------
    print("\n-- A. streaming")
    types = [(e.get("type"), str(e.get("run_id"))) for e in events]
    started = {r for t, r in types if t == "RUN_STARTED"}
    finished = {r for t, r in types if t == "RUN_FINISHED"}
    check("every run announced RUN_STARTED and RUN_FINISHED",
          started == finished and started == {str(r) for r in runs},
          f"{len(started)} runs streamed, {len(runs)} runs persisted")

    child = children[0] if children else None
    if child:
        order = [t for t, _ in types]
        open_i = order.index("TOOL_CALL_START")
        close_i = len(order) - 1 - order[::-1].index("TOOL_CALL_END")
        child_positions = [i for i, (_, r) in enumerate(types) if r == str(child.id)]
        check("the child run's events are nested inside the parent's tool call",
              all(open_i < i < close_i for i in child_positions),
              f"tool call spans [{open_i}..{close_i}], child at {child_positions}")

    deltas: dict[str, str] = {}
    for event in events:
        if event.get("type") == "TEXT_MESSAGE_CONTENT":
            deltas[str(event["run_id"])] = deltas.get(str(event["run_id"]), "") + event["delta"]
    streamed_ids = {
        str(e["message_id"]) for e in events if e.get("type") == "TEXT_MESSAGE_START"
    }
    assistant_ids = {str(m.id) for m in messages if m.role == "assistant"}
    check("the streamed message id IS the persisted row's id",
          streamed_ids <= assistant_ids,
          f"{len(streamed_ids)} streamed, {len(assistant_ids)} assistant rows")

    for run_id, streamed in deltas.items():
        persisted = next(
            (m.content for m in messages if str(m.run_id) == run_id and m.role == "assistant"), None
        )
        check(f"streamed text == persisted assistant row (run {run_id[:8]})",
              streamed == persisted,
              f"{len(streamed)} chars streamed")

    persisted_ids = {str(m.id) for m in messages}
    checkpointed = {str(e["message_id"]) for e in events if e.get("type") == "MESSAGE_PERSISTED"}
    check("every persisted message has a MESSAGE_PERSISTED checkpoint",
          persisted_ids == checkpointed,
          f"{len(persisted_ids)} rows, {len(checkpointed)} checkpoints")

    # --- B. what is stored, and what is deliberately not ------------------
    print("\n-- B. persistence structure")
    by_run: dict[UUID, list] = {}
    for m in messages:
        by_run.setdefault(m.run_id, []).append(m)

    # Keyed by run, and a run's own turn is always exactly one of each — however
    # many tool_call/tool_response rows it also carries for delegating.
    check("every run stored exactly one user and one assistant message",
          all(
              len([m for m in rows if m.role == "user"]) == 1
              and len([m for m in rows if m.role == "assistant"]) == 1
              for run_id, rows in by_run.items()
              if run_id is not None
          ),
          " / ".join(f"{len(rows)} rows" for rows in by_run.values()))

    # Two things legitimately produce tool rows: a delegation, and a chained
    # action the runtime itself fired. Nothing else may.
    tool_rows = [m for m in messages if m.role in ("tool_call", "tool_response")]
    chained = [m for m in tool_rows if m.tool_call_id == CHAINED_CALL_ID]
    delegations = [m for m in tool_rows if m.tool_call_id != CHAINED_CALL_ID]
    calls = {m.tool_call_id: m for m in delegations if m.role == "tool_call"}
    check("tool_call/tool_response rows exist ONLY for delegations",
          bool(delegations)
          and all((m.content or "").startswith(TOOL_PREFIX) for m in calls.values())
          and all(m.tool_call_id in calls for m in delegations if m.role == "tool_response"),
          f"{len(delegations)} delegation rows, {len(calls)} call(s), all paired"
          + (f"; {len(chained)} chained-action rows" if chained else ""))

    retrieval_calls = [
        c
        for m in messages
        if m.role == "assistant"
        for c in m.tool_calls
        if not c["tool_name"].startswith(TOOL_PREFIX)
    ]
    check("retrieval happened and left no message rows",
          len(retrieval_calls) > 0
          and not any(m.role == "tool_response" and not (m.content or "").startswith("agent")
                      for m in tool_rows if m.tool_call_id is None),
          f"{len(retrieval_calls)} retrieval calls, 0 rows")

    check("the assistant's tool_calls JSONB records the call, never its result",
          all(set(c) <= {"call_id", "tool_name", "is_error", "error_kind"} for c in retrieval_calls),
          f"keys: {sorted(set().union(*(set(c) for c in retrieval_calls)))}")

    cited = [m for m in messages if m.citations]
    check("citations exist, and only on assistant rows",
          bool(cited) and all(m.role == "assistant" for m in cited),
          f"{sum(len(m.citations) for m in cited)} citations on {len(cited)} row(s)")

    async with client.as_user(repo.claims) as conn:
        known = await conn.fetch("select chunk_id, resource_id from demo.chunks")
    known_chunks = {str(r["chunk_id"]) for r in known}
    all_citations = [c for m in cited for c in m.citations]
    check("every citation points at a chunk that really was returned",
          all(str(c.chunk_id) in known_chunks for c in all_citations if c.kind == "chunk"),
          f"{len(all_citations)} citations resolve")

    # --- C. the tree ------------------------------------------------------
    print("\n-- C. delegation / span tree")
    check("a delegated child run exists", bool(child), child.agent_name if child else "none")
    if child:
        check("child.parent_span_id == parent.span_id", child.parent_span_id == parent.span_id)
        check("one trace across the tree", child.trace_id == parent.trace_id, parent.trace_id)
        check("depth increments", child.depth == parent.depth + 1)
        call_row = next((m for m in messages if m.id == child.delegated_by_message_id), None)
        check("delegated_by_message_id points at the parent's tool_call row",
              call_row is not None and call_row.role == "tool_call"
              and call_row.run_id == parent.id,
              call_row.content if call_row else "missing")

    # --- D. round trip ----------------------------------------------------
    print("\n-- D. round trip: rows -> model messages")
    parent_window = await repo.branch_messages(session.id, None)
    child_window = await repo.branch_messages(session.id, parent.id) if child else []
    reloaded = sequencer.persistence.to_model_messages(parent_window)
    check("the parent's branch reloads without loss",
          len(reloaded) == len(parent_window),
          f"{len(parent_window)} rows -> {len(reloaded)} model messages")
    kinds = [type(p).__name__ for m in reloaded for p in m.parts]
    check("the delegation round-trips as a real tool call, not as prose",
          "ToolCallPart" in kinds and "ToolReturnPart" in kinds, " ".join(sorted(set(kinds))))
    # The session's rolling summary (run_id null) belongs to *every* window by
    # design — it is the one row the reserved slot holds — so it is excluded
    # here rather than treated as a leak.
    child_ids = {c.id for c in children}
    turns = lambda rows: [m for m in rows if m.role != "summary"]
    check("the child branch contains only delegated runs' rows",
          all(m.run_id in child_ids for m in turns(child_window)) if child else True,
          f"{len(child_window)} rows across {len(children)} child run(s)")
    check("no child row leaks into the parent's window",
          all(m.run_id == parent.id for m in turns(parent_window)))

    # --- G. mounted, not just runnable ------------------------------------
    print("\n-- G. mounted into a host app (spec §10.1)")
    # The host app from dev/host_app.py, driven in-process over ASGI: no port,
    # no second server, and its own lifespan — so this asserts the composition
    # a deployment does, not a copy of it.
    from host_app import app as host_app

    async with host_app.router.lifespan_context(host_app):
        transport = httpx.ASGITransport(app=host_app)
        async with httpx.AsyncClient(transport=transport, base_url="http://host") as http:
            health = await http.get("/healthz")
            check("the host's own routes still work beside the mounted ones",
                  health.json().get("mounted") == "percolate_core.agentic", health.text)

            unauth = await http.post("/agents/chat", json={"model": "echo", "messages": []})
            check("the mounted router enforces the same identity rule",
                  unauth.status_code == 401, str(unauth.status_code))

            events: list[str] = []
            async with http.stream(
                "POST",
                "/agents/chat",
                headers={"Authorization": f"Bearer {os.environ['P8_REST_TOKEN']}"},
                json={
                    "model": "echo",
                    "messages": [{"role": "user", "content": "go"}],
                    "stream": True,
                },
                timeout=90,
            ) as response:
                mounted_session = response.headers.get("x-p8-session-id")
                async for line in response.aiter_lines():
                    if line.startswith("event: "):
                        events.append(line[7:])

    check("a turn streams identically through the mounted prefix",
          events[:1] == ["RUN_STARTED"] and events[-1:] == ["RUN_FINISHED"],
          f"{len(events)} frames, {events[0] if events else '-'} … {events[-1] if events else '-'}")
    async with client.as_user(repo.claims) as conn:
        mounted_rows = await conn.fetchval(
            "select count(*) from agentic.messages_api where session_id = $1",
            UUID(mounted_session),
        )
    check("and its rows land in the same tables", mounted_rows == 2, f"{mounted_rows} rows")

    # --- H. session resume ------------------------------------------------
    print("\n-- H. resuming a session (X-P8-Session-Id)")
    await repo.upsert_agent(
        AgentSpec(
            name="recall",
            system_prompt=(
                "Answer only from what has been said in this conversation. "
                "Be terse. If you were told a reference, repeat it exactly."
            ),
        )
    )

    async with httpx.AsyncClient(base_url="http://127.0.0.1:8080", timeout=90) as http:
        auth = {"Authorization": f"Bearer {os.environ['P8_REST_TOKEN']}"}

        async def turn(text: str, session: str | None) -> tuple[str, str]:
            """One turn over HTTP, resuming by header when given a session."""
            headers = dict(auth)
            if session:
                headers["X-P8-Session-Id"] = session
            said: list[str] = []
            async with http.stream(
                "POST",
                "/chat",
                headers=headers,
                json={
                    "model": "recall",
                    "messages": [{"role": "user", "content": text}],
                    "stream": True,
                },
            ) as response:
                sid = response.headers["x-p8-session-id"]
                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        event = json.loads(line[6:])
                        if event["type"] == "TEXT_MESSAGE_CONTENT":
                            said.append(event["delta"])
            return sid, "".join(said)

        first_id, _ = await turn("My incident reference is INC-9137. Acknowledge it.", None)
        resumed_id, answer = await turn("What is my incident reference?", first_id)

        bad = await http.post(
            "/chat",
            headers={**auth, "X-P8-Session-Id": "00000000-0000-0000-0000-000000000000"},
            json={"model": "recall", "messages": [{"role": "user", "content": "x"}]},
        )

    check("the header resumes the same session", resumed_id == first_id, resumed_id)
    check("the resumed turn remembers what the first one was told",
          "INC-9137" in answer, answer.strip()[:70])
    check("an unknown session id fails before the stream opens, not inside it",
          bad.status_code == 404, f"{bad.status_code} {bad.text[:60]}")

    # Recovery: everything needed to reconstruct the conversation is in rows —
    # this is the same read a fresh client (or a new process) would do.
    recovered = await repo.session_messages(UUID(first_id))
    roles = [m.role for m in recovered]
    check("the conversation is recoverable from rows alone",
          roles == ["user", "assistant", "user", "assistant"], " ".join(roles))
    replayed = sequencer.persistence.to_model_messages(
        await repo.branch_messages(UUID(first_id), None)
    )
    check("and replays as an alternating history",
          len(replayed) == 4, f"{len(replayed)} model messages")

    # --- F. tenant isolation ---------------------------------------------
    print("\n-- F. tenant isolation (phases.py gate 1)")
    # Read as the real `authenticated` role with another user's claims, exactly
    # as PostgREST does per request. An ad-hoc role or a superuser would prove
    # nothing: both bypass the policies this is checking.
    async with client.as_user({"sub": "bbbbbbbb-0000-0000-0000-000000000002"}) as conn:
        their_sessions = await conn.fetchval("select count(*) from agentic.sessions_api")
        their_messages = await conn.fetchval("select count(*) from agentic.messages_api")
    async with client.as_user(repo.claims) as conn:
        my_sessions = await conn.fetchval("select count(*) from agentic.sessions_api")
    check("the owner sees their conversations", my_sessions > 0, f"{my_sessions} sessions")
    check("another user sees none of them",
          their_sessions == 0 and their_messages == 0,
          f"{their_sessions} sessions, {their_messages} messages")

    # --- E. background: threshold -> workflow -> scheduled run -> summary --
    print("\n=== E: summarization as a scheduled run ===")
    await repo.upsert_agent(
        AgentSpec(
            name="chatter",
            system_prompt="Reply in one short sentence.",
            context_policy=ContextPolicy(window_messages=2, summarize_after_messages=4),
        )
    )
    chat_session = await repo.create_session(Session(title="verify-summary"))
    for prompt in ("Say hello.", "Say goodbye.", "Say anything."):
        s = TurnSequencer(repo, settings, sink=EventSink(repo))
        await s.run_turn(
            ChatRequest(
                model="chatter",
                messages=[InboundMessage(role="user", content=prompt)],
                session_id=chat_session.id,
            ),
            RequestContext(user_id=repo.user_id),
        )
    dispatched = any(r.name == "maybe_summarize" and "dispatched" in r.detail for r in s.trace)
    check("crossing the threshold dispatched a workflow run", dispatched,
          next((r.detail for r in s.trace if r.name == "maybe_summarize"), ""))

    from worker import run_once  # the stand-in http_call executor

    # Drain every queued http_call task, not just one: a worker claims the
    # oldest ready task, which in a database with leftovers from a previous run
    # is somebody else's. Draining is what a real worker pool does anyway.
    dispatched_any = False
    for _ in range(10):
        if not await run_once(client, "http"):
            break
        dispatched_any = True
    check("an http_call task was queued and dispatched", dispatched_any)

    # The dispatch is `mode: "async"` -- the executor returns as soon as the run
    # is accepted, and the runtime completes the task when it is genuinely done
    # (brief.md §3). Polling, not sleeping, is the honest way to wait for that.
    # Scoped to *this* session, not "the most recent scheduled run": with a
    # shared queue and leftovers from earlier runs, "most recent" is somebody
    # else's work, and an assertion that races is worse than no assertion.
    summary = scheduled = None
    for _ in range(60):
        async with client.as_user(repo.claims) as conn:
            scheduled = await conn.fetchrow(
                "select * from agentic.runs_api where trigger_kind = 'scheduled' "
                "and session_id = $1 order by created_at desc limit 1",
                chat_session.id,
            )
            summary = await conn.fetchrow(
                "select * from agentic.messages_api where session_id = $1 and role = 'summary'",
                chat_session.id,
            )
        if summary is not None and scheduled is not None and scheduled["status"] != "running":
            break
        await asyncio.sleep(0.5)
    # workflow.tasks has no grant for `authenticated` (workers use functions,
    # not tables) -- this is a test assertion, so it reads as the table owner.
    async with client.as_user(None, role="app_owner") as conn:
        task_status = await conn.fetchval(
            "select status from workflow.tasks where id = $1",
            scheduled["workflow_task_id"] if scheduled else None,
        )

    check("a scheduled run exists, linked to its workflow task",
          scheduled is not None and scheduled["workflow_task_id"] is not None,
          f"status={scheduled['status']}" if scheduled else "none")
    check("the chained action wrote the session's summary row",
          summary is not None, (summary["content"] or "")[:60] if summary else "none")
    # 'succeeded'. This said 'done', under a comment asserting that tasks and
    # runs use two different terminal words "deliberately". They do not:
    # workflow.tasks' CHECK admits pending / ready / running / waiting_external
    # / succeeded / failed / cancelled, and 'done' is in neither vocabulary. So
    # this check could not pass, `failures` was never empty, and the harness
    # exited 1 whatever the runtime did -- while the phase gates and the release
    # notes cited it as the thing that closes a gate. A check that cannot pass stops being run, and the
    # claims resting on it keep getting written.
    check("the runtime completed its own triggering task", task_status == "succeeded",
          f"task status={task_status}")

    await listener.close()
    await client.close()

    print("\n" + ("=" * 60))
    if failures:
        print(f"{len(failures)} FAILED: " + "; ".join(failures))
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    asyncio.run(main())
