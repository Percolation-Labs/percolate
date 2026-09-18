-- The claims graph, step 1: a claim is an identity, and each occurrence expresses one (REM-473).
--
-- specs/claims/graph.md §3 and §5, built as the spike chose (§14): typed, append-only tables, each row naming the
-- transaction that made it. research.claims is the OCCURRENCE -- a claim as written in one revision, keyed
-- (revision_id, claim_key) -- and stays exactly as it is, so every foreign key to it still holds. Behind each
-- occurrence is now a claim: an id minted once with uuidv7(), never computed from text, and carried from one revision
-- of a work to the next by an `expresses` assertion the platform makes when it projects the revision.
--
-- WHAT IS NOT HERE YET. Relations between claims (REM-474), the read functions and their access tests (REM-475),
-- frames and questions (REM-476), cross-package same_as (REM-478), parts beyond the first (REM-506) and the writer's
-- answer to a reworded claim (REM-483). A claim with no occurrence left after an erasure is REM-481's.

create schema if not exists claims;

-- ------------------------------------------------------------
-- 1. Transactions. Who asserted a set of statements, as what, and why (graph.md §3).
-- ------------------------------------------------------------
-- revision_id is a plain column and not a foreign key: a transaction is history, and research.erase_work
-- removing a revision must not reach back and delete the record that something was once asserted from it.
create table if not exists claims.tx (
    id            bigint generated always as identity primary key,
    at            timestamptz not null default now(),
    actor_id      uuid references rbac.users(id),
    actor_kind    text not null check (actor_kind in ('person', 'agent', 'platform')),
    credential_id uuid,
    revision_id   uuid,
    reason        text not null check (length(reason) > 0),
    check (actor_kind = 'platform' or actor_id is not null)
);

-- ------------------------------------------------------------
-- 2. Claims. A proposition with an identity and nothing else: its text is whatever its occurrences say.
-- ------------------------------------------------------------
create table if not exists claims.claims (
    id uuid primary key default uuidv7(),
    tx bigint not null references claims.tx(id)
);

-- ------------------------------------------------------------
-- 3. expresses: occurrence (and part) -> claim, one row per statement, never updated.
-- ------------------------------------------------------------
-- A later status (the writer confirming a reworded claim, REM-483) or a retraction is a later row for the same
-- (revision_id, claim_key, part); the row with the highest id is current. `part` is 1 until a writer's agent
-- splits an occurrence (graph.md §5 *Parts*, REM-506), and `gloss` is the part's own wording, null for part 1,
-- whose text is the occurrence's. The cascade is how research.erase_work's delete reaches these rows;
-- research.refuse_rewrite refuses every other delete.
create table if not exists claims.expresses (
    id          bigint generated always as identity primary key,
    revision_id uuid not null,
    claim_key   text not null,
    part        smallint not null default 1 check (part > 0),
    claim_id    uuid not null references claims.claims(id),
    method      text not null check (method in ('unchanged', 'reworded', 'new')),
    status      text not null check (status in ('proposed', 'confirmed', 'disputed')),
    op          text not null default 'assert' check (op in ('assert', 'retract')),
    gloss       text check (gloss is null or length(gloss) > 0),
    tx          bigint not null references claims.tx(id),
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key) on delete cascade
);
-- The spike's index (meta/spikes/2026-09-18-claims-graph, "added after the first 1.1M run"): every read by revision
-- and the projection's own "is this occurrence linked" check use it.
create index if not exists expresses_occurrence on claims.expresses (revision_id, claim_key, part, id desc);
create index if not exists expresses_claim on claims.expresses (claim_id);

-- ------------------------------------------------------------
-- 4. The §5 rule, applied to one revision.
-- ------------------------------------------------------------
-- Whitespace and case do not change a claim; anything else is a rewording, which keeps the claim as a proposal.
create or replace function claims.normalised(p_text text) returns text
language sql immutable parallel safe set search_path = pg_catalog as $$
    select lower(regexp_replace(btrim(p_text), '\s+', ' ', 'g'));
$$;

