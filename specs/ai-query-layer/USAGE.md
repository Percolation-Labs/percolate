# Using the query layer — SQL, REST, and pgAdmin

Every example below was run against a live PG19 beta3 instance with the real
`specs/` SQL loaded. Output shown is real output, not illustrative.

---

## Connecting

### Which stack, and therefore which port

Two compose files exist and they bind different ports on purpose, so a
newcomer's stack and a contributor's can run side by side with no flags. Every
example on this page was run against the **dev** stack; every URL on it is
written with the **published** port, which is what the rest of the docs type.
Read across this table once and the difference never comes up again:

| | Published (`get-percolate/compose`) | Dev (`dev/docker-compose.yml`) |
|---|---|---|
| Postgres | `5432`, database `percolate` | `5610`, database `p8dev` |
| PostgREST | `3000` | `5611` |
| Content Server | `8081` | `5613` |
| S3 store (RustFS, service `minio`) | `9000` / `9001` | `5614` / `5615` |

Container-internal URLs are the same on both — inside either compose network
PostgREST is still `:3000` — so only what you type from the host changes.

### pgAdmin (or any SQL client)

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `5610` (dev) or `5432` (published) |
| Database | `p8dev` (dev) or `percolate` (published) |
| Username | `p8` |
| Password | `p8` |

**Then do one thing before you query anything**, or your results will be
misleading:

```sql
-- p8 is a SUPERUSER. Superusers bypass RLS unconditionally, so querying as p8
-- shows you EVERY tenant's rows and hides every access bug. Switch to a real
-- role first.
set role authenticated;

-- RLS reads identity from a request-scoped GUC that PostgREST normally sets
-- per request. In a SQL client you set it yourself, and it must be inside a
-- transaction (set_config's third argument = "local").
begin;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000009",
    "orgs":["11111111-1111-1111-1111-111111111111"]}', true);

select * from aiq.query('LOOKUP "acme"');

commit;
```

Without the `set_config`, `current_user_id()` and `current_org_ids()` return
nothing and you will see only globally-shared rows (`org_id =
rbac.shared_org_id()`) — which
looks like "the data is missing" rather than "you are anonymous".

To inspect data as an administrator instead, use `set role app_owner;` — it
owns the tables and bypasses RLS by design (that is the trusted path the
`SECURITY DEFINER` functions run on).

### Making this less tedious

**Option 1 — session-scoped claims, no extra code.** `set_config`'s third
argument is "transaction-local"; pass `false` and the claims persist for the
whole session, so you set them once per pgAdmin tab and drop the
`BEGIN`/`COMMIT` entirely:

```sql
set role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000009",
    "orgs":["11111111-1111-1111-1111-111111111111"]}', false);

select * from aiq.lookup('acme');          -- scoped
select * from aiq.query('GRAPH "acme"');   -- still scoped
```

**Option 2 — `dev-helpers.sql`.** Optional, **not part of the production load
order**, and every function in it refuses to run unless `app.dev_mode` is
`'on'` (`alter database <db> set app.dev_mode = 'on'`). Two lines and you are
scoped:

```sql
select aiq.dev_assume_org('11111111-1111-1111-1111-111111111111');  -- as owner
set role authenticated;                                             -- then drop privileges

select * from aiq.lookup('acme');
```

Also `aiq.dev_assume(sub, orgs[])` for a specific user, and `aiq.dev_anon()`
to check what an unauthenticated caller sees — the case most easily forgotten,
and where a missing policy shows up.

**What these do not do: they set an identity, they never disable RLS.** You
still see exactly what that identity is entitled to see. A helper that relaxed
the rules "just for testing" is deliberately absent — testing against relaxed
rules tells you nothing about the rules you ship. Order matters: call the
helper as the owner, *then* `set role`, because impersonation is not granted
to `authenticated` (letting an API caller reassign its own identity is the
exact escalation shape this collection keeps fixing).

### `whoami()` — when results look wrong

**Also `dev-helpers.sql`**, like the two above — this section used to sit under
its own heading with no such note, so a reader who took Option 1 and scrolled
here got `function aiq.whoami() does not exist`. Unlike `dev_assume*` it needs
no `app.dev_mode`, and it is safe to install anywhere, because it reveals only
who the caller already is.

An empty result from a superuser session and an empty result from a wrong-org
session look identical. This tells you which you are in:

```sql
select * from aiq.whoami();
```

```
    db_role    | is_superuser | rls_applies |               user_id                |                  orgs
---------------+--------------+-------------+--------------------------------------+------------------------
 authenticated | f            | t           | 122efda4-7be3-42b1-987d-504182271784 | {11111111-…}
```

`rls_applies = f` means you are a superuser and **not being filtered at all** —
the single most misleading state to query from, and the reason `set role` comes
first in every example above.

### REST (PostgREST)

`http://localhost:3000`, or `:5611` on the dev stack — see the port table
above. Every request needs a bearer JWT, signed HS256 with the same secret
PostgREST is configured with. The claims that matter:

```json
{"role":"authenticated","sub":"<user-uuid>","orgs":["<org-uuid>"],"exp":<unix-ts>}
```

`sub` becomes `rbac.current_user_id()`; `orgs` *narrows*
`rbac.current_org_ids()`, which reads `rbac.org_members` — so a `sub` naming a
user who belongs to no org is an org-less caller however many orgs the token
lists, and the claim can only ever intersect what the membership table already
grants. (It used to BE the membership, via `aiq.current_org_ids()`, which is
gone.)
Mint it with whatever you already use — no tool ships here, because a JWT
minter is not something this collection needs to own:

