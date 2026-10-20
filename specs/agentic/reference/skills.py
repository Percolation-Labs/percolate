#!/usr/bin/env python3
"""Prompt expansion: turn an agent row plus a request into one system prompt.

    python3 skills.py --dsn "$DSN" expand percolate-skilled "lookup gives nothing"

This is `plugins.md` §5 executed. The claim it exists to make checkable:

    A prompt is ASSEMBLED, not authored. An agent row carries a short prompt
    and a set of keys; the text those keys name lives once, is shared, and is
    read at invocation. Fragments this turn does not need never enter context.

Three paths in, and they differ only in who decides (§5):

    composed   agents.skills            -- the author. Always expanded.
    matched    context_policy.skills    -- the runtime. Ranked per turn.
    fetched    a serves_skills server   -- the model. Not implemented here:
                                          it is an ordinary tool call, and
                                          binder.py already dispatches those.

What is NOT in this file: any skill. Grep it for `p8ql` or `workflow` and there
is nothing to find. The fleet is rows; this is the assembly.

Read through `agentic.agents_api` and `agentic.skills_api` rather than the base
tables, because the runtime reads its own configuration through the same views
every other client does (`brief.md` §10.2) -- a column hidden from the view is a
column the runtime does not have.
"""
import argparse
import json
import os
import sys
import urllib.request

EMBED_MODEL = "text-embedding-3-small"
EMBED_URL = "https://api.openai.com/v1/embeddings"

# Roughly 4 characters per token for English prose. Used only for reporting, so
# an approximation is honest as long as it is applied to every arm equally --
# the ratios below are the claim, not the absolute counts.
CHARS_PER_TOKEN = 4.0


# ---------------------------------------------------------------- environment

def load_env(path):
    """Read KEY=VALUE lines into os.environ without printing anything.

    A credential_ref in a row names an environment variable (`env:OPENAI_API_KEY`);
    resolving it is the caller's job and the value never touches the database,
    a log line or this file's output.
    """
    if not path or not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip().strip('"').strip("'")
            if k.strip() and v and k.strip() not in os.environ:
                os.environ[k.strip()] = v


# ---------------------------------------------------------------- embeddings

API_KEY_ENV = "OPENAI_API_KEY"


def api_key_from_env(env_name=None):
    """Resolve the credential the way a `credential_ref` says to.

    `aiq.embedding_models.credential_ref` is `env:<NAME>` -- an indirection, and
    the NAME is a property of the deployment, not of the model. A machine whose
    variable is called `P8_OPENAI_API_KEY` is not misconfigured; it is the case
    the indirection exists for. So the variable is named, never assumed.
    """
    name = env_name or API_KEY_ENV
    key = os.environ.get(name)
    if not key:
        raise SystemExit(
            "no %s in the environment. The model row names its credential as "
            "`env:%s` -- export it, or pass --api-key-env naming the variable "
            "this deployment actually uses." % (name, API_KEY_ENV))
    return key


def embed(texts, api_key=None, model=EMBED_MODEL, env_name=None):
    """One call for many texts. §6: the batch shape is the registry's, not ours.

    `aiq.embed_batch_call()` is where a deployed worker gets this request shape
    from -- model, url, body template and the name of the credential -- so that
    the batch path and the single path cannot end up calling different models.
    This function hardcodes the OpenAI shape because it is a harness, and says
    so rather than pretending to be the worker.
    """
    key = api_key or api_key_from_env(env_name)
    out = []
    for i in range(0, len(texts), 128):
        batch = texts[i:i + 128]
        body = json.dumps({"model": model, "input": batch}).encode()
        req = urllib.request.Request(
            EMBED_URL, data=body,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + key})
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = json.load(resp)
        # The response is in input order, which is the whole reason a batch is
        # usable at all; asserting it rather than trusting it costs nothing.
        rows = sorted(payload["data"], key=lambda d: d["index"])
        assert len(rows) == len(batch), "provider returned %d vectors for %d inputs" % (
            len(rows), len(batch))
        out.extend(r["embedding"] for r in rows)
    return out


def to_vector(vec):
    """pgvector's text input format."""
    return "[" + ",".join("%.7g" % x for x in vec) + "]"


# ---------------------------------------------------------------- reading rows

