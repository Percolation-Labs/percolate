-- claims.candidates (REM-659, specs/claims/graph.md §5 *Did you mean*): the claims nearest an occurrence that the
-- caller may read, to be asked about. Four exclusions, each shown against the case where it does not apply, so a
-- removed predicate fails here rather than passing: the occurrence itself, its own work, a revision the
-- caller may not read, and a pair that already carries a relation. It ranks by distance, it returns no score, and
-- it writes nothing.
--
-- The vectors are three dimensions and hand-written, so every distance below is exact. Cosine distance from
-- [1,0,0] is 0 to [1,0,0], 1 - 1/sqrt(1.04) = 0.0194 to [1,0.2,0], 1 - 1/sqrt(2) = 0.2929 to [1,1,0] and 1 to
-- [0,1,0]. A1's own-work twin A2 sits exactly on it, nearer than anything it may be offered, which is what makes
-- the limit assertion below able to fail: a limit applied before the exclusions would spend it on A2 and return
-- nothing.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000659a1', 'cand-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000659b1', 'cand-b@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000659c1', 'cand-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-cand-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-cand-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000659a1', 'rp-cand-lister'),
                                                   ('00000000-0000-4000-8000-0000000659b1', 'rp-cand-lister'),
                                                   ('00000000-0000-4000-8000-0000000659c1', 'rp-cand-lister');

-- A model of this deployment's own, not the default: claims.candidates is asked for it by name, so the test says
-- nothing about whichever model a deployment has made default.
--
-- Registered AS app_owner, which is not decoration. A space is a table created at run time, and it is
-- `alter default privileges for role app_owner in schema aiq` that grants a caller role select on it
-- (specs/ai-query-layer/integration-rbac.sql §2). Register one as anybody else -- a superuser at a psql prompt --
-- and the space comes up with no grant, its read policy is written for no role, and every SEMANTIC call against
-- that model fails with "permission denied for table emb_<model>".
set local role app_owner;
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('cand-test-3d', 3, 'fastembed', 'cand-test-3d', false,
        'three dimensions, and every vector in its space is written by hand below: nothing here calls a provider');
