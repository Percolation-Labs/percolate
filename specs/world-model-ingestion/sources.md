# Sources — a declarative connector library

**Status: spec, partly shipped — and measured, not imagined.** Three of its
schema files are in `build-sql.py`'s `ORDER`: [`sources.sql`](sources.sql) (a
private source and its workflow saved together), [`api-sources.sql`](api-sources.sql)
(incremental API pulls with durable checkpoints) and [`polling.sql`](polling.sql)
(an enabled channel with a `poll_interval` gets a schedule). `connectors.sql`,
§16–17's connector library, is in `NOT_SHIPPED`, because its rows reach no
channel (§17.4). This document is what the runner reads, and it covers more than "poll a URL": the goal is that
**adding a source is an `INSERT`, not a pull request**, and that the hundredth
source costs what the tenth did.

The measure of this design is one number: *what fraction of new sources need zero
new code?* If it is not most of them, the design failed and a source library is
just a directory of scripts with a table in front of it.

**113 real sources were probed to find out. 102 parsed; 86% needed no code at
all.** §13 is what that exercise changed, and it changed a lot — the first draft
of this document was wrong about conditional GET, wrong about flattening, wrong
about the cursor taxonomy, and silent about the single most common structural
problem in the corpus. The probe and its 113-row results table were research
tooling and are not published.

---

## 1. A source is data, and so is what we learned about it

Two halves, and keeping them apart is the whole idea.

| | Written by | Answers |
|---|---|---|
| **Declaration** | a human or an agent | where it is, how to page it, what it costs, what it should produce |
| **Observation** | a probe, automatically | what actually came back — field shapes, cardinalities, the time field, a schema fingerprint, a query that works |

Almost every connector framework has the first half and treats the second as
tribal knowledge living in whoever wrote the parser. That is exactly what makes
the hundredth source cost more than the tenth. **Capturing the observation as
data is what makes the library scale**, because it turns "how do I parse this?"
from a research task into a lookup — for a person, and for a model.

---

## 2. Exactly three parse targets

Staging holds **what we were told**. Parsing produces **at most three things**,
and the list is closed:

| Target | Table | REM verb it feeds | Unit |
|---|---|---|---|
| **Resources** | `content.resources` → `resource_chunks` | `SEARCH` / `SEMANTIC` / `TEXT` | a document |
| **Entities** | `aiq.nodes` / `node_keys` / `edges` | `LOOKUP` / `GRAPH` / `FUZZY` | a thing with an identifier |
| **Moments** | `content.moments` (new, §7) | `TIMELINE` | something that happened, or was measured, at a time |

That the three targets line up one-to-one with the query substrates is not a
coincidence to note in passing — it is the reason the list is closed. A parser
that wants to produce a fourth kind of thing is proposing a fourth way to query,
and that is a much larger conversation than adding a source.

**"Moments" is the REM vocabulary of an earlier Percolate design, adopted deliberately.** An indicator
reading, a filing event, a thermal anomaly and a session summary are the same
shape: time-anchored, typed, belonging to a grain, consolidatable. Inventing
`indicators` and `events` as separate concepts here would be inventing two names
for one thing that already has a name.

Not every source produces all three, and most produce one or two. A FRED series
is moments only. An arXiv paper is a resource plus entities. A SEC filing is all
three.

---

## 3. Staging — what we were told

Before any target is written, the payload lands and a `content.files` row is
written. This is not a caching optimisation; it is the same *told versus
believed* split the coherence work is built on, applied one layer down. Re-parsing
must never require re-fetching, because re-fetching a paid or rate-limited source
to fix a parser bug is how a budget disappears.

Three staged forms, chosen by what came back:

| Form | When | Then |
|---|---|---|
| **Raw** | always, verbatim bytes | the audit anchor — every claim traces here |
| **Parquet** | tabular or repeated-record payloads | the scan target (§6) |
| **Markdown** | prose documents (PDF, HTML, DOCX) | the chunk-and-embed input |

**Markdown and Parquet are not alternatives; one document often yields both.**
A PDF's prose becomes markdown and gets embedded; its tables become Parquet with
a declared schema. That split matters more than it looks: markdown destroys
table structure, so routing a financial table through markdown loses exactly the
part worth having — and a fact a *parser* produced from Parquet is ground truth,
where the same fact extracted by a model from markdown is a hypothesis.

### 3.1 Modes

Per-source default, overridable per resource, and they compose:

- **`staged`** — bytes land, `files` row written, nothing else. Retrievable by
  key, not by meaning. The right default for high-volume sources.
- **`indexed`** — + chunked + embedded. Costs embedding spend, buys semantic
  retrieval.
- **`tabular`** — + normalised to Parquet with a fingerprinted schema (§5),
  catalogued for scan.

A source polled every 15 minutes that yields one interesting row a week should be
`staged` + `tabular`, never `indexed`. Embedding everything is the default that
quietly consumes the budget in §8.

---

## 4. The declaration

> **This section was overtaken by §17, and the two disagreed for a while.** It
> planned to widen `content.channels` into the declaration table. What actually
> got built is a **separate** `content.connectors` (`connectors.sql`), carrying
> §16.1's four blocks plus limits, valuation and lifecycle, with 304 rows
> registered over PostgREST in a demonstration. `connectors.sql` is not shipped
> in the extension, so a stock install has only `channels`; neither references
> the other, and §17.4 is where that is reconciled. The `alter table`
> below was never applied and is kept only because the *columns* it names are
> still the right ones — read it as the column list `connectors` is missing, not
> as a migration anyone should run.

```sql
-- NOT APPLIED. See §17.4 -- these columns belong on whichever table wins.
alter table content.channels
    add column mode          text[] not null default array['staged'],
    add column parser        text references content.parsers(name),
    add column cost_per_call numeric not null default 0,
    add column budget_key    text,          -- workflow.rate_limits key, §8
    add column rate_key      text,          -- workflow.rate_limits key, §8
    add column targets       jsonb not null default '{}',   -- §2, the projections
    add column probe_at      timestamptz,
    add column schema_id     bigint references content.source_schemas(id);
```

**`config jsonb` needs a schema per `kind`, enforced by a trigger.** The column
comment already argues against a column-per-provider, and it is right; the
opposite failure is forty undocumented config shapes discovered one at a time.
A JSON Schema per `kind`, validated on write, is the same shape as the pool image
policy — reject at `INSERT` with a comprehensible message, not at 03:00 on a poll.

### 4.1 Cursors are a closed taxonomy, not a string

A single `cursor` field becomes free text within a month. Five kinds cover
everything in the master source table, and a sixth should be a conversation:

| Kind | Config | Example |
|---|---|---|
| `high_water` | `field`, `order` | EDGAR `accessionNumber` |
| `timestamp` | `field`, `overlap` | FAERS `receiptdate` |
| `page_token` | `field`, `param` | ClinicalTrials `nextPageToken` |
| `offset` | `param`, `size` | openFDA `skip` |
| `sequence` | `head_url`, `field` | HN `maxitem` — the id space *is* the cursor |
| `etag` | — | conditional GET; the cursor is HTTP's |

`overlap` on `timestamp` is not optional. A source whose clock is behind yours
drops records silently at the boundary unless you re-read a window; the cost is
duplicate rows, which dedup handles, and the alternative is missing data nobody
detects.

---

## 5. Schema capture — the part that makes hundreds of sources tractable

A **probe** runs on first registration and on every schema-fingerprint change.
It fetches one page and records what it found.

```sql
create table content.source_schemas (
    id           bigint generated always as identity primary key,
    channel_id   uuid not null references content.channels(id) on delete cascade,
    fingerprint  text not null,            -- hash of the normalised field tree
    observed_at  timestamptz not null default now(),
    field_tree   jsonb not null,           -- path -> {type, nullable, cardinality, examples}
    row_path     text,                     -- JSONPath to the repeated record
    time_field   text,                     -- detected; drives moments
    identity_fields text[],                -- detected; drives entity resolution
    geometry_field  text,
    units        jsonb,                    -- path -> unit, where declarable
    row_estimate int,
    llm_card     text,                     -- §5.2
    duck_example text,                     -- §5.3
    unique (channel_id, fingerprint)
);
```

### 5.1 Drift is a signal, not a shrug

DuckDB will read a directory of drifting schemas with `union_by_name=true` and
hand back `NULL` where a column was renamed. **That is a silent-wrong-answer
generator, and this collection has already been bitten by exactly that class of
bug** — `node_keys`/`org_id` drift made a key visible while its node was not, and
`LOOKUP` returned an empty result indistinguishable from "no such key."

So the fingerprint is stored per file and per schema version, and a partition
whose fingerprint differs from its predecessor **inserts a new
`source_schemas` row and raises a moment**. It is not absorbed.

