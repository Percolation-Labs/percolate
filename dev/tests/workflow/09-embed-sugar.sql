-- EMBEDDINGS -- the half of a vector search the database cannot do, authored
-- as if it could.
--
-- `SEARCH "..." FROM chunks` needs a vector, and a vector is a model call, and
-- the database makes none. That was the author's problem for as long as this
-- engine has existed: write the model call by hand, wire its result into
-- p8ql_vec, and hold the one invariant nothing checked -- that the space you
-- search is the space your vector came from.
--
-- Everything below is that shape being taken over by the compiler and the
-- registry, and the assertions are in two families:
--
--   * the sugar produces EXACTLY the rows the hand-written pair produces --
--     the test YAML.md sets for promoting a shorthand, run as a diff rather
--     than asserted in prose;
--   * the failures that used to be silent are now refusals, by name.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- A model that could actually be called: the committed fixture space is 4-dim
-- with provider `fixture`, which has no request shape, so these tests register
-- their own and roll it back.
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default)
values ('t-embed-a', 768, 'ollama', '{{env.LLM_URL}}/api/embeddings', false),
       ('t-embed-b', 768, 'ollama', 'http://elsewhere/api/embeddings', false);

-- ---------------------------------------------------------------------
-- 1. ONE STEP IN, TWO TASKS OUT -- and the author's id stays on the search.
--
-- The embed is a PREPENDED PREDECESSOR, not a child. That is the whole reason
-- this is cheap where `matrix:` was not: successors still say needs: [retrieve]
-- and still read {{steps.retrieve.result}}, because the step that produces the
-- result kept its key. Nothing is rewired, because nothing moved.
-- ---------------------------------------------------------------------
do $$
declare
    v_spec jsonb;
begin
    perform workflow.define_yaml($y$
name: t_embed_sugar
steps:
  - id: retrieve
    p8ql: 'SEARCH "outage causes" FROM chunks USING t-embed-a LIMIT 5'
  - id: triage
    needs: [retrieve]
    sql: {function: content_drift, args: []}
$y$);
    select spec into v_spec from workflow.definitions where name = 't_embed_sugar';

    if jsonb_array_length(v_spec->'steps') <> 3 then
        raise exception 'one p8ql SEARCH step should compile to two tasks, got % in total',
            jsonb_array_length(v_spec->'steps');
    end if;
    if v_spec#>>'{steps,0,key}' <> 'retrieve__embed' then
        raise exception 'the embed step is not where it should be: %', v_spec#>>'{steps,0,key}';
    end if;
    if v_spec#>>'{steps,1,key}' <> 'retrieve'
       or v_spec#>>'{steps,1,input,function}' <> 'p8ql_vec' then
        raise exception 'the search step lost its key or its arity';
    end if;
    if v_spec#>>'{steps,1,depends_on,0}' <> 'retrieve__embed' then
        raise exception 'the search does not wait for its own embedding';
    end if;
    -- The successor is untouched: it names the step the AUTHOR wrote.
    if v_spec#>>'{steps,2,depends_on,0}' <> 'retrieve' then
        raise exception 'a successor was rewired onto the hidden step';
    end if;

    raise notice 'workflow/09: a vector query compiles to two tasks, and the author''s id stays on the search';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE DIFF TEST.
--
-- YAML.md's rule for promoting a shorthand: it must compile to exactly the
-- rows the raw form would have produced, "verifiable by diffing
-- p8_compile_workflow output for both spellings". A shorthand that produces
-- different rows is a new step kind and needs the argument that goes with one.
-- Here it is as an equality, on the STORED spec, so the registry expansion is
-- inside the comparison too.
-- ---------------------------------------------------------------------
do $$
begin
    perform workflow.define_yaml($y$
name: t_embed_diff_sugar
steps:
  - id: retrieve
    p8ql: 'SEARCH "outage" FROM chunks USING t-embed-a LIMIT 5'
$y$);
    perform workflow.define_yaml($y$
name: t_embed_diff_raw
steps:
  - id: retrieve__embed
    embed: {text: 'outage', model: t-embed-a}
  - id: retrieve
    needs: [retrieve__embed]
    sql:
      function: p8ql_vec
      args: ['SEARCH "outage" FROM chunks USING t-embed-a LIMIT 5',
             '{{steps.retrieve__embed.result}}']
$y$);
    if (select spec from workflow.definitions where name = 't_embed_diff_sugar')
    is distinct from
       (select spec from workflow.definitions where name = 't_embed_diff_raw') then
        raise exception
            'the shorthand and the hand-written pair produce different task rows -- '
            'that makes it a new step kind, not sugar';
    end if;
    raise notice 'workflow/09: the shorthand compiles to exactly the rows the hand-written pair does';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE MODEL IS PINNED INTO BOTH HALVES, AND A DISAGREEMENT IS REFUSED.