def load_agent(cur, name):
    """The agent, at invocation. No cache, no registry (`brief.md` §11.9)."""
    cur.execute(
        "select name, system_prompt, skills, context_policy, tools "
        "from agentic.agents_api where name = %s", (name,))
    row = cur.fetchone()
    if not row:
        raise SystemExit(
            "no agent named %r. It is a row -- insert one and call again." % name)
    return {"name": row[0], "system_prompt": row[1], "skills": list(row[2] or []),
            "context_policy": row[3] or {}, "tools": row[4] or []}


def load_skills(cur, names):
    """Bodies, by name, in the order asked for."""
    if not names:
        return []
    cur.execute(
        "select name, description, when_to_use, content, version "
        "from agentic.skills_api where name = any(%s)", (list(names),))
    by_name = {r[0]: {"name": r[0], "description": r[1], "when_to_use": r[2],
                      "content": r[3], "version": r[4]} for r in cur.fetchall()}
    missing = [n for n in names if n not in by_name]
    if missing:
        # §7: a name that resolves to nothing is REPORTED, not skipped.
        # Instructions an agent silently never receives are the one failure
        # that produces no error anywhere.
        raise SystemExit(
            "agent composes skill(s) %s which do not exist" % ", ".join(missing))
    return [by_name[n] for n in names]


def listings(cur, names=None, scope=None):
    """The listing columns, and DELIBERATELY NOT `content`.

    This is where the laziness actually lives, and it is a projection rather
    than a framework feature: the index needs a name, a description and a
    trigger, so the query asks for those and the body is never read. Written
    the obvious way -- select the row, use the columns you want -- it read
    every attached body out of Postgres on every turn and put none of them in
    the prompt. The prompt was lazy and the database was not, which is the half
    of the claim nobody looks at.
    """
    sql = ("select name, description, when_to_use, version, tags "
           "from agentic.skills_api")
    where, args = [], []
    if names is not None:
        where.append("name = any(%s)")
        args.append(list(names))
    if scope and scope.get("tags"):
        where.append("tags && %s")
        args.append(list(scope["tags"]))
    if where:
        sql += " where " + " and ".join(where)
    cur.execute(sql, args)
    rows = {r[0]: {"name": r[0], "description": r[1], "when_to_use": r[2],
                   "version": r[3], "tags": list(r[4] or [])}
            for r in cur.fetchall()}
    # In the caller's order when the caller named them: composition order is
    # meaningful and a dict from the database is not ordered by intent.
    return [rows[n] for n in names if n in rows] if names is not None \
        else list(rows.values())


# ---------------------------------------------------------------- matching

def rank_semantic(cur, query_vec, model=EMBED_MODEL, limit=200):
    """Through `aiq.semantic_in`, the collection's one vector path.

    It joins the embedding space back to the source table by id, so
    `agentic.skills` needed no adaptation to become a corpus: it has an `id`,
    which is the whole contract. Score is 1 - cosine distance.
    """
    cur.execute(
        "select s.name, (1 - m.distance)::float8 "
        "  from aiq.semantic_in('skills', %s::vector, %s, %s) m "
        "  join agentic.skills_api s on s.id = m.chunk_id "
        " order by 2 desc", (to_vector(query_vec), model, limit))
    return [(r[0], float(r[1])) for r in cur.fetchall()]


def rank_lexical(cur, query_text, limit=200):
    """TEXT-mode matching over the same listing text, for a deployment with no
    embedding provider. Score is ts_rank.

    NOT `aiq.lexical`, and the reason is measured rather than stylistic: that
    function builds its query with `plainto_tsquery`, which is CONJUNCTIVE --
    every term of the request must appear in the listing. That is right for
    finding a document that contains a phrase and hopeless for matching a
    sentence against a 120-character listing. On the eval set it scores 4%.

    Flipping the operators on the same parsed, stemmed, stopword-stripped query
    makes it disjunctive and takes the same corpus, the same rows and the same
    ts_rank to 74% hit@3. So this builds that query directly, and `aiq.lexical`
    is left alone: an `any` mode belongs in the query layer's own dialect, on
    its own evidence, not smuggled in from a consumer.

    ts_rank is on a completely different scale from cosine, and worse, on this
    corpus it has no usable threshold at all -- recall falls from 74% to 26%
    between 0.01 and 0.03. A lexical matcher is therefore a `top_k` matcher;
    `min_score` is a knob that means something only on the semantic arm.
    """
    cur.execute(
        "select s.name, ts_rank(s.search_tsv, q)::float8 "
        "  from agentic.skills s, "
        "       to_tsquery('english', "
        "           replace(plainto_tsquery('english', %s)::text, ' & ', ' | ')) q "
        " where s.search_tsv @@ q "
        " order by 2 desc limit %s", (query_text, limit))
    return [(r[0], float(r[1])) for r in cur.fetchall()]