This is worth more than hygiene here. A source silently changing its schema *is*
a coherence signal — the source broke its own pattern, which is `brief.md`'s
absence-as-signal applied one level down. In any other pipeline that is an ops
annoyance; here it belongs in the same machinery that notices a filer forty-one
days late.

### 5.2 The LLM card — what we store so a model knows what to do

The probe's most valuable output is not the field tree, it is a compact
description a model can be handed for a source it has never seen. Stored as
data, regenerated when the fingerprint changes, and used verbatim as a prompt
fragment:

```
SOURCE  sec-edgar-submissions   (JSON, ~1 record/company/filing)
RECORDS $.filings.recent  — COLUMNAR: parallel arrays, not objects.
        Index i of every array is one filing. Zip before use.
TIME    filingDate (date, ISO-8601, always present)
IDENTITY cik (int, → aiq canonical key 'sec:cik'), accessionNumber (unique)
FIELDS  form (str, card 41: 10-K 8-K 4 …), primaryDocument (str, → URL),
        items (str, nullable 62%, comma-separated 8-K item codes)
TARGETS entities: cik → company node
        moments : one per filing, moment_type='filing'
        resources: primaryDocument fetched separately, mode=indexed
GOTCHA  Parallel arrays are the single most common mis-parse of this API.
        `items` is only meaningful for form='8-K'.
```

The `GOTCHA` line is the part that earns its place. Every source has one or two
things that are obvious once and expensive to rediscover, and they are precisely
what does not survive in a hand-written parser's head. **Writing them down as
data is how the library gets better as it gets bigger** rather than worse.

### 5.3 A worked DuckDB query, per schema version

Stored alongside, because "here is a query that works against this shape" is the
fastest possible onboarding for both a person and a model:

```sql
-- duck_example for sec-edgar-submissions
select cik, form, filingDate, accessionNumber
from read_parquet($files)
where form in ('8-K','10-Q') and filingDate >= $since
order by filingDate desc;
```

It is also a **test**. If the stored example stops returning rows against the
current partitions, either the schema drifted or the source did — and that is a
cheap, continuously-run canary that costs one query per source per day.

---

### 5.4 Probe etiquette — what we may do to somebody else's endpoint

§5 says a probe fetches one page and records what it found, and says nothing
about the fact that the page belongs to a third party who has not agreed to
anything. That gap mattered as soon as the probe moved to authoring time: the
registration probe in §5 runs against a source somebody already configured,
while the authoring probe runs against a URL somebody has just typed, possibly
wrongly, possibly not theirs.

The rules, which are the same for both:

- **One request per inspection**, capped in bytes and in time. A probe that
  reads a whole export is an ingestion nobody asked for; the cap is 2MB and the
  report says when it truncated, so a shape derived from a partial page is
  never presented as a shape derived from the page.
- **Only an origin the operator entered.** A continuation URL found in the
  response is *reported* and not followed — the same rule the puller applies at
  §4, where a continuation on another origin is refused rather than fetched.
  Following discovered links is what makes a probe a crawler.
- **It identifies itself.** A `User-Agent` naming the product and the fact that
  this is a single inspection, so the endpoint's operator can tell it from a
  scraper in one line of their log.
- **Credentials by reference, resolved service-side.** A probe of an
  authenticated endpoint takes a `credential_ref`, never a value, and the
  operator's origin bindings decide whether that reference may travel to that
  host. A value typed into a browser has nowhere to go, which is the property
  being preserved rather than a restriction being added.
- **The caller is authenticated.** An unauthenticated URL fetcher inside a
  deployment's network is a request forwarder for whoever finds it, whatever
  the report is for.
- **It refuses rather than guesses, and says which is which.** The report
  separates what was read from the response from what was ranked out of field
  names, and what a single response cannot show — which request parameter
  filters by the watermark, above all — is named as unobservable instead of
  being filled in. A plausible dot path is the failure this whole mechanism
  exists to remove, and a probe that invents one has made it worse, not better.

**The authoring probe is not stored.** `content.source_schemas` is the
registration probe's table and stays that way: it describes a source that
exists. A report about a URL somebody is still typing would be a second,
ageing account of a shape beside the configuration it produced.

## 6. DuckDB runs in the worker, not in Postgres

> **Built as [`lake.md`](lake.md).** Both reasons below held up when it was
> run, and running it added a third: DuckDB's own sandbox is not a boundary by
> itself, because a locked connection still accepts `CREATE SECRET`, and that
> exfiltrated a file (lake.md §3.1). §6.1's partition index is not what the lake
> reads. It resolves datasets by name through `content.datasets`, which is the
> same idea one level coarser.

Two reasons, both of them this collection's own arguments turned on a new case.

1. **The extension build record.** `dev/Dockerfile.pg19` carries a patch for
   `pg_cron` on PG19 (`dev/patches/pg_cron-pg19.patch`), and pgvector needed
   build changes for it. `pg_duckdb` on PG19 is an unknown with a bad prior, and it
   would sit on the critical path of every analytical query.
2. **It would give the database outbound network egress to object storage** —
   the exact posture change the worker exists to avoid: the database makes no
   outbound calls. The
   argument does not weaken because the payload is Parquet.

So a `work` step runs DuckDB in a pool and returns a small result. What that
costs is genuine cross-store joins; what makes it acceptable is that the small
side is always the Postgres side — a watchlist, a tile grid, a set of CIKs — and
is pushed down as a parameter.

### 6.1 Postgres is the partition index; DuckDB is the scanner

For this to work, `content.files` must carry enough to prune with, or "which
files do I scan" degrades into a bucket listing:

```sql
alter table content.files
    add column partition_key      text,        -- source + grain
    add column row_count          bigint,
    add column time_range         tstzrange,
    add column schema_fingerprint text;
create index on content.files using gist (time_range);
```

The pattern is then one `SELECT` and one scan:

```sql
select key from content.files
where partition_key like 'sec-edgar/%'
  and time_range && tstzrange(now() - interval '7 days', now())
  and schema_fingerprint = $expected;   -- refuse drifted partitions loudly
```

— and that list is handed to DuckDB. This is the join that actually matters, and
it needs no extension at all.

**The small-file problem is real and arrives at month three.** Twenty sources
polled every fifteen minutes is ~2,000 objects a day; DuckDB scan performance
degrades on that long before storage cost does. Compaction is a scheduled
workflow that rewrites a day's partitions into one file and supersedes the
`files` rows — unglamorous, and cheaper to design now than to retrofit.

---

## 7. Moments — the third target

```sql
create table content.moments (
    id           uuid primary key default gen_random_uuid(),
    moment_type  text not null,          -- 'filing' | 'reading' | 'anomaly' | 'indicator' | …
    at           timestamptz not null,
    grain        interval,               -- the window this consolidates, null = instant
    subject_node uuid references aiq.nodes(id),
    resource_id  uuid references content.resources(id),
    channel_id   uuid references content.channels(id),
    value        numeric,                -- indicators
    unit         text,
    payload      jsonb,
    org_id       uuid,
    created_at   timestamptz not null default now()
) partition by range (at);
```

Partitioned by `at` with `pg_partman` (not yet in the image), plus
a BRIN index on `at`. **Not TimescaleDB, yet, and the reason is that the Parquet
decision removed the workload that would justify it**: the high-volume raw series
lives in object storage, and what reaches this table is the derived, sanitised,
promoted side — small. TimescaleDB is deliberately not a dependency; the trigger
for adopting it is sharper:
adopt it when a measured ingest rate or a continuous-aggregate need appears, not
because the word "time-series" appeared in a design.

The table is shaped so the migration is `create_hypertable()` and nothing else —
which is the point of naming the trigger rather than the tool.

**This opens a gap worth stating.** `ai-query-layer` has `LOOKUP`, `GRAPH`,
`SEMANTIC`, `TEXT`, `SEARCH`, `SCHEMA`, `SQL`, `LAKE`, `PATH` and `RELEVANCE`. It has no `TIMELINE`. REM does. A
populated `moments` table is the substrate for one, and until that exists the
third target is queryable only through `SQL` — which is honest, and is a
decision to revisit once there are moments worth walking.

---

## 8. Budget and rate reuse the token bucket

`workflow.rate_limits(key, capacity numeric, tokens numeric, refill_rate
numeric)` and `try_consume_rate_limit(key, amount numeric)` are already a budget
enforcer. **`amount` is `numeric`, so tokens need not be requests — they can be
dollars.**

A $50/month cap is one row: `capacity 50`, `refill_rate 50/2592000`, each call
consuming its actual `cost_per_call`. No new machinery, and a budget
allocation becomes rows rather than a spreadsheet.

