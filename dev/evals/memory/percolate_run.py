"""Percolate 0.2.23 on the same fixture, same questions, same embedder as B1-mem0.

Each fact is written the way Mem0's add() writes one, plus the graph:
  1. the user registers the text     content.register_text, in their own org
  2. the vector is stored            aiq."emb_<model>" (the caller computes it,
                                     as Mem0's fastembed embedder does)
  3. the worker writes the fact      aiq.upsert_graph: subject -relation-> object,
                                     provenance naming the resource, agent, run
  4. valid time                      valid_from = when it was said; a superseding
                                     fact closes the old edge (valid_to)

DREAM=1 (REM-961) takes the supersession from aiq.dream() instead of the
fixture's answer key: lives_in, works_at, manager_is and working_on are declared
single-valued, no edge is closed by hand, and dream runs once after the load.
The systems are then printed as percolate-search-dream and percolate-valid-dream.

Two read paths, printed as separate systems:
  percolate-search  SEARCH (lexical + semantic, RRF) as the user, nothing else
  percolate-valid   the same candidates, kept only if the fact they state held
                    at the question's time (now, unless the question names one)
"""
import json, os, sys
DREAM = os.environ.get("DREAM") == "1"
# EXTRACT=<model> (REM-1309): the facts are not written from the fixture's triples. Each memory is registered into a
# channel whose ingest workflow graph-indexes it with Percolate's own extractor (structure_null) on that model, as an
# upload is, dated from its said_at; then the runner waits for every run. Needs a stack whose worker can call the
# model (LLM_API_KEY), not a bare database. Graphiti extracts from the same text (graphiti_run.py).
EXTRACT = os.environ.get("EXTRACT")
SINGLE_VALUED = {"lives_in", "works_at", "manager_is", "working_on"}
import psycopg
from fastembed import TextEmbedding

DSN = os.environ.get("DSN", "postgresql://p8:p8@localhost:47959/p8")
# ORGLESS=1 registers every memory with no org: the path REM-962 is about,
# where two owners' facts can name one shared entity node.
ORGLESS = os.environ.get("ORGLESS") == "1"
MODEL = "bge-small-en-v1-5"
EMB = f'aiq."emb_{MODEL.replace("-", "_")}"'
fixture = json.load(open(sys.argv[1]))
USERS = {"maya": ("00000000-0000-0000-0000-00000000aaaa", "0000000a-0000-0000-0000-00000000000a"),
         "leo":  ("00000000-0000-0000-0000-00000000bbbb", "0000000b-0000-0000-0000-00000000000b")}
NAMES = {"maya": "Maya Okafor", "leo": "Leo Brandt"}
embedder = TextEmbedding("BAAI/bge-small-en-v1.5")
vec = lambda t: "[" + ",".join(f"{x:.6f}" for x in next(iter(embedder.embed([t])))) + "]"

# A container started a moment ago is still installing the extension at first start: wait for it, up to two minutes.
import time
for _ in range(60):
    try:
        db = psycopg.connect(DSN, autocommit=True)
        if db.execute("select 1 from pg_extension where extname = 'percolate'").fetchone():
            break
        db.close()
    except psycopg.OperationalError:
        pass
    time.sleep(2)
else:
    sys.exit(f"no percolate extension at {DSN} after two minutes")
x = db.execute


def as_user(user):
    sub, org = USERS[user]
    x("reset role")  # claims go before the role switch: set_config is revoked from it
    x("select set_config('request.jwt.claims', %s, false)",
      (json.dumps({"sub": sub, "orgs": [org]}),))
    x("set role authenticated")


def as_operator():
    x("reset role")
    x("reset request.jwt.claims")


