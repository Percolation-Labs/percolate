# Ingestion — what happens to a file after it is uploaded

`brief.md` §3.5 calls upload-to-answerable **the primary use case for content
upload existing at all**, and until this document it was the one thing in the
content plane that had never been run. The pieces each existed: the Content
Server stored bytes and started a workflow, `content.record_chunks` wrote
chunks, `aiq.semantic_in` searched them. Nothing in the collection ever turned
a PDF into a chunk, and nothing anywhere wrote a vector into an embedding
space — every vector in `aiq.emb_demo_quad_a` is a hand-written literal in a
fixture that says so in capitals.

This document is the missing middle. The rule it is written to is that a
default must be **light, replaceable and honest about what it cannot read** —
and the shape it arrives at is one parse feeding two indexes: chunks and
vectors for retrieval, nodes and edges for the graph.

---

## 1. The pipeline, and how little of it is code

`content.install_ingest_workflow()` writes this definition
([`ingestion.sql`](ingestion.sql)); the `uploads` channel names it, so
`POST /files` starts it:

```yaml
name: ingest_file
steps:
  - id: parse                       # parse, chunk, record
    work: true
    queue: ingest
    input: {op: ingest, resource_id: '{{run.resource_id}}'}

  - id: embed                       # SEMANTIC index: every chunk, batched
    needs: [parse]
    work: true
    queue: ingest
    input: {op: embed, resource_id: '{{run.resource_id}}',
            model: text-embedding-3-small}

  - id: graph                       # GRAPH index: one extraction per window
    needs: [parse, extractor_format]
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template: {queue: http, rate_key: structure_extraction, rest: …}

  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
```

**Two indexes, one parse, and they are siblings rather than a chain.** `embed`
and `graph` both declare `needs: [parse]`, so a deployment with no embedding
model can still index a graph, a failed extraction does not cost the vectors,
and the two run concurrently over the same text. The graph branch is **off by
default** (`p_graph_index => true` turns it on): an embedding per chunk is
cheap and is the whole point of an upload, while a completion per window is a
different order of money — the one place in this pipeline where the default is
cost rather than capability.

No url appears in any of it. The worker asks `aiq.embed_batch_call()` for the
embedding endpoint, request shape, response path and credential *name*; the
extractor's system instructions and output schema come from its row in
`agentic.agents` via `aiq.extractor_call()`. Both models live in exactly one
place and naming one here is naming a registered thing.

**Chunking is code, and that is the design.** `brief.md` §3 refused `chunk:` as
a workflow shorthand because "the strategy is a decision the author has to
make". percolate-core ships a default implementation of that decision; the step
stays `kind: work` on its own queue so that replacing it is running a different
worker, not patching this one.

### Why the embed step is `work` and not a matrix of `embed:`

The declarative shape — a `matrix:` over the chunks with an `embed:` template
and `aiq.land_embeddings` as the fan-in — is written, tested, and still the
right way to embed a **query**. It cannot be the way to embed a **corpus**, for
a reason that is structural rather than a missing feature:

- it is one HTTP request per chunk, where every provider accepts an array
  (OpenAI takes 2048 inputs in one call);
- and it **cannot be batched**, because a step's output is capped at
  `workflow.max_payload_bytes` (64KB) and one 1536-dimension vector is ~31KB of
  JSON. *Two vectors do not fit in one task output.* Any design that carries
  corpus vectors through `tasks.output` is limited to batches of one or two
  whatever else it does.

So the process that receives the vectors is the one that writes them
(`aiq.record_embeddings`), and what comes back to the engine is a receipt:
`{"embedded": 412, "requests": 5}`. Measured on this collection's fixtures: an
eight-chunk document goes from eight requests and eight task rows to **one
request and one task row**.

`chunks_to_embed` — the function `workflow-engine/YAML.md` has used as its
per-row-embedding example since `matrix:` was written, and which did not exist
— is what both paths read, so the fan-out shape stays available and the
documented example is finally true. `windows_to_index` is its counterpart for
the graph branch, named by `graph-index.md` §6.2 and equally absent until now.

### The graph branch, and what it landed

