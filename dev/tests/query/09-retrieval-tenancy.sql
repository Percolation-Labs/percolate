-- RETRIEVAL AND TENANCY -- what a vector search can tell you about content you
-- may not read.
--
-- `06-graph-tenancy.sql` covers the graph half. This is the retrieval half,
-- and it is separate because the leak has a different shape: a graph walk
-- moves between rows in tables that carry policies, while a vector search
-- ranks rows in a table that carries none. `aiq.emb_<model>` is generated per
-- MODEL, holds every registered corpus's chunks together, and has no way to
-- know which consumer table a chunk_id came from -- so nothing about it can be
-- row-filtered on its own.
--
-- The measured failure, on the committed fixture: a caller holding org B's
-- claim can read five of six chunks -- content's own RLS correctly hides org
-- A's memo -- and SEMANTIC returned all six, org A's memo included, at rank
-- three. The text did not come back; the id, the existence, and the cosine
-- distance to an arbitrary probe did. A similarity oracle over content you
-- cannot read, answering any vector you care to send, is the attack rather
-- than a step towards one.
--
-- The fix is that SEMANTIC joins the space to the corpus named in `FROM`,
-- which both scopes the search and puts the consumer's own policies in the
-- path, since the mode is SECURITY INVOKER and the join reads as the caller.

\set ON_ERROR_STOP on

begin;

do $$
begin
    if not exists (select 1 from content.resources
                    where id = '22220000-0000-0000-0000-000000000004') then
        raise exception 'the corpus sample is not loaded (dev/init/05-corpus-sample.sql)';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. THE FIXTURE IS ACTUALLY ASYMMETRIC.
--
-- Every assertion below is worthless if the owner and the tenant see the same
-- corpus, so that is established first rather than assumed.
-- ---------------------------------------------------------------------
do $$
declare v_owner int; v_b int;
begin
    set local role app_owner;
    select count(*) into v_owner from content.resource_chunks;

    set local role authenticated;
    set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000b"]}';
    select count(*) into v_b from content.resource_chunks;
    reset role;

    if v_b >= v_owner then
        raise exception
            'org B can read every chunk the owner can (% of %) -- content''s own '
            'RLS is not scoping this corpus, and nothing below tests anything',
            v_b, v_owner;
    end if;
    if v_b = 0 then
        raise exception 'org B can read nothing, so a mode returning nothing would pass';
    end if;
    raise notice 'query/09: the corpus is asymmetric (owner %, org B %)', v_owner, v_b;
end $$;

-- ---------------------------------------------------------------------
-- 2. NO MODE RETURNS A CHUNK THE CALLER CANNOT READ.
--
-- Asserted against the caller's OWN view of the corpus rather than against a
-- hardcoded count: the question is not "did it return five rows", it is "did
-- it return anything that is not in `select id from resource_chunks` for this
-- caller". A count would keep passing if the fixture grew.
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000b"]}';

do $$
declare v_leaked uuid[];
begin
    -- SEMANTIC: the mode with no policy of its own to lean on.
    select array_agg(s.chunk_id) into v_leaked
    from aiq.semantic_in('chunks', '[1,0,0,0]', 'demo-quad-a', 50) s
    where not exists (select 1 from content.resource_chunks c where c.id = s.chunk_id);
    if v_leaked is not null then
        raise exception
            'SEMANTIC returned % chunk(s) this caller cannot read: %. The space '
            'holds every corpus and carries no policy; only the join to the '
            'corpus named in FROM can filter it', array_length(v_leaked,1), v_leaked;
    end if;

    -- TEXT reads the consumer's table directly, so it inherits the policy for
    -- free -- asserted anyway, because "for free" is a property of the current
    -- implementation rather than a guarantee anybody wrote down.
    select array_agg(l.chunk_id) into v_leaked
    from aiq.lexical('chunks', 'R7', 50) l
    where not exists (select 1 from content.resource_chunks c where c.id = l.chunk_id);
    if v_leaked is not null then
        raise exception 'TEXT returned chunks this caller cannot read: %', v_leaked;
    end if;

    -- SEARCH fuses the two and must not widen either.
    select array_agg(h.chunk_id) into v_leaked
    from aiq.search('chunks', 'R7 recall', '[1,0,0,0]', 'demo-quad-a', 50) h
    where not exists (select 1 from content.resource_chunks c where c.id = h.chunk_id);
    if v_leaked is not null then
        raise exception 'SEARCH returned chunks this caller cannot read: %', v_leaked;
    end if;

    raise notice 'query/09: no mode returns a chunk outside the caller''s corpus';
end $$;

-- The specific row, named, because a generic assertion can pass on an empty
-- result and this is the one that was actually leaking.
do $$
begin
    if exists (select 1 from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-a',50)
                where chunk_id = '33330000-0000-0000-0000-000000000004') then
        raise exception
            'org A''s private memo is still reachable through SEMANTIC by org B';
    end if;
    -- ...and the caller can still see its own org-scoped chunk, so the filter
    -- is scoping rather than simply hiding everything org-scoped.
    if not exists (select 1 from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-a',50)
                    where chunk_id = '33330000-0000-0000-0000-000000000005') then
        raise exception 'the caller cannot reach its OWN org-scoped chunk -- the '
                        'filter has become a blanket exclusion of org-scoped rows';
    end if;
    raise notice 'query/09: the hidden memo is gone, the caller''s own row is not';
end $$;

