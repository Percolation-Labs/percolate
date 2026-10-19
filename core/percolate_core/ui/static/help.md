# How Percolate works

Percolate turns work you need done into workflows you can run, inspect and repeat. Define the steps and how they depend on each other; Percolate records each run, coordinates execution and applies the configured retry and scheduling rules. Queries, AI agents and calls to other systems are steps you can combine to deliver an outcome.

Start with the job: a recurring operations review, an investigation, or processing incoming records. Decide what goes in, what should come out, where a query gives an exact answer and where an agent needs to interpret evidence. That becomes a saved workflow with explicit inputs, dependencies and results.

## Why the workflow comes first

The workflow gives the work a life beyond a conversation. Each run retains its inputs, task states, outputs and events, so you can inspect what happened and where something failed. An agent supplies reasoning where a step needs it; the workflow defines how that step fits into the larger job.

Percolate puts that coordination in PostgreSQL. Workflow definitions are data, authored as YAML or JSON and managed through SQL or REST. Changing a definition does not require deploying new application code. PostgreSQL owns dependencies, queues, retries, schedules and run state, alongside the permissions and data the work uses. Database steps execute there; workers handle model calls, external services and custom work. The browser and appropriately configured agents use the same permission-checked interfaces to manage the work.

## Try a complete workflow

A workflow combines sources, queries, agents and plugin capabilities into a job; a package carries the definitions for reuse. For example, refresh an API news feed using its watermark, query the latest articles and ask an agent for a sourced brief. Inspect one run, then schedule the whole job.

