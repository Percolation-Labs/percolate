-- RETRIEVAL AT SCALE -- the vector index gives up before the tenant filter
-- does, and the caller is told nothing.
--
-- `08-retrieval.sql` proves the three retrieval modes return the right rows.
-- `09-retrieval-tenancy.sql` proves they never return a row the caller may not
-- see. Both are about PRECISION, both pass, and both are blind to the failure
-- this file exists for, which is RECALL: the modes returning FEWER rows than
-- exist -- often none at all -- for a caller whose tenancy is narrow.
--
-- THE MECHANISM. `aiq.semantic_in` ranks with an HNSW index and then joins the
-- consumer's table, so the consumer's policies decide what survives. The join
-- is deliberately after the ranking (09 asserts exactly that, and is right to).
-- But an HNSW index scan with pgvector's default `hnsw.iterative_scan = off`
-- produces a BOUNDED candidate set -- `hnsw.ef_search`, 40 rows by default --
-- and is then exhausted. If the caller's policy removes all of them, the query
-- ends with nothing, having never asked the index for more.
--
-- So the failure is:
--
--     a tenant who can read 1004 chunks of a 200004-chunk corpus
--     asks SEMANTIC ... LIMIT 10
--     and receives 0 rows
--
-- measured on that fixture, with LIMIT 50 also returning 0 -- because LIMIT is
-- not what bounds the index scan, which is the part that defeats the obvious
-- workaround. Nothing raises. `aiq.search` inherits it and is worse: its
-- lexical half still answers, so SEARCH returns a plausible page of results
-- with its entire semantic ranker silently contributing nothing, and the only
-- trace is a `semantic_rank` that is null on every row.
--
-- WHY EVERY EXISTING TEST PASSED. `dev/init/05-corpus-sample.sql` holds six
-- chunks. Below a few thousand rows the planner does not choose the HNSW index
-- at all -- it seq-scans and ranks exactly -- so the entire suite has been
-- exercising a code path that production does not take. This is the
-- "a small graph hides the shape of every cost" argument from
-- `dev/scale/graph/README.md`, one subsystem over: a small CORPUS hides the
-- only interesting thing about a vector index.
--
-- HOW THIS FILE REPRODUCES IT IN A SECOND RATHER THAN FOUR MINUTES. Two
-- things, and both are what make the assertion deterministic rather than
-- probabilistic:
--
--   * the tenant's rows are placed at the FAR END of the vector space from the
--     probe. A bounded scan cannot reach them by construction, so the test
--     does not depend on how a random draw happened to land.
--   * `enable_seqscan = off` forces the planner onto the index at 2010 rows,
--     which is the plan it would choose on its own at 200000.
--
-- Neither is a cheat: they reproduce at fixture speed the plan the database
-- picks by itself at corpus scale. What the file must NOT do is assert the
-- happy path alone -- an assertion that cannot fail is documentation wearing a
-- test's clothes -- so §2 is a CONTROL that runs the same query with the
-- iterative scan off and requires it to come back SHORT. If the control ever
-- starts returning a full page, this file has stopped testing anything and
-- says so rather than going quietly green.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

-- The probe, and the two poles. Written once here so §1-§3 cannot drift apart.
\set probe '''[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]'''

-- ---------------------------------------------------------------------
-- 0. A corpus big enough for the planner to reach for the index.
--
-- 2000 chunks in a resource nobody but the owner may read, and 10 in a
-- resource the tenant may read: 0.5% visible, which is an ordinary shape for a
-- shared corpus and the one the committed fixture cannot express with six rows.
-- ---------------------------------------------------------------------
insert into aiq.embedding_models (name, dim, is_default) values ('scaletest', 16, false);
select aiq.register_embedding_space('scaletest');

insert into rbac.orgs (id, slug, name)
    values ('cccc0000-0000-0000-0000-00000000000a','scaletest','scaletest');
insert into rbac.org_members (org_id, user_id, role)
    values ('cccc0000-0000-0000-0000-00000000000a',
            '22222222-2222-2222-2222-222222222222','member');