`graph.sql` (a separate design, `graph-index.md`) supplies the vocabulary, the
upserter and the schema; this pipeline supplies the trigger. Measured on the
five fixtures: **~90 soft nodes and ~70 extracted edges** --
counts that move between runs, because a model is doing the reading -- with
every extracted edge carrying the resource, the run and the agent that produced
it, and every relation inside the closed vocabulary. `Bellhaven Metals`, `Ravensworth
Precision`, `harmonic drive assembly` and `Kestrel line` are nodes because
documents named them — one upload, two indexes.

**The extractor is a row, and only the transport is not.** `graph-index.md`
§6.1 writes this step as `agent: structure_null`, which is right and
ran nowhere while the Agent Runtime served only `POST /chat` and refused
`stream: false`. It now serves the compiler's `/v1/chat/completions` route too.
The pipeline still calls `aiq.extractor_call()`, which reads the system
instructions and the output schema **from the agent row** and emits an ordinary
`rest:` call, so the agent stays the unit of authorship; moving the step to
`agent: structure_null` and deleting the function is the remaining change.

---

## 2. What happens per file type

The family is decided from the content type, falling back to the extension —
never from `application/octet-stream`, which is what every uploader sends when
it does not know and which is treated as silence rather than as a family.

| family | mode | reader | why this one |
|---|---|---|---|
| markdown, text | text | itself | already the intermediate form |
| html | text | stdlib `HTMLParser` | a dependency to strip tags is not one worth having |
| pdf | text | **pymupdf4llm** | reads the PDF's own structure, no model, milliseconds a page |
| docx | text | **python-docx** | a zip and some XML, in document order |
| wav/mp3/m4a/… | text | **a transcription endpoint** | a model call, and model calls belong to the worker |
| csv/tsv/xlsx/parquet | tabular | **pyarrow → Parquet** | a table is not prose; see §6 |
| images, unknown | store | none | registered, retrievable, not pretended to be text |

**Everything text-shaped is normalised to markdown before chunking**, and that
is the decision the rest follows from. Chunking each format from its own
structure would be three chunkers with three sets of edge cases; normalising
first means one, and it means the passage a model is eventually shown still
carries the heading and the table that told a reader what the sentence was
about.

### The libraries, and the ones deliberately not chosen

