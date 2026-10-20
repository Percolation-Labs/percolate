-- A research-platform corpus of any size, written straight into core's tables (REM-500).
--
--     psql -v works=100000 -f generate.sql
--
-- Shape, per work: 1-3 revisions (mean 2), 6 claims, 5 sources, 7 citations and 5 argument edges per
-- revision; 3 useful votes per revision, a comment on every second revision, an endorsement on every tenth.
-- One user per 5 works; one org per 100 works. Visibility: 60% public (half of those listed), 30% private,
-- 10% org. Origins are shared: a source cites one of works/2 origins, skewed so a few are cited widely.
--
-- WHY STRAIGHT INTO THE TABLES. research.submit_package writes one package per call through the access
-- checks, the projection and the hash; ten million claims that way is a day. The rows here are the rows
-- the projection writes, so the reads under test see what they would see in production. Triggers and
-- foreign-key checks are skipped for the load (session_replication_role = replica); the ids are built so
-- every reference resolves, and probe.py refuses a corpus with a dangling reference before measuring.
--
-- The ids are md5-derived, so a rerun at the same size writes the same rows.

\set ON_ERROR_STOP on
set session_replication_role = replica;
set synchronous_commit = off;

create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$ select md5(p)::uuid $$;
-- A vocabulary that makes text search do real work: a claim draws 12 words from 400, skewed.
create or replace function pg_temp.words(p_seed bigint, p_n int) returns text language sql immutable as $$
    select string_agg('w' || (((p_seed * 2654435761 + g * 40503) % 1000003) % (1 + (g * 37 + p_seed) % 400)), ' ')
      from generate_series(1, p_n) g
$$;

select greatest(:works / 5, 10) as users, greatest(:works / 100, 2) as orgs, greatest(:works / 2, 10) as origins \gset

insert into rbac.users (id, email, status)
select pg_temp.u('user' || i), 'scale-' || i || '@example.test', 'active' from generate_series(1, :users) i
on conflict do nothing;
insert into rbac.orgs (id, slug, name)
select pg_temp.u('org' || i), 'scale-org-' || i, 'Scale org ' || i from generate_series(1, :orgs) i
on conflict do nothing;
insert into rbac.org_members (org_id, user_id, role)
select pg_temp.u('org' || (1 + i % :orgs)), pg_temp.u('user' || i), 'member' from generate_series(1, :users) i
on conflict do nothing;

-- Works. owner(i) and nrev(i) are the two functions every table below agrees on.
create temp table w as
select i, pg_temp.u('work' || i) as id, 'scale-' || i as public_id,
       pg_temp.u('user' || (1 + (i::bigint * 7919) % :users)) as owner_id,
       case when i % 10 < 6 then 'public' when i % 10 < 9 then 'private' else 'org' end as visibility,
       pg_temp.u('org' || (1 + ((i::bigint * 7919) % :users) % :orgs)) as org_id,
       1 + i % 3 as nrev,
       timestamptz '2026-01-01' + (i || ' seconds')::interval as at
  from generate_series(1, :works) i;
insert into research.works (id, public_id, owner_id, org_id, visibility, listed_at, created_at)
select id, public_id, owner_id, case when visibility = 'org' then org_id else rbac.shared_org_id() end,
       visibility, case when visibility = 'public' and i % 2 = 0 then at end, at from w;

create temp table r as
select w.i, n, pg_temp.u('rev' || w.i || '.' || n) as id, w.id as work_id, w.owner_id, w.at + (n || ' hours')::interval as at,
       n = w.nrev as is_head
  from w, generate_series(1, 3) n where n <= w.nrev;
insert into research.revisions (id, work_id, number, label, schema_version, document, content_hash, predecessor_id,
                                actor_id, actor_kind, created_at)
select id, work_id, n, 'draft-' || n, '0.1',
       jsonb_build_object('title', 'Scale work ' || i || ' draft ' || n, 'summary', pg_temp.words(i * 3 + n, 20)),
       md5(id::text), case when n > 1 then pg_temp.u('rev' || i || '.' || (n - 1)) end, owner_id, 'person', at from r;
