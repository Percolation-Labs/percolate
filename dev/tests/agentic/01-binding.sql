-- AGENTIC SURFACE -- a binding that looks registered and is missing its tools.
--
-- Every assertion here corresponds to a failure found by actually binding the
-- sample in `specs/agentic/reference/`, and they share the shape this suite
-- exists for: the call returned, the row looked right, and something the
-- author wrote had been dropped on the way in.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

do $$
declare
    v_srv agentic.tool_servers;
    v_ag  agentic.agents;
begin
    -- ---------------------------------------------------------------
    -- 1. RE-REGISTERING A SERVER MUST NOT ERASE WHAT DISCOVERY FOUND.
    --
    -- Registration and re-sync are the same call, and `excluded` carries the
    -- column DEFAULT for a key the caller omitted -- not "no change". So
    -- correcting a server's url emptied its tool list, and every agent bound
    -- to it was left naming tools that no longer existed anywhere. Nothing
    -- raised; the row simply came back with cached_tools = [].
    -- ---------------------------------------------------------------
    v_srv := agentic.upsert_tool_server($j${
        "name": "t_srv", "kind": "openapi", "url": "http://a",
        "cached_tools": [{"name": "t_one"}]}$j$::jsonb);
    if jsonb_array_length(v_srv.cached_tools) <> 1 then
        raise exception 'registration did not store the discovered tools';
    end if;

    v_srv := agentic.upsert_tool_server(
        '{"name": "t_srv", "kind": "openapi", "url": "http://b"}'::jsonb);
    if jsonb_array_length(v_srv.cached_tools) <> 1 then
        raise exception
            're-registration erased cached_tools -- every agent bound to this '
            'server now names tools that resolve to nothing';
    end if;
    if v_srv.url <> 'http://b' then
        raise exception 're-registration did not update the url';
    end if;

    -- ---------------------------------------------------------------
    -- 2. A SECRET MUST NOT REACH default_headers.
    --
    -- The column carries non-secret routing headers (Accept-Profile and the
    -- like). credential_ref is the seam for anything else, and the boundary
    -- is enforced by the table rather than by a reviewer noticing.
    -- ---------------------------------------------------------------
    begin
        perform agentic.upsert_tool_server($j${
            "name": "t_srv2", "kind": "openapi", "url": "http://a",
            "default_headers": {"Authorization": "Bearer hunter2"}}$j$::jsonb);
        raise exception 'a literal credential was accepted into default_headers';
    exception when check_violation then
        null;   -- refused, as it must be
    end;

    -- ---------------------------------------------------------------
    -- 3. THE WRITE PATH MUST BE ABLE TO EXPRESS EVERY COLUMN IT HAS.
    --
    -- upsert_agent ignored audience, category and tags for as long as those
    -- columns existed. An agent authored as user-facing was accepted,
    -- reported as created, defaulted to `internal`, and never appeared in
    -- agents_pickable -- which is the only view an interactive client reads.
    -- ---------------------------------------------------------------
    v_ag := agentic.upsert_agent($j${
        "name": "t_agent", "audience": "user", "category": "router",
        "tags": ["alpha", "beta"], "system_prompt": "you are a fixture",
        "tools": [{"server": "t_srv", "tools": ["t_one"]}]}$j$::jsonb);

    if v_ag.audience <> 'user' or v_ag.category <> 'router' then
        raise exception
            'upsert_agent dropped the classification: audience=% category=%',
            v_ag.audience, v_ag.category;
    end if;
    if v_ag.tags <> array['alpha','beta'] then
        raise exception 'upsert_agent dropped tags: %', v_ag.tags;
    end if;
    if not exists (select 1 from agentic.agents_pickable where name = 't_agent') then
        raise exception
            'an agent authored as user-facing is invisible to the view a '
            'client picks from';
    end if;

    -- ---------------------------------------------------------------
    -- 3b. AN OMITTED KEY MEANS "LEAVE IT ALONE", NOT "RESET IT".
    --
    -- The worst of these, because the call that triggers it is the most
    -- ordinary edit there is: {"name": ..., "model": ...} to point an agent at
    -- a different model. Written with a plain `set x = excluded.x`, `excluded`
    -- carries the column DEFAULT for every key the caller did not send -- so
    -- that call returned 200 and left the agent with no system prompt and no
    -- tools. It still existed and still resolved by name, and could do
    -- nothing. Found by doing it to the sample agent.
    -- ---------------------------------------------------------------
    v_ag := agentic.upsert_agent(
        '{"name": "t_agent", "model": "openai:gpt-4.1-mini"}'::jsonb);

    if v_ag.model <> 'openai:gpt-4.1-mini' then
        raise exception 'the partial upsert did not apply the field it named';
    end if;
    if jsonb_array_length(v_ag.tools) <> 1 then
        raise exception
            'a partial upsert erased the tool bindings: an agent that still '
            'resolves by name and can call nothing';
    end if;
    if v_ag.audience <> 'user' or v_ag.category <> 'router'
       or v_ag.tags <> array['alpha','beta'] then
        raise exception 'a partial upsert reset the classification';
    end if;
    if v_ag.system_prompt = '' then
        raise exception 'a partial upsert erased the system prompt';
    end if;

    -- The same rule on the other table, checked the same way: a registration
    -- correcting only the url must not clear the credential the next sync
    -- needs, which is how a tool list silently becomes the anonymous subset.
    perform agentic.upsert_tool_server($j${
        "name": "t_srv", "kind": "openapi", "url": "http://a",
        "credential_ref": "env:T_TOKEN"}$j$::jsonb);
    v_srv := agentic.upsert_tool_server(
        '{"name": "t_srv", "url": "http://c"}'::jsonb);
    if v_srv.credential_ref is distinct from 'env:T_TOKEN' then
        raise exception
            'a partial registration cleared credential_ref -- the next sync '
            'would fetch anonymously and cache a plausible subset';
    end if;

    -- ---------------------------------------------------------------
    -- 4. AN AGENT MAY NOT NAME A TOOL SERVER THAT WAS NEVER REGISTERED.
    --
    -- Not enforced by a foreign key -- `tools` is jsonb and the binding is by
    -- name, deliberately, so an agent can be authored before its server is.
    -- This asserts the fact the binder's own check relies on: the join is
    -- resolvable, so a dangling reference is findable rather than only
    -- discovered at the moment a model tries to call it.
    -- ---------------------------------------------------------------
    if exists (
        select 1
          from agentic.agents a,
               jsonb_array_elements(a.tools) b
         where a.name = 't_agent'
           and not exists (select 1 from agentic.tool_servers s
                            where s.name = b->>'server'))
    then
        raise exception 't_agent binds a tool server that is not registered';
    end if;

    raise notice 'agentic binding: 5 assertions passed';
