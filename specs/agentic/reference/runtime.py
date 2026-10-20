#!/usr/bin/env python3
"""A minimal agent turn: load the agent from a row, run it, persist what happened.

    python3 runtime.py percolate "Which pairs moved with sterling?"

The point of this file is what is NOT in it. There is no agent here. There is
no tool here. There is no prompt here. `percolate` appears nowhere except in
the argv above -- grep this file for it and there is nothing to find, which is
the property `brief.md` §5.2 claims and this is the check.

**Agents load dynamically, at invocation, from the database.** Not at import,
not at deploy, not from a registry compiled into the process. Every turn reads
the agent row and the tool_servers rows it references, so editing an agent's
prompt, model, tool allowlist or classification changes the very next turn --
with nothing restarted and nothing redeployed. That is the whole reason an
agent is a row (`brief.md` §2, §6, and the requirement in §11.9): a runtime
that cached agents at startup would turn every agent edit back into a deploy,
which is the thing this design exists to avoid.

The loop, and nothing else:

    1. read the agent row                        (agentic.agents_api)
    2. resolve its tool allowlist to real tools  (tool_servers_api.cached_tools)
    3. open a session and a run                  (create_session, start_run)
    4. ask the model, with those tools
    5. it asked for a tool -> dispatch it        (binder.invoke) and go to 4
    6. it answered -> persist the turn and close (persist_turn, finish_run)

What this is NOT: the runtime this collection deploys. That is
percolate-core's `agent` subpackage, which wraps pydantic-ai and does streaming,
delegation, context windowing, summarization and citations
(`brief.md` §5.1, §10). This file is the same contract with all of that removed,
so the contract itself can be read in one sitting and executed in one command.

The model endpoint is OpenAI-shaped and is configuration, not agent data: the
row names a model, and where to reach one is a property of the deployment.

    --model-url         https://api.openai.com/v1/chat/completions
    --model-credential  env:OPENAI_API_KEY     (a reference, never the secret)

Point it at a vendor, or at dev/faultsrv's scripted stub to exercise the loop
without a key. Which model is used comes from the AGENT ROW, so switching one
agent from a stub to a real model is an upsert, not an edit here.
"""
import argparse
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import binder                                                    # noqa: E402


def load_agent(p8, name):
    """The agent, at invocation time. Two reads, no cache, no registry."""
    rows = binder.http(
        "GET", "%s/agents_api?name=eq.%s" % (p8.base, name),
        headers=p8._h("agentic"))
    if not rows:
        raise binder.ToolError(
            "no agent named %r. It is a row -- insert one and call again; "
            "nothing here needs restarting." % name)
    return rows[0]


def resolve_tools(p8, agent):
    """The agent's allowlist -> the tools the model is actually offered.

    The allowlist is by NAME, into cached_tools that discovery wrote. A name
    that no longer resolves is dropped and reported rather than passed through:
    handing a model a tool whose server has forgotten it produces a call that
    fails at dispatch, one round trip later, with a worse error.
    """
    offered, missing = [], []
    for binding in agent.get("tools") or []:
        srv = p8.server(binding["server"])
        allow = binding.get("tools")
        for t in srv["cached_tools"]:
            if allow is not None and t["name"] not in allow:
                continue
            offered.append((srv, t))
        have = {t["name"] for t in srv["cached_tools"]}
        missing += ["%s.%s" % (srv["name"], n) for n in (allow or []) if n not in have]
    return offered, missing


def as_openai(offered):
    return [{"type": "function",
             "function": {"name": t["name"],
                          "description": (t.get("description") or "")[:1024],
                          "parameters": t["input_schema"]}}
            for _, t in offered]


