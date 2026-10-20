-- AGENTIC SURFACE -- an agent document installs the same row whichever tool
-- applies it.
--
-- `brief.md` §6: an agent IS a JSON Schema document. There is no `prompt` key --
-- the system prompt is the document's `description` and the output contract is
-- its `properties` -- and an `agents` ROW spells those two `system_prompt` and
-- `structured_output_schema`. Both forms are documented and every worked example
-- authors the first one.
--
-- Before REM-70 each tool that read a document translated it itself and knew one
-- dialect, and `upsert_agent` dropped the keys it did not read. Measured on
-- `origin/main` (b4f49e5) before the fix, the documented form applied directly:
--
--   select agentic.upsert_agent('{"name":"rem70-before","category":"tool_user",
--     "description":"Read the note and return the claims it makes.",
--     "properties":{"claims":{...}},"required":["claims"]}');
--   ->  name         | system_prompt | structured_output_schema
--       rem70-before | (EMPTY)       | (NULL)
--
-- An agent that exists, resolves by name and can do nothing, reported as a
-- success. Same document with `category: extractor` failed instead on
-- `violates check constraint "agents_extractor_needs_schema"` with a row dump --
-- the CHECK catching, badly, the one category where an empty contract is
-- illegal. Every assertion here is one of those two outcomes, replaced.
--
-- WHAT IS UNDER TEST IS THE TRANSLATION AND THE REFUSAL, in that order of
-- importance-to-length and the reverse order of importance. Translating both
-- dialects fixes the three loaders that exist today; refusing a key nobody reads
-- is what stops the fourth loader from shipping the same silence.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------
-- 1. THE DOCUMENTED FORM INSTALLS A COMPLETE AGENT.
--
-- `description` becomes the prompt, `properties` become the contract, and
-- `category: extractor` -- the one category whose CHECK requires a schema --
-- now passes, because the schema arrived.
-- ---------------------------------------------------------------
do $$ begin perform agentic.upsert_agent($j${
    "name": "t-doc-extractor",
    "type": "object",
    "category": "extractor",
    "audience": "internal",
    "model": "openai:gpt-4.1-mini",
    "description": "Read the note and return the claims it makes.",
    "properties": {"claims": {"type": "array", "items": {"type": "string"}}},
    "required": ["claims"]
}$j$::jsonb); end $$;

do $$
declare a agentic.agents;
begin
    select * into a from agentic.agents where name = 't-doc-extractor';
    if a.system_prompt <> 'Read the note and return the claims it makes.' then
        raise exception
            'the document''s `description` did not become the system prompt: %',
            coalesce(nullif(a.system_prompt, ''), '(empty)');
    end if;
    if a.structured_output_schema is null then
        raise exception
            'the document''s `properties` did not become an output contract. This '
            'is the REM-70 failure: the agent exists and has no shape to parse.';
    end if;
    if a.structured_output_schema <> '{"type":"object",
            "properties":{"claims":{"type":"array","items":{"type":"string"}}},
            "required":["claims"]}'::jsonb then
        raise exception 'the output contract is not the document''s properties: %',
            a.structured_output_schema;
    end if;
    -- The agent config beside the schema fields is not schema and is not lost.
    if a.category <> 'extractor' or a.model <> 'openai:gpt-4.1-mini' then
        raise exception 'agent config beside the schema fields was dropped: category=%, model=%',
            a.category, a.model;
    end if;
    -- And nothing of the schema document leaked into the row's own columns.
    if a.tags <> '{}' or a.tools <> '[]'::jsonb then
        raise exception 'schema keywords were filed as agent config: tags=%, tools=%',
            a.tags, a.tools;
    end if;
end $$;

-- ---------------------------------------------------------------
-- 2. THE SAME AGENT IN THE ROW DIALECT IS THE SAME ROW.
--
-- This is REM-70's acceptance criterion at the layer that decides it. The two
-- loaders that used to translate -- our package loader and percolate-core's
-- `core/samples.py` -- now send the document through untouched, so "both tools
-- install the same row" is the statement that these two documents do, and it is
-- asserted here rather than inferred from the two tools agreeing today.
-- ---------------------------------------------------------------
do $$ begin perform agentic.upsert_agent($j${
    "name": "t-row-extractor",
    "category": "extractor",
    "audience": "internal",
    "model": "openai:gpt-4.1-mini",
    "system_prompt": "Read the note and return the claims it makes.",
    "structured_output_schema": {
        "type": "object",
        "properties": {"claims": {"type": "array", "items": {"type": "string"}}},
        "required": ["claims"]}
}$j$::jsonb); end $$;

do $$
declare v_diff text;
begin
    select string_agg(c, ', ') into v_diff
      from (
        select 'system_prompt' as c from agentic.agents d, agentic.agents r
         where d.name = 't-doc-extractor' and r.name = 't-row-extractor'
           and d.system_prompt is distinct from r.system_prompt
        union all
        select 'structured_output_schema' from agentic.agents d, agentic.agents r
         where d.name = 't-doc-extractor' and r.name = 't-row-extractor'
           and d.structured_output_schema is distinct from r.structured_output_schema
        union all
        select 'model' from agentic.agents d, agentic.agents r
         where d.name = 't-doc-extractor' and r.name = 't-row-extractor'
           and d.model is distinct from r.model
        union all
        select 'category' from agentic.agents d, agentic.agents r
         where d.name = 't-doc-extractor' and r.name = 't-row-extractor'
           and d.category is distinct from r.category) x;
    if v_diff is not null then
        raise exception
            'the same agent written in the two documented forms installed '
            'different rows. Differing: %', v_diff;
    end if;
