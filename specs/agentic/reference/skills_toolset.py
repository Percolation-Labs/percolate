#!/usr/bin/env python3
"""The fetched path: a model asking for a fragment by name, and by search.

    python3 skills_toolset.py --dsn "$DSN" ask percolate-skilled \
        'LOOKUP "sterling" came back empty. What now?'

`plugins.md` §5.4. Two surfaces, and the split between them is by POPULATION
rather than by preference -- which is the tool tax (every tool an agent is
offered costs it attention) applied to this spec's own first proposal, where it removed a
mechanism instead of adding one:

    load_skill(name)      ONE tool, over the agent's attached surface. The
                          index in the prompt already names those fragments, so
                          the model needs no search to find them -- it needs a
                          way to ask, and that is one tool with one argument.

    deferred discovery    N tools, one per fragment, over the population the
                          agent may reach but cannot list (`scope`). Hidden
                          from the prompt entirely by pydantic-ai's
                          `defer_loading()`, surfaced by its auto-injected tool
                          search. Only agents that set `scope` carry any of it.

Why not N deferred tools for the attached surface too, which was the first
design: the index is already in the prompt and already earns its keep, so
deferring those tools would spend a round trip searching for what the model has
already been told. Deferral pays when there is something to hide.
"""
import argparse
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skills                                                    # noqa: E402


def tool_name(skill_name):
    """`p8ql-fuzzy-lookup` -> `skill_p8ql_fuzzy_lookup`.

    Only the deferred surface needs this. The single `load_skill` tool takes
    the name as an ARGUMENT, so it never has to be an identifier -- which is
    one more small thing the one-tool shape does not have to get right.
    """
    return "skill_" + skill_name.replace("-", "_")


def build_toolsets(conn, agent):
    """One FunctionToolset for the attached surface, one deferred for discovery."""
    from pydantic_ai.toolsets import FunctionToolset

    policy = (agent.get("context_policy") or {}).get("skills") or {}
    attached = set(agent["skills"])

    def fetch_body(name):
        """Read ONE body, at call time. The laziness is the query, here too."""
        cur = conn.cursor()
        cur.execute("select content, version from agentic.skills_api where name = %s",
                    (name,))
        row = cur.fetchone()
        if not row:
            return "No procedure named %r. The ones offered are listed in your instructions." % name
        return row[0]

    # ---- the attached surface: ONE tool -----------------------------------
    surface = FunctionToolset()

    @surface.tool_plain
    def load_skill(name: str) -> str:
        """Load the full text of one of the procedures listed in your instructions.

        Pass the procedure's name exactly as it appears there. Use this when a
        listed procedure looks relevant and you need its detail before acting.
        """
        if name not in attached:
            return ("%r is not one of this agent's procedures. The ones you may "
                    "load are listed in your instructions." % name)
        return fetch_body(name)

    toolsets = [surface]

    # ---- discovery beyond it: N tools, deferred ---------------------------
    #
    # `defer_loading()` marks these so they are hidden from the model until its
    # tool search surfaces them. That is the same trade this design already
    # makes one layer up -- a listing is cheap, a body is not -- expressed in
    # the framework's own vocabulary, and it is the right mechanism HERE
    # because a population you cannot list is exactly what it is for.
    scope = policy.get("scope")
    if scope:
        cur = conn.cursor()
        beyond = [s for s in skills.listings(cur, scope=scope)
                  if s["name"] not in attached]
        if beyond:
            discovery = FunctionToolset()
            for s in beyond:
                def make(name=s["name"]):
                    def fn() -> str:
                        return fetch_body(name)
                    return fn
                # The tool's DESCRIPTION is the fragment's listing, so
                # pydantic-ai's search index and this system's index are the
                # same text rather than two things to keep in step.
                discovery.add_function(
                    make(), name=tool_name(s["name"]),
                    description=skills.listing_line(s).lstrip("- "))
            toolsets.append(discovery.defer_loading())
    return toolsets


async def run(conn, agent_name, request, model_name, api_key_env):
    from pydantic_ai import Agent

    os.environ.setdefault("OPENAI_API_KEY", skills.api_key_from_env(api_key_env))
    cur = conn.cursor()
    agent_row = skills.load_agent(cur, agent_name)

    # The prompt is assembled exactly as §5 says -- always-on bodies plus the
    # index -- and matching is left off here so the trace shows the FETCHED
    # path doing the work rather than the runtime having pre-empted it.
    policy = dict(agent_row.get("context_policy") or {})
    policy["skills"] = dict(policy.get("skills") or {}, match=False)
    prompt, acct = skills.expand(cur, dict(agent_row, context_policy=policy),
                                 None, request=request)

    toolsets = build_toolsets(conn, agent_row)
    agent = Agent(model_name, instructions=prompt, toolsets=toolsets)
    result = await agent.run(request)
    # `.tools` lives on the WRAPPED toolset -- a DeferredLoadingToolset is a
    # wrapper, and reading `.tools` off the wrapper reports zero for a surface
    # that is fully populated.
    n_deferred = sum(len(getattr(getattr(t, "wrapped", None), "tools", {}) or {})
                     for t in toolsets[1:])

    print("prompt        %d chars, %d listed, %d always-on"
          % (acct["chars"]["prompt"], acct["indexed"], len(acct["composed"])))
    print("tool surface  1 (load_skill) + %d deferred (hidden until searched)"
          % n_deferred)
    print("-" * 66)
    for m in result.all_messages():
        for part in m.parts:
            kind = part.__class__.__name__
            if kind == "ToolCallPart":
                print("  -> %s(%s)" % (part.tool_name, part.args))
            elif kind == "ToolReturnPart":
                body = str(part.content).strip().replace("\n", " ")
                print("  <- %s: %s%s" % (part.tool_name, body[:90],
                                         "..." if len(body) > 90 else ""))
    print("-" * 66)
    print(result.output.strip()[:600])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dsn", default=os.environ.get("P8_DSN"))
    ap.add_argument("--env-file", default=os.environ.get("P8_ENV_FILE"))
    ap.add_argument("--api-key-env", dest="api_key_env", default="OPENAI_API_KEY")
    ap.add_argument("--model", default="openai:gpt-4.1-mini")
    ap.add_argument("command", choices=["ask"])
    ap.add_argument("agent")
    ap.add_argument("request")
    args = ap.parse_args()

    skills.load_env(args.env_file)
    import psycopg2
    conn = psycopg2.connect(args.dsn)
    asyncio.run(run(conn, args.agent, args.request, args.model, args.api_key_env))
    conn.close()


if __name__ == "__main__":
    main()