1. Open [Create a workflow](#/draft) and **Design with AI**. Describe the outcome. **Browse workspace components** searches visible sources, agents, plugins, skills, tool servers and saved workflows. Select components to steer the design, or let AI consider the catalogue.
2. Choose **Suggest a workflow**. Review the outcome, dependencies and component choices. AI can reuse existing components, propose missing API sources or agents, or ask for a missing API contract. The proposal is compiled without registration; drafting has tool calls and chained actions disabled.
3. Choose **Apply to draft**, inspect proposed component definitions and explicitly **Create source** or **Create agent** where needed. Each action has its own receipt. Existing components are reused unchanged. **Review definition & save** opens the workflow for authoritative validation and saving.
4. Use **Run with inputs → Start workflow**, then inspect [Runs](#/runs). **Package** exports source, agent and workflow definitions, with queries inside steps. Review destination requirements for worker queues, provider credentials and named plugin, tool or skill capabilities. The export contains no records or run history; referenced workflows that cannot be exported must be installed separately.
5. When the complete job works, use [Schedules](#/schedules) to repeat it. [Query](#/query) remains useful for developing an individual step; **Use in workflow** opens it in the definition editor. A query-only workflow is valid when it completes the requested job.

For a delayed suggestion, **Stop waiting** returns control and the conversation remains inspectable in Chat. **Previous AI designs → Recover last completed design** retrieves a completed proposal and checks its components and compilation again before Apply. Stopping the wait does not claim to cancel the runtime turn.

If a workflow needs document evidence, add it in [Files](#/files). Ingestion is itself a workflow: a configured channel can parse a file into searchable chunks and compute embeddings. Other workflows can operate on existing database records or connected services without uploading a document.

## Data sources and reusable ingestion

Open [Data Sources](#/sources) when a workflow needs a current feed from an API. Start from the job: for example, keep GitHub issues current so a recurring triage workflow can query open work and produce an action brief. **Configuration** lets you specify the endpoint and ingestion contract; **Ask AI** drafts it from your task and an optional response example. Review the proposal and save the source, then open **Records & progress → Pull now** to test it. A proposal does not itself connect or run anything.

API pulls are workflow runs. Each page commits its records and continuation together. A page limit pauses at a saved checkpoint; **Continue pull** resumes from there. An HTTP failure preserves that checkpoint for retry. The committed watermark advances only when all pages finish. Timestamp overlap re-reads a boundary window, and stable record IDs deduplicate repeats and update changed records. Older timestamp or numeric versions cannot replace newer records.

The current worker supports GET JSON endpoints; bearer or API-key header authentication by worker credential reference; timestamp or numeric watermark filters; Link-header, next-URL, token, page-number or single-response pagination. Configure credentials on the worker and bind each credential to the API's origin. Do not paste secret values into the editor. APIs with OAuth refresh, webhooks, streaming, custom request signing or POST search need additional connector work.

**Transform records** projects or renames fields using dot paths, with optional string, number, boolean, lowercase and trim casts. Original JSON and transformed data are retained in `content.source_records`, scoped to the source. The editor shows recent records, the committed and pending watermark, and links to run receipts. Use Query to inspect the data, then compose a follow-on workflow to interpret or act on it. This ingestion step does not automatically create graph entities, embeddings, destination tables or AI summaries.

Under **New API source → Examples & help**, the **News API example** starts a public Spaceflight News feed from the last seven days, with article IDs, update timestamps and next-page URLs. AI can propose this known example when asked to choose a news API; it cannot browse for arbitrary APIs.

The **GitHub issues example** provides a working public endpoint and known field mappings. GitHub's issues endpoint also returns pull requests. Choose an initial timestamp and page budget for the backfill you want. **Schedule workflow** preselects the ingestion workflow so you can choose its cadence; it does not enable a schedule until you save one.

The **Package** tab previews and exports the current draft's source configuration and ingestion workflow in `manifest.yaml`. The package resolves the source by name under its installation owner, so another workspace starts with independent progress. It excludes records, watermarks, page checkpoints and credential values. Install with `packages/apply.py PACKAGE --owner USER_UUID`; the destination needs the API source database functions, ingestion worker, named queue and credential references. Installation refuses an existing API source with different settings or ownership. Choose a new source name for an independent feed. Exports do not include schedules.

**File & document sources** is the secondary ingestion path. It supports uploaded files or pasted text, parsing and chunking, optional embeddings, and an optional agent transformation for text documents. Transformations return structured run output and accept up to 80,000 characters per document. Tables convert CSV, Excel or Parquet into a registered Parquet dataset. This path remains useful for document evidence; API feeds are the path for ongoing external records.

## Moving around the workbench

Sources, Files, Agents and Schedules separate the collection from the selected editor or preview. Use **Back to list** to return; **Expand** gives a source or document more room on a wide screen. Query’s **Both**, **Editor** and **Results** controls keep the same query and results while changing the available space. **Ask AI** opens assistance; **Query help & options** holds the guide and semantic-search input.

Workflow creation has **Design with AI**, **Definition**, **Run with inputs** and **Package**. Save the definition before starting a recorded run. Existing drafts keep their example starter collapsed. Run details offer **Results**, **Tasks**, **Dependencies** and **History & details**, with failed runs opening Tasks. **Schedules → New schedule** lets you write a cron expression or describe the cadence, review and apply a proposal, then save the schedule separately.

**Files → Add document** opens a full-width upload or paste form. Open a document to inspect processing and **Source preview**; **Back to list** preserves the file search. Choosing a layout or applying a proposal does not save or execute work. Newer query, source and schedule edits are protected from older AI proposals.

## Queries and evidence

Percolate's query language is **p8ql**. Run `SCHEMA` to discover this deployment, and `SCHEMA "p8ql"` for its grammar, registered sources and examples. Do not assume a table, source, column or embedding model exists: inspect the live schema first.

- **TEXT** searches words in registered text sources without an embedding vector.
- **SEMANTIC** uses an embedding vector for similarity search. **SEARCH** combines text and semantic retrieval. Both require a vector matching the selected model. The editor accepts an explicit vector; a configured workflow can compute it. Vectors must come from that embedding model; the editor does not generate them automatically.
- **SQL** supports read-only exploration of permitted relations. `SCHEMA "sql"` lists readable relations; `SCHEMA "sql" FROM content.resources` describes columns if that relation is available. The editor executes a returned SQL plan through the read-only SQL RPC.
- Graph lookup is available where this deployment has registered graph sources and indexed entities. Inspect the live grammar and sources before suggesting syntax.

An AI suggestion is a draft, not proof that a query is valid or will return data. Schema checks help with syntax and available names; executing the query is a separate action. An empty result is different from a permission, service or ingestion failure.

## What happens underneath

PostgreSQL stores document metadata, chunks, agent definitions, conversations, permissions and workflow state. File bytes are served through the Content Server and its object storage. The browser calls PostgREST RPCs with your session; agents run through the agent runtime and call their configured tools. Caller-scoped tools and database permissions determine which data is accessible.

A workflow defines tasks and dependencies. Workers pick up queued tasks, execute them and report results. Runs retain task states and events so you can see what succeeded or failed. [Queues & pools](#/queues) shows the worker side; [Surface](#/surface) checks whether the UI's configured services and database reads are reachable. A healthy connection does not by itself prove an AI provider or a particular task works.

## Getting unstuck

- **Session expired / JWT expired:** open [Account / Sign in](#/signin). The local development workspace can renew its development session automatically or use **Continue to workspace**. Other deployments require a valid access token from their configured authentication provider; this workbench does not supply a password login.
- **A file is missing from search:** inspect the file's ingestion run, extracted text, channel configuration and worker queue. Text retrieval needs parsed chunks; semantic retrieval also needs the correct embeddings.
- **An agent returns irrelevant evidence:** use [Help](#/help) for product guidance. For document questions, name the document and the task, and ask for source identifiers. Check the selected agent's instructions and tools in [Agents](#/agents).
- **A tool or model fails:** inspect the error, run and agent configuration. The task's result shows whether the work completed successfully.

This guide describes the workbench. Live schema and run results show what your deployment supports. Use this guide for product help and your uploaded documents as evidence for your tasks.