-- ---------------------------------------------------------------------
-- 3. A HIDDEN CHUNK DOES NOT OCCUPY A RANK.
--
-- Subtler than the disclosure and worth its own assertion: if the invisible
-- row were filtered AFTER ranking, it would still consume a position, so every
-- visible chunk's fused RRF score would depend on content the caller cannot
-- see. Ranks must be dense from the caller's point of view.
-- ---------------------------------------------------------------------
do $$
declare v_ranks int[];
begin
    select array_agg(semantic_rank order by semantic_rank) into v_ranks
    from aiq.search('chunks','R7 recall','[1,0,0,0]','demo-quad-a',50)
    where semantic_rank is not null;

    if v_ranks is null then
        raise exception 'no semantic ranks at all -- the fusion lost its vector half';
    end if;
    for i in 1 .. array_length(v_ranks, 1) loop
        if v_ranks[i] <> i then
            raise exception
                'semantic ranks are % -- a gap means an invisible chunk was ranked '
                'and then filtered, so this caller''s scores depend on rows it '
                'cannot see', v_ranks;
        end if;
    end loop;
    raise notice 'query/09: ranks are dense -- hidden rows never entered the ranking';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------
-- 4. THE TWO TENANTS GET DIFFERENT ANSWERS TO THE SAME QUERY.
--
-- The end-to-end statement of the property, through the dialect rather than
-- the functions, and the form in which a reviewer would want to see it: the
-- identical request, the identical probe vector, two callers, two answers.
-- ---------------------------------------------------------------------
do $$
declare v_a jsonb; v_b jsonb; v_owner jsonb;
begin
    set local role authenticated;
    set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000a"]}';
    v_a := aiq.query('SEARCH "R7 recall" FROM chunks LIMIT 10', '[1,0,0,0]');
    set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000b"]}';
    v_b := aiq.query('SEARCH "R7 recall" FROM chunks LIMIT 10', '[1,0,0,0]');
    reset role;
    v_owner := aiq.query('SEARCH "R7 recall" FROM chunks LIMIT 10', '[1,0,0,0]');

    if v_a = v_b then
        raise exception 'two different tenants got byte-identical answers to a '
                        'query whose corpus differs between them';
    end if;
    if jsonb_array_length(v_a->'rows') >= jsonb_array_length(v_owner->'rows')
       and jsonb_array_length(v_b->'rows') >= jsonb_array_length(v_owner->'rows') then
        raise exception 'both tenants see as much as the owner does';
    end if;
    -- The counts are equal here and that is correct -- each tenant holds
    -- exactly one org-scoped chunk -- so the assertion is on WHICH rows came
    -- back, not how many. Comparing counts would have passed even if the two
    -- callers had received each other's corpora.
    --
    -- org A owns the second R7 memo; it must appear for org A and for nobody
    -- else, and it is a lexical hit rather than a vector one, so this covers
    -- the branch the vector fix did not touch.
    if not exists (select 1 from jsonb_array_elements(v_a->'rows') r
                    where r->>'chunk_id' = '33330000-0000-0000-0000-000000000004') then
        raise exception 'org A cannot retrieve its own R7 memo';
    end if;
    if exists (select 1 from jsonb_array_elements(v_b->'rows') r
                where r->>'chunk_id' = '33330000-0000-0000-0000-000000000004') then
        raise exception 'org B retrieved org A''s R7 memo through SEARCH';
    end if;
    if not exists (select 1 from jsonb_array_elements(v_owner->'rows') r
                    where r->>'chunk_id' = '33330000-0000-0000-0000-000000000004') then
        raise exception 'the owner cannot see it either, so the filter is not '
                        'tenancy -- it is hiding the row from everybody';
    end if;
    raise notice 'query/09: same query, same vector, three callers, three corpora (% / % / %)',
        jsonb_array_length(v_a->'rows'), jsonb_array_length(v_b->'rows'),
        jsonb_array_length(v_owner->'rows');
end $$;

-- ---------------------------------------------------------------------
-- 5. WHAT IS STILL EXPOSED, PINNED SO THAT CLOSING IT IS DELIBERATE.
--
-- The embedding spaces themselves are directly SELECT-able by `authenticated`.
-- That is not an oversight: integration-rbac.sql grants the schema's tables --
-- and sets ALTER DEFAULT PRIVILEGES so spaces registered later are covered --
-- precisely because the query modes are SECURITY INVOKER and must read them as
-- the caller. Withholding the grant would break every SEMANTIC call.
--
-- The residue is that a caller who queries `aiq.emb_<model>` directly still
-- sees chunk ids and raw vectors for content it cannot read. Raw vectors are
-- not innocuous -- embedding inversion is a published attack -- so this is a
-- real exposure with a known fix that is NOT built: per-source row policies on
-- generated spaces, which needs the registry to be consulted at policy time.
--
-- This assertion documents the current state rather than approving it. It is
-- expected to be INVERTED when the policies land, not deleted, so that the
-- engine and graph-identity.md's note change together.
-- ---------------------------------------------------------------------
do $$
declare v_direct int; v_via_mode int;
begin
    set local role authenticated;
    set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000b"]}';
    select count(*) into v_direct from aiq.emb_demo_quad_a;
    select count(*) into v_via_mode from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-a',50);
    reset role;

    if v_direct <= v_via_mode then
        raise exception
            'the embedding space is no longer more permissive than the mode over '
            'it (direct %, via SEMANTIC %). If per-source policies on generated '
            'spaces have landed, that is the improvement this assertion is '
            'waiting for -- update the note in ai-query-layer/schema.sql §10 and '
            'invert this check rather than deleting it', v_direct, v_via_mode;
    end if;
    raise notice 'query/09: the space is readable directly (% rows vs % via the mode) '
                 '-- documented residue, not a passing grade', v_direct, v_via_mode;
end $$;

rollback;
