-- The claims graph, step 1: a claim is an identity, and each occurrence expresses one (REM-473).
--
-- specs/claims/graph.md §3 and §5, built as the spike chose (§14): typed, append-only tables, each row naming the
-- transaction that made it. research.claims is the OCCURRENCE -- a claim as written in one revision, keyed
-- (revision_id, claim_key) -- and stays exactly as it is, so every foreign key to it still holds. Behind each
-- occurrence is now a claim: an id minted once with uuidv7(), never computed from text, and carried from one revision
-- of a work to the next by an `expresses` assertion the platform makes when it projects the revision.
--
-- Relations between claims (REM-474) are assertions in one vocabulary, claims.predicates (graph.md §6).
--
-- The graph is read through §12's functions (REM-475), each security invoker and each as of a date.
--
-- WHAT IS NOT HERE YET. The reads over questions and origins (answers, evidence, question_evidence: REM-476, REM-477),
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
--    expresses it. A transaction's id, time and actor kind are readable behind a row the caller may read (§12 below);
--    the rest of it is not granted.
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
-- 7. The vocabulary (graph.md §6). One row per predicate: what it relates, what kind of statement it is, and the
--    two properties a derived reading may rely on. It is the extension's, replayed on every upgrade.
-- ------------------------------------------------------------
create table if not exists claims.predicates (
    name         text primary key check (name ~ '^[a-z_]+$'),
    kind         text not null check (kind in ('identity', 'framing', 'inferential', 'comparative', 'evidence', 'outcome')),
    subject_kind text not null check (subject_kind in ('claim', 'occurrence', 'question')),
    object_kind  text not null check (object_kind in ('claim', 'question', 'origin', 'entity', 'value')),
    is_transitive boolean not null,
    is_symmetric  boolean not null,
    requires     text not null
);
insert into claims.predicates (name, kind, subject_kind, object_kind, is_transitive, is_symmetric, requires) values
 ('expresses',            'identity',    'occurrence', 'claim',    false, false, 'platform or owner; written by claims.link_revision'),
 ('same_as',              'identity',    'claim',      'claim',    true,  true,  'evidence on both sides (REM-478)'),
 ('supersedes',           'identity',    'claim',      'claim',    true,  false, 'the owner of both'),
 ('answers',              'framing',     'claim',      'question', false, false, 'a frame (REM-476)'),
 ('refines',              'framing',     'question',   'question', true,  false, 'a narrower slot value (REM-476)'),
 ('supports',             'inferential', 'claim',      'claim',    false, false, 'nothing beyond the writer''s assertion'),
 ('challenges',           'inferential', 'claim',      'claim',    false, false, 'nothing beyond the writer''s assertion'),
 ('qualifies',            'inferential', 'claim',      'claim',    false, false, 'both read'),
 ('limits',               'inferential', 'claim',      'claim',    false, false, 'both read'),
 ('motivates',            'inferential', 'claim',      'claim',    false, false, 'nothing'),
 ('compares_with',        'inferential', 'claim',      'claim',    false, true,  'nothing'),
 ('agrees',               'comparative', 'claim',      'claim',    false, true,  'same question; spans from both (REM-476)'),
 ('contradicts',          'comparative', 'claim',      'claim',    false, true,  'same question; every frame slot same or overlaps; spans from both (REM-476)'),
 ('different_scope',      'comparative', 'claim',      'claim',    false, true,  'the slot that differs, named (REM-476)'),
 ('same_source_opposite', 'comparative', 'claim',      'claim',    false, true,  'a shared origin; a span from each (REM-477)'),
 ('cites',                'evidence',    'occurrence', 'origin',   false, false, 'a source in the revision (REM-477)'),
 ('mentions',             'evidence',    'occurrence', 'entity',   false, false, 'a locator'),
 ('resolved_as',          'outcome',     'claim',      'value',    false, false, 'graph.md §12, an event (REM-480)'),
 ('consensus_as',         'outcome',     'claim',      'value',    false, false, 'graph.md §12; independent origins counted (REM-496)')