`tasks.rate_key` is one column, so a task cannot consume two buckets. Rather than
widen it, **split the two by moment — which is where they belong anyway**:

- **Budget is consumed at planning**, in the SQL step that decides to enqueue a
  fetch. Exhausted budget means the task is never created, which is better than
  creating tasks that can never be claimed. This is the half that works today:
  a planning step calls `try_consume_rate_limit(key, cost)` directly and passes
  whatever `numeric` amount it likes.
- **Rate is consumed at claim**, by `claim_task` — which absorbed rate limiting,
  so any worker gets the throttle without opting in (`05-faults.sql` asserts
  it). `claim_task_rate_limited` still exists and is now a superseded alias of
  it; do not write new callers against that name.

Degradation then comes free: the lookahead-skip means an exhausted paid source
does not head-of-line-block the free ones. The paid tier drops out, EDGAR keeps
flowing, and `v_queue_depth` shows it.

**Two things this section claimed that the engine does not do, corrected here
rather than left to be discovered against a real bill.** Both are asks on
the workflow engine, not work for this system:

- **Claim-time consumption is hardcoded to one token.** `claim_task` calls
  `try_consume_rate_limit(t.rate_key)` with the default `amount`, so "tokens
  can be dollars" is true of a *planning* call and false of every *claim*. A
  cost-weighted claim needs the amount to travel on the task — a `rate_amount`
  column beside `rate_key` — or the dollar interpretation only ever holds for
  the half of the design that is a SQL step.
- **There is no reconciliation, because there is nothing to reconcile with.**
  `workflow.rate_limits` has a consume and no release: `try_consume_rate_limit`
  is the only function that touches the bucket. Returning the difference
  between estimated and actual cost after a call requires
  `release_rate_limit(key, amount)`, which does not exist. Until it does, a
  month of small underestimates overspends silently — which is exactly what
  this paragraph previously claimed was handled.

And one thing the schema does not model at all: **quota is not a rate**, though
`connectors.quota` is declared as if something enforces it. A token bucket with
a slow refill approximates "N calls per day" badly — it grants a burst of
`capacity` and then trickles, where a daily quota should grant N and refuse
until the period rolls. OpenDota advertising a per-minute *and* a per-day limit
in one response (§19.1) is the clearest argument that these are two mechanisms.
Nothing currently materialises `connectors.rate_limit` or `connectors.quota`
into `workflow.rate_limits` rows either, so today both columns are documentation
that a runner may choose to honour.

---

## 9. The parser registry

Copy `workflow.step_functions` exactly, including the reasoning:

```sql
create table content.parsers (
    name        text primary key,       -- what a channel names
    fn          text not null,          -- schema-qualified function
    arg_types   text[] not null default '{}',
    media_types text[] not null default '{}',
    timeout_ms  int not null default 30000,
    provided_by text,                   -- '<extension>' | …
    description text
);
```

Registration is owner-only with a `to_regprocedure` existence check, so a typo'd
parser fails at registration rather than at 03:00 on a poll, and registering
decides what a channel author can cause to run.

Three tiers, cost-ordered — the same cascade philosophy as entity resolution:

| Tier | What | Runs | Should cover |
|---|---|---|---|
| **0 — declarative** | JSONPath/XPath projection + cursor, no code | Postgres | most JSON APIs and feeds |
| **1 — core parser** | registered function: `rss`, `atom`, `xbrl`, `csv`, `sitemap`, `html_readable` | Postgres | anything with a format spec |
| **2 — extension parser** | registered by another extension, or a `work` handler | pool | the exotic ones |

**A channel names a parser, never an implementation.** Promoting a parser from a
Python handler in a consumer's image to a `pgrx` function in core is then an
`UPDATE` to one registry row — no channel changes, no redeploy. That is
prototype-outside-then-promote with a mechanical migration path instead of a
migration project.

---

## 10. The example library

The library is seed data. Adding a source is an `INSERT`; adding a *shape* is
occasionally a parser. Below are twelve chosen because their shapes differ, not
because they are the twelve most useful — a hundred JSON APIs that page by offset
teach the library nothing after the first.

| Source | Wire | Cursor | Targets | The shape it teaches |
|---|---|---|---|---|
| SEC EDGAR submissions | JSON | `high_water` | E, M | **columnar JSON** — parallel arrays, not objects |
| SEC XBRL companyconcept | JSON | `high_water` | M | units-keyed object; values are facts, not text |
| ClinicalTrials.gov | JSON | `page_token` | R, E, M | **versioned records** — the diff is the signal |
| Federal Register | JSON | `page_token` | R, E | full document behind a URL in the record |
| arXiv | Atom XML | `offset` | R, E | XML feed; author lists are entity fan-out |
| HN Firebase | JSON | `sequence` | M, R | **the id space is the cursor**; one fetch per item |
| Wikipedia RecentChanges | JSON | `timestamp` | M | high volume, ~all noise — `staged` only |
| FRED series | JSON | `timestamp` | M | pure indicator; no entities, no documents |
| NASA FIRMS | CSV | `timestamp` | M | **geometry**; native tabular → Parquet directly |
| openFDA FAERS | JSON | `offset` | M, E | facet endpoints return aggregates, not records |
| Telegram `t.me/s/` | HTML | `high_water` | R | **scrape**; ToS constrains use, not fetch |
| S3 inbox | Parquet/PDF | `etag` | varies | **no API at all** — files simply appear |

Three worked in full:

### 10.1 SEC EDGAR submissions — columnar JSON

```yaml
name: sec-edgar-submissions
kind: http_pull
poll_interval: 15 min
mode: [staged, tabular]
parser: jsonpath
config:
  url: https://data.sec.gov/submissions/CIK{{item.cik}}.json
  headers: {User-Agent: "{{env.SEC_UA}}"}     # SEC rejects requests without one
  row_path: $.filings.recent
  columnar: true            # parallel arrays; zip by index
  cursor: {type: high_water, field: accessionNumber}
  rate_key: rps:sec         # 10/s, their stated limit
  cost_per_call: 0
targets:
  entities:
    - {key: "sec:cik:{{cik}}", type: company, kind: canonical}
  moments:
    - {moment_type: filing, at: "{{filingDate}}", subject: "sec:cik:{{cik}}",
       payload: {form: "{{form}}", accession: "{{accessionNumber}}"}}
  resources:
    - {when: "form in ('8-K','10-Q','10-K')", fetch: "{{primaryDocument}}", mode: indexed}
```

Everything above is tier 0 — no code. The one thing that needs a parser flag is
`columnar: true`, and it is the single most common mis-parse of this API, which
is exactly why it belongs in the declaration rather than in someone's head.

### 10.2 FRED — indicator only

```yaml
name: fred-{{series_id}}
kind: http_pull
poll_interval: 6 h
mode: [staged, tabular]
parser: jsonpath
config:
  url: https://api.stlouisfed.org/fred/series/observations?series_id={{item.series_id}}
  row_path: $.observations
  cursor: {type: timestamp, field: date, overlap: 7 days}   # FRED revises
  credential_ref: FRED_API_KEY
targets:
  moments:
    - {moment_type: indicator, at: "{{date}}", value: "{{value}}",
       unit: "{{units}}", subject: "fred:{{series_id}}"}
```

No entities, no resources. The `overlap` is load-bearing: FRED revises published
observations, so a strict high-water cursor silently keeps the first value
forever — and a revised indicator is precisely the kind of disagreement the
staging area exists to preserve rather than overwrite.

### 10.3 S3 inbox — no API at all

```yaml
name: partner-drop
kind: file_watch
mode: [staged, tabular]
parser: auto            # by media type, via content.parsers.media_types
config:
  prefix: s3://inbox/partner-a/
  cursor: {type: etag}
targets:
  auto: true            # from the probe's detected time/identity fields
```

Worth including because it is the case that proves sources are data rather than
integrations: nothing is fetched, nothing is authenticated, and the same
staging, probing, fingerprinting and parsing machinery applies unchanged.

---

## 11. Build order and gates

1. **Fetch utilities + the runner.** Conditional GET, the five cursor kinds,
   politeness via `rate_key`. *Gate: three sources of different wire formats
   land `files` rows and staged bytes, and a re-poll fetches nothing changed.*
2. **The probe + `source_schemas`.** Field tree, time/identity detection,
   fingerprint. *Gate: a deliberately mutated payload produces a new schema row
   and a drift moment rather than NULLs.*
3. **Tier-0 projection into the three targets.** *Gate: EDGAR yields company
   nodes and filing moments with no parser code, and the columnar arrays zip
   correctly.*
4. **Parquet staging + `files` partition index + DuckDB in a worker.** *Gate:
   the stored `duck_example` runs against real partitions and returns rows.*