```python
import base64, hmac, hashlib, json, time
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h, p = {"alg":"HS256","typ":"JWT"}, {"role":"authenticated","sub":SUB,"orgs":[ORG],"exp":int(time.time())+3600}
si = f"{b(json.dumps(h).encode())}.{b(json.dumps(p).encode())}"
print(f"{si}.{b(hmac.new(SECRET.encode(), si.encode(), hashlib.sha256).digest())}")
```

**For testing policies, skip JWTs entirely.** What is worth verifying is that
*your* RLS behaves, not that PostgREST validates tokens — and that is SQL-level
(`set_config('request.jwt.claims', ...)`, or `aiq.dev_assume_org()`). The SQL
tests in `dev/tests/` do exactly that and mint nothing.

---

## The grammar, in full

```
[FUZZY] LOOKUP "<key>" [, "<key>" ...]                    [LIMIT n]
        GRAPH  "<key>"  [DEPTH n] [TYPE <rel>]            [LIMIT n]
        PATH   "<key>", "<key>" [, "<key>" ...]
                        [DEPTH n] [TYPE <rel>]            [LIMIT n]
        RELEVANCE "<key>" [, "<key>" ...]  [TYPE <rel>]   [LIMIT n]
        TEXT   "<text>" FROM <source>                     [LIMIT n]
        SEMANTIC "<text>" FROM <source> [USING <model>]   [LIMIT n]
        SEARCH   "<text>" FROM <source> [USING <model>]   [LIMIT n]
        LAKE FROM <dataset> [, <dataset> ...] <select statement>
        SCHEMA ["<facet>"] [FROM <name>]
        <any ordinary SQL statement>
```

Ten modes, `SQL` included, and `p8_query_grammar()` is what settles the count
— it emits the table above, so this block is a transcription of the parser
rather than a second copy of the grammar. Quotes are interchangeable (`"…"` and
`'…'`), commas in a list are optional, and mode keywords are case-insensitive.

Three spellings were retired, and each one's error names its replacement
rather than saying only "unknown mode":

| Was | Now | Why |
|---|---|---|
| `HYBRID "…"` | `SEARCH "…"` | `HYBRID` named the implementation — fusing two rankers. Someone looking for something asks to **search**; that it fuses lexical and semantic rank underneath is our business, not theirs. |
| `LOOKUP "…" FUZZY` | `FUZZY LOOKUP "…"` | It reads as an adjective on the verb, the way it is spoken. A modifier that changes what a query *means* belongs before the thing it modifies, not appended where it scans as an afterthought. |
| `SQL select …` | `select …` | Ceremony on the one mode that needed no help identifying itself. |

`FUZZY` applies only to `LOOKUP` — it is trigram matching over `node_keys`, and
`SEMANTIC` and `SEARCH` are already approximate by construction. Written
anywhere else it is refused rather than ignored, because silently dropping a
modifier someone wrote is how a query quietly means something other than what
it says. The same rule now covers `DEPTH` and `TYPE`, which describe a
traversal and are refused outside `GRAPH` — `LOOKUP "acme" DEPTH 3` used to
parse and silently do a depth-1 lookup — and `LIMIT`, which is refused on
`SCHEMA` because a schema document is not a result set.

`SCHEMA` is the only mode whose argument is optional, and the only one
answerable before you know anything: bare `SCHEMA` returns the index of what
you may ask about. Every other mode requires you to already hold a key, a
source or a relation.

Which is why `SCHEMA "graph"` lists **`sample_keys`** — up to three real keys
per entity type, scoped to what the caller may see. Without them the discovery
path dead-ends one step short: the facet says an `fx_pair` entity type exists
and a `same_band` relation runs between them, and leaves you to invent the name
of an instance. An agent given exactly that read both facets correctly, then
tried `sterling`, `gbp`, `gbp_usd` and `gbpusd` in four calls and gave up. The
keys were `usd/gbp`. A naming convention is the one thing that cannot be
reasoned out, and three examples end the question.

When a name still does not resolve, `FUZZY LOOKUP` is the intended next step
rather than another spelling: `FUZZY LOOKUP "gbp"` returns `usd/gbp`.

## One endpoint, every mode

The whole dialect goes through a single RPC, `POST /rpc/query`. The response
always carries the parsed `plan` alongside `rows`, so you can see how your
string was understood — a misparse is otherwise indistinguishable from an
empty result.

```bash
TOKEN=<an HS256 token with the claims above>

curl -s -X POST http://localhost:3000/rpc/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_query":"LOOKUP \"acme\""}'
```

```json
{
  "mode": "LOOKUP",
  "plan": {"ok": true, "arg": "acme", "args": ["acme"], "mode": "LOOKUP",
           "depth": 1, "fuzzy": false, "limit": 20, "model": null,
           "source": null, "relation": null},
  "rows": [{"key": "acme", "score": 1, "node_id": "484e50ce-…",
            "entity_id": "1df1f6d5-…", "match_kind": "canonical",
            "entity_type": "company"}]
}
```

The SQL equivalent of every REST call below is the same string passed to
`aiq.query(...)`, so only the REST form is shown where they differ trivially.

---

## LOOKUP — find a node by name

```sql
select * from aiq.lookup('acme');                 -- exact canonical
select * from aiq.lookup('  ACME  ');             -- normalised (lower/trim)
select * from aiq.lookup('acme robotics');        -- alias
select * from aiq.lookup('Acme Robotcs', true);   -- FUZZY (opt-in)
select * from aiq.lookup_many(array['acme','nadler']);  -- a list, one call
```