SETUP = f"""
set role app_owner;  -- the extension owns what it creates, or it cannot maintain it
insert into rbac.users (id, email) values
  ('{USERS['maya'][0]}','maya@example.com'), ('{USERS['leo'][0]}','leo@example.com')
  on conflict do nothing;
-- one org per person: Mem0's user_id is a filter argument, here it is a tenant
insert into rbac.orgs (id, slug, name) values
  ('{USERS['maya'][1]}','maya','Maya'), ('{USERS['leo'][1]}','leo','Leo') on conflict do nothing;
insert into rbac.org_members (org_id, user_id, role) values
  ('{USERS['maya'][1]}','{USERS['maya'][0]}','member'),
  ('{USERS['leo'][1]}','{USERS['leo'][0]}','member') on conflict do nothing;
-- a fresh core ships no roles: writing needs resources:create from somewhere
insert into rbac.roles (name) values ('member') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action)
  values ('member','resources','create') on conflict do nothing;
insert into rbac.user_roles values ('{USERS['maya'][0]}','member'), ('{USERS['leo'][0]}','member')
  on conflict do nothing;
insert into content.channels (name, kind, org_id, visibility)
  values ('memory','manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
  values ('{MODEL}', 384, null, 'vector_cosine_ops', false,
          'fastembed BAAI/bge-small-en-v1.5, computed by the caller') on conflict (name) do nothing;
select aiq.register_embedding_space('{MODEL}');
select aiq.register_graph_vocabulary('{json.dumps([dict({"relation": r}, **({"single_valued": True} if DREAM and r in SINGLE_VALUED else {})) for r in
    ["lives_in","works_at","manager_is","diet","prefers","working_on","decided",
     "allergic_to","has_pet","goal"]])}');
"""


def load():
    as_operator()
    x(SETUP)
    if EXTRACT:
        x("set role app_owner")
        for stmt in filter(str.strip, EXTRACT_SETUP.split(";")):
            x(stmt, {"m": EXTRACT} if "%(m)s" in stmt else None)
        x("reset role")
    x("reset role")
    edge_of = {}
    for f in sorted(fixture["facts"], key=lambda f: f["said_at"]):
        sub, org = USERS[f["user"]]
        # 1. add, as the user
        as_user(f["user"])
        r = x("select content.register_text(%s, %s, %s, null, null, %s, %s)",
              ("memory-extract" if EXTRACT else "memory", f["id"], json.dumps([{"content": f["text"]}]), None if ORGLESS else org,
               json.dumps({"agent": f["agent"], "run": f["run"], "said_at": f["said_at"],
                           "quote": f["quote"]}))).fetchone()[0]
        rid = r["resource_id"]
        as_operator()
        # 2. the vector, as the worker that embeds would
        (chunk,) = x("select id from content.resource_chunks where resource_id = %s", (rid,)).fetchone()
        x(f"insert into {EMB} (chunk_id, embedding) values (%s, %s)", (chunk, vec(f["text"])))
        if EXTRACT:
            edge_of[f["id"]] = rid
            continue
        # 3. the fact, as the worker that extracts would
        x("set role worker")
        g = x("select aiq.upsert_graph(%s, %s)", (
            json.dumps({"nodes": [{"k": "soft", "n": NAMES[f["user"]]}, {"k": "soft", "n": f["object"]}],
                        "edges": [{"s": 0, "t": 1, "r": f["relation"]}]}),
            json.dumps({"resource_id": rid, "agent": f["agent"], "run_id": f["run"], **({} if ORGLESS else {"org_id": org})}),
        )).fetchone()[0]
        x("reset role")
        assert g["edges_new"] + g["edges_merged"] == 1, g
        (eid,) = x("""select e.id from aiq.edges e, jsonb_array_elements(e.provenance->'sources') s
                       where s->>'resource_id' = %s""", (rid,)).fetchone()
        edge_of[f["id"]] = eid
        # 4. valid time. GAP: upsert_graph cannot state valid_from (it is now()),
        # and nothing closes ONE edge, so both are written as the operator.
        if g["edges_new"]:
            x("update aiq.edges set valid_from = %s where id = %s", (f["said_at"], eid))
        if f["supersedes"] and not DREAM:
            x("update aiq.edges set valid_to = %s where id = %s",
              (f["said_at"], edge_of[f["supersedes"]]))
    if EXTRACT:
        edge_of = extracted(edge_of)
    if DREAM:
        as_operator()
        (receipt,) = x("select aiq.dream()").fetchone()
        print(f"dream: {json.dumps(receipt)}", file=sys.stderr)
    return edge_of


# The upload pipeline's graph branch, as content.install_ingest_workflow(p_graph_index => true) writes it, without
# its parse step: parse reads a file's bytes, and a memory registered as text with its said_at has chunks and no
# file ("resource ... has no file"). An upload can carry no said_at, so the shipped pipeline cannot read a dated
# memory into dated facts; this is the same extractor, windows and lander, started by the channel as an upload is.
EXTRACT_SETUP = """
select aiq.install_structure_null(%(m)s);
select content.install_ingest_workflow(null, 'ingest', 'ingest_file_graph', true, %(m)s);
select workflow.define_yaml(format($y$
name: extract_facts
steps:
%%s  - id: graph
    needs: [extractor_format]
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template:
        queue: http
        rate_key: structure_extraction
        rest: %%s

  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
$y$, aiq.extractor_format_step('structure_null', %(m)s),
     (aiq.extractor_call_at_run('structure_null', %(m)s, '{{item.content}}'))::text));
insert into content.channels (name, kind, org_id, visibility, config)
  values ('memory-extract', 'manual', rbac.shared_org_id(), 'public', '{"ingest_workflow": "extract_facts"}')
  on conflict do nothing;
"""