5. **Budget + rate buckets.** *Gate: an exhausted paid budget stops enqueueing
   that source while free sources keep flowing — measured, not asserted.*
6. **The parser registry and tiers 1–2.** *Gate: a parser moves from a `work`
   handler to a registered function with no channel row changed.*
7. **Compaction.** *Gate: a day of partitions rewrites to one file, `files` rows
   supersede, and the `duck_example` still returns the same rows.*

The library grows after step 3, not before. A hundred sources declared against an
unproven projection is a hundred things to redo.

---

## 12. Open questions

- **How much does the probe actually infer?** Time-field detection is easy;
  identity-field detection is entity resolution wearing a hat, and getting it
  wrong silently creates duplicate nodes. It may need to propose rather than
  decide, with the declaration confirming.
- **Who writes the `GOTCHA` line?** The valuable part of the LLM card is the part
  a probe cannot observe. A model can draft it from a sample; whether that is
  reliable enough to store unreviewed is unknown, and a wrong gotcha is worse
  than none.
- **Auto-targets.** §10.3's `targets: {auto: true}` is a real convenience and a
  real risk — a source that decides for itself what it produces can quietly start
  writing entities. It may need to be a proposal a human accepts once.
- **Cross-source schema reuse.** Twelve sources emit "a company." Whether the
  library should carry shared target templates, or whether that is premature
  abstraction over sources that merely look alike, is unresolved.
- **Where the runner lives.** Core, by §1's utility test. It gets prototyped
  in a consuming project first, and the claims work is the consumer that needs
  it.
- **Per-deployment or per-tenant credentials** (§15.4). It constrains the
  resolver, the budget model and the pool boundary at once, and it is the one
  credential question worth settling before the manager is chosen.

---

## 13. What 113 real sources taught us

Every claim in this section is measured. The probe
fetched 113 sources across 14 categories, detected the wire format, found the
record path, inferred a field tree, and — the part that mattered — recorded what
declarative parsing **could not** do.

```
probed  113
parsed  102   (90%)
failed   11   — 5 auth, 2 quota, 3 timeout, 1 bad request
```

**The residual failures are credential and quota problems, not shape problems.**
Not one source in the corpus was unparseable because its structure defeated the
approach. That is the strongest result here, and it relocates the hard part of a
source library from parsing to secrets and budget.

### 13.1 The headline number holds, but the escape hatch is smaller than proposed

| | n | |
|---|---|---|
| Parsed with no code and no flag | 88 | **86%** |
| Needed a **layout flag** — still no code | 14 | 14% |
| Needed a hand-written parser | **0** | — |

§9 proposed three tiers, with tier 2 as "write a parser." **Nothing in 113
sources reached tier 2.** The real escape hatch is one enum-valued column, not a
function, and that is a much cheaper extension point than the one specified.

### 13.2 Six layouts, and two of them were missing from this document

| Layout | n | What it is |
|---|---|---|
| `objects` | 66 | a JSON array of objects — the assumed case |
| `xml` | 13 | RSS/Atom/generic XML |
| `single` | 9 | **one object, no repeated record** — `github_repo`, `frankfurter`, `ipapi` |
| `keyed_map` | 4 | **records are object VALUES; the key is the id** — `npm`, `wikidata`, `imf`, `sec_company_tickers` |
| `columnar` | 2 | parallel arrays — `sec_submissions`, `open_meteo` |
| `lines` / `scalar` / `arrays` / `html` | 8 | text, a bare value, header-rows, scrape |

`keyed_map` was **not in this document at all** and is as common as `columnar`,
which had a worked example. `single` at 9% was also unanticipated — a source
that returns one object per call is a perfectly ordinary shape (an entity
lookup) and needs no record path.

`scalar` deserves its own note: `hn_maxitem` returns the bare integer
`49515605`. It is not a document, it has no fields, and it exists to be a
**cursor head**. §4.1's `sequence` cursor named a `head_url` without noticing
that the thing at the other end is a distinct payload shape.

### 13.3 Conditional GET is a minority capability — this document over-sold it

**21% of sources send an `ETag` or `Last-Modified`.** §3 and §4.1 treat
conditional GET as a headline fetch utility; it is available for one source in
five. **Cursors do essentially all of the incremental-fetch work**, and the
`etag` cursor kind is an optimisation to apply where offered, not a mechanism to
design around.

### 13.4 The cursor taxonomy was missing its most robust member

Pagination keys across the corpus barely agree: `nextPageToken`, `next_page_url`,
`nextCursorMark`, `nextPageUrl`, `startIndex`, `offset`, `skip`, `has_more`,
`links.next`, `resumptionToken` — mostly appearing once each. Two things follow.

**Add a seventh cursor kind, `next_url`: follow the absolute URL the server
hands back.** Several APIs return one in the body, and **7 of 102 send an
RFC-5988 `Link: <…>; rel="next"` header** (openFDA's four endpoints, GitHub,
HuggingFace ×2). It is the most robust kind available — no parameter
reconstruction, no guessing — and it was absent from §4.1.

**Do not try to unify the rest.** A closed taxonomy of *mechanisms*
(high-water, timestamp, page-token, offset, sequence, etag, next-url) works; a
closed taxonomy of *field names* does not, and the field name belongs in
`config` per source.

### 13.5 Ten time formats, and seven carry no timezone

| Format | n | Example |
|---|---|---|
| ISO-8601 with `Z` | 19 | `2017-08-23T15:17:23Z` |
| date only | 12 | `2026-08-27` |
| **ISO-8601 naive, no zone** | 7 | `2023-07-10T21:05:09` — `fec_candidates` |
| ISO-8601 with offset | 7 | `2024-08-02T09:43:39.193+02:00` |
| RFC-822 | 5 | `Mon, 31 Aug 2026 22:25:59 GMT` — feeds |
| epoch seconds | 4 | `1175714200` — `hn_item` |
| year only | 3 | `2026` |
| `YYYYMMDD` int | 2 | `20210902` — `openfda_label` |
| epoch millis | 1 | `1788212763374` — `usgs_earthquakes` |

**A naive timestamp is a silent-wrong-answer generator for a timestamp cursor**:
you cannot know its zone, so a cursor boundary is wrong by up to a day and
nothing errors. The `timestamp` cursor kind must carry a declared `tz` for these,
and the probe must flag naive timestamps rather than accept them.

Epoch seconds and millis are distinguishable only by magnitude — which is a
heuristic, so it belongs in the declaration once observed, not in the reader
every time.

### 13.6 The biggest structural problem was not in this document at all

**26% of sources have array-of-object fields that need exploding**, up to 26 such
fields in a single record. Author lists, taxonomy tags, identifier lists,
geometry rings. §2's three targets have no way to express "one record becomes N
entity rows," and it is the single most common thing the corpus needs.

The projection language needs an **explode** operator, and it is what turns
`openalex.authorships[]` into author entities and `arxiv.category[]` into
taxonomy edges. Without it, tier 0 covers the row but silently drops the graph.

### 13.7 Do not flatten — Parquet has nested types and DuckDB queries them

Flattening a nested document explodes its width: median 11 columns, but
`openalex_works` produces **496 columns from 10 records** and `gbif_occurrence`
192. §3 implied a flat table as the tabular form. That is wrong.

Parquet supports `STRUCT` and `LIST` natively and DuckDB queries them with dot
and `UNNEST`. **Stage nested, project flat at query time.** The 496-column table
is an artifact of the writer, not a property of the data.

### 13.8 Ragged schemas are normal, so the fingerprint must be a union

**33% of sources return records with different field sets inside a single
response.** `bluesky_feed`: 167 fields in the union, 24 in common — **86% of
fields optional**. `openalex_works`: 85%.

§5's fingerprint over "the normalised field tree" would therefore change with
sampling depth and flag drift constantly. The fingerprint must be computed over
the **union across the whole page**, with per-field presence rates recorded — and
`present_pct` then becomes the useful signal, because a field that was in 100% of
records and is now in 40% is real drift, while a field that was always optional
is not.

### 13.9 Dynamic keys make the schema formally unbounded

Three sources embed data in *key positions*: `imf_datasets` has **52 dynamic path
segments** (years as keys), `gbif_occurrence` nests a UUID mid-path
(`classifications.7ddf754f-….classification`), `openalex_works` has 7.

A field tree over these grows without bound and the fingerprint churns per
record. The probe must **detect dynamic segments and collapse them to a
wildcard** (`classifications.*.classification`), which is also the only form a
human or a model can read.

### 13.10 Paths cannot be dotted strings

`npm_registry`'s `versions` object is keyed `"4.17.1"`, `"0.14.1"`. A dot-joined
path is ambiguous and un-splittable, and this crashed the first probe run.
**Paths are segment arrays**, rendered bracketed (`$["versions"]["4.17.1"]`).
§10.1's `$.filings.recent` notation is convenient shorthand and wrong as an
implementation.