on conflict (name) do update set kind = excluded.kind, subject_kind = excluded.subject_kind,
    object_kind = excluded.object_kind, is_transitive = excluded.is_transitive, is_symmetric = excluded.is_symmetric,
    requires = excluded.requires;

-- The document's words for the six in-package relations, mapped onto the vocabulary's.
create or replace function claims.predicate_of_edge(p_relation text) returns text
language sql immutable parallel safe set search_path = pg_catalog as $$
    select case p_relation when 'compares with' then 'compares_with' else p_relation end;
$$;

-- ------------------------------------------------------------
-- 8. Relations: claim -> claim, one row per statement, never updated (graph.md §3, §11).
-- ------------------------------------------------------------
-- The evidence is one revision, or two for a relation between works; `keys` names the occurrences in it
-- ({"src": "C1", "dst": "C2"}), and `spans` quotes them where a predicate needs quotes. The row with the highest id
-- for one (src, predicate, dst, evidence) is current: a status change or a retraction is a later row, so the
-- history of a relation is its rows. Two assertions of one relation from two revisions are two statements, each
-- readable with its own evidence (graph.md §9).
create table if not exists claims.relations (
    id          bigint generated always as identity primary key,
    src         uuid not null references claims.claims(id),
    predicate   text not null references claims.predicates(name),
    dst         uuid not null references claims.claims(id),
    status      text not null check (status in ('proposed', 'confirmed', 'disputed')),
    op          text not null default 'assert' check (op in ('assert', 'retract')),
    evidence    uuid not null references research.revisions(id) on delete cascade,
    evidence2   uuid references research.revisions(id) on delete cascade,
    keys        jsonb not null default '{}'::jsonb check (jsonb_typeof(keys) = 'object'),
    spans       jsonb check (spans is null or jsonb_typeof(spans) = 'object'),
    tx          bigint not null references claims.tx(id),
    check (src <> dst),
    check (evidence2 is null or evidence2 <> evidence)
);
create index if not exists relations_src on claims.relations (src, predicate, dst, id desc);
create index if not exists relations_dst on claims.relations (dst, predicate);
create index if not exists relations_evidence on claims.relations (evidence);
create index if not exists relations_evidence2 on claims.relations (evidence2) where evidence2 is not null;

-- A revision's argument edges, asserted as relations between the claims its occurrences express (REM-474). The
-- writer made them in their document, so the platform records them confirmed, in the revision's own transaction.
-- Only an edge with no relation yet is asserted, so a rebuild and a replay write nothing.
create or replace function claims.project_edges(p_revision uuid) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    t bigint;
    e record;
    n int := 0;
begin
    for e in select a.source_claim_key, a.target_claim_key, claims.predicate_of_edge(a.relation) as predicate,
                    xs.claim_id as src, xd.claim_id as dst
               from research.argument_edges a
               join lateral (select x.claim_id from claims.expresses x
                              where x.revision_id = a.revision_id and x.claim_key = a.source_claim_key and x.part = 1
                              order by x.id desc limit 1) xs on true
               join lateral (select x.claim_id from claims.expresses x
                              where x.revision_id = a.revision_id and x.claim_key = a.target_claim_key and x.part = 1
                              order by x.id desc limit 1) xd on true
              where a.revision_id = p_revision
                and not exists (select 1 from claims.relations r
                                 where r.evidence = p_revision and r.evidence2 is null
                                   and r.keys = jsonb_build_object('src', a.source_claim_key, 'dst', a.target_claim_key)
                                   and r.predicate = claims.predicate_of_edge(a.relation))
              order by a.source_claim_key, a.relation, a.target_claim_key loop
        continue when e.src = e.dst;   -- two keys of one revision expressing one claim relate nothing
        if t is null then
            select x.tx into t from claims.expresses x where x.revision_id = p_revision order by x.id desc limit 1;
        end if;
        insert into claims.relations (src, predicate, dst, status, evidence, keys, tx)
        values (e.src, e.predicate, e.dst, 'confirmed', p_revision,
                jsonb_build_object('src', e.source_claim_key, 'dst', e.target_claim_key), t);
        n := n + 1;
    end loop;
    return n;