def turn(p8, agent, question, model_url, token, model_headers=None,
         max_steps=8, verbose=True):
    offered, missing = resolve_tools(p8, agent)
    if missing:
        print("  ! bound tools that no longer resolve: %s" % ", ".join(missing))
    if verbose:
        print("  agent   %s  (%s, %s)" % (agent["name"], agent["model"],
                                          agent.get("category", "?")))
        print("  tools   %s" % ", ".join(t["name"] for _, t in offered))

    # Both of these return the ROW, not the id -- they are `returns
    # agentic.sessions` / `returns agentic.runs`, so PostgREST hands back the
    # whole record and the id has to be taken out of it.
    session = p8.rpc("agentic", "create_session",
                     {"p_title": question[:60]})["id"]
    run = p8.rpc("agentic", "start_run", {"p_agent_name": agent["name"],
                                          "p_session_id": session})
    if verbose:
        print("  session %s\n  run     %s" % (session, run["id"]))

    # Only what the API defines goes in the request body. An earlier version
    # also sent `session`, which dev/faultsrv echoes back -- and OpenAI rejects
    # outright ("Unrecognized request argument supplied: session"). Worth the
    # note because it is the shape of mistake a stub invites: the double
    # accepted a field the real endpoint refuses, so the loop passed against
    # the fake and failed on the first real call. Conversation identity lives
    # in agentic.sessions, not in a model request.
    #
    # The system prompt is the agent's, from the row. Not a template here.
    msgs = [{"role": "system", "content": agent["system_prompt"]},
            {"role": "user", "content": question}]
    rows = [{"run_id": run["id"], "session_id": session,
             "role": "user", "content": question}]

    by_name = {t["name"]: (srv, t) for srv, t in offered}
    final = None

    for _ in range(max_steps):
        reply = binder.http("POST", model_url, headers=model_headers, body={
            # The provider prefix is stripped: the row says
            # `openai:gpt-4.1-mini` or `anthropic:claude-sonnet-5`, and the
            # part before the colon selects WHICH endpoint a deployment points
            # this at -- it is not part of the model name any vendor accepts.
            "model": agent["model"].split(":", 1)[-1],
            "messages": msgs, "tools": as_openai(offered)})
        choice = reply["choices"][0]
        m = choice["message"]

        if not m.get("tool_calls"):
            final = m.get("content")
            aid = str(uuid.uuid4())
            rows.append({"id": aid, "run_id": run["id"], "session_id": session,
                         "role": "assistant", "content": final,
                         "citations": citations_for(rows, by_name)})
            break

        msgs.append(m)
        rows.append({"run_id": run["id"], "session_id": session,
                     "role": "tool_call", "content": None,
                     "tool_calls": m["tool_calls"]})

        for tc in m["tool_calls"]:
            name = tc["function"]["name"]
            args = json.loads(tc["function"]["arguments"] or "{}")
            if verbose:
                print("  call    %s(%s)" % (name, json.dumps(args)[:70]))
            srv, tool = by_name[name]
            try:
                out = binder.invoke(srv, tool, args, token)
                err_kind = None
            except (binder.ToolError, binder.DispatchError) as e:
                # brief.md §5.2: a failed tool is an OBSERVATION, handed back to
                # the model as a tool result, never an exception that ends the
                # turn. The two kinds stay distinguishable on the row.
                out, err_kind = {"error": str(e)}, e.__class__.kind
                if verbose:
                    print("  failed  %s (%s)" % (name, err_kind))

            text = json.dumps(out)
            msgs.append({"role": "tool", "tool_call_id": tc["id"], "content": text})
            rows.append({"run_id": run["id"], "session_id": session,
                         "role": "tool_response", "tool_call_id": tc["id"],
                         "content": text, "is_error": err_kind is not None,
                         "error_kind": err_kind,
                         "_server": srv["name"], "_result": out})

    if final is None:
        # The step cap, said out loud. It first defaulted to 4 and a real model
        # spent all four discovering the schema before it could answer -- the
        # turn ended with no assistant message, printed "(none)", and stored a
        # failed run with nothing in it saying why. A turn that ran out of room
        # and a turn whose model refused are different facts, and the run row
        # has to be able to tell them apart.
        rows.append({"run_id": run["id"], "session_id": session,
                     "role": "assistant",
                     "content": "[no answer: the turn hit its %d-step tool cap. "
                                "The model was still working -- raise max_steps "
                                "or narrow the question.]" % max_steps})

    # One call for the whole turn, not N inserts (brief.md §4).
    p8.rpc("agentic", "persist_turn",
           {"p_rows": [{k: v for k, v in r.items() if not k.startswith("_")}
                       for r in rows]})
    # `succeeded`, not `completed`: agentic.runs and workflow.runs do NOT share
    # a status vocabulary, and the check constraint is the only thing that says
    # so. Worth the note because every other verb in this file was borrowed
    # straight from the workflow side and worked.
    p8.rpc("agentic", "finish_run", {
        "p_run_id": run["id"],
        "p_status": "succeeded" if final else "failed",
        "p_state": None if final else {"reason": "step_cap", "max_steps": max_steps}})
    return run["id"], session, final