insert into content.channels (id, name, kind, org_id, visibility)
    values ('11110000-0000-0000-0000-0000000000aa','scaletest','manual',null,'public');
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility) values
    ('33330000-0000-0000-0000-00000000aa01','11110000-0000-0000-0000-0000000000aa',
     'st-crowd','memo://scaletest/crowd','the crowd','ready',null,'private'),
    ('33330000-0000-0000-0000-00000000aa02','11110000-0000-0000-0000-0000000000aa',
     'st-mine','memo://scaletest/mine','the tenant''s own','ready',
     'cccc0000-0000-0000-0000-00000000000a','org');

insert into content.resource_chunks (id, resource_id, ordinal, content)
select ('55550000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
       '33330000-0000-0000-0000-00000000aa01', n, 'crowd chunk '||n
from generate_series(1,2000) n;
insert into content.resource_chunks (id, resource_id, ordinal, content)
select ('55550000-0000-0000-0000-'||lpad((9000+n)::text,12,'0'))::uuid,
       '33330000-0000-0000-0000-00000000aa02', n, 'zebrafish memorandum '||n
from generate_series(1,10) n;

-- LATERAL, so the vector is computed per row. An uncorrelated scalar subquery
-- here is evaluated ONCE by Postgres and gives every row the same vector --
-- which is how the first version of this fixture came to hold 200000 rows and
-- one distinct value, and to measure nothing at all while looking busy.
insert into aiq.emb_scaletest (chunk_id, embedding)
select c.id, v.vec
from content.resource_chunks c
cross join lateral (
    select ('[' || string_agg(
        case when c.resource_id = '33330000-0000-0000-0000-00000000aa01'
             then (1.0 + (hashtext(c.id::text || d) % 1000) / 100000.0)::text
             else (-1.0)::text end, ',' order by d) || ']')::vector(16) as vec
    from generate_series(1,16) d
) v
where c.resource_id in ('33330000-0000-0000-0000-00000000aa01',
                        '33330000-0000-0000-0000-00000000aa02');

analyze aiq.emb_scaletest;
analyze content.resources;
analyze content.resource_chunks;

-- ---------------------------------------------------------------------
-- 1. THE FIXTURE IS ACTUALLY NARROW, and the tenant's rows are actually far.
--
-- Both assertions below are worthless if either is untrue, so neither is
-- assumed. The second is the one that makes §2 deterministic.
-- ---------------------------------------------------------------------
do $$
declare v_visible int; v_total int; v_near_rank int;
begin
    select count(*) into v_total from aiq.emb_scaletest;

    set local role authenticated;
    set local request.jwt.claims =
        '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["cccc0000-0000-0000-0000-00000000000a"]}';
    select count(*) into v_visible from content.resource_chunks
     where id::text like '55550000%';

    if v_visible <> 10 then
        raise exception 'the tenant should see 10 of the % chunks, sees %', v_total, v_visible;
    end if;

    -- Every visible chunk is farther from the probe than every invisible one.
    set local role app_owner;
    select count(*) into v_near_rank
    from aiq.emb_scaletest e
    join content.resource_chunks c on c.id = e.chunk_id
    where c.resource_id = '33330000-0000-0000-0000-00000000aa02'
      and (e.embedding <=> '[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]'::vector(16))
          < (select max(e2.embedding <=> '[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]'::vector(16))
             from aiq.emb_scaletest e2
             join content.resource_chunks c2 on c2.id = e2.chunk_id
             where c2.resource_id = '33330000-0000-0000-0000-00000000aa01');
    if v_near_rank <> 0 then
        raise exception
            'the fixture is not polarised: % of the tenant''s chunks are nearer '
            'the probe than the farthest crowd chunk, so a bounded scan might '
            'reach them by luck and section 2 would not be deterministic', v_near_rank;
    end if;

    raise notice 'query/13: the tenant sees 10 of % chunks, and all 10 are the farthest from the probe', v_total;
end $$;

-- ---------------------------------------------------------------------
-- 2. THE CONTROL. The trap is live on this fixture.
--
-- This runs the query `aiq.semantic_in` builds, with the iterative scan left
-- at pgvector's default, and REQUIRES it to come back short. It is the half of
-- this file that can fail for the right reason: if a future pgvector defaults
-- `hnsw.iterative_scan` on, or the planner stops choosing the index here, this
-- assertion fires and tells you §3 has become a tautology -- rather than §3
-- passing forever on a database where nothing is being tested.
-- ---------------------------------------------------------------------
do $$
declare v_rows int;
begin
    set local role authenticated;
    set local request.jwt.claims =
        '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["cccc0000-0000-0000-0000-00000000000a"]}';
    set local enable_seqscan = off;
    set local hnsw.iterative_scan = off;

    select count(*) into v_rows from (
        select e.chunk_id
        from aiq.emb_scaletest e
        join content.resource_chunks c on c.id = e.chunk_id
        order by e.embedding <=> '[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]'::vector(16)
        limit 5) t;

    if v_rows >= 5 then
        raise exception
            'the control returned % rows: a bounded HNSW scan is no longer '
            'losing this tenant''s chunks on this fixture, so section 3 is '
            'asserting nothing. Check whether pgvector now defaults '
            'hnsw.iterative_scan on, or whether the planner stopped choosing '
            'the index at this size.', v_rows;
    end if;

    raise notice 'query/13: control -- the bounded scan returns %/5 rows, so the trap is live here', v_rows;
end $$;

-- ---------------------------------------------------------------------
-- 3. SEMANTIC ANSWERS IN FULL, for a caller the bounded scan cannot serve.
--
-- Same query, same fixture, same caller, through the mode rather than by hand.
-- It must return the whole page. And it must do so even when the CALLER has
-- set the parameter the other way: the guarantee belongs to the function, not
-- to whoever happened to configure the session.
-- ---------------------------------------------------------------------
do $$
declare v_rows int; v_after text;
begin
    set local role authenticated;
    set local request.jwt.claims =
        '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["cccc0000-0000-0000-0000-00000000000a"]}';
    set local enable_seqscan = off;
    set local hnsw.iterative_scan = off;

    select count(*) into v_rows from aiq.semantic_in(
        'chunks', '[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]'::vector(16), 'scaletest', 5);
    if v_rows <> 5 then
        raise exception
            'SEMANTIC returned % of the 5 rows asked for, from a corpus holding '
            '10 the caller may read. The vector index gave up before the tenant '
            'filter did.', v_rows;
    end if;

    -- and it put the session back the way it found it, rather than leaving a
    -- planner setting altered for the rest of the caller's transaction.
    v_after := current_setting('hnsw.iterative_scan', true);
    if v_after <> 'off' then
        raise exception
            'aiq.semantic_in left hnsw.iterative_scan = %, changing how every '
            'later vector query in this transaction is planned', v_after;
    end if;

    raise notice 'query/13: SEMANTIC returns 5/5 for a 0.5%% tenant, and restores the caller''s setting';
end $$;

-- ---------------------------------------------------------------------
-- 4. SEARCH STILL HAS TWO RANKERS.
--
-- The reason this gets its own section rather than riding on §3: SEARCH is the
-- mode where the failure is invisible. Its lexical half is unaffected, so it
-- returns a full, plausible, well-ordered page whether or not the semantic half
-- contributed anything -- and a caller reading results has no way to tell that
-- half the ranking is missing. `semantic_rank` is the only witness, so it is
-- what gets asserted.
-- ---------------------------------------------------------------------
do $$
declare v_rows int; v_with_semantic int;
begin
    set local role authenticated;
    set local request.jwt.claims =
        '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["cccc0000-0000-0000-0000-00000000000a"]}';
    set local enable_seqscan = off;
    set local hnsw.iterative_scan = off;

    select count(*), count(s.semantic_rank) into v_rows, v_with_semantic
    from aiq.search('chunks', 'zebrafish memorandum',
                    '[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]'::vector(16), 'scaletest', 5) s;

    if v_rows = 0 then
        raise exception 'SEARCH returned nothing at all -- the lexical half is broken too';
    end if;
    if v_with_semantic = 0 then
        raise exception
            'SEARCH returned % rows and not one carries a semantic_rank: the '
            'fusion degraded to lexical-only and reported success', v_rows;
    end if;

    raise notice 'query/13: SEARCH returns % rows, % of them ranked by the semantic half too',
        v_rows, v_with_semantic;
end $$;

rollback;