end $$;

-- ---------------------------------------------------------------------
-- 5. THE BOOTSTRAP BRANCH MUST NOT BE REACHABLE FROM OUTSIDE.
--
-- agentic.may_author lets a migration register the first agent, because at
-- initdb there is no JWT identity and a null holds no permissions. It stays
-- closed because the branch also requires a session that could have INSERTed
-- the row directly -- and every role PostgREST can arrive as holds no table
-- grant at all. If any of them ever gains one, this fails here rather than
-- silently opening agent authoring to anonymous callers.
-- ---------------------------------------------------------------------
do $$
declare r text;
begin
    foreach r in array array['web_anon','authenticated','authenticator'] loop
        if pg_catalog.has_table_privilege(r, 'agentic.agents', 'insert')
        or pg_catalog.has_table_privilege(r, 'agentic.tool_servers', 'insert') then
            raise exception
                'role % can INSERT agentic rows directly, which opens '
                'may_author''s bootstrap branch to unauthenticated callers', r;
        end if;
    end loop;
    raise notice 'agentic authoring: bootstrap branch is unreachable over REST';
end $$;

-- ---------------------------------------------------------------------
-- THE NEAR-MISS SPELLINGS OF A TOOL BINDING WIDEN IT, so the write path
-- refuses them.
--
-- A binding is {"server": "<name>", "tools": ["a","b"]}, and an absent or null
-- `tools` deliberately means "every tool this server exposes". That default is
-- what makes the singular spelling dangerous: `{"server": "p8-query", "tool":
-- "query"}` was stored verbatim, the runtime looked for `tools`, found none,
-- and handed the model the server's entire surface. One character, no error,
-- and an allow-list that silently became its opposite -- which was documented
-- in a comment in dev/examples/10-agent.sql, where nobody reads it at
-- authoring time.
-- ---------------------------------------------------------------------
do $$
declare v_msg text;
begin
    begin
        perform agentic.upsert_agent(jsonb_build_object(
            'name', 't_ab_widened',
            'tools', jsonb_build_array(
                jsonb_build_object('server', 'p8-query', 'tool', 'query'))));
        raise exception 'the singular `tool` spelling was accepted, which grants every '
                        'tool the server exposes';
    exception when others then
        v_msg := sqlerrm;
        if v_msg not like '%does not read%' then
            raise exception 'refused for the wrong reason: %', v_msg;
        end if;
    end;

    -- The correct spellings still work, including the deliberate "all tools".
    perform agentic.upsert_agent(jsonb_build_object(
        'name', 't_ab_narrow',
        'tools', jsonb_build_array(
            jsonb_build_object('server', 'p8-query', 'tools', jsonb_build_array('query')))));
    perform agentic.upsert_agent(jsonb_build_object(
        'name', 't_ab_wide',
        'tools', jsonb_build_array(jsonb_build_object('server', 'p8-query'))));

    if (select tools->0->>'server' from agentic.agents where name = 't_ab_narrow')
       is distinct from 'p8-query' then
        raise exception 'a correctly spelled binding did not round-trip';
    end if;

    raise notice 'agentic authoring: a tool binding that would silently widen the '
                 'allow-list is refused at the write path';