end;
$$;

-- ------------------------------------------------------------
-- 9. Writing a relation (graph.md §11). Every write opens its own transaction record, and nothing is updated.
-- ------------------------------------------------------------
-- The caller owns the work of `p_evidence` -- the asserting side -- and may read `p_evidence2`. Each claim is
-- expressed by the occurrence `p_keys` names in one of them. An agent's assertion lands `proposed`, and an agent
-- asking for `confirmed` is refused, never downgraded. The vocabulary row decides the rest: a predicate that relates
-- anything but two claims is written elsewhere, and one whose requirement needs a record that does not exist yet
-- (a question, an origin entity, a cross-work identity) is refused naming the card that builds it.
create or replace function claims.assert_relation(p_src_key text, p_predicate text, p_dst_key text,
                                                  p_evidence uuid, p_evidence2 uuid default null,
                                                  p_status text default null, p_spans jsonb default null,
                                                  p_reason text default null) returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user  uuid := rbac.require('research', 'insert');
    v_actor text := rbac.current_actor();
    v_pred  claims.predicates;
    v_src   uuid;
    v_dst   uuid;
    v_status text := coalesce(p_status, case when rbac.current_actor() = 'person' then 'confirmed' else 'proposed' end);
    t       bigint;
    v_id    bigint;
begin
    select * into v_pred from claims.predicates where name = p_predicate;
    if not found then
        raise check_violation using message = 'Unknown predicate', detail = p_predicate;
    end if;
    if v_pred.subject_kind <> 'claim' or v_pred.object_kind <> 'claim' then
        raise check_violation using message = 'This predicate does not relate two claims', detail = p_predicate;
    end if;
    if v_pred.kind = 'comparative' then
        raise feature_not_supported using message = 'A comparative relation needs the question both claims answer',
            detail = p_predicate, hint = 'REM-476 builds questions; REM-479 moves comparisons into core';
    elsif p_predicate = 'same_as' then
        raise feature_not_supported using message = 'same_as between claims is REM-478', detail = p_predicate;
    end if;
    if v_status not in ('proposed', 'confirmed', 'disputed') then
        raise check_violation using message = 'Unknown status', detail = v_status;
    end if;
    if v_status = 'confirmed' and v_actor <> 'person' then
        raise insufficient_privilege using message = 'Only a person confirms a relation; an agent proposes it',
            hint = 'human_only';
    end if;
    if not exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
                    where v.id = p_evidence and w.owner_id = v_user) then
        raise insufficient_privilege using message = 'A relation is asserted from a revision of your own work',
            hint = 'no_grant';
    end if;
    if p_evidence2 is not null and not research.revision_readable(p_evidence2) then
        raise no_data_found using message = 'Research revision not found';
    end if;
    select x.claim_id into v_src from claims.expresses x
     where x.revision_id = p_evidence and x.claim_key = p_src_key and x.part = 1 order by x.id desc limit 1;
    select x.claim_id into v_dst from claims.expresses x
     where x.revision_id = coalesce(p_evidence2, p_evidence) and x.claim_key = p_dst_key and x.part = 1
     order by x.id desc limit 1;
    if v_src is null or v_dst is null then
        raise foreign_key_violation using message = 'Each claim must be an occurrence in its evidence revision',
            detail = coalesce(p_src_key, '') || ' ' || coalesce(p_dst_key, '');
    end if;
    if p_predicate = 'supersedes' and not exists (
           select 1 from claims.expresses x join research.revisions v on v.id = x.revision_id
             join research.works w on w.id = v.work_id
            where x.claim_id = v_dst and w.owner_id = v_user) then
        raise insufficient_privilege using message = 'Only the owner of both claims says one supersedes the other',
            hint = 'no_grant';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, v_actor, rbac.current_credential_id(), p_evidence, coalesce(nullif(p_reason, ''), 'asserted'))
    returning id into t;
    insert into claims.relations (src, predicate, dst, status, evidence, evidence2, keys, spans, tx)
    values (v_src, p_predicate, v_dst, v_status, p_evidence, p_evidence2,
            jsonb_build_object('src', p_src_key, 'dst', p_dst_key), p_spans, t)
    returning id into v_id;
    return v_id;
