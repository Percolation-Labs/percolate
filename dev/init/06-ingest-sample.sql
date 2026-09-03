-- Sample: file upload, chunked and embedded, end to end.
--
-- 05-corpus-sample.sql seeds a corpus as LITERALS, deliberately, so that
-- retrieval can be tested with no model server anywhere. This file is the
-- other half and it is the opposite bargain: a real embedding model, called
-- over the network, so that "upload a file and it becomes answerable" is
-- exercised as the thing it actually is rather than as a fixture.
--
-- It therefore needs a credential, and it is written so that NOT having one
-- costs nothing: registering a model is a row, `credential_ref` is a NAME the
-- worker resolves from its own environment, and an ingest run on a stack with
-- no key fails at the embed step with a message naming the missing variable
-- rather than at install.
--
-- Runs as app_owner at initdb, after the extension and the corpus sample.
-- Idempotent; safe to re-run:
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8experiment \
--         < dev/init/06-ingest-sample.sql

set role app_owner;

do $$
begin
    -- BY NAME, NOT BY SIGNATURE, and that is a correction rather than a style
    -- choice. This guard was written against
    -- `install_ingest_workflow(text,text,text)`, which ingestion.sql then
    -- DROPPED and replaced with a six-argument version -- so from that commit
    -- onward the check was false on every install, the whole ingestion sample
    -- silently did not run, and the warning blamed a stale image for a
    -- signature change inside the current one. A guard asking "does this image
    -- have the function at all" should not be able to be wrong about that
    -- because an argument was added.
    if not exists (select 1 from pg_catalog.pg_proc p
                     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'content'
                      and p.proname = 'install_ingest_workflow') then
        raise warning
            'skipping the ingestion sample: this database image predates '
            'content.install_ingest_workflow. Everything else installed '
            'normally. Rebuild: dev/build-image.sh';
        return;
    end if;
end $$;

-- ------------------------------------------------------------
-- 1. A real embedding model.
--
-- 1536 dimensions, OpenAI's text-embedding-3-small -- chosen because it is the
-- cheapest widely-available model whose vectors are worth ranking, and because
-- the `openai` provider row already ships in aiq.embedding_providers, so this
-- is genuinely one INSERT and not an integration.
--
-- NOT is_default, and that is a fixture constraint rather than a
-- recommendation: dev/tests/query/08-retrieval.sql §6 asserts that SEMANTIC
-- with no USING resolves to `demo-quad-a`, so moving the default here would
-- break a test of a different surface to make this one convenient. A real
-- deployment has no fixture and should set is_default on its real model:
--
--     update aiq.embedding_models set is_default = false;
--     update aiq.embedding_models set is_default = true
--      where name = 'text-embedding-3-small';
--
-- Until it does, queries against uploaded content name the space:
--     SEARCH "…" FROM chunks USING text-embedding-3-small
-- ------------------------------------------------------------
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, notes)
values ('text-embedding-3-small', 1536, 'openai',
        'https://api.openai.com/v1/embeddings', 'LLM_API_KEY',
        'a real model, called over the network by the worker. The credential is '
        'a NAME resolved from the worker environment; no secret is stored here.')
on conflict (name) do update set dim = excluded.dim, provider = excluded.provider,
    endpoint = excluded.endpoint, credential_ref = excluded.credential_ref,
    notes = excluded.notes;

select aiq.register_embedding_space('text-embedding-3-small');

-- ------------------------------------------------------------
-- 2. The ingestion pipeline, pointed at that model.
--
-- install_ingest_workflow() with no argument installed the parse-only variant
-- when the extension loaded, because the default model at that point is the
-- 4-dimension fixture and it has no endpoint to call. Naming the real model
-- here upgrades the definition -- workflow.define_yaml versions it, so runs
-- already in flight keep the shape they started with.
-- ------------------------------------------------------------
-- ------------------------------------------------------------
-- 2b. The second indexer, over the same parse.
--
-- `graph.sql` ships the vocabulary, the upserter and the schema; the extractor
-- itself is deliberately NOT installed there, because which model to point it
-- at is a deployment's decision. This is that decision, made for the dev
-- stack: gpt-4o-mini, cheap enough to run over every upload.
--
-- Turning graph indexing ON here is the one place this file spends real money
-- per upload -- a completion over the whole document, where the embedding
-- branch spends a fraction of a cent. It is on because the point of the dev
-- stack is to exercise both indexes; a deployment decides for itself.
-- ------------------------------------------------------------
do $$
declare v_msg text;
begin
    if to_regprocedure('aiq.install_structure_null(text)') is null then
        raise warning 'skipping graph indexing: this database predates graph.sql';
        select content.install_ingest_workflow('text-embedding-3-small') into v_msg;
    else
        raise notice 'ingestion sample: %', aiq.install_structure_null('gpt-4o-mini');
        select content.install_ingest_workflow(
                   p_model       => 'text-embedding-3-small',
                   p_graph_index => true,
                   p_graph_model => 'gpt-4o-mini') into v_msg;
    end if;
    raise notice 'ingestion sample: %', v_msg;
end $$;

-- ------------------------------------------------------------
-- 3. Asking the corpus a question -- the other half of the claim.
--
-- "Upload a file and it becomes answerable" is two halves, and the second one
-- is worth shipping as a definition rather than describing: this is the whole
-- of a RAG pipeline over uploaded content, and it contains no user code, no
-- vector handling and no embedding url.
--
--   retrieve   ONE p8ql step, which the compiler turns into TWO tasks: an
--              embed of the question at the url the registry holds, and the
--              SEARCH that ranks against it. USING pins the space, so the
--              vector and the corpus cannot come from different models.
--   answer     an ordinary REST call with the passages interpolated. The key
--              is a NAME resolved from the worker's environment; nothing
--              secret is stored in this row.
--
-- The chat model is named here rather than registered, deliberately: this is
-- an EXAMPLE of consuming retrieval, not a second model registry. Agents are
-- rows in `agentic.agents` and that is where a durable answer-er belongs.
-- ------------------------------------------------------------
select workflow.define_yaml($$
name: ask_uploads
steps:
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks USING text-embedding-3-small LIMIT 4'

  - id: answer
    needs: [retrieve]
    rest:
      url: https://api.openai.com/v1/chat/completions
      method: POST
      credential_ref: LLM_API_KEY
      timeout_ms: 60000
      jsonpath: choices.0.message.content
      body:
        model: gpt-4o-mini
        temperature: 0
        messages:
          - role: system
            content: >-
              Answer the question using only the passages provided. Be specific
              and quote figures exactly as they appear. If the passages do not
              contain the answer, say so.
          - role: user
            content: "Question: {{run.question}}\n\nPassages:\n{{steps.retrieve.result}}"
$$);


reset role;
