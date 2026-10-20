-- Candidate fixes for what the baseline probes found (REM-500). Applied to a copy of each corpus and
-- probed again, so every fix is a measurement before it is a migration. Not yet in the extension.
\set ON_ERROR_STOP on

-- 1. PER-REVISION AND PER-OWNER LOOKUPS THAT HAD NO INDEX. Each was a scan of the whole table on a path
-- a reader takes on every page (revision_signals, a package's comments, trust's endorsements, "my
-- packages"), or one erasure takes per cascaded row.
-- Not partial: erasure deletes withdrawn votes too, and a foreign-key cascade cannot use a partial index.
create index if not exists votes_by_revision on engagement.votes (revision_id);
-- REM-507's definition, which lands first in schema.sql §4; one name, one definition.
create index if not exists comments_by_revision on engagement.comments (revision_id, created_at) where revision_id is not null;
create index if not exists valuations_by_revision on engagement.valuations (revision_id);
-- endorsements_one_active is partial (withdrawn_at is null); trust reads withdrawn ones too, so it cannot use it.
create index if not exists endorsements_by_revision on research.endorsements (revision_id);
create index if not exists works_by_owner on research.works (owner_id);
create index if not exists heads_by_revision on research.heads (revision_id);
create index if not exists operations_by_work on research.operations (work_id);
create index if not exists revisions_by_predecessor on research.revisions (predecessor_id) where predecessor_id is not null;
create index if not exists sources_by_origin on research.sources (origin) where origin <> '';
-- Foreign keys that erasure's cascade checks once per deleted parent row (measured with pg_stat_statements
-- on erase_work at 80K works: each was a scan of the child table).
create index if not exists revisions_by_base on research.revisions (base_revision_id) where base_revision_id is not null;
create index if not exists works_by_parent on research.works (parent_work_id) where parent_work_id is not null;
create index if not exists endorsement_claims_by_claim on research.endorsement_claims (revision_id, claim_key);
create index if not exists saves_by_work on engagement.saves (work_id);
-- The listing walks exposures newest first.
create index if not exists exposures_newest on research.exposures (exposed_at desc, revision_id);

-- 2. A LISTING THAT READS A PAGE, NOT THE CORPUS. list_packages visits every work, asks visible_head of
-- each, sorts them all and returns everything; a LIMIT outside it saves nothing. This walks exposures
-- newest first through their index and stops at p_limit readable rows, so its cost is the page, however
-- many works exist. Keyset: the next page passes the last row's exposed_at.
create or replace function research.list_listed(p_before timestamptz default null, p_limit int default 20)
returns setof jsonb language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object('id', w.public_id, 'title', r.document->>'title', 'summary', r.document->>'summary',
                              'revision', r.label, 'exposed_at', e.exposed_at)
      from research.exposures e
      join research.revisions r on r.id = e.revision_id
      join research.works w on w.id = e.work_id
     where (p_before is null or e.exposed_at < p_before) and research.readable(w.id)
     order by e.exposed_at desc, e.revision_id
     limit least(greatest(p_limit, 1), 100)
$$;
grant execute on function research.list_listed(timestamptz, int) to authenticated;

-- 3. SEARCH THAT ASKS THE INDEX FIRST. Under row security the planner must run the policy on every
-- claim before `@@`, because ts_match_vq is not leakproof, so a search reads the whole table. As the
-- definer, the index answers first; readability is then asked of the candidates only, and the answer
-- never includes a claim the caller could not have read. p_candidates bounds the work for a term that
-- matches millions; a caller who needs more asks again with a narrower query.
create or replace function research.search_claims(p_query text, p_limit int default 20, p_candidates int default 2000)
returns table (claim_id uuid, revision_id uuid, claim_key text, text text, score real)
language sql stable security definer set search_path = pg_catalog, public as $$
    with q as (select plainto_tsquery('simple', p_query) as q),
    candidates as (
        select c.id, c.revision_id, c.claim_key, c.text, c.search_tsv
          from research.claims c, q where c.search_tsv @@ q.q
         limit least(greatest(p_candidates, 1), 10000))
    select k.id, k.revision_id, k.claim_key, k.text, ts_rank(k.search_tsv, q.q)::real
      from candidates k, q
     where research.revision_readable(k.revision_id)
     order by 5 desc
     limit least(greatest(p_limit, 1), 100)
$$;
grant execute on function research.search_claims(text, int, int) to authenticated;
analyze;