end;
$$;

-- A later statement about a relation already asserted: a new status, or its retraction. The caller owns the
-- asserting side's work, and the same rule on `confirmed` holds. The earlier rows stay.
create or replace function claims.restate_relation(p_relation bigint, p_status text default null,
                                                   p_retract boolean default false, p_reason text default null)
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user  uuid := rbac.require('research', 'insert');
    v_actor text := rbac.current_actor();
    r       claims.relations;
    cur     claims.relations;
    t       bigint;
    v_id    bigint;
begin
    select * into r from claims.relations where id = p_relation;
    if not found or not exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
                                 where v.id = r.evidence and w.owner_id = v_user) then
        raise no_data_found using message = 'Relation not found';
    end if;
    select * into cur from claims.relations c
     where c.src = r.src and c.predicate = r.predicate and c.dst = r.dst and c.evidence = r.evidence
       and c.evidence2 is not distinct from r.evidence2 and c.keys = r.keys
     order by c.id desc limit 1;
    if cur.op = 'retract' then
        raise check_violation using message = 'This relation was retracted; assert it again instead';
    end if;
    if coalesce(p_status, cur.status) not in ('proposed', 'confirmed', 'disputed') then
        raise check_violation using message = 'Unknown status', detail = p_status;
    end if;
    if not p_retract and coalesce(p_status, cur.status) = 'confirmed' and v_actor <> 'person' then
        raise insufficient_privilege using message = 'Only a person confirms a relation; an agent proposes it',
            hint = 'human_only';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, v_actor, rbac.current_credential_id(), r.evidence,
            coalesce(nullif(p_reason, ''), case when p_retract then 'retracted' else 'restated' end))
    returning id into t;
    insert into claims.relations (src, predicate, dst, status, op, evidence, evidence2, keys, spans, tx)
    values (cur.src, cur.predicate, cur.dst, coalesce(p_status, cur.status),
            case when p_retract then 'retract' else 'assert' end, cur.evidence, cur.evidence2, cur.keys, cur.spans, t)
    returning id into v_id;
    return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 10. History and access for relations, as for the links: nothing is rewritten, and a relation is readable when
--     the caller may read every revision in its evidence (graph.md §9).
-- ------------------------------------------------------------
do $$
begin
    execute 'create or replace trigger trg_refuse_rewrite before update or delete on claims.relations '
            'for each row execute function research.refuse_rewrite()';
    execute 'create or replace trigger trg_refuse_truncate before truncate on claims.relations '
            'for each statement execute function research.refuse_rewrite()';
end $$;
alter table claims.relations enable row level security;
drop policy if exists relations_readable on claims.relations;
create policy relations_readable on claims.relations for select
    using (research.revision_readable(evidence) and (evidence2 is null or research.revision_readable(evidence2)));
grant select on claims.relations, claims.predicates to authenticated;
revoke all on function claims.link_revision(uuid), claims.project_edges(uuid) from public;
grant execute on function claims.assert_relation(text, text, text, uuid, uuid, text, jsonb, text),
                          claims.restate_relation(bigint, text, boolean, text) to authenticated;

-- ------------------------------------------------------------
-- 11. Who asserted, and when, behind a row the caller may read (graph.md §9). An actor sees their own transactions;
--     anybody else sees a transaction's id, time and actor kind when a link or relation they may read names it, and
--     never its actor, credential or reason.
-- ------------------------------------------------------------
drop policy if exists tx_readable on claims.tx;
create policy tx_readable on claims.tx for select using (
    actor_id = rbac.current_user_id()
    or exists (select 1 from claims.expresses e where e.tx = tx.id)
    or exists (select 1 from claims.relations r where r.tx = tx.id));