end $$;

-- ---------------------------------------------------------------
-- 3. A KEY NOBODY READS IS REFUSED, NOT DROPPED.
--
-- The half of the fix that keeps the next loader honest. `output_schema` is
-- named because it is a real spelling from a real place -- a package manifest's
-- reference to a FILE in the package -- so the refusal says where it belongs
-- rather than calling the author's document broken.
-- ---------------------------------------------------------------
do $$
declare
    v_case record;
    v_err  text;
    v_ok   boolean;
begin
    for v_case in
        select * from (values
            -- key sent,              must appear in the refusal
            ('"output_schema": "schemas/motif.json"', 'output_schema', 'structured_output_schema'),
            ('"prompt": "do the thing"',              'prompt',        'description'),
            ('"systm_prompt": "typo"',                'systm_prompt',  'system_prompt'),
            ('"structured_output": true',             'structured_output', 'thinking aides'),
            ('"id": "00000000-0000-0000-0000-000000000001"', 'id',     'never the author')
        ) as c(frag, key, says)
    loop
        v_ok := false; v_err := null;
        begin
            perform agentic.upsert_agent(
                ('{"name": "t-doc-refused", "system_prompt": "x", '
                 || v_case.frag || '}')::jsonb);
            v_ok := true;
        exception when others then v_err := sqlerrm;
        end;
        if v_ok then
            raise exception
                'upsert_agent accepted `%`, a key it does not read. Dropping it is '
                'how an agent installs with an empty prompt and reports success.',
                v_case.key;
        end if;
        if v_err not like '%' || v_case.key || '%' then
            raise exception 'the refusal of `%` does not name the key: %',
                v_case.key, v_err;
        end if;
        if v_err not like '%' || v_case.says || '%' then
            raise exception
                'the refusal of `%` does not say where the key belongs (expected to '
                'mention %): %', v_case.key, v_case.says, v_err;
        end if;
        -- Refused BEFORE writing, which is the difference between a refusal and
        -- a report.
        if exists (select 1 from agentic.agents where name = 't-doc-refused') then
            raise exception 'the refused document (`%`) still wrote a row', v_case.key;
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------
-- 4. ONE FACT, ONE SPELLING -- and a schema part with no schema.
--
-- A document carrying both `description` and `system_prompt` is an author who
-- believes one of them is being read. Picking a winner silently is how they find
-- out which one in production.
-- ---------------------------------------------------------------
do $$
declare
    v_case record;
    v_err  text;
    v_ok   boolean;
begin
    for v_case in
        select * from (values
            ('{"name":"t-doc-both","description":"a","system_prompt":"b"}',
             'both `description` and `system_prompt`'),
            ('{"name":"t-doc-both","properties":{"x":{"type":"string"}},'
             || '"structured_output_schema":{"type":"object","properties":{}}}',
             'both `properties` and `structured_output_schema`'),
            ('{"name":"t-doc-both","system_prompt":"a","required":["x"]}',
             'no `properties`'),
            ('{"name":"t-doc-both","system_prompt":"a","type":"string"}',
             'describes an object')
        ) as c(doc, says)
    loop
        v_ok := false; v_err := null;
        begin
            perform agentic.upsert_agent(v_case.doc::jsonb);
            v_ok := true;
        exception when others then v_err := sqlerrm;
        end;
        if v_ok then
            raise exception 'this document was accepted and should not be: %', v_case.doc;
        end if;
        if v_err not like '%' || v_case.says || '%' then
            raise exception 'the refusal does not say why (expected %): %',
                v_case.says, v_err;
        end if;
        if exists (select 1 from agentic.agents where name = 't-doc-both') then
            raise exception 'a refused document wrote a row: %', v_case.doc;
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------
-- 5. WHAT PYDANTIC ACTUALLY EMITS.
--
-- `model_json_schema()` on a model whose `json_schema_extra` sets no name emits
-- `title` (the class name) and no `name`, and a model with a nested field emits
-- `$defs` with `$ref`s into it. A contract carrying a `$ref` and no `$defs` is
-- one no provider can validate against, so `$defs` travels with the schema.
-- ---------------------------------------------------------------
do $$ begin perform agentic.upsert_agent($j${
    "title": "t-doc-pydantic",
    "type": "object",
    "description": "You triage incident questions for the support desk.",
    "properties": {"claim": {"$ref": "#/$defs/Claim"}},
    "$defs": {"Claim": {"type": "object", "properties": {"text": {"type": "string"}}}},
    "additionalProperties": false,
    "required": ["claim"]
}$j$::jsonb); end $$;