insert into research.heads (work_id, revision_id, updated_at) select work_id, id, at from r where is_head;
-- A listed work exposes its head; so does every work in a publication (5% of works).
insert into research.exposures (revision_id, work_id, exposed_by, exposed_at)
select r.id, r.work_id, r.owner_id, r.at from r join w on w.id = r.work_id where r.is_head and w.visibility = 'public' and w.i % 2 = 0;
insert into research.publication_exposures (revision_id, work_id, publication, org_id, exposed_by, exposed_at)
select r.id, r.work_id, 'edition', rbac.shared_org_id(), r.owner_id, r.at from r join w on w.id = r.work_id where r.is_head and w.i % 20 = 1;

insert into research.claims (id, revision_id, claim_key, kind, text, locator)
select pg_temp.u('claim' || r.id || k), r.id, 'C' || k, case when k = 1 then 'Source assertion' else 'Inference' end,
       pg_temp.words(r.i * 7 + r.n * 13 + k, 12), 'p' || k
  from r, generate_series(1, 6) k;
insert into research.sources (id, revision_id, source_key, title, url, origin, status, locator)
select pg_temp.u('source' || r.id || s), r.id, 'S' || s, 'Source ' || s, 'https://example.test/' || o, 'doi:10.500/' || o, 'read', 'p1'
  from r, generate_series(1, 5) s,
       lateral (select (((r.i * 31 + s * 17) % :origins) * ((r.i + s) % 7 + 1) / 7) as o) z;
insert into research.citations (revision_id, claim_key, source_key)
select r.id, 'C' || k, 'S' || (1 + (k - 1) % 5) from r, generate_series(1, 6) k
union all
select r.id, 'C1', 'S5' from r;
insert into research.argument_edges (revision_id, source_claim_key, relation, target_claim_key)
select r.id, 'C' || k, case when k = 3 then 'challenges' when k = 5 then 'qualifies' else 'supports' end, 'C' || (k + 1)
  from r, generate_series(1, 5) k;

insert into research.endorsements (id, revision_id, endorser_id, scope, checked, kind, created_at)
select pg_temp.u('endorse' || r.id), r.id, pg_temp.u('user' || (1 + (r.i::bigint * 104729) % :users)), 'the sources', 'each citation', 'claims', r.at
  from r where r.i % 10 = 0;
insert into research.endorsement_claims (endorsement_id, revision_id, claim_key)
select pg_temp.u('endorse' || r.id), r.id, 'C1' from r where r.i % 10 = 0;
insert into engagement.votes (id, user_id, revision_id, created_at)
select pg_temp.u('vote' || r.id || v), pg_temp.u('user' || (1 + (r.i::bigint * 3 + v * 7727) % :users)), r.id, r.at
  from r, generate_series(1, 3) v
on conflict do nothing;
insert into engagement.comments (id, revision_id, claim_key, author_id, body, created_at)
select pg_temp.u('comment' || r.id), r.id, 'C2', pg_temp.u('user' || (1 + (r.i * 13) % :users)), pg_temp.words(r.i, 25), r.at
  from r where r.n % 2 = 0;
insert into engagement.saves (user_id, work_id)
select pg_temp.u('user' || (1 + (w.i::bigint * 17) % :users)), w.id from w where w.i % 3 = 0 on conflict do nothing;
insert into engagement.follows (user_id, target_org_id)
select pg_temp.u('user' || i), pg_temp.u('org' || (1 + (i * 3) % :orgs)) from generate_series(1, :users) i on conflict do nothing;

reset session_replication_role;
analyze;
select 'loaded', :works as works,
       (select count(*) from research.revisions) as revisions, (select count(*) from research.claims) as claims,
       (select count(*) from research.sources) as sources, (select count(*) from engagement.votes) as votes,
       pg_size_pretty(pg_database_size(current_database())) as size;