end $$;

-- ---------------------------------------------------------------------
-- `audience` IS A FILTER AND NOT A BOUNDARY, asserted in both directions
-- because the docs claimed the second one.
--
-- brief.md's classification table called `audience` "an access decision", in
-- bold. It is not: schema.sql §7 puts `for select using (true)` on this table
-- and says so, and `agents_api` returns every agent's system_prompt to any
-- authenticated caller. Someone reading only the brief would mark a sensitive
-- agent `internal` and believe it was restricted.
--
-- And the view that IS the filter had no grant at all, so the only role that
-- could read "the view an interactive UI reads" was its owner. Both halves are
-- asserted here so neither can drift back: the filter must work for a real
-- caller, and it must not be mistaken for a boundary.
-- ---------------------------------------------------------------------
do $$
declare v_prompt text; v_pickable int; v_secret text := 'internal-only escalation code 4417';
begin
    perform agentic.upsert_agent(jsonb_build_object(
        'name', 't_ab_internal', 'system_prompt', v_secret, 'audience', 'internal'));
    perform agentic.upsert_agent(jsonb_build_object(
        'name', 't_ab_user', 'system_prompt', 'hello', 'audience', 'user'));

    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"11111111-1111-1111-1111-111111111111"}');

    -- The filter works, for a role that is not the owner.
    select count(*) into v_pickable
      from agentic.agents_pickable where name in ('t_ab_internal', 't_ab_user');
    if v_pickable <> 1 then
        raise exception
            'agents_pickable returned % of the two agents to an ordinary caller, '
            'expected only the audience=user one. A permission denied here means '
            'the view an interactive UI reads is readable only by its owner.',
            v_pickable;
    end if;

    -- And it is not a boundary, which is the half the docs got wrong. This
    -- asserts the CURRENT contract: if a per-tenant column ever makes audience
    -- load-bearing, this is the assertion that has to be rewritten, and it
    -- should be, rather than the claim quietly changing meaning again.
    select system_prompt into v_prompt
      from agentic.agents_api where name = 't_ab_internal';
    if v_prompt is distinct from v_secret then
        raise exception
            'an audience=internal prompt is no longer readable through '
            'agents_api. That may be an improvement, but brief.md and '
            'schema.sql §7 both document the opposite -- update them with it.';
    end if;

    reset role;
    raise notice 'agentic: audience filters agents_pickable for a real caller, and '
                 'does not hide a system_prompt from agents_api';
end $$;