- **`semchunk`** for chunking. The recursive character splitter most pipelines
  use (LangChain's, and its copies) splits on a separator list and takes
  whatever length falls out; semchunk splits on the most semantically
  significant boundary that fits the budget — sections, then paragraphs, then
  sentences, then clauses. On Isaacus's legal-RAG measurement that is worth
  ~8% correctness over recursive splitting and ~12% over fixed-size. It is
  pure Python with no model behind it, and it returns **offsets**, which is why
  `resource_chunks.start_offset`/`end_offset` are finally filled after existing
  unused since the table was written.
  *Not enabled:* semchunk's AI chunking mode (`chunking_model=`) is worth
  another ~6% on that benchmark and is a paid API call per document, on the
  step that runs for every upload. A deployment that wants it has an obvious
  place to say so; a default that silently bills per document is not shippable.
- **`pymupdf4llm`** for PDF. Docling and MinerU are better on scanned and
  multi-column documents and cost 1–2GB of model weights and 5–30× the time —
  the right opt-in, the wrong default. Worth stating plainly: since 1.28
  pymupdf4llm pulls `pymupdf-layout`, which pulls `onnxruntime` (~75MB), so the
  "light" claim is weaker than it was. `parser: pymupdf` is the same text
  extraction with none of that, kept as a named parser rather than as a
  fallback so the downgrade is reproducible instead of depending on what
  happened to be installed.
- **`python-docx`** for DOCX, and not MarkItDown, which covers more formats and
  pulls `magika` (onnxruntime again) to guess types we are already told.
  Kreuzberg was the other candidate and is the same trade: more formats, more
  weight, an OCR stack behind it.
- **No OCR anywhere.** A scanned PDF has no text layer, and the parser
  **raises** rather than returning three characters — see §5.

### Transcription

The default is one HTTPS call to an OpenAI-shaped `/audio/transcriptions`
endpoint, with the credential resolved **by name** from the worker's
environment exactly as an `http_call` step's `credential_ref` is. A local model
is not the default: `faster-whisper` is excellent and is a model download, a
CTranslate2 build per platform, and a first run that fetches weights from the
internet inside a worker whose contract is small restartable units of work.
Pointing at a local server is a URL, not a code path:

```yaml
transcribe: {endpoint: "http://whisper:9000/v1/audio/transcriptions",
             model: whisper-large-v3, credential: LOCAL_NOOP}
```

which is the same "one S3-compatible client, always" reasoning the Content
Server uses for storage.

---

## 3. Policy: defaults in code, overrides in the database

Three layers, later winning key by key **at every depth**:

```
family default   percolate_core.ingest.policy   a fact about a format and its library
      ↓
channel          content.channels.config.ingest_policy       the deployment's
      ↓
upload           content.resources.metadata.ingest_policy    the uploader's
```

The split is the argument. Defaults are statements about libraries — they
change when the library does, in the same commit — so a table of them is a
second place to be wrong, kept in step by hand by the person who just changed
the code. Overrides are statements about a deployment's content, made by the
person uploading, who is not the person deploying the worker.

Layers 2 and 3 merge in the database (`content.merge_policy`, a deep merge) and
arrive at the worker as one patch. **The merge is deep** because a shallow `||`
lets an upload that sets one chunking field erase the channel's other chunking
fields silently — the uploader would then be running a strategy nobody chose.

The override is a **pydantic model**, and it is strict:

```python
class IngestPolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")
    mode: Literal["text", "tabular", "store", "skip"] = "text"
    parser: str | None = None
    chunking: ChunkPolicy      # target_tokens=700, overlap=0.08, tokenizer, min_chars
    transcribe: TranscribePolicy
    table: TablePolicy         # name, mode=append|replace, partition_by, delimiter
    keep_markdown: bool = True
```

`extra="forbid"` is the load-bearing line: a policy with a misspelled key is
refused **by name**, because a silently-ignored override is a chunking strategy
the uploader believes is in force and is not. A policy that does not validate
fails the step *terminally* — it will not validate on the fifth attempt either.

```sql
-- every PDF on this channel chunks small and keeps no markdown
update content.channels
   set config = content.merge_policy(config, '{"ingest_policy":
        {"chunking": {"target_tokens": 300}, "keep_markdown": false}}'::jsonb)
 where name = 'contracts';
```

### API sources are the other way round

An `http_pull` source's `api` block (`api-sources.sql`) keeps its defaults in
the database, in `percolate.types` as `content.api_source`
(`specs/contract/types/content.api_source.yaml`). The argument above does not
carry over. Those defaults describe no library. They say what a row means
when it leaves a key out, and three writers produce these rows: the UI,
`content.save_api_source` called by an agent or from SQL, and a package through
`percolate.apply_package`. When each reader kept its own answer, a source saved
without `watermark_type` pulled as `timestamp` in the worker and was guarded as
`none` in `content.commit_api_page`, so a late, older version of a record
replaced the newer one.

So there is one rule. `content.validate_api_source` is what every writer calls:
it refuses a key the type does not declare, a value outside an enum, and a
literal credential, and it returns the complete block, which the writer stores.
`content.api_source_settings` lays the declared defaults under a stored block,
and every reader (`begin_api_pull`, which hands the worker its settings, and
`commit_api_page`) reads through it, so a row saved before blocks were stored
whole means what the worker always took it to mean. `percolate.enums()`
publishes the three vocabularies (`auth_type`, `pagination`,
`watermark_type`). percolate-core's `APIConfig` and the UI's `API_DEFAULTS`
remain copies, and each is tested against `contract.json`.

#### Whose run a pull returns

`content.start_source_pull` hands back a run id, and the section above said
nothing about whose. That gap was a cross-tenant leak for as long as it stood.

The function is idempotent by design: pulling a source that is already being
pulled should return the pull in flight rather than start a second one. It
resolved "already being pulled" as *any running run of the workflow this source
names* — and `content.channels.config.ingest_workflow` may name a workflow that
is not this source's own. `content.save_api_source` mints a per-source
definition (`source_<uuid>`), but a channel built any other way can name a
shared one, and `ingest_file` is shared by every tenant because **workflow
definitions are installation-wide by design**. So the newest running
`ingest_file` run belonged to whoever had most recently uploaded anything, and
pulling your own source returned it:

```
ana run:    01a09308-…  (owner …000a, status running)
bo got run: 01a09308-…  owned by …000a, input {"who": "ana, privately"}
```

**A shared definition name is not a tenancy.** The owner check the function
already had is about the *channel*; it says nothing about the *run*, and the two
objects need separate questions.

The rule, therefore:

1. **A pull returns a run the caller may see, or a new one.** The lookup filters
   on `workflow.may_access_run(run, 'select')` — the predicate extracted
   from `assert_run_access` — so it is the same question the engine asks
   everywhere else about a run. A third hand-written copy of "may this person
   see this run" is how the first two drifted.
2. **Your own run wins.** The result is ordered to prefer a run the caller owns
   before one their permissions merely reach, so an administrator holding
   `workflow_runs:select` — who can see every tenant's runs — still gets their
   own in-flight pull back rather than whichever started last. This is
   `workflow.reusable_run`'s ordering, and the two are deliberately the same
   shape: both answer "is there an existing run for this request?"
3. **Overlap is the workflow engine's idea, not a second one.** This check is a
   hand-rolled cousin of `overlap_policy` (`workflow-engine/spec.md` §12b). It
   stays hand-rolled for now, but it is scoped like the engine's rather than by
   a name that spans tenants.

**What remains, stated because it is a real limit and not a leak.** Two sources
owned by the *same* person that both name one shared `ingest_workflow` still
share an in-flight run: pulling the second returns the first's id. Scoping to
the source rather than to the definition would need the run to carry
`source_id`, and it does not — `start_source_pull` calls `start_workflow` with
`'{}'` and the step reads `source_id` from the definition. Changing what a run's
input means did not belong in a security fix; it is recorded as an open limit.

Asserted in `dev/tests/content/04-api-sources.sql`, with two owners whose
sources name the same workflow, and declared in
`dev/tests/rbac/14-every-reachable-definer-says-how-it-authorizes.sql`.

The workflow step names its source by `source_id` when `save_api_source` wrote
it and by `source_name` in a package. That is two keys, not two names for one:
a package is installed into databases whose ids it cannot know, so it resolves
by name under the run's owner (`begin_named_api_pull`).

### Why 700 tokens

The instinct in most RAG code is 200–400, and it is wrong for what this
collection does with a chunk: it is retrieved, shown to a model, and **cited**.
A 250-token chunk retrieves the sentence that matched and loses the sentence
that explains it, so the model answers from a fragment and the citation points
at one. 700 tokens is roughly two to three paragraphs of prose. Ranking gets
blunter only when one chunk holds several unrelated things, which at that size
it does not. Transcripts default lower (450) with more overlap: no headings, no
blank lines, nothing structural to cut on.

The token counter defaults to **characters ÷ 4**, offline. tiktoken is a better
count and downloads its encoding on first use — a container that boots without
egress then fails inside the chunker, which is a bad place to discover a
network policy. `tokenizer: "tiktoken:cl100k_base"` when the exactness is worth
that.

---

## 4. The embedding half, and the space skew it cannot have

`embed:` produces a vector and hands it to the next step. That is right for a
*query* — embed the question, rank, discard — and it was the whole story the
collection had. Embedding a *corpus* is the other direction: N vectors that
must be **kept**, keyed by chunk, in the space of the model that produced them.
Nothing could write one. There are now two functions that can, and the split
between them is §1's payload-cap argument:

- **`aiq.land_embeddings(matrix_task)`** — the fan-in for a declarative
  `matrix:` of `embed:` children. One vector per child, through `tasks.output`.
- **`aiq.record_embeddings(model, rows)`** — a whole batch at once, called by
  whatever process holds the vectors. This is what the shipped pipeline uses.

Both write the same space, both replace on conflict, and neither takes a
dimension: the model names the space.

**The model is not an argument to `land_embeddings`**, and that is the point of
its shape. The obvious signature — `land_embeddings(matrix_task, model)` —
reintroduces one
step later the exact defect `aiq.expand_embed_steps` exists to remove: the
author names the model twice, the two can disagree, and vectors from model A
land in model B's space with no error and no dimension mismatch when the two
are the same width. So the model is read off each child's own task input, where
`embed_call` recorded it. The vector and the name of the space it belongs in
travel on one row, and there is no second place to state it.

Re-embedding a chunk replaces its vector (`on conflict (chunk_id) do update`):
re-ingesting a resource whose text changed must not leave the old vector
ranking against the new text.

---

## 5. Failing loudly, where the failure is silent by default

Three of these were written because the failure mode is a pipeline that reports
success:

- **A parse that yields nothing raises.** A scanned PDF, an empty file, a
  content type that lies: the parser returning "" would produce zero chunks,
  a resource marked `stored`, and a file silently absent from every search
  anyone runs. The message names the likely cause for the parser that ran.
- **`ready` means "in the corpus".** `record_ingest` marks a resource `ready`
  only when it wrote chunks, and `stored` otherwise — because
  `content.check_drift()` reports a ready-with-no-chunks resource as a writer
  bug and would be right to.
- **A missing vector raises.** If an embed child completed with no `result`
  (its output was offloaded as an artifact for exceeding the payload cap),
  `land_embeddings` refuses rather than landing the rest: a chunk silently
  absent from a space is a hole in a corpus that still answers questions.

---

## 6. Tabular: Parquet in the lake, and exactly how Iceberg-like that is

> **There is now an Iceberg path, in [`lake.md`](lake.md).** An upload still
> becomes the prefix-and-glob dataset described here. A `refine` step can write
> an Iceberg table through a REST catalog, registered in the same
> `content.datasets` with `format = 'iceberg'`, and `dataset_uri` returns
> `iceberg:<table_ref>` for it rather than a glob that would read deleted rows.
> lake.md §8 records that this section's `mode: replace` does not stop a reader
> seeing the replaced files.

Chunking a CSV is a category error, and it is the default in most RAG
pipelines. Two hundred rows of a price table become two hundred
near-identical embeddings that rank against each other and answer nothing: ask
"what was August revenue" and retrieve five rows that all look equally like the
question. A table's query language already exists.

So a tabular upload converts once to Parquet (typed, columnar, compressed,
read by everything), lands in object storage beside the original bytes, and is
registered in `content.datasets` — chunk count zero, status `stored`. The
column list comes from the Arrow schema the conversion actually produced, never
from a CSV header, because a header is names and a query needs types.

```sql
select content.dataset_uri('incidents');
-- s3://p8-content/datasets/incidents/*.parquet
```

```python
tabular.read_dataset(uri, "select site, sum(downtime_hours) from dataset group by 1")
```

**How Iceberg-like this is, precisely**, because the phrase invites more than
is here: files for one dataset land under one prefix, and `mode: append` means
the reader globs it, so this month's export joins last month's under one name.
That is all of it — no manifest, no snapshot isolation, no schema evolution, no
time travel, no compaction, no deletes. What breaks first is a schema change
between two files under one prefix, which DuckDB will union by name or refuse
depending on how far apart they are. Iceberg exists because those are hard;
when a deployment needs them it needs Iceberg, and the migration is a
`read_parquet` into a table, not a rewrite of this path.

`mode: replace` forgets the dataset's other members and **does not delete
objects**: the bytes stay content-addressed and reachable through their own
resources, and an object no dataset points at is what `check_drift()` is for. A
registry that deleted from a bucket would be a second deletion authority over
content nobody said to destroy.

---

## 7. What running this found

Every item here was found by executing the pipeline rather than by reading it.
The first four and the seventh are fixed, the fifth and sixth are handled where
they surface and named where the fix belongs, and the last two are open. Items 8 and 9 came out of
writing the worked examples in `dev/examples/` rather than out of the pipeline
run: a cookbook has to state what a function does, and stating it is what
found that two of these did something else.

1. **A `rate_key` naming a bucket that does not exist parks the task forever.**
   `claim_task` consults `try_consume_rate_limit`, which does
   `update workflow.rate_limits where key = …` and returns false when there is
   no row — so the task is never claimed **by anyone**, while the worker beside
   it reports an empty queue. Measured, when the embed half was still a fan-out
   carrying `rate_key: embeddings`: fourteen children, eight done, six sitting
   in `ready` with no error, no retry and no dead task. `rate_key` reads like a
   declaration and is a reference. The embed branch stopped naming one when it
   stopped fanning out; the graph branch still does (`structure_extraction`,
   because completions and embeddings hit different provider limits), so the
   installer creates the bucket it names. That is a workaround at one call
   site: `workflow.plan_graph` now reports it as `unknown_rate_key` and
   `workflow.v_unclaimable` lists the stuck tasks; `define_yaml` still accepts
   the definition.
2. **`work` steps had their templates resolved nowhere.** `{{run.resource_id}}`
   reached the handler with the braces intact: `http_call` resolves inside
   `build_request` and nothing did it for `work`, so every handler would have
   had to know to call `resolve()` itself. The worker now resolves for `work`
   before dispatch — and deliberately not for `http_call`, whose payload can
   legally contain braces (a chunk of text on its way to a model), where a
   second pass would turn data into a missing reference.
3. **A pre-dumped JSON string sent to a `jsonb` parameter arrives as a jsonb
   *string*.** The pool installs a codec whose encoder is `json.dumps`, so
   `json.dumps(outcome)` is encoded twice: `p_outcome ? 'chunks'` is then
   false, no chunks are written, the resource goes `stored`, and the step
   reports success. Five text uploads landed that way in the first run, with no
   error anywhere.
4. **`unique (org_id, name)` did not constrain a null org.** NULLs are
   distinct in a unique index unless it says otherwise, so
   `on conflict (org_id, name)` in `register_dataset` matched nothing and every
   append inserted *another* dataset of the same name. `content.channels` has
   the same shape and answers it with `where not exists` at each insert site;
   here the constraint is the right place (`nulls not distinct`), because the
   upsert is the API.
5. **A matrix template cannot declare `output_schema`.** The compiler accepts
   `queue`, `p8ql`, `sql`, `rest`, `embed`, `agent`, `work`, `input`, `session`,
   `session_group`, `jsonpath`, `rate_key` and `matrix` inside a `template:` — and not `output_schema`,
   which is the field that parses a model's JSON-in-a-string answer into an
   object before storing it. So every child of a fan-out that calls a model
   lands a jsonb *string* where its fan-in expects an object. This is the
   fourth thing `matrix:` has answered wrongly by omission, after nested
   fan-out, the successors that had to be rewired, and `template: {embed: …}`.
   Worked around in `content.land_graph_windows` (which parses the string);
   the fix belongs in the parser, and that function collapses into
   `aiq.land_graph_fanout` when it lands.
6. **A model mis-numbers edges, and refusing them fails the upload.** Measured
   on the first real extraction: gpt-4o-mini at temperature 0, eight nodes, an
   edge citing `s=7 t=8`. And `r` carries an enum built from the vocabulary
   which OpenAI honours only in *strict* structured-output mode —
   `aiq.graph_schema()` cannot use strict, because strict requires every
   property in `required` and the attribute bag `a` is deliberately optional —
   so a cheap model reaches past it (it emitted `trips` on a document about a
   robotic arm). `aiq.upsert_graph` raises on both, deliberately and with a
   stated argument. The argument is right about a *graph* and wrong about a
   *model*: an ordinal past the end is not a hole in the evidence, it is an
   extractor mis-numbering a list. Both are dropped before landing and
   **counted in the receipt** (`edges_dropped_ordinal`,
   `edges_dropped_offvocab`), which keeps the invariant exactly as written —
   what reaches `upsert_graph` is coherent, and nothing is lost silently. The
   counts are also half the measurement `graph.sql` asks for: which relations
   are ever emitted, and which are being reached past.

7. **Two resources with the same title used to collide in the graph.** The
   document projection keyed nodes on `coalesce(title, uri, id)`, so a shared
   heading raised a unique violation inside the projection trigger and failed
   the parse step. A label is no longer an identity: a resource with a file is
   keyed by its own `external_id` or id, and the title is the summary.
8. **`register_upload` has two dedup keys and only one of them dedups a
   registration.** The checksum dedups the *bytes* in `content.files`;
   `external_id` dedups the *resource* in `content.resources`, whose conflict
   target is `(channel_id, external_id)`. A NULL `external_id` never conflicts,
   so the same upload retried without one produces a second resource over the
   same file — and each resource starts its own ingestion run, so the chunks
   and vectors are written twice. Found writing the worked examples
   (`dev/examples/05-upload.sql`), where the first draft asserted that the same
   checksum returns the same resource id and got `f`. Whether the fix is a
   partial unique index on `(channel_id, file_id) where external_id is null`,
   or making the Content Server mint an `external_id` when the caller gives
   none, is a decision this file should not take alone. Until it is taken:
   **an upload that might be retried must carry an `external_id`**, and it is
   the caller's idempotency key in everything but name.

9. **The file dedup is global, and it hands a tenant another tenant's storage
   location.** `content.files` is unique on `checksum` alone, and the upsert is
   `on conflict (checksum) do update set checksum = excluded.checksum` — so the
   second uploader's `bucket` and `object_key` are discarded and the row keeps
   the first writer's. Two tenants uploading identical bytes therefore share
   one file row, and `content.resolve_file` on tenant B's OWN resource returns
   tenant A's bucket and path:

   ```
   -- as tenant B, resolving a resource B created:
     bucket  |    object_key     |  content_type   | size_bytes
   ----------+-------------------+-----------------+------------
    bucket-a | a/secret-path.pdf | application/pdf |         10
   ```

   Direct reads of `content.files` are correctly denied to `authenticated`;
   this comes back through the supported route. The bytes are identical by
   definition so the *content* does not leak, and the three things that do are:
   A's bucket name and object layout become visible to B, B's resource depends
   on an object A can delete, and a deployment whose Content Server holds one
   credential across buckets will read B's file out of A's bucket. The fix is a
   scoping decision with a real storage cost on the other side — dedup per
   `org_id` and store the bytes twice, or keep one file row and give each
   resource its own `bucket`/`object_key` so the dedup is of content and not of
   location. **Open, and it should be closed before a second tenant shares a
   bucket policy with a first.**

---

## 8. What is not built

- **No OCR path.** A scanned PDF fails loudly and stays `pending`. The opt-in
  (Docling, or a vision model per page) is a parser name away and is not
  written.
- **No image understanding.** Images are `store`. Describing one with a vision
  model is a real feature; defaulting to it would put a model call behind every
  avatar upload.
- **No incremental re-chunking.** `record_chunks` deletes and rewrites every
  chunk of a resource, and `land_embeddings` re-embeds all of them. For a
  100-page document that is the whole document's worth of model calls to fix a
  typo. The shape that fixes it (hash each chunk, embed the ones that changed)
  is obvious and unbuilt.
- **No partial-batch recovery.** A batch that fails after four of five requests
  re-embeds all five on retry: the step is idempotent (`on conflict do update`)
  but not resumable, and the chunks already embedded are paid for twice. The
  fix is to ask for the chunks that have no vector rather than for all of them,
  which is one predicate and is not written.
- **A provider that cannot batch is called N times.** Ollama's
  `/api/embeddings` takes one prompt, so `batch_request_template` is null for
  it and the worker loops — same receipt, same retry, same code path, N
  requests. Correct, and no faster than the fan-out it replaced.
- **Soft nodes wait for the resolver.** Extraction lands *names*
  (`aiq.soft_nodes`); deciding that `Ravensworth` and `Ravensworth Precision`
  are one entity is `aiq.promote_soft_node`, called by the resolver (`percolate_core.resolve`)
  for proposals above its acceptance threshold. Until it has run over a corpus, the graph answers "what did documents name,
  and how did they connect it" rather than "what is there".
- **The graph branch re-extracts everything on re-ingest**, exactly as the
  embed branch re-embeds everything, and a completion costs more than an
  embedding. Same fix, same absence.
- **The graph branch still calls the extractor as a plain `rest:` step** with
  its prompt and schema read from its row (§1). The runtime now serves the route
  an `agent:` step calls; when the pipeline switches, `aiq.extractor_call()` is
  deleted and the step becomes `agent: structure_null`.