### 13.11 Per-source headers are mandatory, not a nicety

`data.sec.gov` returns **403 to any User-Agent containing a URL**. It wants
`Company Name email`. A single polite UA for the whole library does not work,
and the failure is a hard 403 with no explanation — the exact class of thing the
`GOTCHA` field in §5.2 exists to carry.

### 13.12 The `resources` target is rarer than the naive heuristic claims

Detecting "has a long string field" marked 51 of 102 sources as producing
resources. Actually extracting prose, traversing nested fields:

| Prose in the largest record | n | |
|---|---|---|
| any | 47 | 48% |
| > 200 bytes | 34 | 35% |
| > 1000 bytes | 17 | **17%** |
| > 4000 bytes | 2 | 2% |

**Most APIs return facts, not documents.** The `resources` target applies to
about a third of sources and genuinely matters for a sixth — `clinicaltrials`
(11KB per record), arXiv abstracts, Federal Register documents, news feeds.
Entities and moments are the common case at 76% each, and that ratio is worth
knowing before spending an embedding budget.

**A correction worth keeping rather than quietly fixing.** The first pass of this
measurement walked only top-level fields and reported 41% / 32% / 15%. Prose is
routinely nested — `bluesky_feed`'s post text is at `post.record.text`,
`clinicaltrials`' at `protocolSection.descriptionModule.*` — so seven sources
scored zero while carrying real documents, `clinicaltrials` worst at 11KB read as
nothing. The numbers above are the corrected ones. The general lesson is §13.7's
in a different costume: **a measurement that only looks at the top level of a
nested document measures the wrong thing**, and it fails silently in the
direction of "nothing here.".

### 13.13 What this changes

| § | Was | Is |
|---|---|---|
| 3, 4.1 | conditional GET a headline utility | 21% of sources; an optimisation |
| 4.1 | six cursor kinds | seven — `next_url` added, and it is the most robust |
| 4.1 | `timestamp` cursor | must carry a declared `tz`; 7 sources are naive |
| 2 | three targets | plus an **explode** operator, needed by 26% |
| 3 | tabular means flat | tabular means **nested**; flattening produced 496 columns |
| 5 | fingerprint over the field tree | over the **union**, with presence rates |
| 5 | — | dynamic key segments collapse to `*` |
| 9 | three tiers, tier 2 writes a parser | **one layout enum**; 0 of 113 needed a parser |
| 10.1 | `$.filings.recent` | segment arrays; dotted paths break on real keys |
| — | one polite User-Agent | per-source headers, or SEC 403s you |

### 13.14 What the exercise did not settle

- **Only first pages were fetched.** Every cursor kind in §4.1 is inferred from
  an envelope or a header, not driven. Paging is where sources actually break.
- **One sample per source.** Drift detection (§5.1) is untested — it needs the
  same source over days, which is the next probe run, not this one.
- **Auth-gated sources are unrepresented.** All 5 auth failures are ordinary
  APIs; a corpus of only-free sources may be systematically simpler than a real
  deployment's.
- **`present_pct` is measured over one page**, so a field absent from page 1 and
  universal on page 2 reads as optional. The union must accumulate across
  fetches, which the schema table supports and the probe does not yet do.

---

## 14. Gotchas — the notes that cost time, kept as data

Forty-three of the 113 probed sources have a recorded gotcha in
the probe's catalogue. They are **data, in a column, not prose in this
document** — for the reason §5.2 already gives: the valuable part of a source
card is the thing a probe cannot observe, and it is exactly what evaporates when
it lives in a parser author's head.

`content.source_schemas` therefore carries `gotchas text[]`, populated by hand or
by review, versioned with the fingerprint, and rendered into the LLM card. A
gotcha is not a bug report; it is **a durable note about a source's contract that
survives whoever discovered it**.

The nine that cost the most time in this pass, and what each one generalises to:

| Source | Note | Generalises to |
|---|---|---|
| `data.sec.gov` (all) | UA must be `Company Name email`; **any UA containing a URL is a hard 403** | per-source headers are mandatory (§13.11) |
| `npm_registry` | keys contain dots (`"4.17.1"`) | paths are segment arrays, never dotted strings (§13.10) |
| `imf_datasets` | years are object **keys** — 52 dynamic path segments | dynamic segments collapse to `*` (§13.9) |
| `gbif_occurrence` | a UUID appears mid-path as a key | same |
| `usgs_earthquakes` | epoch **millis**, where `hn_item` is epoch **seconds** | epoch scale is a declaration, not a guess (§13.5) |
| `fec_candidates` | ISO-8601 with **no timezone** | `timestamp` cursors need a declared `tz` (§13.5) |
| `openfda_*` | paging is `Link: rel=next` with `search_after`; **`skip` is capped** | follow the link, never reconstruct (§13.4) |
| `census_pop` | the first array is the **header row**, not data | `header_rows` layout |
| `telegram_preview` | structure is a CSS-class contract (`tgme_widget_message`) | a scrape breaks without warning; pin the class and alert on zero rows |

Two are worth stating as rules rather than entries, because each cost a debugging
cycle and neither produces a useful error:

- **A hard 403 with no body is usually a User-Agent policy, not an auth
  problem.** It reads as "you need a key" and is not.
- **A cursor that silently returns the same page** is the failure mode of a
  capped `skip`. Nothing errors; the pipeline simply re-ingests page one until
  someone notices duplicate rows. Dedup hides it, which makes it worse.

The `gotcha` column (`content.connectors.gotcha`) is the seed. It is expected to grow faster than the
source count — a source that has been driven through pagination and a schema
change will accumulate several — and a source with **zero** gotchas after real
use should read as "not yet exercised," not "clean."

---

## 15. Credentials — a name, a shape, and a resolver

17 of 113 catalogued sources need a credential, and five of the eleven probe
failures were `401`/`403`. This is not a corner: it is the largest remaining
barrier to the library, now that parsing is not one (§13).

A credential vault is out of scope for the first release, and
`credential_ref` resolves from worker environment today. **That is fine as an
implementation and wrong as an interface**, so this section specifies the seam
rather than the vault — the goal being that a real manager drops in later
without rewriting a single source row.

### 15.1 Three separable things

The mistake to avoid is conflating them, because each changes on its own
schedule:

| | Lives in | Changes when |
|---|---|---|
| **The name** | `content.channels.config.credential_ref` | never — it is the stable logical handle |
| **The shape** | `content.channels.config.auth` | the API changes how it authenticates |
| **The material** | a resolver, never Postgres | rotation, per deployment, per tenant |

A source row names a credential and declares how it is *presented*. It never
contains the secret, and it never contains a path into any particular store — a
row saying `vault://kv/prod/fred#key` has hard-coded the vault, and migrating
stores then rewrites every source.

### 15.2 Auth shapes are a closed set; adding one must not touch source rows

Observed across the catalogue, plus the two that will arrive:

```yaml
auth: {type: none}
auth: {type: query_param, param: api_key}          # NASA, FEC, EIA, BLS
auth: {type: header, header: X-API-Key}            # OpenAQ
auth: {type: bearer}                               # TMDB, CoinCap, CORE
auth: {type: basic, user_from: ref}                # Companies House
auth: {type: user_agent, template: "{{name}} {{email}}"}   # SEC — see §14
auth: {type: oauth2_cc, token_url: …, scope: …}    # not yet in the catalogue
auth: {type: signed, algo: sigv4, region: …}       # not yet in the catalogue
```

`user_agent` is in the list because of SEC: **identity carried in a header that
is not an auth header is still a credential**, and modelling it as "just a
header" is how it ends up hard-coded in a fetcher.

`oauth2_cc` and `signed` are listed while absent from the corpus deliberately —
they are the two shapes that force a resolver to do *work* rather than return a
string (a token exchange with an expiry; a per-request signature over the
canonical request). **If the interface only ever returns a string, both are
impossible to add later without changing it.** Hence §15.3.

### 15.3 The resolver interface

One call, in the worker, at dispatch:

```
resolve(credential_ref, auth_shape, request) -> mutated request
```

Not `get_secret(name) -> str`. The resolver **mutates the outbound request**,
which is what lets a token exchange, a cached expiring token and a request
signature all be resolvers rather than special cases in the fetcher. Today's
implementation reads `os.environ[credential_ref]` and sets a header; nothing
about the interface says so.

Requirements a future manager must satisfy, stated now because retrofitting any
of them is expensive:

- **Postgres never holds material.** Already true, and the property that keeps
  `channels` inspectable and dumpable. A resolver that writes a cached token
  back into a table breaks it.