def citations_for(rows, by_name):
    """Provenance by construction (brief.md §5.3).

    Built by the RUNTIME from the tool responses in this turn, from servers
    flagged `emits_citations` -- never asked of the model, which drops them,
    invents them, or cites generically. Scoped to this answer, not the run.
    """
    out = []
    for r in rows:
        if r.get("role") != "tool_response" or r.get("is_error"):
            continue
        srv = next((s for s, _ in by_name.values() if s["name"] == r.get("_server")), None)
        if not srv or not srv.get("emits_citations"):
            continue
        for row in (r.get("_result") or {}).get("rows") or []:
            if row.get("chunk_id"):
                out.append({"kind": "chunk", "resource_id": row.get("resource_id"),
                            "chunk_id": row["chunk_id"]})
            elif row.get("node_id") or row.get("neighbor_id"):
                out.append({"kind": "node",
                            "node_id": row.get("node_id") or row["neighbor_id"]})
    seen, uniq = set(), []
    for c in out:
        k = json.dumps(c, sort_keys=True)
        if k not in seen:
            seen.add(k)
            uniq.append(c)
    return uniq


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("agent")
    ap.add_argument("question")
    ap.add_argument("--postgrest", default=os.environ.get(
        "P8_POSTGREST", "http://localhost:3000"))
    ap.add_argument("--token", default=os.environ.get("P8_TOKEN"))
    ap.add_argument("--model-url", default=os.environ.get(
        "P8_MODEL_URL", "http://faultsrv:8099/v1/chat/completions"))
    # Same indirection as tool_servers.credential_ref, and for the same reason:
    # a reference resolved at call time, never a literal. Empty by default
    # because the default endpoint is dev/faultsrv, which wants no credential
    # and must not be handed one.
    ap.add_argument("--model-credential", default=os.environ.get("P8_MODEL_CREDENTIAL"))
    a = ap.parse_args()

    p8 = binder.Percolate(a.postgrest, a.token)
    try:
        key = binder.resolve_credential(a.model_credential)
        headers = {"Authorization": "Bearer %s" % key} if key else {}
        agent = load_agent(p8, a.agent)
        run_id, session, answer = turn(p8, agent, a.question, a.model_url,
                                       a.token, model_headers=headers)
    except (binder.ToolError, binder.DispatchError) as e:
        sys.exit("turn failed: %s" % e)

    print("\n  answer  %s" % (answer or "(none)"))
    print("\n  the turn, as persisted:")
    for m in binder.http("GET", "%s/messages_api?run_id=eq.%s&order=seq"
                         % (p8.base, run_id), headers=p8._h("agentic")):
        detail = m["content"] or json.dumps(m["tool_calls"])
        print("    %-14s %s%s" % (
            m["role"], (detail or "")[:88].replace("\n", " "),
            "  [%s]" % m["error_kind"] if m["error_kind"] else ""))
        if m["citations"]:
            print("    %-14s %s" % ("", json.dumps(m["citations"])[:88]))


if __name__ == "__main__":
    main()