select aiq.register_embedding_space('cand-test-3d');
reset role;

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('wa', research.submit_package('{"schema_version": "0.1", "title": "Cand A", "visibility": "listed", "edges": [],
        "claims": [{"id": "A1", "kind": "Inference", "text": "A retrieval floor is a cost, not a confidence.", "source_ids": ["S1"]},
                   {"id": "A2", "kind": "Inference", "text": "A retrieval floor is a cost and never a confidence.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/ca", "origin": "A"}]}', null, 'rp-cand-a')->>'revision_id');
    insert into ids values ('wp', research.submit_package('{"schema_version": "0.1", "title": "Cand private", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "A retrieval floor is a cost, privately noted.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cp", "origin": "P"}]}', null, 'rp-cand-p')->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('wb', research.submit_package('{"schema_version": "0.1", "title": "Cand B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "Choosing a retrieval floor is choosing what to pay.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cb", "origin": "B"}]}', null, 'rp-cand-b')->>'revision_id');
    insert into ids values ('wc', research.submit_package('{"schema_version": "0.1", "title": "Cand C", "visibility": "listed", "edges": [],
        "claims": [{"id": "C1", "kind": "Inference", "text": "Gravitational lensing traces total matter.", "source_ids": ["S1"]},
                   {"id": "C2", "kind": "Inference", "text": "This claim is never embedded at all.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cc", "origin": "C"}]}', null, 'rp-cand-c')->>'revision_id');
end $$;
reset role;

-- The vectors, written as the owner of the space: A1, its own-work twin A2 sitting exactly on it, the private P1
-- just off it, the near B1, the far C1, and C2 with no vector at all.
insert into aiq."emb_cand_test_3d" (chunk_id, embedding)
select c.id,
       case c.claim_key when 'A1' then '[1,0,0]' when 'A2' then '[1,0,0]' when 'P1' then '[1,0.2,0]'
                        when 'B1' then '[1,1,0]' when 'C1' then '[0,1,0]' end::vector
  from research.claims c
 where c.revision_id in (select v::uuid from ids) and c.claim_key <> 'C2';

-- 1. The near one is offered, and the three exclusions hold for the owner of the arriving claim.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare
    wa   uuid := (select v::uuid from ids where k = 'wa');
    rows record;
begin
    select array_agg(k.claim_key order by k.distance) keys, array_agg(round(k.distance::numeric, 4) order by k.distance) d
      into rows
      from claims.candidates(wa, 'A1', 0.5, 5, null, 'cand-test-3d') k;
    assert rows.keys = '{P1,B1}',
        'the two claims inside the floor, nearest first, and neither A1 nor its own work''s A2: ' || rows.keys::text;
    assert rows.d = '{0.0194,0.2929}', 'the distance is the metric and not a score: ' || rows.d::text;

    -- The floor is the caller's, and raising it reaches the far claim.
    assert (select array_agg(claim_key order by distance)
              from claims.candidates(wa, 'A1', 1.5, 5, null, 'cand-test-3d')) = '{P1,B1,C1}',
        'a wider floor reaches the far claim';
    -- And a claim with no vector is in no space, so it is never a candidate at any floor.
    assert not (select array_agg(claim_key) from claims.candidates(wa, 'A1', 2.0, 9, null, 'cand-test-3d')) @> '{C2}',
        'an unembedded claim cannot be offered';
    -- p_limit bounds what the reader is asked, after the ordering and not before it.
    assert (select array_agg(claim_key order by distance)
              from claims.candidates(wa, 'A1', 1.5, 1, null, 'cand-test-3d')) = '{P1}',
        'the limit keeps the nearest OFFERABLE claim: spent on the excluded A2 it would return nothing';
    -- The vector may arrive alongside instead of being looked up, which is how a claim being written is asked.
    -- Inside 0.1 of A1's own vector lies P1; inside 0.1 of the one passed here lies B1, and the answer changes.
    assert (select array_agg(claim_key order by distance)
              from claims.candidates(wa, 'A1', 0.1, 5, null, 'cand-test-3d')) = '{P1}',
        'the stored vector is used when none is passed';
    assert (select array_agg(claim_key order by distance)
              from claims.candidates(wa, 'A1', 0.1, 5, '[1,1,0]'::vector, 'cand-test-3d')) = '{B1}',
        'a passed vector is the one ranked against';
end $$;
reset role;

-- 2. A stranger is offered only what they may read, and the same call proves the difference is the horizon.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659c1"}';
set local role authenticated;
do $$
declare wa uuid := (select v::uuid from ids where k = 'wa');
begin
    assert (select array_agg(claim_key order by distance)
              from claims.candidates(wa, 'A1', 0.5, 5, null, 'cand-test-3d')) = '{B1}',
        'the private claim its owner was offered is not offered to a stranger';
end $$;
reset role;

-- 3. An answered pair is not asked about again, and the count of relations says the reader wrote nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare
    wa uuid := (select v::uuid from ids where k = 'wa');
    wb uuid := (select v::uuid from ids where k = 'wb');
    n  bigint := (select count(*) from claims.relations);
begin
    perform claims.candidates(wa, 'A1', 1.5, 9, null, 'cand-test-3d');
    assert (select count(*) from claims.relations) = n, 'asking writes nothing';

    perform claims.assert_relation('A1', 'same_as', 'B1', wa, wb, null,
        jsonb_build_object('src', 'A retrieval floor is a cost', 'dst', 'Choosing a retrieval floor is choosing what to pay',
            'slots', jsonb_build_object(
                'src', jsonb_build_object('subject','a retrieval floor','predicate','is','object','a cost','scope','retrieval','polarity','positive','modality','asserted'),
                'dst', jsonb_build_object('subject','a retrieval floor','predicate','is','object','a cost','scope','retrieval','polarity','positive','modality','asserted'))),
        'answered');
    assert (select array_agg(claim_key order by distance)
              from claims.candidates(wa, 'A1', 0.5, 5, null, 'cand-test-3d')) = '{P1}',
        'the answered pair is not asked about again, and the unanswered one still is';
end $$;
reset role;

-- 4. What it refuses, each by its own condition rather than by failing to return rows.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare
    wa uuid := (select v::uuid from ids where k = 'wa');
    wc uuid := (select v::uuid from ids where k = 'wc');
begin
    begin
        perform claims.candidates(wa, 'no-such-key', 0.5, 5, null, 'cand-test-3d');
        raise exception 'candidates for a claim key that is not there';
    exception when no_data_found then null;
    end;
    begin
        perform claims.candidates(wa, 'A1', 0.5, 5, null, 'cand-test-nonesuch');
        raise exception 'candidates against a model nobody registered';
    exception when no_data_found then null;
    end;
    begin
        -- A null floor makes `distance <= null` null for every row, so it returned nothing and said nothing --
        -- this function's own defect, through the front door. Measured before the refusal existed: 0 rows, no
        -- error, against 2 for the same call at 1.5.
        perform claims.candidates(wa, 'A1', null, 5, null, 'cand-test-3d');
        raise exception 'candidates with a null floor returned rather than refusing';
    exception when check_violation then null;
    end;
    begin
        perform claims.candidates(wa, 'A1', 0.5, 5, '[1,0,0,0]'::vector, 'cand-test-3d');
        raise exception 'candidates against a vector of the wrong shape';
    exception when check_violation then null;
    end;
    begin
        -- C2 is in no space, so asking about it has no vector to rank with and says so.
        perform claims.candidates(wc, 'C2', 0.5, 5, null, 'cand-test-3d');
        raise exception 'candidates for a claim that was never embedded';
    exception when no_data_found then null;
    end;
end $$;
reset role;

-- 5. research.claims is a registered semantic source, shipped with the extension, so a claim has a space by
--    construction and aiq's own policies cover its vectors. Read DIRECTLY here, not through claims.candidates:
--    that function joins research.claims, so its own row security would hide an unreadable claim even if the
--    space policy were open, and an assertion through it proves nothing about the space.
do $$ begin
    assert (select source_table from aiq.semantic_sources where name = 'claims') = 'research.claims',
        'claims are registered with the query layer';
    assert exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
                    where c.relname = 'emb_cand_test_3d' and p.polname like 'space\_read\_%'),
        'and the space carries a read policy rather than handing every tenant''s vectors to any caller';
    -- Each branch is correlated, not hashed. Without `offset 0` the planner rewrites it to a hashed IN and reads
    -- the whole source table once per query: measured at 443 ms against 0.41 ms on an eleven-vector space once
    -- research.claims (3,909 rows) was registered. The TIMING needs that corpus; the PLAN does not, which is
    -- what the assertion below this one reads.
    assert (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
             where c.relname = 'emb_cand_test_3d' and p.polname like 'space\_read\_%'
               and pg_get_expr(p.polqual, p.polrelid) not like '%OFFSET 0%') = 0,
        'every branch of a space read policy is fenced with OFFSET 0, or the planner hashes it';
end $$;

-- And the fence still WORKS, which the assertion above cannot see. `OFFSET 0` is optimiser behaviour rather
-- than a documented contract: a future planner that treats a zero offset as the no-op it literally is would
-- leave the policy text unchanged, the assertion above green, and 443 ms back on every vector search in every
-- deployment with nothing failing anywhere. So this reads the plan. The two fail for different reasons -- one
-- catches a branch generated without the fence, the other catches the fence going inert -- and both are needed.
-- The plan differs at five rows even though the timing does not, which is what makes this gateable at all.
create or replace function pg_temp.plan_of(p_rel text) returns text language plpgsql as $$
declare r record; out text := '';
begin
    for r in execute format('explain (costs off) select * from %s', p_rel) loop
        out := out || r."QUERY PLAN" || E'\n';
    end loop;
    return out;
end $$;
create table pg_temp.unfenced_probe (chunk_id uuid);
insert into pg_temp.unfenced_probe select id from research.claims limit 5;
grant select on pg_temp.unfenced_probe to authenticated;
alter table pg_temp.unfenced_probe enable row level security;
create policy unfenced on pg_temp.unfenced_probe for select to authenticated
    using (exists (select 1 from research.claims s where s.id = unfenced_probe.chunk_id));

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare
    plan    text := pg_temp.plan_of('aiq."emb_cand_test_3d"');
    control text := pg_temp.plan_of('pg_temp.unfenced_probe');
    sources int  := (select count(*) from aiq.semantic_sources s
                      where to_regclass(s.source_table) is not null
                        and has_table_privilege('authenticated', s.source_table, 'select'));
begin
    -- THE CONTROL COMES FIRST, because without it this whole block is a gate that cannot fail. Whether an
    -- UNFENCED branch flattens is a cost decision, not a certainty: the planner hashes a small source because
    -- reading it whole is cheap and declines on a large one, so an unfenced policy over a big table plans
    -- identically to a fenced one. A fenced branch is correlated at any size, because the fence blocks the
    -- transformation rather than outbidding it. So the assertion below has no false alarms -- and it goes inert
    -- the day this fixture grows past the threshold, passing forever having tested nothing.
    --
    -- unfenced_probe is that threshold, asserted rather than assumed: a deliberately unfenced policy over the
    -- same source these claims sit in. If it does not flatten, this fixture cannot exercise the real assertion
    -- and the gate says so instead of going green.
    assert control like '%chunk_id = (hashed SubPlan%',
        'the control did not flatten, so this fixture can no longer tell a fenced policy from an unfenced one '
        'and the assertions below prove nothing. Control plan: ' || control;

    -- The signature of the flattening is exactly `chunk_id = (hashed SubPlan`. The bare words `hashed SubPlan`
    -- are too wide: content.resource_chunks' own policy carries two of them NESTED INSIDE a correctly
    -- correlated branch, so that form fires on a fenced policy. Measured here before this was narrowed.
    assert plan not like '%chunk_id = (hashed SubPlan%',
        'a space read policy was flattened to a hashed subplan: the OFFSET 0 fence is inert, and every vector '
        'search now reads each registered source table once per query. Plan: ' || plan;

    -- And the positive half: one correlated branch per source this role may read, counted rather than merely
    -- present, so a policy with one branch flattened and the rest correlated fails here. No node prefix: a
    -- correlated branch over a small source renders `Filter: (id = ...)` under a Seq Scan and over a large one
    -- `Index Cond: (id = ...)`, and matching either spelling would be fixture-size dependent. A join form
    -- qualifies both sides (`Hash Cond: (s.id = x.chunk_id)`) so it does not match this.
    assert (length(plan) - length(replace(plan, '(id = emb_cand_test_3d.chunk_id)', ''))) 
           / length('(id = emb_cand_test_3d.chunk_id)') = sources,
        format('expected %s correlated branches, one per source authenticated may read. Plan: %s', sources, plan);
end $$;
reset role;

-- 5a. And asking leaves the caller's scan order where it found it. claims.candidates does NOT force
--     strict_order the way aiq.semantic_in does: proving a negative over the whole index costs 232 ms a call
--     against 13 ms, and 99% of calls are that negative. The setting is the caller's, so a later change that
--     raises it and forgets to put it back shows up here rather than in somebody's transaction.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare wa uuid := (select v::uuid from ids where k = 'wa');
begin
    perform aiq.set_scan_order('off');
    perform claims.candidates(wa, 'A1', 0.5, 5, null, 'cand-test-3d');
    assert current_setting('hnsw.iterative_scan', true) = 'off',
        'candidates left hnsw.iterative_scan at ' || coalesce(current_setting('hnsw.iterative_scan', true), 'null');
end $$;
reset role;

-- 6. The space is readable to exactly the callers who may read the claim, asserted against the space itself.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare owner_sees int := (select count(*) from aiq."emb_cand_test_3d");
begin
    assert owner_sees = 5, 'the owner of every work reads all five vectors: ' || owner_sees::text;
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659c1"}';
set local role authenticated;
do $$
declare stranger_sees int := (select count(*) from aiq."emb_cand_test_3d");
begin
    -- A1, A2, B1 and C1 are in listed works; P1 is in a private one and its vector goes with it.
    assert stranger_sees = 4, 'a stranger reads the listed works'' vectors and not the private one: '
        || stranger_sees::text;
end $$;
reset role;

rollback;