- **Rotation touches no source row.** The name is stable; the value moves behind
  it. A source row that has to change on rotation is a source row that will be
  wrong during an incident.
- **Resolution is scoped, and the scope is not the pool.** `pools.md` §7.3 is
  explicit that any pool may name any Secret in the pool namespace — so a
  namespace-wide secret is a credential every pool has. A per-tenant or
  per-source credential needs the resolver to enforce scope, because the
  namespace will not.
- **A missing credential fails the task by name.** `credential FRED_API_KEY not
  resolvable for source fred-gdp` — not a bare 401 the operator reverse-engineers.
  Five of this run's failures were exactly that experience.
- **The audit records the name, never the value**, and rides the existing
  `trace_id` so "which run used which credential" is one query.
- **Resolution happens at dispatch, never at authoring.** Same rule as `{{env.*}}`
  in `YAML.md`: substituting earlier would put a secret in a stored definition
  and make the recorded task input a lie about what was sent.

### 15.4 What this does not decide

Which manager. Kubernetes Secrets via the existing `secret_refs` mechanism,
External Secrets Operator, Vault, or a cloud KMS are all satisfiable by §15.3,
and the choice depends on what the deployment already runs — which is exactly
why this document specifies the seam and not the product.

The one thing worth deciding early, because it constrains the others: **whether a
credential is per-deployment or per-tenant.** Per-deployment is what
the first release assumes and what worker env supports; per-tenant needs the
scope enforcement in §15.3 and probably a resolver that sees the task's `org_id`.
Sources are shared, but a rate limit and a bill are not, and a shared API key
across tenants makes the §8 budget a fiction.

---

## 16. The connector — connect, auth, page, store, adapt

**Mapping is deliberately not in this section.** A connector's job is to reach a
source, get the bytes onto durable storage, and turn them into records where it
can. Mapping those records onto resources, entities and moments is a separate,
smaller step that is easier to specify once the pulling is understood — and
a prototype runner (not published) implemented everything below, exercised
against the full catalogue.

### 16.1 The declaration

Four blocks. Nothing else is needed to pull a source.

```yaml
id: openfda_faers
connect:
  url: https://api.fda.gov/drug/event.json?limit=5
  headers: {}
auth:    {type: none}
paging:  {type: link_header}
expect:  {kind: json, min_records: 5}
```

```yaml
id: sec_submissions
connect: {url: "https://data.sec.gov/submissions/CIK{{cik}}.json"}
auth:    {type: user_agent, template: "Percolate Research you@example.com"}
paging:  {type: none}
expect:  {kind: json, min_records: 1}
```

`auth` shapes are §15.2's closed set. `paging` is §4.1's closed set. `expect` is
new and §16.4 is why.

### 16.2 The store — three tiers, and the first one always succeeds

```
store/
  raw/<source>/<date>/<seq>-<sha8>.<ext>       always written
  parsed/<source>/<date>/<seq>-<sha8>.jsonl    when an adapter handled it
  meta/<source>/<date>/<seq>-<sha8>.json       url, status, headers, checksum, counts
```

**Writing the raw bytes is the floor and it is unconditional.** If every adapter
fails we still have the payload with a checksum, which is the difference between
a bad parse (fix the adapter, re-run over what is on disk) and lost data (fetch
it again, if the source still has it, if the budget allows). A PDF that no
adapter understands is stored, marked `opaque`, and that is a **successful
outcome** — `arxiv_pdf` stores 2.1 MB and produces zero records, exactly as
intended.

`meta/` exists so the store is queryable without re-reading payloads: it carries
the `ETag`, the `Link` header, the record count and the adapter's verdict, which
is what §6.1's partition index is built from.

### 16.3 Adapters

One function per wire format, registered by name, chosen by sniffing the bytes
rather than trusting `Content-Type`:

| Adapter | Handles | Produces |
|---|---|---|
| `json` | JSON | records, plus the detected layout (§13.2) |
| `xml` / `rss` / `atom` | feeds and generic XML | records; flags when the record element was **guessed** |
| `csv` | delimited text | records |
| `html` | pages | one record: title + stripped text |
| `text` | plain text | one record per line |
| `pdf` / `binary` | anything else | **no records** — stored only |

Adding a format is registering a function. Nothing else in the connector changes,
and the `binary` adapter returning nothing is a normal path rather than an error
branch.

### 16.4 HTTP 200 is not success

`stooq.com` answers a CSV request with **status 200 and a JavaScript
bot-challenge page**. The HTML adapter parsed it happily into one record, so
without a check the pipeline records a successful fetch of nothing — the worst
available outcome, because nothing anywhere is red.

`expect` makes the contract explicit and the failure loud:

```yaml
expect: {kind: csv, min_records: 10, fields: [Date, Close]}
```

Plus one unconditional check: a body matching a bot-challenge signature
(`enable javascript`, `verify your browser`, `captcha`, `Just a moment`) fails
regardless of what was declared. Run against `stooq_csv` this produces three
violations where there had been silence.

A violation also **stops paging**. Following a next-link from a challenge page
walks into the challenge repeatedly.

### 16.5 What was actually pulled

The connector was run over the whole catalogue.

```
sources pulled      100 / 113
pages fetched       129
records extracted    45,992
bytes stored         22.3 MB across 451 files
```

Adapter usage: 109 JSON, 7 RSS, 4 Atom, 4 XML, 3 HTML, 1 text, 1 binary.
One source landed `opaque` (`debian_udd_rss`, gzip with NUL bytes) — bytes on
disk, no records, correctly not an error. One violation caught (`stooq_csv`).

**All five paging kinds were driven, not inferred.** Fifteen sources were paged
three deep — `link_header`, `page_token`, `next_url`, `page` and `offset` — and
every one returned **genuinely distinct records** across pages, verified by
hashing each record and comparing sets. That closes §13.14's first open item:
paging was previously specified from envelopes and headers alone, and is now
exercised.

### 16.6 Then mapping, which is the small part

With bytes on disk, records extracted, layouts known and gotchas recorded, the
remaining step is a projection from record fields onto the three targets. It is
a small language over paths that already exist in `source_schemas`, and it is
deliberately left until the pulling is boring — a mapping written against a
source nobody has successfully paged is a mapping written against a guess.

---

## 17. Registration — a connector is a row, over PostgREST

§16 built the runner. This is how a source gets into it, and the answer is the
one the rest of the collection already gives: **it is a row, reachable over the
REST surface PostgREST generates, with no code path for adding one.**

`connectors.sql` is the DDL. `content.connectors` carries §16.1's four blocks as
columns, plus the observed state the runner writes back.

### 17.1 The round trip, run against a live stack

```bash
# register a source nobody has ever run
curl -X POST http://localhost:3000/connectors -H "Authorization: Bearer $TOK" \
  -d '{"id":"wikimedia_search","category":"culture",
       "url":"https://api.wikimedia.org/core/v1/wikipedia/en/search/page?q=postgres&limit=5",
       "paging":{"type":"none"},"expect":{"kind":"json","min_records":1}}'
# 201

# the runner reads rows, not code
row  = GET /connectors?id=eq.wikimedia_search
out  = run(Source(**row))            # 5 records, 2954 bytes, layout=objects
POST /rpc/report_connector_run       # observed state written back

GET /v_connectors?id=eq.wikimedia_search
# last_status=ok  last_records=5  last_layout=objects
```

Verified end to end against PG19 beta3 and PostgREST 12.2.8: **304 connectors
registered over HTTP**, one of them a source added during the demonstration
itself and fetched without touching a line of code. (This ran as
`authenticated`; registration now needs the operator role.)

The failure path was exercised too, and by accident, which is better. The first
new source registered (`eu_ted_notices`) turned out to need `POST` rather than
`GET` and returned 405 — and the loop recorded it honestly: `last_status=error`,
`last_error="page0: HTTP 405"`, visible in the view. A registration surface that
only demonstrates the happy path has not been demonstrated.

### 17.2 The closed sets are enforced, not documented

A trigger validates `auth.type` and `paging.type` against §15.2's and §4.1's
taxonomies, so a typo is a rejected `INSERT` rather than a worker crash at 03:00:

```
POST {"auth":{"type":"magic"}}    -> unknown auth type magic
POST {"paging":{"type":"scroll"}} -> unknown paging type scroll
```

And one rule that is a security boundary rather than a spelling check:

```
POST {"auth":{"type":"bearer","value":"sk-live-abc123"}}
  -> auth may reference a credential by name, never carry its value
```

§15.1 says the database holds a name and never material. **That is now enforced
by the database rather than asserted by this document** — a row that looks like
it carries a secret is refused, which is the difference between a convention and
a property.

### 17.3 Permissions fall out of the existing model