--
-- This is the defect the two-step form could not see. A vector is only
-- comparable inside the space of the model that produced it; searching space B
-- with a vector from space A raises nothing anywhere, because aiq.semantic_in
-- checks the DIMENSION and two 768-dim models are the same width. The answer
-- is a number. It is not an answer.
-- ---------------------------------------------------------------------
do $$
declare
    v_q  text;
    v_ok boolean := false;
begin
    update aiq.embedding_models set is_default = false;
    update aiq.embedding_models set is_default = true where name = 't-embed-a';

    -- No USING: the default is resolved ONCE, at definition time, and written
    -- into the query -- so the run cannot mean a different model than the
    -- embed step did because someone moved is_default in between.
    perform workflow.define_yaml($y$
name: t_embed_pin
steps:
  - id: retrieve
    p8ql: 'SEARCH "outage" FROM chunks LIMIT 3'
$y$);
    select spec#>>'{steps,1,input,args,0}' into v_q
      from workflow.definitions where name = 't_embed_pin';
    if v_q not like '%USING t-embed-a%' then
        raise exception 'the resolved model was not pinned into the query: %', v_q;
    end if;

    -- ...and the same pin applied to the raw form catches the disagreement,
    -- because the pairing is read off the data flow rather than off a marker
    -- the compiler left behind.
    begin
        perform workflow.define_yaml($y$
name: t_embed_mismatch
steps:
  - id: q
    embed: {text: 'outage', model: t-embed-b}
  - id: retrieve
    needs: [q]
    sql:
      function: p8ql_vec
      args: ['SEARCH "outage" FROM chunks USING t-embed-a', '{{steps.q.result}}']
$y$);
    exception when others then
        v_ok := sqlerrm like '%is handed a vector produced by%';
    end;
    if not v_ok then
        raise exception 'a query searching one space with another space''s vector was accepted';
    end if;

    raise notice 'workflow/09: the model is resolved once and pinned into both halves; a disagreement is refused by name';
end $$;

-- ---------------------------------------------------------------------
-- 4. A REGISTRATION THAT CANNOT BE CALLED IS REFUSED AT AUTHORING TIME.
--
-- A model row is two registrations made by two people in two places: a SPACE
-- (dimension, operator class, HNSW index) and a CALL (endpoint, provider
-- shape). The first is enough to search; only the second is enough to embed.
-- Each of these used to be discovered at run time, by a step that failed.
-- ---------------------------------------------------------------------
do $$
declare
    v_msg text;
begin
    -- (a) a model nobody registered
    begin
        perform workflow.define_yaml($y$
name: t_embed_unknown
steps:
  - id: q
    embed: {text: 'x', model: no-such-model}
$y$);
        raise exception 'an unregistered model was accepted';
    exception when others then
        v_msg := sqlerrm;
        if v_msg not like '%not registered%' then raise; end if;
    end;

    -- (b) registered as a space, with nowhere to send the text
    insert into aiq.embedding_models (name, dim, provider) values ('t-embed-noep', 768, 'ollama');
    begin
        perform workflow.define_yaml($y$
name: t_embed_noep
steps:
  - id: q
    embed: {text: 'x', model: t-embed-noep}
$y$);
        raise exception 'a model with no endpoint was accepted';
    exception when others then
        v_msg := sqlerrm;
        if v_msg not like '%has no endpoint%' then raise; end if;
    end;

    -- (c) a provider whose request shape nothing knows
    insert into aiq.embedding_models (name, dim, provider, endpoint)
    values ('t-embed-weird', 768, 'homegrown', 'http://x/embed');
    begin
        perform workflow.define_yaml($y$
name: t_embed_weird
steps:
  - id: q
    embed: {text: 'x', model: t-embed-weird}
$y$);
        raise exception 'a provider with no request shape was accepted';
    exception when others then
        v_msg := sqlerrm;
        if v_msg not like '%aiq.embedding_providers%' then raise; end if;
    end;

    raise notice 'workflow/09: a model that is a space but not a call is refused while authoring, not while running';