-- Links every occurrence of a revision that is not yet linked, and returns how many it linked. A second call writes
-- nothing, which is what lets research.project call it in both its modes and lets the backfill below be replayed.
--
--   the key was in the predecessor, same text  -> the predecessor's claim, `unchanged`, confirmed
--   the key was in the predecessor, reworded   -> the predecessor's claim, `reworded`, proposed
--   a new key, or no predecessor               -> a claim minted here, `new`, confirmed
--
-- The predecessor is the revision's predecessor_id, else the work's previous number. Its link must already exist,
-- which holds for a write (the predecessor was projected first) and for the backfill (oldest revision first).
create or replace function claims.link_revision(p_revision uuid) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    r    research.revisions;
    pred uuid;
    t    bigint;
    o    record;
    p    record;
    cid  uuid;
    n    int := 0;
begin
    select * into r from research.revisions where id = p_revision;
    if not found then
        raise no_data_found using message = 'Research revision not found';
    end if;
    pred := coalesce(r.predecessor_id,
                     (select v.id from research.revisions v where v.work_id = r.work_id and v.number = r.number - 1));
    for o in select c.claim_key, c.text from research.claims c
              where c.revision_id = p_revision
                and not exists (select 1 from claims.expresses e
                                 where e.revision_id = c.revision_id and e.claim_key = c.claim_key and e.part = 1)
              order by c.claim_key loop
        if t is null then
            insert into claims.tx (actor_kind, revision_id, reason)
            values ('platform', p_revision, 'projection of ' || r.label) returning id into t;
        end if;
        select e.claim_id, pc.text into p
          from research.claims pc
          join lateral (select x.claim_id, x.op from claims.expresses x
                         where x.revision_id = pc.revision_id and x.claim_key = pc.claim_key and x.part = 1
                         order by x.id desc limit 1) e on e.op = 'assert'
         where pc.revision_id = pred and pc.claim_key = o.claim_key;
        if found then
            insert into claims.expresses (revision_id, claim_key, claim_id, method, status, tx)
            values (p_revision, o.claim_key, p.claim_id,
                    case when claims.normalised(p.text) = claims.normalised(o.text) then 'unchanged' else 'reworded' end,
                    case when claims.normalised(p.text) = claims.normalised(o.text) then 'confirmed' else 'proposed' end,
                    t);
        else
            insert into claims.claims (tx) values (t) returning id into cid;
            insert into claims.expresses (revision_id, claim_key, claim_id, method, status, tx)
            values (p_revision, o.claim_key, cid, 'new', 'confirmed', t);
        end if;
        n := n + 1;
    end loop;
    return n;
end;
$$;

-- ------------------------------------------------------------
-- 5. History: nothing here is updated or deleted, except by research.erase_work.
-- ------------------------------------------------------------
do $$
declare t text;
begin
    foreach t in array array['claims.tx', 'claims.claims', 'claims.expresses'] loop
        execute format('create or replace trigger trg_refuse_rewrite before update or delete on %s '
                       'for each row execute function research.refuse_rewrite()', t);
        execute format('create or replace trigger trg_refuse_truncate before truncate on %s '
                       'for each statement execute function research.refuse_rewrite()', t);
    end loop;
end $$;

-- ------------------------------------------------------------
-- 6. Access (graph.md §9): an expresses row is readable with its revision, and a claim when a readable occurrence
--    expresses it. A transaction is not granted to authenticated: the read functions (REM-475) show an assertion's
--    actor kind, never the rest of its transaction.
-- ------------------------------------------------------------
alter table claims.expresses enable row level security;
drop policy if exists expresses_readable on claims.expresses;
create policy expresses_readable on claims.expresses for select using (research.revision_readable(revision_id));

alter table claims.claims enable row level security;
drop policy if exists claims_readable on claims.claims;
create policy claims_readable on claims.claims for select
    using (exists (select 1 from claims.expresses e where e.claim_id = claims.id));

alter table claims.tx enable row level security;

grant usage on schema claims to authenticated;
grant select on claims.claims, claims.expresses to authenticated;

-- ------------------------------------------------------------
-- 7. The backfill: every revision projected before this existed gets its links, oldest first within each work, so
--    each predecessor is linked before its successor asks it. On a fresh install, and on every replay after the
--    first, it finds nothing and writes nothing.
-- ------------------------------------------------------------
do $$
declare v uuid;
begin
    for v in select r.id from research.revisions r
              where exists (select 1 from research.claims c
                             where c.revision_id = r.id
                               and not exists (select 1 from claims.expresses e
                                                where e.revision_id = c.revision_id and e.claim_key = c.claim_key
                                                  and e.part = 1))
              order by r.work_id, r.number loop
        perform claims.link_revision(v);
    end loop;
end $$;