`content.connectors` has no tenant column, so it is operator data and the grants
say so. `connectors.sql` revokes everything on the table and its views from
`web_anon` and `authenticated`; `app_owner` reads and writes the table, and
`worker` can only select it and the views. Registering a connector is an
operator action — the demonstration in §17.1 ran as `authenticated`, before the
grant was narrowed. A signed-in grant comes back when the table takes scope
columns.

`due_connectors()` and `report_connector_run()` are `SECURITY DEFINER` RPCs so
the runner needs no write grant, matching how `worker` reaches the
workflow engine.

### 17.4 Two tables describe a source, and only one of them is wired up

The contradiction §4 now points at, stated plainly because it blocks more than
it looks like it does.

| | `content.channels` | `content.connectors` |
|---|---|---|
| Introduced by | `brief.md` §2, `schema.sql` | §17, `connectors.sql` |
| Key | `uuid`, unique on `(org_id, name)` | `text` id |
| Carries | `kind`, `config jsonb`, `poll_interval` | connect / auth / paging / expect, rate, quota, credentials, valuation, `enabled`/`health` |
| Rows in the demonstration stack | a handful, from uploads | **304**, registered over PostgREST |
| Referenced by | `content.resources.channel_id` (FK), `content.register_fetched` | **nothing shipped** |
| Has a runner | no | a prototype, not published |

So the table that is wired into the content plane has no runner, and the table
with a runner is wired into nothing. `content.connectors` contains no reference
to `channels`, `resources`, `files` or `workflow` — the runner's output goes to
§16.2's `store/` directory on a worker's filesystem and stops there. **304
registered connectors have produced zero `resources` rows.**

Three consequences, in increasing order of how expensive they are to discover
late:

- `register_fetched(p_channel text, …)` resolves a channel by *name* within an
  org; the runner holds a connector's text `id`. The two identity schemes do not
  meet, so there is no call the runner can currently make.
- §16.2's raw tier is exactly `content.files` with a different spelling —
  content-addressed bytes with a checksum. Keeping it on a filesystem forfeits
  dedup, RLS, and the `resources` join that `SEARCH`/`SEMANTIC` need.
- **It blocks the consumer.** A claims consumer needs every claim to reproduce
  its quoted text from the stored source, and a claim references
  `resources(id)`. Nothing pulled can be cited until fetched bytes land as a
  resource. Separately, any independence graph keyed on `channels(id)` reads
  the emptier table, while the registrant, licence and URL evidence that would
  populate it lives on `connectors`.

**The recommendation, not yet applied.** `connectors` is the declaration and
`channels` is the lineage anchor: add `channels.connector_id → connectors(id)`,
one-to-many so a connector with several streams gets a channel each, and give
`register_fetched` a connector-keyed sibling. That keeps the FK `resources`
already depends on, keeps the registration surface that is demonstrably working,
and moves §4's unbuilt column list onto `connectors` where the runner can read
it. Folding the two the other way means re-registering 304 rows and rewriting
the live round trip in §17.1, for no gain.

This is recorded as a decision to take rather than taken, because it is a schema
migration against a table with committed rows and it wants one deliberate change,
not a paragraph.

---

## 18. The wide run — 302 sources

The connector was pointed at 302 sources: the original 113 plus 189 open,
zero-auth APIs chosen to stress the range rather than the count — space,
seismology, transit feeds, package registries, museums, bioinformatics, crypto,
sport, language, and a deliberate tail of trivial public APIs.

```
sources attempted   302
sources fetched     260   (86%)
records            129,939
bytes stored       106 MB
```
### 18.1 What the adapters had to handle

| Adapter | pages | | Layout | pages |
|---|---|---|---|---|
| json | 245 | | `objects` | 192 |
| rss | 20 | | `single` | 32 |
| atom | 6 | | `xml` | 32 |
| xml | 6 | | `keyed_map` | 7 |
| text | 6 | | `columnar` | 6 |
| html | 5 | | `lines` | 6 |
| binary | 1 | | `arrays` / `scalars` / `opaque` | 8 |

**The layout distribution held at four times the sample size.** `keyed_map`,
`columnar`, `single` and `scalars` — the four layouts discovered at n=113 and
absent from the first draft of this document — remain 15% of the corpus at
n=302. Nothing new appeared, which is the useful result: the layout enum looks
closed.

### 18.2 Failures, and none of them are parsing

| | n |
|---|---|
| auth required | 10 |
| DNS / connection | 7 |
| quota (429) | 6 |
| timeout | 5 |
| gone (404) | 5 |
| other | 8 |
| bad request | 1 |

Same conclusion as §13, at scale: **not one source failed because its structure
defeated the approach.** The barriers are credentials, quotas and reachability —
which is why §15 exists and why it is the next thing to build.

### 18.3 The check that earned its place

Two sources returned **HTTP 200 with a bot-challenge page** — `stooq_csv` and
`paperswithcode`. Without §16.4's assertion both would have recorded a
successful fetch of a JavaScript notice. The second one was found only because
the check was already there, which is the argument for adding it before you
know you need it.

One source landed `opaque` (`debian_udd_rss`): bytes on disk, no records, and
correctly not an error.

---

## 19. Operational metadata — limits, credentials, and lifecycle

§17 registers a source. This is what a registered source has to *say about
itself* so that a deployment of three hundred of them is operable rather than
merely large. DDL in `connectors.sql`, transitions exercised against PG19.

### 19.1 Rate and quota are different things

They are routinely collapsed into one number, and the corpus settles it:
`opendota_pro` advertises `X-Rate-Limit-Remaining-Minute: 59` **and**
`X-Rate-Limit-Remaining-Day: 2999` in the same response. One paces requests, the
other is a budget over a period, and a source can be comfortably inside one
while exhausted on the other.

```sql
rate_limit  jsonb   -- {"requests": 10, "per_seconds": 1}       -> §8's rps bucket
quota       jsonb   -- {"calls": 1000, "per": "day",
                    --  "cost_per_call": 0.0004}                 -> §8's budget bucket
```

These feed the two token buckets §8 already specifies, consumed at different
moments — quota at planning, rate at claim.

### 19.2 Advertised limits are the exception, so declared limits are authoritative

**13 of 150 sources — 9% — send any rate-limit header at all.** When they do,
there are four conventions and three reset formats:

| Convention | Seen on | Shape |
|---|---|---|
| `X-RateLimit-{Limit,Remaining,Reset}` | 8 | GitHub-style, the de facto one |
| `RateLimit` + `RateLimit-Policy` | 2 | IETF draft: `"pages";r=99;t=30` |
| `ratelimit-{limit,name,observed}` | 1 | GitLab, with a policy name |
| `X-Rate-Limit-Remaining-{Minute,Day}` | 1 | per-window, no limit value |

`Reset` is seconds-until (`2198`), epoch seconds (`1785303503`), **or** an ISO
timestamp (`2026-09-01T06:25:00Z`) depending on the source — the same format zoo
as §13.5, in a different field.

So `observed_rate` is **evidence, not configuration**: parsed opportunistically
into a jsonb column and used to correct a declared limit, never as the limit
itself. A pipeline that only respects advertised limits is unlimited against 91%
of its sources.

### 19.3 Credentials are declared before they exist

```sql
credentials  text[]   -- names, never material (§15.1)
```

Ten of 302 sources failed with `401`/`403`. Declaring what a source *needs*
means it can be registered before the credential is available, and that the
question "what does this deployment have to supply?" is one query:

```sql
select * from content.v_required_credentials;
--  credential_ref | sources | used_by
--  FRED_API_KEY   |       2 | {census_x, fred_x}
```

A trigger copies `auth.credential_ref` into `credentials` automatically, so the
array cannot silently disagree with the auth block.

### 19.4 Lifecycle: two columns, not one status

```sql
enabled  boolean   -- human intent.   Only a person writes it.
health   text      -- observed state. Only the runner writes it.
```

**Collapsing these loses the difference between "we turned this off" and "it
broke"**, and the cost is re-enabling a source somebody disabled deliberately.
It is the same desired/observed split as `workflow.pools`, and for the same
reason. Verified: a disabled source that then runs successfully ends
`enabled=false, health=ok` — healthy, and still off.

| `health` | Means | Recovers alone? |
|---|---|---|
| `unknown` | never run | — |
| `ok` | last run succeeded | — |
| `degraded` | 429, 5xx, timeout | yes, with backoff |
| `needs_credential` | 401 / 403 | **no** |
| `blocked` | bot challenge behind a 200 | **no** |
| `gone` | 410, or repeated 404 / NXDOMAIN | **no** |

### 19.5 Two transitions chosen from real failures