-- ---------------------------------------------------------------------
-- agentic.agent_call -- the request an agent ROW describes, for ANY agent.
--
-- Three call-builders existed and all three were shapes core happened to need,
-- so a consumer whose own pass is an agent with a structured output schema --
-- the arrangement this whole design recommends -- had to read `system_prompt`
-- and `structured_output_schema` out of the row and assemble the body by hand.
-- That is authorship wearing the costume of a read, which having an agent be a
-- row exists to prevent. Found from outside, by percolate-coherence doing it.
--
-- What this pins is that the general builder really is general: it works for an
-- agent with a NON-graph schema (the case that had nowhere to go), it names the
-- schema after the agent so two agents' queued calls are distinguishable, and
-- aiq.extractor_call still returns exactly what it always did on top of it.
-- ---------------------------------------------------------------------
do $$
declare v_call jsonb; v_x jsonb;
begin
    perform agentic.upsert_agent(jsonb_build_object(
        'name', 't_ac_judge',
        'system_prompt', 'Decide the thing.',
        'model', 'gpt-4o-mini',
        'structured_output_schema', jsonb_build_object(
            'type','object',
            'properties', jsonb_build_object('verdict', jsonb_build_object('type','string')),
            'required', jsonb_build_array('verdict'))));

    v_call := agentic.agent_call('t_ac_judge', 'the input');

    if v_call->'body'->>'model' <> 'gpt-4o-mini' then
        raise exception 'agent_call did not take the model pinned on the row: %', v_call;
    end if;
    if v_call->'body'->'messages'->0->>'content' <> 'Decide the thing.' then
        raise exception 'the system prompt did not come from the row: %', v_call;
    end if;
    if v_call->'body'->'messages'->1->>'content' <> 'the input' then
        raise exception 'the caller input is not the user message: %', v_call;
    end if;
    -- Named after the agent, not a constant: a reader inspecting a queued task
    -- must be able to tell two agents' calls apart from the body alone.
    if v_call->'body'->'response_format'->'json_schema'->>'name' <> 't_ac_judge' then
        raise exception 'the response_format schema is not named for the agent: %', v_call;
    end if;
    if v_call->>'jsonpath' <> 'choices.0.message.content' then
        raise exception 'the answer path is not returned: %', v_call;
    end if;

    -- An agent with no schema is refused HERE rather than at request time in a
    -- worker, which is the whole reason the builder is a function.
    perform agentic.upsert_agent(jsonb_build_object(
        'name', 't_ac_bare', 'system_prompt', 'no schema', 'model', 'gpt-4o-mini'));
    begin
        perform agentic.agent_call('t_ac_bare', 'x');
        raise exception 'an agent with no structured_output_schema built a call';
    exception when others then
        if sqlerrm like '%no structured_output_schema built a call%' then raise; end if;
    end;

    -- And a non-graph agent is refused by the EXTRACTOR wrapper, pointed at the
    -- general builder rather than merely rejected.
    begin
        perform aiq.extractor_call('t_ac_judge', 'gpt-4o-mini', 'x');
        raise exception 'a non-graph agent was accepted as an extractor';
    exception when others then
        if sqlerrm like '%accepted as an extractor%' then raise; end if;
        if sqlerrm not like '%agentic.agent_call%' then
            raise exception 'the refusal does not name the general builder: %', sqlerrm;
        end if;
    end;

    -- The extractor wrapper's own contract is unchanged: `extractor`, not
    -- `agent`, and the schema still named 'graph'.
    v_x := aiq.extractor_call('structure_null', 'gpt-4o-mini', 'some text');
    if v_x->'extractor'->>'agent' <> 'structure_null' or v_x ? 'agent' then
        raise exception 'extractor_call changed the key its callers read: %', v_x;
    end if;
    if v_x->'body'->'response_format'->'json_schema'->>'name' <> 'graph' then
        raise exception 'extractor_call changed its schema name: %', v_x;
    end if;

    raise notice 'agentic: agent_call builds any agent''s request, and extractor_call is a guard on it';
end $$;

-- ---------------------------------------------------------------------
-- A CLOSED VOCABULARY REFUSES WITH ITS CONTENTS, not with its name.
--
-- `category` has always been a CHECK, so a bad one was always refused. What a
-- consumer got was `violates check constraint "agents_category_check"` and a
-- row dump -- the constraint's NAME and not the eight words it would have
-- taken, so the next step was reading pg_constraint. That is the same defect
-- upsert_graph fixed for relations, and it costs more here because writing an
-- agent is the first thing a consumer does. Found by one doing it.
-- ---------------------------------------------------------------------
do $$
begin
    begin
        perform agentic.upsert_agent(
            '{"name":"t_cat_bad","system_prompt":"x","category":"coherence"}'::jsonb);
        raise exception 'an unknown agent category was accepted';
    exception when others then
        if sqlerrm like '%unknown agent category was accepted%' then raise; end if;
        -- The contents, not just the name: a message that does not list the
        -- alternatives sends the reader to the catalogue, which is the whole
        -- thing being fixed.
        if sqlerrm not like '%classifier%' or sqlerrm not like '%extractor%' then
            raise exception
                'the refusal does not name the vocabulary it enforced: %', sqlerrm;
        end if;
    end;

    -- And it still accepts every value the constraint does, or the pre-check
    -- has become a second, narrower vocabulary -- which is the failure mode of
    -- reading a list into code instead of out of the constraint.
    perform agentic.upsert_agent(
        ('{"name":"t_cat_ok","system_prompt":"x","category":"' || c || '"}')::jsonb)
      from unnest(array['general','extractor','summariser','classifier',
                        'router','critic','tool_user','evaluator']) c
     where c <> 'extractor';   -- extractor additionally requires a schema

    raise notice 'agentic: an unknown category is refused by naming the vocabulary';
end $$;

rollback;