do $$
declare a agentic.agents;
begin
    select * into a from agentic.agents where name = 't-doc-pydantic';
    if not found then
        raise exception
            '`title` is not a fallback for `name`, so a pydantic document with no '
            '`json_schema_extra` name installs nothing findable';
    end if;
    if a.structured_output_schema->'$defs' is null then
        raise exception
            'the contract kept a $ref and dropped the $defs it points into: %',
            a.structured_output_schema;
    end if;
    if a.structured_output_schema->'additionalProperties' is null then
        raise exception 'additionalProperties was dropped: %',
            a.structured_output_schema;
    end if;
end $$;

-- `name` wins over `title` when both are present -- `title` is the fallback and
-- never an override, because `json_schema_extra: {"name": ...}` is the author
-- saying so.
do $$ begin perform agentic.upsert_agent(
    '{"name":"t-doc-named","title":"SomeClassName","system_prompt":"x"}'::jsonb); end $$;
do $$
begin
    if not exists (select 1 from agentic.agents where name = 't-doc-named') then
        raise exception '`title` overrode an explicit `name`';
    end if;
end $$;

-- ---------------------------------------------------------------
-- 6. AN OMITTED KEY STILL MEANS "LEAVE IT ALONE".
--
-- The translation must not turn an absent `description` into an empty prompt.
-- That is the same total-data-loss bug the `excluded` arm of this function was
-- written to avoid, and it is exactly what a translation that always emits
-- `system_prompt` would reintroduce one layer up.
-- ---------------------------------------------------------------
do $$ begin perform agentic.upsert_agent('{"name":"t-doc-extractor","model":"openai:gpt-4o-mini"}'::jsonb); end $$;
do $$
declare a agentic.agents;
begin
    select * into a from agentic.agents where name = 't-doc-extractor';
    if a.system_prompt <> 'Read the note and return the claims it makes.' then
        raise exception
            'an edit naming only the model cleared the prompt: %',
            coalesce(nullif(a.system_prompt, ''), '(empty)');
    end if;
    if a.structured_output_schema is null then
        raise exception 'an edit naming only the model cleared the output contract';
    end if;
    if a.model <> 'openai:gpt-4o-mini' then
        raise exception 'the edit did not take: %', a.model;
    end if;
end $$;

-- ---------------------------------------------------------------
-- 7. THE ACCEPTED KEYS ARE THE COLUMNS UPSERT_AGENT WRITES -- asked of the
--    catalogue, so the two cannot drift.
--
-- `agent_document_to_row` spells the column half of its vocabulary as a list,
-- because what makes a key readable is that the INSERT names it and not that the
-- table has the column. A list is a second copy, so this is the gate that keeps
-- it honest: every writable column of `agentic.agents` must be accepted as a
-- document key. A column added to the table and to the INSERT and forgotten here
-- fails this with the column's name in the message -- which is the failure the
-- audience/category columns produced silently when they were added to the table
-- and not to the INSERT.
-- ---------------------------------------------------------------
do $$
declare
    v_col  text;
    v_bad  text[] := '{}';
    v_ok   boolean;
    -- The database's to assign, never the author's (surface.sql's write
    -- contract), and `search_tsv`-style generated columns are nobody's.
    v_unsettable text[] := array['id', 'created_at', 'updated_at'];
begin
    for v_col in
        select column_name from information_schema.columns
         where table_schema = 'agentic' and table_name = 'agents'
           and not (column_name = any(v_unsettable))
           and is_generated = 'NEVER'
    loop
        v_ok := false;
        begin
            -- The VALUE is deliberately null: this asks whether the KEY is part
            -- of the vocabulary, not whether a value of some type is valid.
            perform agentic.agent_document_to_row(
                jsonb_build_object('name', 't-doc-vocab', v_col, null));
            v_ok := true;
        exception when others then null;
        end;
        if not v_ok then
            v_bad := v_bad || v_col;
        end if;
    end loop;
    if array_length(v_bad, 1) > 0 then
        raise exception
            'agentic.agents has writable column(s) no agent document may name: %. '
            'Either the document vocabulary in agent_document_to_row is behind the '
            'table, or the column is not writable and belongs in this test''s '
            'unsettable list with a reason.', array_to_string(v_bad, ', ');
    end if;
end $$;

-- ---------------------------------------------------------------
-- 8. THE TRANSLATION IS REACHABLE BY THE CALLER WHO AUTHORS AGENTS, and by
--    nobody else -- it is how a client asks whether this database translates
--    documents at all before it installs one (percolate-core's samples
--    pre-flight), which is the difference between a loud refusal and 0.1.x's
--    empty agent.
-- ---------------------------------------------------------------
do $$
begin
    if not has_function_privilege('authenticated',
            'agentic.agent_document_to_row(jsonb)', 'execute') then
        raise exception
            'authenticated cannot call agent_document_to_row, so a client cannot '
            'tell a database that translates documents from one that drops them';
    end if;
    if has_function_privilege('web_anon',
            'agentic.agent_document_to_row(jsonb)', 'execute') then
        raise exception
            'agent_document_to_row is executable by web_anon -- a function born '
            'with PUBLIC EXECUTE, which is the default and not what this wants';
    end if;
end $$;

rollback;
