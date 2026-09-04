-- GRAPH SURFACE, part 3 -- who can see which nodes, keys and edges.
--
-- This is the only part of the graph surface whose characteristic failure is a
-- BREACH rather than a wrong answer, which is why `rbac/` runs first and why
-- these assertions are separate from `05`: a traversal bug returns the wrong
-- rows to the right person, and a bug here returns the right rows to the wrong
-- one.
--
-- Three things make the graph harder than a flat table:
--   * a key is a second row that can outlive or out-see the node it names;
--   * an edge has TWO endpoints and can disclose that an invisible node
--     exists merely by being visible itself;
--   * GRAPH_TABLE is a separate privilege object, so every table grant can be
--     correct while the walk is still refused -- or, worse, still allowed.
--
-- Reads the committed sample (`dev/init/04-graph-sample.sql`), which carries
-- two tenants, a shared tier, and one edge deliberately strung between the two
-- tenants.

\set ON_ERROR_STOP on

\set org_a '''a0000000-0000-0000-0000-00000000000a'''
\set org_b '''a0000000-0000-0000-0000-00000000000b'''

begin;

do $$
begin
    if not exists (select 1 from demo.companies where ticker = 'NWND') then
        raise exception
            'the graph sample is not loaded (dev/init/04-graph-sample.sql). '
            'It carries the two tenants this file is about.';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. THE POLICIES DERIVE VISIBILITY FROM aiq.nodes AND NOWHERE ELSE.
--
-- query/02 §3 asserts this by reading the policy expressions. Here it is
-- asserted by BEHAVIOUR, which is the half a reader of the policy text cannot
-- check: a key must never resolve to a node its holder cannot see, because
-- that shape -- LOOKUP matches, then returns nothing -- is indistinguishable
-- from "no such key" and is how the drift was found in the first place.
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","orgs":["a0000000-0000-0000-0000-00000000000a"]}';

do $$
begin
    -- org A sees its own
    if (select count(*) from aiq.lookup('NWND')) <> 1 then
        raise exception 'a tenant cannot see its own node';
    end if;
    -- ...and the shared tier, which is a real category and not a loophole
    if (select count(*) from aiq.lookup('ACME')) <> 1 then
        raise exception 'shared reference data (org_id is null) is not visible, '
                        'so every tenant would need its own copy of every public '
                        'company -- which is what one identity registry is for';
    end if;
    -- ...and not org B's
    if exists (select 1 from aiq.lookup('ESTG')) then
        raise exception 'a tenant resolved another tenant''s key';
    end if;
    -- no key is visible whose node is not: a match that hydrates to nothing is
    -- worse than no match, because it looks like an empty result
    if exists (select 1 from aiq.node_keys k
                where not exists (select 1 from aiq.nodes n where n.id = k.node_id)) then
        raise exception 'a key is visible whose node is not -- LOOKUP would match '
                        'and then return nothing';
    end if;
    raise notice 'query/06: keys are never more visible than their nodes';
end $$;

-- ---------------------------------------------------------------------
-- 2. AN EDGE IS VISIBLE ONLY WHEN BOTH ENDPOINTS ARE.
--
-- The sample strings one `partners_with` edge from org A's node to org B's.
-- Neither tenant may see it -- not because of the edge's own org_id (which is
-- authoring provenance, not a read gate) but because an edge visible to org A
-- would disclose that org B's node exists at all.
-- ---------------------------------------------------------------------
do $$
declare v_nwnd uuid;
begin
    select node_id into v_nwnd from aiq.lookup('NWND');

    if exists (select 1 from aiq.edges e
                where e.src_id = v_nwnd and e.relation = 'partners_with') then
        raise exception
            'a tenant can see an edge to a node it cannot see. The edge alone '
            'discloses that the other tenant''s node exists, and its id';
    end if;
    -- ...and the walk does not route through it either
    if exists (select 1 from aiq.graph_walk(v_nwnd, 3)) then
        raise exception 'a walk crossed a tenant boundary: %',
            (select string_agg(coalesce(key, node_id::text), ', ')
               from aiq.graph_walk(v_nwnd, 3));
    end if;
    -- nor does the dialect
    if jsonb_array_length(aiq.query('GRAPH "NWND"')->'rows') <> 0 then
        raise exception 'the dialect crossed a tenant boundary the functions did not';
    end if;
    raise notice 'query/06: an edge needs both endpoints visible, and the walk agrees';
end $$;

-- ---------------------------------------------------------------------
-- 3. GRAPH_TABLE IS RLS-FILTERED, NOT JUST THE TABLES UNDER IT.
--
-- A property graph is its own catalog object with its own privilege, and it
-- compiles to joins over the base tables -- so the question "do the base
-- tables' policies still apply through it" has an answer that is not
-- guessable from either fact. It is the one place where a graph could
-- silently become a privilege escalation: a pattern match that reads
-- unfiltered rows would leak every tenant to every caller, and would look
-- exactly like a correctly-working graph query.
-- ---------------------------------------------------------------------
do $$
declare v_via_graph int; v_via_table int;
begin
    select count(*) into v_via_graph from graph_table (aiq.knowledge_graph
        match (a is node) -[e is related]-> (b is node)
        columns (a.id as a_id, b.id as b_id));
    select count(*) into v_via_table from aiq.edges;

    if v_via_graph <> v_via_table then
        raise exception
            'GRAPH_TABLE returned % edges where the RLS-filtered table returns % '
            '-- the property graph is not subject to the policies on the tables '
            'it is defined over', v_via_graph, v_via_table;
    end if;
    if v_via_graph = 0 then
        raise exception 'the caller can see no edges at all, so this assertion '
                        'proves nothing -- the fixture or the grants are wrong';
    end if;
    raise notice 'query/06: GRAPH_TABLE is filtered by the same policies (% edges)',
        v_via_graph;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------