def match(cur, request, query_vec, scope, top_k, min_score,
          matcher="semantic", model=EMBED_MODEL, attached=None):
    """Rank the eligible fragments against this turn's request, then cut.

    Returns [(name, score)], best first, already filtered by `scope`,
    `min_score` and `top_k` -- the three knobs §5.2 defines.
    """
    names = None
    if attached is not None:
        names = set(attached)
        if scope and scope.get("tags"):
            cur.execute("select name from agentic.skills_api where tags && %s",
                        (list(scope["tags"]),))
            names |= set(r[0] for r in cur.fetchall())
    elif scope and scope.get("tags"):
        cur.execute("select name from agentic.skills_api where tags && %s",
                    (list(scope["tags"]),))
        names = set(r[0] for r in cur.fetchall())

    if matcher == "lexical":
        ranked = rank_lexical(cur, request)
    else:
        ranked = rank_semantic(cur, query_vec, model)

    hits = []
    for name, score in ranked:
        if names is not None and name not in names:
            continue
        if score < min_score:
            continue
        hits.append((name, float(score)))
        if len(hits) >= top_k:
            break
    return hits


# ---------------------------------------------------------------- assembly

def listing_line(skill):
    """One index line: what a model reads to know a fragment exists (§2)."""
    line = "- %s: %s" % (skill["name"], skill["description"])
    if skill["when_to_use"]:
        line += " Use when: " + skill["when_to_use"]
    return " ".join(line.split())