```
 entity_type |      key      | match_kind | score
-------------+---------------+------------+-------
 company     | acme robotics | fuzzy      |  0.69
 event       | acme-recall   | fuzzy      |  0.32
```

Fuzzy is **off by default** — a misspelling returns zero rows unless you ask
for it, so a typo never silently becomes a different answer. Matching is over
`node_keys` only, never document text (that is `TEXT`, below).

### LOOKUP takes a list

Resolving several names is the normal case: an agent rarely holds exactly one
entity. Five names is one round trip and one plan, not five.

```sql
select * from aiq.query('LOOKUP "acme", "nadler", "does-not-exist"');
```

```
 input_key |  key   | match_kind | score
-----------+--------+------------+-------
 acme      | acme   | canonical  |     1
 nadler    | nadler | canonical  |     1
```

Two things to notice. **`input_key` comes back with each row**, so you can tell
which of the names produced it. And **`unresolved` names the ones that produced
nothing**, so "which of these did you not find" is handed over rather than left
as a set difference on the input:

```json
{"mode": "LOOKUP",
 "rows": [{"input_key": "acme",   "key": "acme",   "match_kind": "canonical"},
          {"input_key": "nadler", "key": "nadler", "match_kind": "canonical"}],
 "unresolved": ["does-not-exist"]}
```

This paragraph used to claim a miss was "absent rather than returned as an
empty row", and the function had been changed to do the opposite: `lookup_many`
LEFT JOINs, so a miss comes back as a **row of nulls** with `input_key` echoed.
Each side carried a comment explaining why it was right, and neither knew about
the other. Through this JSON envelope the LEFT JOIN is the worse of the two —
`rows` is non-empty, and a miss is indistinguishable from a hit to anything
that does not inspect the fields. A model asked about sterling read
`rows: [{…}]`, concluded it had found the node, and answered as though it had.

Both intents are kept: `aiq.lookup_many` still LEFT JOINs, for SQL callers who
want one result set they can filter, and the dialect splits them — so `rows`
holds only matches and an empty result is empty.

`unresolved` appears on LOOKUP responses only. Absent means "this mode does not
resolve names"; present and empty means "every name you gave me resolved".

And **each key resolves independently**, running the whole canonical → alias →
fuzzy cascade on its own. Resolving them as one set would let one key's exact
hit suppress another key's fuzzy match, which would make a list mean something
different from the same keys asked one at a time:

```sql
select input_key, key, round(score::numeric,2) from aiq.lookup_many(
    array['acme','nadlr'], true);
--  acme  | acme   | 1.00     <- canonical
--  nadlr | nadler | 0.44     <- fuzzy, in the same call
```

**Quoting: `"…"` and `'…'` are interchangeable.** A key with a space or a slash
must be quoted, and which quote is free is decided by whatever P8QL is embedded
in — SQL takes the single (`aiq.query('LOOKUP …')`), YAML takes the double
(`args: ["LOOKUP …"]`). Both characters quote, so the host language never
forces the query to be rewritten:

```sql
select * from aiq.query('LOOKUP "R7 Notice"');    -- inside YAML, use these
select * from aiq.query($$LOOKUP 'R7 Notice'$$);  -- inside SQL, use these
```

Accepting only the double quote was a real bug, and its bad half was silent:
`LOOKUP 'R7 Notice'` failed with `unexpected token 'Notice''`, but `LOOKUP 'R7'`
*succeeded* with the key `'R7'`, quotes and all — a lookup that matches nothing
and reports no error.

```bash
-d '{"p_query":"FUZZY LOOKUP \"Acme Robotcs\" LIMIT 5"}'
```

### The two halves of LOOKUP do not cost the same

Exact and normalised lookup is an index probe and stays one: **0.02 ms at
200000 keys**, flat, because `node_keys` carries a btree on `key`.

`FUZZY` is not that, and its cost is set by **how many keys the trigram
operator matches**, not by how many rows you asked for. The query computes a
similarity for every match and dedupes by node before applying `LIMIT`, so
nothing bounds the work but the data. On 200000 keys built from a deliberately
narrow vocabulary — where a probe matches 20000 of them — that is **97 ms p50,
312 ms p95**, and the planner leaves the GIN trigram index alone because a 10%
match rate does not earn it.

How likely you are to see that depends on your naming, not your size: keys
drawn from a small set of repeated words are similar to each other by
construction, and distinctive keys match far fewer. If `FUZZY` is slow on your
graph, that is the number to look at first —

```sql
select count(*) from aiq.node_keys where key % 'the probe you used';
select set_limit(0.7);   -- default is 0.3; on the fixture above this cut
                         -- 20000 matches to 2
```

This is measured and **not fixed**: bounding the candidate set would change
which rows rank, and that is a change to what `FUZZY` means rather than to what
it costs.

---

## GRAPH — walk relationships

Every result below is real output from the committed sample graph
(`dev/init/04-graph-sample.sql`), which a `docker compose up` installs. It used
to be output from a fixture that lived only in a psql session, which is a
worked example nobody can re-run.

```sql
-- depth 1, both directions, via native SQL/PGQ
select entity_type, key, summary, relation, weight, direction
from aiq.graph_neighbors((select node_id from aiq.lookup('ACME')));
```