end $$;

-- ---------------------------------------------------------------------
-- 5. THE TWO WAYS A SPEC ARRIVES WITHOUT PASSING THE EXPANDER.
--
-- define_yaml is one of three doors into workflow.definitions; a migration and
-- a hand-written JSON spec are the others, and both skip the expansion. The
-- lint is the gate all three pass, which is why the check lives there.
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
    -- (f) a marker nobody expanded: an http_call with no url
    select count(*) into v_n from workflow.lint_spec($j$
    {"steps": [{"key":"e","kind":"http_call","queue":"http",
                "input":{"embed":{"text":"x","model":null}}}]}
    $j$) where severity = 'error';
    if v_n <> 1 then
        raise exception 'an unexpanded embed marker was not refused (% errors)', v_n;
    end if;

    -- (g) a vector query handed no vector -- exactly what a compiler that
    -- predates the desugar emits from a document that is correct as written.
    select count(*) into v_n from workflow.lint_spec($j$
    {"steps": [{"key":"r","kind":"sql","queue":"none",
                "input":{"function":"p8ql","args":["SEARCH \"x\" FROM chunks"]}}]}
    $j$) where severity = 'error';
    if v_n <> 1 then
        raise exception 'a SEARCH with no embedding was not refused (% errors)', v_n;
    end if;

    -- ...and a mode that needs no vector is untouched by that rule.
    select count(*) into v_n from workflow.lint_spec($j$
    {"steps": [{"key":"r","kind":"sql","queue":"none",
                "input":{"function":"p8ql","args":["LOOKUP \"acme\""]}}]}
    $j$) where severity = 'error';
    if v_n <> 0 then
        raise exception 'a LOOKUP step was refused as if it needed a vector';
    end if;

    raise notice 'workflow/09: an unexpanded marker and a vectorless SEARCH are both refused at the one gate every spec passes';
end $$;

-- ---------------------------------------------------------------------
-- 6. A MATRIX TEMPLATE IS ONE STEP, AND A VECTOR QUERY IS TWO.
--
-- Refused by name rather than compiled into a search with no vector, which
-- would be a run-time failure on every child at once.
-- ---------------------------------------------------------------------
do $$
declare v_ok boolean := false;
begin
    begin
        perform workflow.define_yaml($y$
name: t_embed_matrix
steps:
  - id: fan
    matrix:
      items: [{k: 1}]
      max_fanout: 10
      template:
        p8ql: 'SEARCH "x" FROM chunks'
$y$);
    exception when others then
        v_ok := sqlerrm like '%template%' and sqlerrm like '%two%';
    end;
    if not v_ok then
        raise exception 'a matrix templating a vector query was accepted';
    end if;
    raise notice 'workflow/09: a matrix cannot template a query that needs two steps';
end $$;