def expand(cur, agent, request_vec, sticky=None, request=""):
    """Assemble one turn's system prompt. `plugins.md` §5, steps 1-4.

    `sticky` is the set already expanded on this branch, as {name: version}.
    It is STATE, carried in runs.state (§5.3) -- passed in and returned rather
    than recomputed, because the transcript does not contain the composed
    prompt and a resumed conversation must expand the same set.

    Returns (prompt, accounting).
    """
    policy = (agent.get("context_policy") or {}).get("skills") or {}
    sticky = dict(sticky or {})

    # ATTACHED is the agent's skill SURFACE, and it is the same idea as its
    # tool surface one column over: `agents.tools` says which tools this agent
    # may call without carrying their implementations, and `agents.skills` says
    # which fragments it may use without carrying their bodies. Attaching one
    # costs a listing line, not a body.
    attached = listings(cur, names=agent["skills"])
    attached_by_name = {s["name"]: s for s in attached}
    missing = [n for n in agent["skills"] if n not in attached_by_name]
    if missing:
        # §7: reported, not skipped.
        raise SystemExit(
            "agent attaches skill(s) %s which do not exist" % ", ".join(missing))

    # ALWAYS is the small subset whose body is expanded unconditionally --
    # house style, safety rules, the things that must hold whether or not the
    # turn looks like it needs them. It is a policy key rather than the meaning
    # of attachment, because making attachment itself eager is what turns a
    # skill back into a paragraph of the prompt.
    always = [n for n in agent["skills"] if n in set(policy.get("always") or [])]
    v_unknown = [n for n in (policy.get("always") or []) if n not in attached_by_name]
    if v_unknown:
        raise SystemExit(
            "context_policy.skills.always names %s, which the agent has not "
            "attached. Always-expanding a fragment the agent does not carry is "
            "a policy about something that is not there."
            % ", ".join(v_unknown))
    # The ONLY place a body is read for the always-on set, and it reads exactly
    # as many rows as there are names in `always`.
    composed = load_skills(cur, always)

    # --- matched, this turn ------------------------------------------------
    hits = []
    matcher = policy.get("matcher", "semantic")
    # Matching ranks the ATTACHED surface by default. `scope` widens it to
    # fragments the agent has not attached, which is discovery rather than
    # capability -- an agent reaching outside its own surface is a different
    # claim from an agent using what it was given, and they are different keys.
    if policy.get("match") and (request_vec is not None or matcher == "lexical"):
        hits = match(cur, request, request_vec,
                     policy.get("scope"),
                     int(policy.get("top_k", 3)),
                     float(policy.get("min_score", 0.0)),
                     matcher=matcher, attached=agent["skills"])

    composed_names = set(s["name"] for s in composed)
    new_names = [n for n, _ in hits if n not in composed_names and n not in sticky]

    # --- sticky: the union, never a swap (§5.3) ----------------------------
    # The whole point. `carried` is what an earlier turn matched and this turn
    # did not -- expanded anyway, so instructions stay monotonic within a
    # branch. Without this line an agent told to cite its sources on turn three
    # is silently not told on turn four, and nothing anywhere reports it.
    if policy.get("sticky", True):
        wanted = [n for n in sticky] + new_names
    else:
        wanted = new_names

    # --- the budget: bounded, and what it drops is reported (§5.2) ---------
    budget = int(policy.get("max_chars", 0)) or None
    expanded, dropped, used = [], [], 0
    for skill in load_skills(cur, wanted):
        cost = len(skill["content"])
        if budget is not None and used + cost > budget:
            dropped.append(skill["name"])
            continue
        expanded.append(skill)
        used += cost

    for s in expanded:
        sticky[s["name"]] = s["version"]

    # --- the index: the attached surface, minus what is already expanded ----
    #
    # THIS IS THE LAZY HALF, and what makes attachment cheap. Every attached
    # fragment is advertised by one listing line whether or not its body is
    # here; the body arrives when the turn calls for it. Exactly how a tool is
    # offered -- name and description in the prompt, implementation elsewhere,
    # fetched on demand.
    shown = composed_names | set(s["name"] for s in expanded)
    # Default `bound`, and measured rather than chosen -- twice, in opposite
    # directions. The index is the one term that grows with the fleet
    # (plugins.md §11.3), and it is also where 16 of the 18 behaviour changes a
    # full body produces actually come from (§11.4). Cost said `none`; benefit
    # said `bound`, and benefit won.
    index = []
    if policy.get("index", "bound") != "none":
        # THE ATTACHED SURFACE ONLY. `scope` is deliberately not indexed: it is
        # the population an agent may reach and cannot list, which is exactly
        # what the deferred toolset in `skills_toolset.py` hides behind a
        # search. Indexing it too would put the whole population back in the
        # prompt and leave the deferral with nothing to defer.
        index = [s for s in attached if s["name"] not in shown]

    # --- the prompt ---------------------------------------------------------
    parts = [agent["system_prompt"].rstrip()]
    for s in composed + expanded:
        parts.append(s["content"].rstrip())
    if index:
        parts.append(
            "Further procedures are available. Ask for one by name if you need it:\n"
            + "\n".join(listing_line(s) for s in index))
    prompt = "\n\n".join(p for p in parts if p)

    body_chars = sum(len(s["content"]) for s in composed + expanded)
    index_chars = sum(len(listing_line(s)) + 1 for s in index)
    return prompt, {
        "attached": agent["skills"],
        "composed": [s["name"] for s in composed],
        "matched": [{"skill": n, "score": round(sc, 4)} for n, sc in hits],
        "carried": [n for n in sticky if n not in composed_names
                    and n not in new_names],
        "expanded": [s["name"] for s in expanded],
        "dropped_for_budget": dropped,
        "indexed": len(index),
        "chars": {"prompt": len(prompt), "agent": len(agent["system_prompt"]),
                  "bodies": body_chars, "index": index_chars},
        "tokens_est": round(len(prompt) / CHARS_PER_TOKEN),
        "sticky": sticky,
    }


# ---------------------------------------------------------------- cli

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dsn", default=os.environ.get("P8_DSN"),
                    help="libpq DSN for the database holding agentic.skills")
    ap.add_argument("--env-file", default=os.environ.get("P8_ENV_FILE"),
                    help="file setting the api key variable; never printed")
    ap.add_argument("--api-key-env", dest="api_key_env", default="OPENAI_API_KEY",
                    help="which environment variable holds the key, per credential_ref")
    ap.add_argument("command", choices=["expand", "index"])
    ap.add_argument("agent")
    ap.add_argument("request", nargs="?", default="")
    args = ap.parse_args()

    load_env(args.env_file)
    globals()["API_KEY_ENV"] = args.api_key_env
    import psycopg2
    conn = psycopg2.connect(args.dsn)
    cur = conn.cursor()

    agent = load_agent(cur, args.agent)
    matcher = ((agent.get("context_policy") or {}).get("skills") or {}).get(
        "matcher", "semantic")
    vec = None
    if args.request and matcher != "lexical":
        vec = embed([args.request])[0]
    prompt, acct = expand(cur, agent, vec, request=args.request)

    if args.command == "index":
        print(json.dumps(acct, indent=2))
    else:
        print(prompt)
        print("\n" + "-" * 68)
        print(json.dumps({k: v for k, v in acct.items() if k != "sticky"}, indent=2))
    conn.close()


if __name__ == "__main__":
    main()