```
 entity_type |       key       |     summary     |   relation    | weight | direction
-------------+-----------------+-----------------+---------------+--------+-----------
 company     | ndlr            | Nadler Systems  | competes_with |   0.9  | out
 company     | brls            | Borealis Mining | competes_with |   0.35 | in
 company     | cygl            | Cygnus Labs     | parent_of     |   0.95 | in
 company     | hlfr            | Helios Freight  | parent_of     |   0.95 | in
 person      | dana whitfield  | Dana Whitfield  | employs       |   1    | in
 event       | acme q3 results | Acme Q3 results | mentioned_in  |   1    | in
```

Only `competes_with`, `subsidiary_of`, `works_at` and `mentions` are stored.
`parent_of`, `employs` and `mentioned_in` are **inverse labels resolved from
the relation catalogue at read time** — no inverse edge is ever written, and
reverse questions are served by the `dst_id` index.

Those labels are usable as filters too: `TYPE parent_of` and
`TYPE subsidiary_of` name the same two edges from Acme's point of view. They
did not, and that was a round-trip bug rather than a missing convenience — the
read path displayed `parent_of` and the query layer then refused it, so a
result could not be fed back into the next query. Every row also carries a
`key`, so a walk's output is nameable rather than a column of uuids.

```bash
-d '{"p_query":"GRAPH \"ACME\" DEPTH 1"}'
-d '{"p_query":"GRAPH \"ACME\" TYPE competes_with"}'
-d '{"p_query":"GRAPH \"ACME\" DEPTH 2"}'
```

The dialect answers with the node it actually walked:

```json
{"mode": "GRAPH",
 "plan": {"ok": true, "arg": "ACME", "mode": "GRAPH", "depth": 1},
 "seed": {"key": "acme", "node_id": "a1e74f69-...",
          "entity_type": "company", "match_kind": "canonical"},
 "rows": [...]}
```

`seed` is not decoration. The seed key is resolved **exactly** — canonical,
then short, then alias, never trigram — and until it was, `GRAPH` resolved
fuzzily, always, and took whichever node came back first. A walk of somebody
else's neighbourhood was reported as if it were yours, and the answer named
neither the node walked nor the fact that a guess had been made. What happens
now when a seed does not resolve exactly:

```json
// GRAPH "ACMEE" -- a typo resolves to nothing, and says what it nearly matched
{"rows": [], "error": "no node matches key 'ACMEE'",
 "did_you_mean": [{"key": "acme", "entity_type": "company", "score": 0.66}]}

// GRAPH "borealis" -- a short key naming two nodes is refused, not guessed
{"rows": [], "error": "'borealis' names 2 nodes -- name the one you mean by its canonical key",
 "candidates": [{"key": "borealis", "entity_type": "event",   "match_kind": "short"},
                {"key": "borealis", "entity_type": "company", "match_kind": "short"}]}
```

And what it refuses outright rather than accepting and ignoring — the same rule
`USING` has always been held to, applied to three more constructs that were
being quietly dropped or reinterpreted:

| Written | Answer |
|---|---|
| `GRAPH "ACME" FROM chunks` | `FROM` names a corpus; a walk starts at a node |
| `GRAPH "ACME" DEPTH 0` | `DEPTH must be at least 1` — it used to be served a depth-1 walk |
| `GRAPH "ACME" DEPTH 1000` | above the dialect's ceiling of 5; call `aiq.graph_walk()` directly for a deliberate deep walk |
| `GRAPH "ACME" TYPE not_a_relation` | no such relation in the catalogue — an empty result is indistinguishable from "nothing is related" |

Depth ≥ 2 falls back to `WITH RECURSIVE` — PG19 rejects quantified path
patterns. Results are one row per node at its **shortest** depth, ordered by
depth and then by `path_weight`, the product of the edge weights along the
path:

```sql
select key, entity_type, depth, path_weight, path_relations
from aiq.graph_walk((select node_id from aiq.lookup('ACME')), 2);
```

```
       key       | entity_type | depth | path_weight |       path_relations
-----------------+-------------+-------+-------------+------------------------------
 acme q3 results | event       |     1 |        1    | {mentions}
 dana whitfield  | person      |     1 |        1    | {works_at}
 cygl            | company     |     1 |        0.95 | {subsidiary_of}
 hlfr            | company     |     1 |        0.95 | {subsidiary_of}
 ndlr            | company     |     1 |        0.9  | {competes_with}
 brls            | company     |     1 |        0.35 | {competes_with}
 marcus oyelaran | person      |     2 |        0.9  | {competes_with,works_at}
 mrdn            | company     |     2 |        0.57 | {subsidiary_of,partners_with}
 borealis strike | event       |     2 |        0.35 | {competes_with,mentions}
 priya raman     | person      |     2 |        0.35 | {competes_with,works_at}
```

`path_weight` is where the ingestion pipeline's coherence score arrives at the
read path (`brief.md` §3.6): Borealis is one hop away on a single
uncorroborated blog claim (0.35) and ranks below Cygnus, one hop away on a
registry filing (0.95). Meridian, reachable at depth 2 by two routes, is
0.95 × 0.60 and appears once, at its shortest depth. Because the result is
ordered, `LIMIT` truncates the far, weak end — it previously ordered by node
uuid, so a capped walk dropped whatever the uuids happened to drop.

---

## PATH — how are these connected?

`GRAPH` answers "what is next to this". `PATH` answers a question a depth cap
cannot phrase: *how* two things are joined, and by what. Output below is real,
from the same sample graph.

```sql
select * from aiq.query('PATH "acme", "marcus oyelaran" LIMIT 3');
```

`rows` carries one entry per route, cheapest first, each with its `cost`, its
`hops`, the `nodes` it passed through and the `path` edges that joined them.
The edges are uuid-keyed because that is what the graph stores; resolving them
back to names is one join, and worth showing because it is what makes the
answer readable:

```sql
select r.cost, r.hops,
       (select string_agg(k.key, ' -> ' order by o.ord)
        from jsonb_array_elements_text(r.nodes) with ordinality o(nid, ord)
        join aiq.node_keys k on k.node_id = o.nid::uuid and k.kind = 'canonical')
       as route
from jsonb_to_recordset(aiq.query('PATH "acme", "marcus oyelaran" LIMIT 3')->'rows')
     as r(cost numeric, hops int, nodes jsonb);
```

```
  cost  | hops |                            route
--------+------+--------------------------------------------------------------
 2.1054 |    2 | acme -> ndlr -> marcus oyelaran
 2.3567 |    2 | acme -> dana whitfield -> marcus oyelaran
 3.3567 |    3 | acme -> acme q3 results -> dana whitfield -> marcus oyelaran
```

Each `path` edge carries `reversed`, because a route may traverse an edge
against its stored direction: the first route runs `acme -competes_with-> ndlr`
forwards and `marcus oyelaran -works_at-> ndlr` backwards. Direction is
preserved in the answer rather than flattened, so a route can be read as a
sentence and not just as a distance.

**Three or more keys is the same question generalised, not a second mode.**
Two keys give the `LIMIT` best routes between them; three or more give the
smallest subgraph joining all of them, as one `edges` array rather than as
routes:

```sql
select * from aiq.query('PATH "acme", "brls", "marcus oyelaran"');
```

**An honest empty answer is the interesting case.** `nwnd` and `estg` are a
disconnected component in the sample graph on purpose, so:

```sql
select * from aiq.query('PATH "acme", "nwnd" LIMIT 3');
-- {"mode": "PATH", "rows": [], "exhausted": false, "unresolved": []}
```

`rows: []` with `exhausted: false` means *there is no route*. `exhausted: true`
would mean the search hit its budget before it could say — a different answer,
and the reason the flag is on the envelope rather than inferred from an empty
result.

`PATH` honours `valid_to`, which is the one read path that does: `p_as_of` on
`aiq.graph_paths()` walks the graph as it stood at a past instant.

---

## RELEVANCE — rank what is most related

The one mode that is not a walk. `GRAPH` returns a *frontier* — everything
within n hops, unordered beyond depth. `RELEVANCE` returns an *order*:
personalised PageRank by local push in the `pgrx` extension, over a cached
adjacency snapshot.

```sql
select * from aiq.query('RELEVANCE "acme" LIMIT 5');
```

```json
{"mode": "RELEVANCE",
 "rows": [
   {"key": "acme",            "entity_type": "company", "summary": "Acme Robotics",   "score": 0.3369},
   {"key": "dana whitfield",  "entity_type": "person",  "summary": "Dana Whitfield",  "score": 0.1143},
   {"key": "acme q3 results", "entity_type": "event",   "summary": "Acme Q3 results", "score": 0.0916},
   {"key": "ndlr",            "entity_type": "company", "summary": "Nadler Systems",  "score": 0.0900},
   {"key": "cygl",            "entity_type": "company", "summary": "Cygnus Labs",     "score": 0.0733}],
 "exhausted": false, "unresolved": []}
```

Rows carry `key` and `summary`, not just uuids, so unlike `PATH` the answer is
readable without a join.

**It takes a list, because relatedness to a *set* is a different question** —
and it is the question an agent holding several entities actually has. The SQL
form is `aiq.related()`:

```sql
select key, entity_type, summary, round(score::numeric, 4) as score
from aiq.related(array['acme', 'brls'], p_limit => 5);
```

```
       key       | entity_type |     summary     | score
-----------------+-------------+-----------------+--------
 acme            | company     | Acme Robotics   | 0.2333
 brls            | company     | Borealis Mining | 0.2123
 ndlr            | company     | Nadler Systems  | 0.0945
 dana whitfield  | person      | Dana Whitfield  | 0.0841
 acme q3 results | event       | Acme Q3 results | 0.0650
```

`ndlr` is third here and third against neither seed alone — fourth from `acme`,
fifth from `brls`, behind each seed's private neighbours (`dana whitfield` for
one, `priya raman` and `borealis strike` for the other). It rises because it is
the only non-seed node *both* seeds reach, and the private neighbours split the
rest of the mass between them. That is what a two-seed ranking is for, and it
is not something two single-seed queries and a merge can reconstruct: the
scores come from one push over both seeds, not from adding two.

**Two things to know before using it.**

It is the only *budgeted* mode, so every answer carries `exhausted` on its
envelope — `true` means the push ran out of budget and the order is partial,
not that nothing was related. Treating a budgeted answer as a complete one is
the failure this flag exists to prevent.

It also **ships switched off** (`graph-algorithms.md` §11) — present, inert,
and openable in one call, rather than absent:

```sql
select aiq.graph_algorithms_available();       -- is the compiled half here?
select aiq.enable_graph_algorithms('authenticated', true);
```

On a stack still running a published image that predates the compiled
algorithms, `graph_algorithms_available()` returns false and the mode says so
rather than returning an empty ranking.

---

## TEXT — lexical search over content

```sql
select * from aiq.lexical('chunks', 'R7 arm');
```

```
                        content                         | score
--------------------------------------------------------+--------
 The R7 robotic arm may fail under sustained load; unit | 0.0985
```

This is the mode that exists because **`LOOKUP` and `FUZZY LOOKUP` both return zero
for `R7`** — they search keys, and chunks are not nodes. Rare exact tokens
(part numbers, tickers, error codes) are where embeddings are weakest.