-- ---------------------------------------------------------------------
-- 7. THE TEMPLATE HALF -- and the bug that made the documented example lie.
--
-- p8ql_vec takes the query as its first ARGUMENT, and the documented pipeline
-- passes 'SEARCH "{{run.question}}" FROM chunks'. resolve_args substituted
-- whole-string references only, so that one was substituted nowhere: the
-- literal braces reached aiq.query, and SEARCH feeds that text to the LEXICAL
-- half. Full-text search for {{run.question}} matches nothing, every lexical
-- rank comes back null, and the fusion quietly degrades to semantic-only.
-- It returns rows. It looks like it worked.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_out jsonb;
begin
    insert into workflow.definitions (name, spec) values
    ('t_embed_tmpl', '{"steps":[{"key":"s","kind":"sql","queue":"none",
                                 "input":{"function":"content_drift","args":[]}}]}');
    v_run := workflow.start_workflow('t_embed_tmpl', '{"question":"R7 recall","n":3}'::jsonb);

    v_out := workflow.resolve_args(
        $j$["{{run.n}}", "SEARCH \"{{run.question}}\" FROM chunks LIMIT 3",
            "no templates here", "n={{run.n}} q={{run.question}}"]$j$, v_run);

    -- A WHOLE-STRING reference is a VALUE and keeps its type: this is what
    -- makes {{steps.embed.result}} arrive as an array of floats rather than as
    -- a string that looks like one.
    if jsonb_typeof(v_out->0) <> 'number' then
        raise exception 'a whole-string reference stopped keeping its native type: %', v_out->0;
    end if;
    -- An EMBEDDED one is TEXT -- the rule the worker already applied to a url
    -- and {{item.*}}, which the database half was silently the exception to.
    if v_out->>1 <> 'SEARCH "R7 recall" FROM chunks LIMIT 3' then
        raise exception 'an embedded reference in a query argument did not resolve: %', v_out->>1;
    end if;
    if v_out->>2 <> 'no templates here' then
        raise exception 'a literal argument was altered';
    end if;
    if v_out->>3 <> 'n=3 q=R7 recall' then
        raise exception 'two references in one string did not both resolve: %', v_out->>3;
    end if;

    -- And a reference that resolves to nothing still fails LOUDLY rather than
    -- interpolating an empty string, which would be the same silent-degradation
    -- failure wearing a different hat.
    begin
        perform workflow.resolve_args($j$["x {{run.nope}} y"]$j$, v_run);
        raise exception 'an unresolvable embedded reference was interpolated anyway';
    exception when others then
        if sqlerrm not like '%resolved to nothing%' then raise; end if;
    end;

    raise notice 'workflow/09: whole-string references keep their type, embedded ones interpolate as text, and neither resolves silently to nothing';
end $$;

-- ---------------------------------------------------------------------
-- 8. DISCOVERY KNOWS ABOUT IT.
--
-- An agent authoring a workflow reads SCHEMA "workflow", and the rule that
-- facet was built on is that it must describe the layer the reader acts
-- THROUGH. A step kind the compiler accepts and the facet does not mention is
-- a capability nobody can find; a model registered as a space but not as a
-- call is a step that authors cleanly and cannot run.
-- ---------------------------------------------------------------------
do $$
declare
    v_doc  jsonb;
    v_caps jsonb;
begin
    v_caps := workflow.compiler_capabilities();
    if not coalesce((v_caps#>>'{accepts,embed}')::boolean, false) then
        raise exception 'the installed compiler does not accept `embed:` -- rebuild the extension';
    end if;
    -- Probed by COUNTING THE ROWS, because compile-success cannot see this
    -- one: a compiler that predates the desugar accepts the document and emits
    -- a single step that fails at dispatch.
    if not coalesce((v_caps#>>'{accepts,p8ql_vector_desugar}')::boolean, false) then
        raise exception 'the installed compiler compiles a SEARCH query to one step';
    end if;

    v_doc := aiq.schema('workflow');
    if not exists (select 1 from jsonb_array_elements(v_doc#>'{doc,declared,actions}') a
                    where a->>'key' = 'embed') then
        raise exception 'SCHEMA "workflow" does not list the embed action';
    end if;
    if not exists (select 1 from jsonb_array_elements(v_doc#>'{doc,derived,embedding_models}') m
                    where m->>'name' = 't-embed-a' and (m->>'callable')::boolean) then
        raise exception 'SCHEMA "workflow" does not report which models an embed step may name';
    end if;
    -- t-embed-noep is registered as a space and has no endpoint: findable, and
    -- reported as what it is rather than omitted or offered.
    if exists (select 1 from jsonb_array_elements(v_doc#>'{doc,derived,embedding_models}') m
                where m->>'name' = 't-embed-noep' and (m->>'callable')::boolean) then
        raise exception 'a model with no endpoint is reported as callable';
    end if;

    raise notice 'workflow/09: the step, the desugar and the models it may name are all discoverable before authoring';
end $$;

rollback;
