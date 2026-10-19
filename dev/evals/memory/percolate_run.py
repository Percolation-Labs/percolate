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

db = psycopg.connect(DSN, autocommit=True)
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
    x("reset role")
    edge_of = {}
    for f in sorted(fixture["facts"], key=lambda f: f["said_at"]):
        sub, org = USERS[f["user"]]
        # 1. add, as the user
        as_user(f["user"])
        r = x("select content.register_text('memory', %s, %s, null, null, %s, %s)",
              (f["id"], json.dumps([{"content": f["text"]}]), None if ORGLESS else org,
               json.dumps({"agent": f["agent"], "run": f["run"], "said_at": f["said_at"],
                           "quote": f["quote"]}))).fetchone()[0]
        rid = r["resource_id"]
        as_operator()
        # 2. the vector, as the worker that embeds would
        (chunk,) = x("select id from content.resource_chunks where resource_id = %s", (rid,)).fetchone()
        x(f"insert into {EMB} (chunk_id, embedding) values (%s, %s)", (chunk, vec(f["text"])))
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
    if DREAM:
        as_operator()
        (receipt,) = x("select aiq.dream()").fetchone()
        print(f"dream: {json.dumps(receipt)}", file=sys.stderr)
    return edge_of


CANDIDATES = f"""
select r.external_id, r.id
  from aiq.search('chunks', %(ask)s, %(v)s::vector, '{MODEL}', 50) h
  join content.resource_chunks c on c.id = h.chunk_id
  join content.resources r on r.id = c.resource_id
 where (%(agent)s::text is null or r.metadata->>'agent' = %(agent)s)
   and (not %(timed)s or exists (
        select 1 from aiq.edges e, jsonb_array_elements(e.provenance->'sources') s
         where s->>'resource_id' = r.id::text
           and aiq.edge_is_current(e.valid_from, e.valid_to, %(at)s::timestamptz)))
 order by h.rrf_score desc
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