Native `tsvector`/`ts_rank`, **not BM25** (`pg_search` does not build on PG19).

```bash
-d '{"p_query":"TEXT \"R7 arm\" FROM chunks"}'
```

---

## SEMANTIC — meaning-based search

The dialect carries the **text**; the caller supplies the **vector**, because
embedding generation is an external model call. `USING <model>` picks the
embedding space, and `FROM <src>` picks the corpus — **both are load-bearing
and neither is decoration.**

That is the API. It is not what a *workflow* author writes: in YAML,
`p8ql: 'SEMANTIC "…" FROM chunks'` compiles to an embed task and this call,
with the model resolved from `aiq.embedding_models` and written into the query
so the vector and the space cannot come from different models: a vector query
is two tasks, and the author writes one.
The two-argument entry point below is what that compiles *to*, and it stays the
only way a vector reaches the database.

```sql
-- source first, exactly like aiq.lexical: the corpus is not optional
select * from aiq.semantic_in('chunks', '[1,0,0,0]'::vector, 'demo-quad-a', 3);
```

```
              chunk_id                | distance |    model
--------------------------------------+----------+-------------
 33330000-0000-0000-0000-000000000001 |    0.000 | demo-quad-a
 33330000-0000-0000-0000-000000000002 |    0.200 | demo-quad-a
 33330000-0000-0000-0000-000000000004 |    0.400 | demo-quad-a
```

Real output from the committed corpus in `dev/init/05-corpus-sample.sql`, whose
vectors are four-dimension literals rather than model output — so the ordering
is arithmetic you can check rather than a property of whichever embedding
server was running.

**`FROM` scopes the search, and that is a security property, not a
convenience.** An embedding space is keyed by *model*, so it holds every
registered corpus at once and has no policy of its own; `semantic_in` joins it
to the corpus you name, which restricts the search *and* puts that consumer's
row policies in the path. The parser has always required `FROM` on SEMANTIC —
the dispatch used to drop it and search everything, so a caller holding one
tenant's claim received chunk ids and cosine distances for another tenant's
content. Passing no corpus is now refused rather than defaulted.

**Two models of the same size are two different spaces.** The sample registers
`demo-quad-a` and `demo-quad-b`, both four-dimensional, over the same six
chunks. The identical probe `[1,0,0,0]` returns chunk `…0001` first in one and
chunk `…0003` first in the other. Nothing about a vector says which space it
belongs to, and no dimension check can catch a caller naming the wrong model —
which is why the space is identified by the model and never by the dimension.

```bash
curl -s -X POST http://localhost:3000/rpc/query \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"p_query":"SEMANTIC \"is this product dangerous?\" FROM chunks",
       "p_embedding":"[0.02,-0.13, … 768 floats … ]"}'
```

Passing a vector of the wrong width is caught with a message naming both
sides, rather than pgvector's bare "expected N dimensions":

```
query vector has 1536 dimensions but model nomic-embed-text expects 768
  -- embedded with the wrong model?
```

### A narrow tenant still gets a full page

The join that makes `FROM` a security property is also the thing that used to
empty the answer, and only above fixture scale. An HNSW scan yields a bounded
candidate set — `hnsw.ef_search`, 40 rows by default — and is then exhausted;
the tenant filter runs *after* it. So a caller who can read a small share of a
large corpus had every candidate removed by their own policy and received
nothing:

| the caller can read | asked for | got, before | got, now |
|---|---|---|---|
| 1004 of 200004 chunks | `LIMIT 10` | 0 | 10 |
| 1004 of 200004 chunks | `LIMIT 50` | 0 | 50 |
| 1004 of 200004 chunks | `LIMIT 200` | 0 | ~107 |
| 198000 of 200004 chunks | `LIMIT 10` | 10 | 10 |

Raising `LIMIT` did not help, which is the part that defeats the obvious
workaround: `LIMIT` bounds the *answer*, not the index scan. `SEMANTIC` now
resumes the scan instead of stopping, so the guarantee is that **you get as
many rows as you asked for whenever that many exist and you may read them.**

It costs nothing on the common path — 0.86 ms p50 against 0.94 ms, for a caller
who can see most of the corpus — and about 29 ms against 1.5 ms for a caller who
can see 0.5% of it. That is a deliberate trade: a right answer in 29 ms is worth
more than an empty one in 1.5 ms.

The residue is `hnsw.max_scan_tuples`, 20000 by default, which bounds the
resumed scan — and it is the fourth row above: asking for 200 returns about a
hundred of the 1004 that exist, because 20000 index tuples at 0.5% selectivity
contain about that many the caller may read. (The exact figure moves with the
corpus — 106 and 107 on two builds of the same fixture — so it is a ceiling to
size for, not a constant to assert.) A tenant narrow enough relative to the
corpus still gets a **short** page. That is a bounded best effort under a named
ceiling rather than silence, and it is the honest limit of this approach: if
your tenants are that narrow, raise it.

```sql
set hnsw.max_scan_tuples = 100000;
```

`dev/tests/query/13-retrieval-at-scale.sql` pins all of this, including a
control that fails if the trap ever stops being reproducible on its fixture.

**Building the index needs shared memory that a container does not have by
default.** Docker gives `/dev/shm` 64 MB, Postgres gives `maintenance_work_mem`
64 MB, and pgvector sizes a parallel HNSW build from the second — so the two
defaults collide and the build dies with `could not resize shared memory
segment`. `dev/docker-compose.yml` sets it now; a
stack you assemble yourself needs `shm_size: 1gb` or the equivalent.

