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
    perform set_config('request.jwt.claims',
        '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

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

rollback;