**One 404 is not `gone`.** A wrong query parameter and a retired endpoint are
indistinguishable from a single response — `nws_alerts` returned 400 for an
unsupported `limit` param, and the URL was wrong, not the source. So 404 needs
repetition before it earns a terminal state. **410 is believed immediately**,
because it means gone explicitly.

**401/403 goes straight to `needs_credential` with no retries.** It will not fix
itself, and retrying an auth failure is a good way to earn a rate-limit on top
of it.

`due_connectors()` then excludes `gone` and `needs_credential` outright and
backs `degraded` off exponentially (capped at four hours). Re-polling a source
that needs a human turns a fixable problem into background noise nobody reads.

`health_since` moves **only when health changes**, so it answers "how long has
this been broken" rather than "when did we last look" — the difference matters
the moment anyone asks how long a source has been down.

### 19.6 The view that gets read at 9am

```sql
select id, health, last_http, action from content.v_connectors_attention;
```
```
 dead_x    | gone             | 404 | endpoint retired or moved -- update url or disable
 openaq_x  | needs_credential | 401 | declare and supply: OPENAQ_KEY
 stooq_x   | blocked          | 200 | bot challenge -- needs a different access route
 busy_x    | degraded         | 429 | transient; backing off
```

Each row carries **what to do**, not just what happened. `blocked` and
`needs_credential` both present as auth-ish failures and have completely
different fixes — one needs a key, the other needs a different route to the data
— which is exactly the distinction a bare status column loses.

---

## 20. The fixture — 372 connectors as seed data

The known-source configuration is kept as a fixture (not published) so a deployment starts with a working catalogue rather than an empty
table. It merges two independently-built lists:

- **302 sources selected to stress the machinery** — every layout, every paging
  kind, every wire format (§18).
- **70 sources selected for value**, from a separately curated catalogue of
  high-value and UK public-record sources, carrying its rubric scores as
  columns.

The two barely overlap, and that is the point: one proves the connector works,
the other says where to point it.

### 20.1 Registered and pulled

All 372 registered over PostgREST, then every one the runner claimed was pulled:

| health | n | records |
|---|---|---|
| `ok` | 298 | 283,405 |
| `degraded` | 48 | — |
| `needs_credential` | 21 | — |
| `blocked` | 2 | — |
| `gone` | 1 | — |
| `unknown` | 2 | — |

**The 21 `needs_credential` rows are the lifecycle working, not a failure.**
Sources requiring an API key were registered deliberately with no key present, so
they classify on first contact and drop out of `due_connectors()` rather than
being retried forever. `v_required_credentials` then answers what the deployment
is missing — 13 distinct keys — which is a shopping list rather than a pile of
401s in a log.

### 20.2 The build order is now a query

```sql
select id, tier, score, noise_tax, clock_is_a_field, health
from content.v_build_order;
```

Which reproduces that catalogue's ranking as data, and adds a column that
document does not have:

```
 gazette_notices        A  24  3  clock_is_a_field=f  ok
 planit_applics         A  23  1  clock_is_a_field=t  ok
 companies_house_search A  23  2  clock_is_a_field=f  needs_credential
 uk_find_a_tender       A  23  2  clock_is_a_field=f  ok
```

**`clock_is_a_field` splits the rubric's C dimension, and it came from checking
rather than scoring.** The Gazette scores C=5 and ranks first; pulling it live
shows a feed carrying only `published` and `updated` — the forward date is inside
notice prose, so extracting it is an LLM step per notice. PlanIt exposes
`consulted_date` and `decided_date` directly. CISA KEV hands back
`dueDate: 2026-09-14` as a typed field across 1,687 rows.

All three are "has a clock" under a 0–5 score. Only two are cheap. A rubric that
cannot express that difference will rank the most expensive source first, which
is exactly what it did.

### 20.3 One registration constraint worth knowing

PostgREST bulk insert requires **every object in the array to have identical
keys** — a heterogeneous batch fails with `All object keys must match` rather
than inserting what it can. The fixture is therefore normalised to a uniform key
set with explicit nulls. Worth stating because the natural way to build a
fixture — omit what does not apply — produces a 400 with a message that does not
obviously mean "add the missing keys as null".

## 21. Whose authority a scheduled fetch carries

This section exists because nothing said it, and a function had been left
ungated on the strength of not knowing. `content.register_fetched` — the entry
point a pull uses to record an item that has no bytes of its own — asked only
whether the caller could act in the org, while its sibling
`content.register_upload` asked `content.may_upload`, which is
`rbac.may_access_org` plus the `resources:create` permission. A signed-in
caller could therefore add a resource to a channel through the fetch path that
the upload path would refuse.

The gap survived review because the fetch path's named caller is a schedule,
and nobody could say what a schedule's authority was. Here is the answer, read
off the code rather than assumed, because the assumption was wrong.

### 21.1 Today a scheduled fetch carries nobody's authority

**It is an operator, not a person.** The caller it was gated for is an
application's registered step function, dispatched
through `workflow.call_step_function`. That path sets `workflow.current_run_id`
and nothing else: it never sets `request.jwt.claims`. So the call reaches this
schema with **no claims**, on the `worker` login, inside a definer context owned
by `app_owner`.

Measured in that exact shape — a `SECURITY DEFINER` function owned by
`app_owner`, invoked by the `worker` login:

```
session_user=worker | is_operator=t | login_can_insert=f | may_upload=f
```

Three things follow, and the third is why the gate is written the way it is:

1. `rbac.is_operator()` is **true** for it — no claims, and `worker` is not a
   login a person arrives through.
2. `content.may_upload()` is **false** for it, because *its* operator arm also
   demands `has_table_privilege(session_user, 'content.resources', 'insert')`
   and the `worker` login holds no table privileges by design.
3. Therefore `register_fetched` **cannot** just ask `may_upload`. Doing so
   would refuse the one caller that exists — an outage dressed as a check.

### 21.2 The rule

```
rbac.is_operator() or content.may_upload(org)
```

- **No person behind the call** — an install, a seed, a registered step
  function — passes on the operator arm. This is exactly the set
  `content.assert_org_write` already admits one line above, so nothing that
  works today stops working.
- **Somebody behind the call** — every request over PostgREST, and the
  `execute_as_viewer` path, since `api_viewer` is a *direct* member of
  `authenticated` and so is correctly not an operator — must satisfy
  `content.may_upload`: a member of the org who holds `resources:create`.

`resources:create` is asked in exactly one place in this collection,
`content.may_upload`, and both `register_*` functions ask it there. That is
what stops them drifting apart a third time.

A signed-in caller cannot reach the operator arm by emptying their own claims:
`user-rbac/roles.sql` §6 took `set_config` away from PUBLIC and left it with the
roles that set identity on someone else's behalf.

### 21.3 What is still owed, and where it belongs

The rule an operator would *want* is "the source owner must hold
`resources:create` in the channel's org" — authority following provenance, the
way `workflow.tick()` already stamps `runs.owner_id` from `schedules.owner_id`.
**This subsystem cannot state that rule yet, and saying so is the point of this
subsection.** The run owner is known at dispatch and then dropped:
`workflow.call_step_function` does not set `{"sub": <run owner>}` for the call,
so by the time a step function reaches `content.register_fetched` the person is
gone.

Two functions in this very subsystem show the shape the fix takes —
`content.lake_resolve` and `content.source_passages` both set the run owner's
claims transaction-locally and put them back, and `workflow.execute_for` does it
for inline `sql:` steps. When `call_step_function` does the same, a scheduled
fetch becomes a person and this section's rule tightens on its own with no edit
here: `is_operator()` goes false for it and `may_upload` asks the owner. That is
the whole reason the predicate is written as a disjunction over
`rbac.is_operator()` rather than as a bespoke owner lookup.

Until then, what an operator gets is the narrower guarantee that was actually
missing: **nobody can use the fetch entry point by hand to write content into a
channel they could not upload to.** The two paths refuse the same people.

Asserted behaviourally in `dev/tests/content/09-fetched-authority.sql`, and
declared in `dev/tests/rbac/14-every-reachable-definer-says-how-it-authorizes.sql`.

## `content.source_state`

One row per pulling channel, holding everything a resumable pull needs and
nothing a reader needs: the durable `watermark` and the `pending_watermark` not
yet earned, the `next_url` and the pages already visited, a hash of the last
page to notice a source that repeats itself, the task currently claiming the
source and the last one that finished, and counters for pages, inserted,
updated, unchanged and total records.

Separate from `content.channels` rather than columns on it, because a channel is
configuration a person writes and this is progress a worker rewrites on every
page. One `revision` column makes the write a compare-and-set, so two workers
that both claimed the source cannot interleave their watermarks. Without it a
pull would restart from the beginning after any interruption, or advance a
watermark for records it had not yet landed.