---

## SEARCH — both, fused

```bash
-d '{"p_query":"SEARCH \"R7 arm\" FROM chunks LIMIT 3",
     "p_embedding":"[…768 floats…]"}'
```

```
 rrf_score | lexical_rank | semantic_rank | content
-----------+--------------+---------------+-----------------------------------
   0.03279 |            1 |             1 | The R7 robotic arm may fail…
   0.01613 |         null |             2 | Quarterly revenue rose 18%…
   0.01587 |         null |             3 | Operating margin expanded…
```

Reciprocal rank fusion, not score blending: `ts_rank` and cosine distance share
neither scale nor direction. `null` in a rank column means that signal did not
match at all — the R7 chunk wins because **both** ranked it first.

---

## SCHEMA — what this database *is*

Every other mode needs you to already know something. `SCHEMA` is the one an
agent can write on arrival.

```sql
select aiq.schema();                          -- the index: which facets exist
select aiq.schema('workflow');                -- one facet
select aiq.schema('sql', 'resource_chunks');  -- narrowed to one relation
```

```
SCHEMA                            -- index
SCHEMA "workflow"
SCHEMA "sql" FROM resource_chunks
```

Four facets ship:

| Facet | What it answers |
|---|---|
| `p8ql` | Every mode and its syntax, plus the sources you may name in `FROM` and the models in `USING`. The grammar is emitted by the parser itself. |
| `workflow` | Enough to author a workflow unaided: the legal step kinds, the allow-listed functions a `sql:` step may call with their real signatures, the queues and agents a step may route to, and worked YAML. |
| `sql` | Tables, views, columns and constraints **your role** can `SELECT`, and whether row-level security applies to each. |
| `graph` | Registered entity types and the enforced edge catalogue — which relations exist, between which types, and what they mean. |

### Three things it does that documentation cannot

**The derived half cannot drift.** `step_kinds` is read off the engine's own
`CHECK` constraint, not listed — so when `matrix` shipped, this document
gained it with no edit. `step_functions` is the allow-list itself, so an agent
authoring a step reads the same row the executor will look the function up in.
Each facet splits its answer into `derived` (from the catalog) and `declared`
(from the Rust crate that implements it), so you can see which half could go
stale.

**Examples are run, not trusted.** The example corpus is a table, and every
read feeds each entry back through the real parser or the real compiler:

```json
{"label": "matrix-fanout", "verified": false,
 "error": "step 'fan' must have exactly one of p8ql/sql/rest/embed/agent/work, found none"}
```

That is not a broken example — it is a correct one on a deployment whose
compiled extension predates `matrix`. The document is telling you your `.so`
is stale. `verified` is three-valued: `true`/`false` is a claim about the
example, `null` means this deployment cannot check.

**The version is a hash, not a number somebody bumps.**

```sql
select * from aiq.capture_schema_revisions();   -- records what changed
select * from aiq.schema_drift();               -- read-only: what has moved since
```

Register a step function and the `workflow` facet's hash moves; a read then
reports `"captured": false` rather than serving an uncaptured document as if
it were versioned, and `capture` appends revision *n+1* rather than
overwriting. Capturing again with nothing changed writes nothing. Run capture
from CI beside `surface.sql`, or as a scheduled workflow.

### Adding a facet

A facet is a registration, not a branch — no parser change, no edit to the
dispatch:

```sql
select aiq.register_schema_facet('tradecraft', 'tradecraft.schema_facet',
    'Analytic vocabularies', 'Likelihood bands, evidence classes, source reliability.');
```