-- 4. THE TWO TENANTS SEE DIFFERENT GRAPHS, AND A CLAIMLESS CALLER SEES THE
--    SHARED ONE.
--
-- Asserted as a comparison rather than as three separate counts: a policy that
-- had quietly become permissive would give all three callers the same numbers,
-- which each count on its own would look fine against.
-- ---------------------------------------------------------------------
do $$
declare v_a int; v_b int; v_none int; v_all int;
begin
    set local role authenticated;

    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","orgs":["a0000000-0000-0000-0000-00000000000a"]}';
    select count(*) into v_a from aiq.nodes;
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}';
    select count(*) into v_b from aiq.nodes;
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","orgs":[]}';
    select count(*) into v_none from aiq.nodes;
    reset role;
    select count(*) into v_all from aiq.nodes;

    if v_a = v_all or v_b = v_all then
        raise exception 'a tenant sees every node in the database (% of %)',
            greatest(v_a, v_b), v_all;
    end if;
    if v_a = v_none or v_b = v_none then
        raise exception 'a tenant sees exactly what a caller with no org claim '
                        'sees -- its own rows are not reaching it, or the shared '
                        'tier is all anyone gets';
    end if;
    -- Exactly the shared tier plus its own, computed from the data rather than
    -- written down: a hardcoded expected count turns every future addition to
    -- the sample into a failing tenancy test, and the pressure then is to bump
    -- the number rather than to ask why it moved.
    if v_a <> v_none + (select count(*) from aiq.nodes
                         where org_id = 'a0000000-0000-0000-0000-00000000000a') then
        raise exception 'org A sees %, which is not the shared tier (%) plus its own', v_a, v_none;
    end if;
    if v_b <> v_none + (select count(*) from aiq.nodes
                         where org_id = 'a0000000-0000-0000-0000-00000000000b') then
        raise exception 'org B sees %, which is not the shared tier (%) plus its own', v_b, v_none;
    end if;
    if v_none >= v_a or v_none >= v_b then
        raise exception 'a caller with no org claim sees at least as much as a '
                        'tenant does';
    end if;
    raise notice 'query/06: org A sees %, org B sees %, no-claim sees %, owner sees %',
        v_a, v_b, v_none, v_all;
end $$;

-- ---------------------------------------------------------------------
-- 5. THE READ PATH IS SECURITY INVOKER, INCLUDING THE FUNCTIONS ADDED SINCE.
--
-- integration-rbac.sql §4 already self-checks a named list. This asserts the
-- rule over the whole read surface rather than over a list somebody has to
-- remember to extend -- which is the failure mode of a named list: the
-- function added next month is the one that is not on it.
--
-- SECURITY DEFINER here would return every tenant's rows through a function
-- that looks like a query helper.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'aiq'
      and p.prosecdef
      -- the schema facets are deliberately SECURITY DEFINER: they return names
      -- and shapes from catalogs the caller holds no grants on, and §13 makes
      -- that case explicitly (the caller-scoped one, `sql`, is the exception
      -- that reads as the caller).
      and p.proname not like 'schema%'
      and p.proname not in ('render_facet','facet_examples','verify_example',
                            'capture_schema_revisions')
      -- ...and only functions a USER can actually reach. The rule this section
      -- asserts is integration-rbac's: "every SECURITY DEFINER function
      -- reachable by an end user MUST do its own authorization check.
      -- Worker-facing functions are exempt because EXECUTE on them is granted
      -- only to `worker`, which is infrastructure, not a user identity --
      -- their authorization IS the grant." Written as a predicate rather than
      -- as three more names on the exclusion list above, because the list is
      -- the failure mode this section's own comment names: the function added
      -- next month is the one that is not on it. A definer function that is
      -- reachable by authenticated, web_anon or api_viewer still fails here,
      -- which is the case that matters.
      and (has_function_privilege('authenticated', p.oid, 'execute')
        or has_function_privilege('web_anon', p.oid, 'execute')
        or has_function_privilege('api_viewer', p.oid, 'execute'));
    if v_bad is not null then
        raise exception
            'aiq read-path functions are SECURITY DEFINER: %. These run on behalf '
            'of a user and must be subject to that user''s RLS', v_bad;
    end if;
    raise notice 'query/06: every non-facet aiq function reads as the caller';
end $$;

-- ---------------------------------------------------------------------
-- 6. NAMING AND REGISTRATION ARE NOT USER OPERATIONS.
--
-- register_entity_table() executes DDL built from its arguments, so granting
-- it to `authenticated` would be a SQL-injection surface with DDL privileges
-- attached. add_node_key() executes no DDL, but an alias silently re-points
-- every LOOKUP that uses it -- editorial power over what names mean -- so it
-- keeps the same company.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'aiq'
      and p.proname in ('register_entity_table','rebuild_entity_type','add_node_key',
                        'register_embedding_space','register_lexical_source')
      and (has_function_privilege('authenticated', p.oid, 'execute')
        or has_function_privilege('web_anon', p.oid, 'execute'));
    if v_bad is not null then
        raise exception
            'administrative graph functions are callable by an end-user role: %',
            v_bad;
    end if;
    raise notice 'query/06: registration and naming stay with the migration role';
end $$;

rollback;