def extracted(rid_of):
    """Wait for every memory's extraction run, report what each wrote, and close replaced facts if told."""
    import time
    as_operator()
    for _ in range(300):
        (busy,) = x("""select count(*) from workflow.runs where input->>'resource_id' = any(%s)
                         and status not in ('succeeded', 'failed', 'cancelled')""",
                    ([str(r) for r in rid_of.values()],)).fetchone()
        if not busy:
            break
        time.sleep(2)
    (failed,) = x("select count(*) from workflow.runs where input->>'resource_id' = any(%s) and status <> 'succeeded'",
                  ([str(r) for r in rid_of.values()],)).fetchone()
    edges = {}
    for fid, rid in rid_of.items():
        edges[fid] = [r[0] for r in x("""select distinct e.id from aiq.edges e, jsonb_array_elements(e.provenance->'sources') s
                                          where s->>'resource_id' = %s""", (str(rid),)).fetchall()]
        print(f"# added {fid}: {len(edges[fid])} edges", file=sys.stderr)
    print(f"percolate: extracted with {EXTRACT}: {sum(len(v) for v in edges.values())} facts written from "
          f"{len(edges)} memories, {sum(1 for v in edges.values() if not v)} memories with none, {failed} runs not succeeded",
          flush=True)
    if not DREAM:
        said = {f["id"]: f["said_at"] for f in fixture["facts"]}
        n = 0
        for f in fixture["facts"]:
            if f.get("supersedes") and f["supersedes"] in edges:
                for eid in edges[f["supersedes"]]:
                    n += x("""update aiq.edges set valid_to = %s where id = %s
                               and (valid_to is null or valid_to > %s)""", (f["said_at"], eid, f["said_at"])).rowcount
        print(f"percolate: told: {n} edges closed from the answer key", flush=True)
    return edges


CANDIDATES = f"""
select r.external_id, r.id
  from aiq.search('chunks', %(ask)s, %(v)s::vector, '{MODEL}', 50)
       with ordinality h(chunk_id, content, rrf_score, lexical_rank, semantic_rank, key_match, ord)
  join content.resource_chunks c on c.id = h.chunk_id
  join content.resources r on r.id = c.resource_id
 where (%(agent)s::text is null or r.metadata->>'agent' = %(agent)s)
   and (not %(timed)s or exists (
        select 1 from aiq.edges e, jsonb_array_elements(e.provenance->'sources') s
         where s->>'resource_id' = r.id::text
           and aiq.edge_is_current(e.valid_from, e.valid_to, %(at)s::timestamptz)))
 order by h.ord  -- aiq.search's own order, ties broken by id (REM-1312); rrf_score alone left them to the plan
 limit 10
"""


def ask():
    for q in fixture["questions"]:
        as_user(q["user"])
        v = vec(q["ask"])
        for system, timed in (("percolate-search", False), ("percolate-valid", q["kind"] != "change")):
            rows = x(CANDIDATES, {"ask": q["ask"], "v": v, "agent": q.get("agent"),
                                  "timed": timed, "at": q["as_of"] or "now"}).fetchall()
            print(json.dumps({"system": system + ("-dream" if DREAM else ""), "q": q["id"],
                              "ranked": [r[0] for r in rows]}))
    as_operator()


def reach():
    """How many of each person's facts each person can read in the graph."""
    for user in USERS:
        as_user(user)
        row = x("""select count(*) filter (where s.summary = %s), count(*) filter (where s.summary = %s)
                     from aiq.edges e join aiq.nodes s on s.id = e.src_id""",
                (NAMES["maya"], NAMES["leo"])).fetchone()
        print(f"graph reach: {user} reads {row[0]} of Maya's facts and {row[1]} of Leo's", file=sys.stderr)
    as_operator()


if __name__ == "__main__":
    if "--ask-only" not in sys.argv:
        load()
    ask()
    reach()