**That one is illustrative and will not run as written** — `tradecraft.sql` is
specified but not shipped (build-sql.py's `NOT_SHIPPED`), so registration
refuses with `schema facet provider tradecraft.schema_facet(text) does not
exist`. Which is the registration doing its job: a facet whose provider is
absent would be a mode that fails at read time instead of at write time. Every
other example in this file runs against the compose stack; this is the one that
names a provider you have to write first.

The provider takes the optional `FROM` argument (null when absent) and returns
`jsonb`. Mark it `caller_scoped` if it describes what the caller can reach
rather than what the deployment is — the `sql` facet is the worked case, and
its provider is `SECURITY INVOKER` for exactly that reason. A schema document
listing relations the reader cannot select from is a directory of things to
try and a disclosure that another tenant's tables exist.

---

## SQL — the floor, not a mode

**Ordinary SQL just works.** There is no `SQL` keyword: a statement starting
with `select`, `with`, `table`, `values` or `explain` is recognised as SQL by
how it starts, and everything else is a dialect error.

```sql
select aiq.query('select entity_type, count(*) from aiq.nodes group by 1');
-- {"mode": "SQL", "statement": "select entity_type, count(*) …"}
```

The keyword was dropped because it was ceremony on the one thing that needed
no announcement — and because it framed SQL as a sixth mode rather than the
floor the other five sit on. Sniffing a fixed set of read-only openers, rather
than treating *anything* unrecognised as SQL, is what keeps `LOKUP "acme"` an
honest `unknown mode` error instead of a SQL syntax error about a language you
were not writing.

`aiq.query` returns the statement rather than running it. Execute it through
the read-only passthrough:

```sql
select aiq.sql_passthrough('select entity_type, count(*) from aiq.nodes group by 1');
```

```json
[{"count": 3, "entity_type": "company"}, {"count": 3, "entity_type": "event"}]
```

`SECURITY INVOKER` (your RLS applies) and read-only **enforced by the
database**, not by inspecting the string:

```sql
select aiq.sql_passthrough('delete from aiq.nodes');
-- ERROR: the SQL passthrough is read-only: statement starts with a write/DDL keyword

select aiq.sql_passthrough('select aiq.link(''ACME'',''competes_with'',''ORB'')');
-- ERROR: cannot execute INSERT in a read-only transaction
```

That second case is the point: a write hidden inside a *function* passes any
keyword filter, and is stopped by the transaction.

---

## Plain table reads (PostgREST auto-CRUD)

For simple filtering you do not need the RPC at all. Use `Accept-Profile` to
select the schema:

```bash
curl -s "http://localhost:3000/nodes_api?entity_type=eq.company&select=summary,org_id" \
  -H "Authorization: Bearer $TOKEN" -H "Accept-Profile: aiq"
```

```json
[{"summary":"Orbital Systems","org_id":null},
 {"summary":"Acme Robotics","org_id":"11111111-…"}]
```

---

## Tenancy — and why your results may look "missing"

`org_id = rbac.shared_org_id()` means shared reference data, visible to
everyone — a well-known row in `rbac.orgs` whose id is derived rather than
generated, so it is the same in every deployment. A tenant's own
`org_id` is visible only to members of that org, taken from the **verified
JWT**, never a parameter.

Verified over REST with three tokens against the same query:

| Token | `LOOKUP "acme"` |
|---|---|
| org1 | returns the row |
| org2 | empty |
| no `orgs` claim | empty |

This propagates through traversal too: an org1 user asking `GRAPH "acme"` gets
3 neighbours, not 4 — Nadler Dynamics belongs to org2 and is filtered out
mid-walk.

So: **an empty result usually means identity, not absence.** Check that you
set `request.jwt.claims` (SQL) or sent a token with the right `orgs` (REST)
before concluding the data is not there.

---

## Registering your own content

`TEXT`/`SEMANTIC`/`SEARCH` read *your* tables, registered by name. Run as
`app_owner`:

**The `chunks` source ships already.** `world-model-ingestion/integration.sql`
registers `content.resource_chunks` as both the lexical and semantic source
named `chunks`, so `TEXT`/`SEMANTIC`/`SEARCH` have a real corpus the moment
the install finishes. What follows is how to register *your own* table
alongside it.

```sql
-- lexical: adds a generated tsvector column + GIN index to your table
select aiq.register_lexical_source('my_docs', 'myschema.my_chunks');

-- semantic: one embedding space per MODEL (not per dimension)
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default)
values ('nomic-embed-text', 768, 'ollama',
        'http://host.docker.internal:11434/api/embeddings', true);
select aiq.register_embedding_space('nomic-embed-text');

-- or a model that runs IN THE WORKER, with no url, no key and no bill. The
-- endpoint is the model id the runtime loads; `register_embedding_space` runs
-- as the schema's owner, because it creates a table the definer functions
-- write to.
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default)
values ('bge-small-en-v1.5', 384, 'fastembed', 'BAAI/bge-small-en-v1.5', true);
set role app_owner;
select aiq.register_embedding_space('bge-small-en-v1.5');
reset role;

-- entities: which of your rows become graph nodes
select aiq.register_entity_table(
    'company', 'wm.companies',
    'coalesce(n.ticker, n.name)',  -- canonical key
    'n.name',                      -- summary
    'n.org_id',                    -- tenancy
    'n.is_public');                -- inclusion policy
```

**A provider is a url, or it is in the worker.** `aiq.embedding_providers.in_process`
says which. A url provider is described by its request templates and answered
over HTTP; `fastembed` is loaded by the ingest worker from the model id in
`endpoint`, so `aiq.embed_batch_call` hands back `{in_process, model_id, dim}`
rather than a url, and nothing resolves a credential. The worker needs
`percolate-core[embed]`, which the published image carries with the model
already in it. Measured at 384 dimensions: 100,000 vectors is 356MB of table
and index, and a top-10 search is 0.86ms at the median
(REM-628).

One thing an in-process model cannot do: be the `embed:` step of a workflow.
That step compiles to an HTTP call, and there is nothing to call, so it is
refused by name. A corpus is embedded by the `embed` op, which is what an
upload already uses; a query supplies its vector.

Two things the registration does **not** do, and that will bite otherwise:

1. **It grants nothing on your schema.** The query functions are
   `SECURITY INVOKER`, so callers need real access to your tables, or every
   content mode fails with `permission denied for schema <yours>` while every
   `aiq` grant looks correct. Granting (and setting your own RLS) is your call
   to make, not this layer's:
   ```sql
   grant usage on schema myschema to authenticated;
   grant select on myschema.my_chunks to authenticated;
   ```
2. **Embeddings have no foreign key to your chunks.** The embedding table is
   generic, so it cannot reference a table it does not know. Deleting or
   recreating chunks leaves orphaned vectors and unembedded rows — with no
   error, just quietly worse results. Re-embed after any bulk change, and
   treat this the same way as node drift (`aiq.check_drift`).

## `aiq.schema_facets`

The registry behind SCHEMA mode. A facet is a name, the function that provides
it, a title and description for a reader, and whether its answer is scoped to
the caller. Registering one is an `INSERT` and a function — never a change to
the parser and never a new branch in a dispatch.

A registry rather than a `CASE` statement because the second consumer proved the
case: the tradecraft vocabularies and a facet over
`content.v_required_credentials` extend the capability document without
recompiling anything. Without it, every new thing a client might want to know
about this database would be a parser change.