grant select (id, at, actor_kind) on claims.tx to authenticated;

-- ------------------------------------------------------------
-- 12. Reading the graph (graph.md §10). Every function is security invoker, so row security decides what it
--     returns, and takes p_at: a row counts when its transaction was at or before p_at, and the latest such row for
--     one statement is that statement's state then. A derived reading is returned as a path of asserted relations,
--     never as a relation of its own.
-- ------------------------------------------------------------

-- The relations touching one claim, as they stood at p_at: the latest row per statement, retractions dropped.
create or replace function claims.relations_at(p_claim uuid, p_at timestamptz default now())
returns table (id bigint, src uuid, predicate text, dst uuid, status text, evidence uuid, evidence2 uuid,
               keys jsonb, at timestamptz, actor_kind text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select c.id, c.src, c.predicate, c.dst, c.status, c.evidence, c.evidence2, c.keys, c.at, c.actor_kind
      from (select distinct on (r.src, r.predicate, r.dst, r.evidence, r.evidence2, r.keys)
                   r.id, r.src, r.predicate, r.dst, r.status, r.op, r.evidence, r.evidence2, r.keys,
                   t.at, t.actor_kind
              from claims.relations r join claims.tx t on t.id = r.tx
             where (r.src = p_claim or r.dst = p_claim) and t.at <= p_at
             order by r.src, r.predicate, r.dst, r.evidence, r.evidence2, r.keys, r.id desc) c
     where c.op = 'assert';
$$;

-- The claims joined to p_id by confirmed same_as the caller may read, p_id included (graph.md §5, §6: identity is
-- transitive over confirmed assertions only, and a proposed edge never extends a set).
create or replace function claims.identity_set(p_id uuid, p_at timestamptz default now()) returns setof uuid
language sql stable security invoker set search_path = pg_catalog, public as $$
    with recursive ids(claim, path) as (
        select p_id, array[p_id]
        union all
        select case when r.src = i.claim then r.dst else r.src end,
               i.path || case when r.src = i.claim then r.dst else r.src end
          from ids i cross join lateral claims.relations_at(i.claim, p_at) r
         where r.predicate = 'same_as' and r.status = 'confirmed'
           and not (case when r.src = i.claim then r.dst else r.src end) = any (i.path)
           and cardinality(i.path) < 64)
    select distinct claim from ids;
$$;

-- A claim: the occurrences that expressed it at p_at, and its identity set over the confirmed same_as the caller
-- may read (graph.md §5). Null when the caller may read no occurrence of it, so a private claim is not observable.
create or replace function claims.claim(p_id uuid, p_at timestamptz default now()) returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    with occ as (
        select distinct on (e.revision_id, e.claim_key, e.part)
               e.revision_id, e.claim_key, e.part, e.claim_id, e.method, e.status, e.op, t.at
          from claims.expresses e join claims.tx t on t.id = e.tx
         where e.revision_id in (select x.revision_id from claims.expresses x where x.claim_id = p_id)
           and t.at <= p_at
         order by e.revision_id, e.claim_key, e.part, e.id desc),
    mine as (
        select o.*, c.text, v.label, v.number, w.public_id
          from occ o join research.claims c on (c.revision_id, c.claim_key) = (o.revision_id, o.claim_key)
          join research.revisions v on v.id = o.revision_id join research.works w on w.id = v.work_id
         where o.claim_id = p_id and o.op = 'assert')
    select case when exists (select 1 from mine) then jsonb_build_object(
        'id', p_id,
        'occurrences', (select jsonb_agg(jsonb_build_object(
                            'package_id', m.public_id, 'revision_id', m.revision_id, 'revision', m.label,
                            'claim_key', m.claim_key, 'part', m.part, 'text', m.text, 'method', m.method,
                            'status', m.status, 'at', m.at) order by m.at, m.public_id, m.number)
                          from mine m),
        'identity_set', (select jsonb_agg(i order by i) from claims.identity_set(p_id, p_at) i),
        'question', null)
    end;
$$;

-- Typed paths out of and into a claim, up to p_depth hops (at most 4), each hop the asserted relation it walked.
create or replace function claims.neighbourhood(p_id uuid, p_predicates text[] default null, p_depth int default 1,
                                                p_at timestamptz default now())
returns table (depth int, relation_id bigint, src uuid, predicate text, dst uuid, status text, evidence uuid,
               actor_kind text, at timestamptz, path uuid[])
language sql stable security invoker set search_path = pg_catalog, public as $$
    with recursive hop(depth, relation_id, src, predicate, dst, status, evidence, actor_kind, at, here, path) as (
        select 1, r.id, r.src, r.predicate, r.dst, r.status, r.evidence, r.actor_kind, r.at,
               case when r.src = p_id then r.dst else r.src end,
               array[p_id, case when r.src = p_id then r.dst else r.src end]
          from claims.relations_at(p_id, p_at) r
         where p_predicates is null or r.predicate = any (p_predicates)
        union all
        select h.depth + 1, r.id, r.src, r.predicate, r.dst, r.status, r.evidence, r.actor_kind, r.at,
               case when r.src = h.here then r.dst else r.src end,
               h.path || case when r.src = h.here then r.dst else r.src end
          from hop h cross join lateral claims.relations_at(h.here, p_at) r
         where h.depth < least(greatest(p_depth, 1), 4)
           and (p_predicates is null or r.predicate = any (p_predicates))
           and not (case when r.src = h.here then r.dst else r.src end) = any (h.path))
    select depth, relation_id, src, predicate, dst, status, evidence, actor_kind, at, path from hop;
$$;

-- What a claim rests on (graph.md §6): every claim it depends on through confirmed supports and motivates, with the
-- path from the claim back to it. Derived, and returned as a path, never as a relation.
create or replace function claims.rests_on(p_id uuid, p_at timestamptz default now())
returns table (claim uuid, depth int, path uuid[], relations bigint[])
language sql stable security invoker set search_path = pg_catalog, public as $$
    with recursive rests(claim, depth, path, relations) as (
        select p_id, 0, array[p_id], array[]::bigint[]
        union all
        select r.src, s.depth + 1, s.path || r.src, s.relations || r.id
          from rests s cross join lateral claims.relations_at(s.claim, p_at) r
         where r.dst = s.claim and r.predicate in ('supports', 'motivates') and r.status = 'confirmed'
           and not r.src = any (s.path) and s.depth < 12)
    select claim, depth, path, relations from rests where depth > 0;
$$;

-- What challenges a claim through what it rests on (graph.md §6): C is challenged through Y when C rests on Y and a
-- confirmed challenges or contradicts is aimed at Y. A challenge aimed at C itself is not one of these. Shown as "a
-- claim this depends on is disputed", with the path; never as "this claim is disputed".
create or replace function claims.challenged_through(p_id uuid, p_at timestamptz default now())
returns table (rests_on uuid, challenger uuid, predicate text, relation_id bigint, path uuid[], relations bigint[])
language sql stable security invoker set search_path = pg_catalog, public as $$
    select s.claim, r.src, r.predicate, r.id, s.path, s.relations
      from claims.rests_on(p_id, p_at) s cross join lateral claims.relations_at(s.claim, p_at) r
     where r.dst = s.claim and r.predicate in ('challenges', 'contradicts') and r.status = 'confirmed'
       and s.claim <> p_id;
$$;

-- Every statement about a claim, oldest first: each link from an occurrence, and each row of each relation that
-- names it, with when it was made and by what kind of actor.
create or replace function claims.history(p_id uuid)
returns table (at timestamptz, actor_kind text, record text, row_id bigint, predicate text, other uuid, status text,
               op text, revision_id uuid, claim_key text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select t.at, t.actor_kind, 'expresses', e.id, 'expresses', null::uuid, e.status, e.op, e.revision_id, e.claim_key
      from claims.expresses e join claims.tx t on t.id = e.tx where e.claim_id = p_id
    union all
    select t.at, t.actor_kind, 'relation', r.id, r.predicate, case when r.src = p_id then r.dst else r.src end,
           r.status, r.op, r.evidence, case when r.src = p_id then r.keys->>'src' else r.keys->>'dst' end
      from claims.relations r join claims.tx t on t.id = r.tx where r.src = p_id or r.dst = p_id
    order by 1, 3, 4;
$$;

-- What an edit did to the argument, claim by claim (graph.md §10): claims added, dropped, carried unchanged or
-- reworded (with whether the rewording is confirmed), and relations gained and lost between the two revisions.
create or replace function claims.revision_diff(p_from uuid, p_to uuid)
returns table (change text, claim uuid, from_key text, to_key text, status text, predicate text, other uuid)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with f as (select distinct on (e.claim_key) e.claim_key, e.claim_id, e.op from claims.expresses e
                where e.revision_id = p_from and e.part = 1 order by e.claim_key, e.id desc),
         t as (select distinct on (e.claim_key) e.claim_key, e.claim_id, e.method, e.status, e.op from claims.expresses e
                where e.revision_id = p_to and e.part = 1 order by e.claim_key, e.id desc),
         fr as (select distinct on (r.src, r.predicate, r.dst, r.keys) r.src, r.predicate, r.dst, r.op
                  from claims.relations r where r.evidence = p_from and r.evidence2 is null
                 order by r.src, r.predicate, r.dst, r.keys, r.id desc),
         tr as (select distinct on (r.src, r.predicate, r.dst, r.keys) r.src, r.predicate, r.dst, r.op
                  from claims.relations r where r.evidence = p_to and r.evidence2 is null
                 order by r.src, r.predicate, r.dst, r.keys, r.id desc)
    select case when f.claim_id is null then 'added'
                when t.method = 'unchanged' then 'carried'
                else 'reworded' end,
           t.claim_id, f.claim_key, t.claim_key, t.status, null::text, null::uuid
      from t left join f on f.claim_id = t.claim_id and f.op = 'assert' where t.op = 'assert'
    union all
    select 'dropped', f.claim_id, f.claim_key, null::text, null::text, null::text, null::uuid
      from f where f.op = 'assert' and not exists (select 1 from t where t.claim_id = f.claim_id and t.op = 'assert')
    union all
    select 'relation gained', tr.src, null::text, null::text, null::text, tr.predicate, tr.dst
      from tr where tr.op = 'assert'
       and not exists (select 1 from fr where (fr.src, fr.predicate, fr.dst) = (tr.src, tr.predicate, tr.dst) and fr.op = 'assert')
    union all
    select 'relation lost', fr.src, null::text, null::text, null::text, fr.predicate, fr.dst
      from fr where fr.op = 'assert'
       and not exists (select 1 from tr where (tr.src, tr.predicate, tr.dst) = (fr.src, fr.predicate, fr.dst) and tr.op = 'assert');
$$;

grant execute on function claims.relations_at(uuid, timestamptz), claims.claim(uuid, timestamptz),
                          claims.identity_set(uuid, timestamptz),
                          claims.neighbourhood(uuid, text[], int, timestamptz), claims.rests_on(uuid, timestamptz),
                          claims.challenged_through(uuid, timestamptz), claims.history(uuid),
                          claims.revision_diff(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 13. The backfill: every revision projected before this existed gets its links, oldest first within each work, so
--     each predecessor is linked before its successor asks it, and then its edges as relations. On a fresh install,
--     and on every replay after the first, it finds nothing and writes nothing.
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
do $$
declare v uuid;
begin
    for v in select distinct a.revision_id from research.argument_edges a
              where not exists (select 1 from claims.relations r where r.evidence = a.revision_id and r.evidence2 is null)
    loop
        perform claims.project_edges(v);
    end loop;
end $$;
