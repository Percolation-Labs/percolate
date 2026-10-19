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
-- Frames, questions and which question a claim answers are §10a (REM-476).
--
-- Origins and what cites them are §10b (REM-477).
--
-- REM-584 adds explicit revision readings; REM-590 records durable execution provenance.
-- REM-603 keeps question links and aggregate counts aligned with occurrence reassignment.
-- Parts beyond the first remain REM-506's work.

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
comment on table claims.tx is
    'One append to the claims graph: who asserted, as what kind of actor, from which revision and why. Every assertion carries its tx.';

-- ------------------------------------------------------------
-- 2. Claims. A proposition with an identity and nothing else: its text is whatever its occurrences say.
-- ------------------------------------------------------------
create table if not exists claims.claims (
    id uuid primary key default uuidv7(),
    tx bigint not null references claims.tx(id)
);
comment on table claims.claims is
    'A claim''s identity, minted once. Everything said about it is an assertion elsewhere that names it.';

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
comment on table claims.expresses is
    'That an occurrence in a revision expresses a claim, by which method, at what review status. Never updated; a change is a later row.';
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

-- The writer's answer to a rewording (graph.md §5, REM-483). The projection links a reworded key to its earlier claim
-- as a proposal; the work's owner answers. "same" confirms that link, a later row. "new" retracts it, mints a claim
-- for the new wording, links the occurrence to it, and when asked records that the new claim supersedes the old,
-- evidenced by this revision and its predecessor. Not answering changes nothing: the reader sees "reworded,
-- unconfirmed".
--
-- WHO MAY ANSWER (REM-622). The owner, as a person. Their agent, relaying the answer the person gave it in
-- conversation, on a private draft: a revision nobody but its owner may read, so not listed, in no publication and
-- not shared with an org. Its transaction names the agent and the credential it used, which
-- claims.rewording_answers shows the owner, and a person's answer after an agent's reverses it with later rows, so
-- both stay in the history. On any other revision an agent needs research:publish, which is human-only unless the
-- person delegated it, and the refusal names the conditions that would allow it, not only the reason code.
create or replace function claims.answer_rewording(p_revision uuid, p_claim_key text, p_answer text,
                                                   p_supersedes boolean default false)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user   uuid := rbac.require('research', 'insert');
    v_actor  text := rbac.current_actor();
    v_decide jsonb;
    r        research.revisions;
    cur      claims.expresses;
    t        bigint;
    cid      uuid;
    old      uuid;
    prior    bigint;
    pred     uuid;
    answer   record;
begin
    if p_answer not in ('same', 'new') then
        raise check_violation using message = 'A rewording is answered same or new', detail = p_answer;
    end if;
    select v.* into r from research.revisions v join research.works o on o.id = v.work_id
     where v.id = p_revision and o.owner_id = v_user;
    if not found then
        raise no_data_found using message = 'Research revision not found';
    end if;
    if v_actor <> 'person'
       and (exists (select 1 from research.works o where o.id = r.work_id and o.visibility = 'org')
            or exists (select 1 from research.exposures e where e.revision_id = r.id)
            or exists (select 1 from research.publication_exposures pe where pe.revision_id = r.id)) then
        v_decide := rbac.decide('research', 'publish');
        if not (v_decide->>'allowed')::boolean then
            raise insufficient_privilege
                using message = format('An agent records a rewording answer only on a private draft, and %s can be '
                                       'read by others', r.label),
                      detail = 'It is allowed on a private draft (not listed, in no publication, not shared with an '
                               'org), or when the person has let this connection publish (research:publish). '
                               'Otherwise the person answers in Percolate.',
                      hint = v_decide->>'reason';
        end if;
    end if;
    select * into cur from claims.expresses
     where revision_id = p_revision and claim_key = p_claim_key and part = 1 order by id desc limit 1;
    if not found then
        raise check_violation using message = 'That claim is not a rewording waiting for an answer';
    end if;
    -- An answer an agent recorded, which the person may reverse: the latest link was written by that answer.
    select x.id into prior from claims.tx x
     where x.id = cur.tx and x.actor_kind = 'agent' and x.revision_id = p_revision
       and x.reason like 'rewording answered %';
    if prior is null or v_actor <> 'person' then
        prior := null;
        if cur.op <> 'assert' or cur.method <> 'reworded' or cur.status <> 'proposed' then
            raise check_violation using message = 'That claim is not a rewording waiting for an answer';
        end if;
    elsif exists (select 1 from research.claims c join research.revisions n on n.id = c.revision_id
                   where n.work_id = r.work_id and n.number > r.number and c.claim_key = p_claim_key) then
        raise check_violation using message = 'A later revision carries this answer forward, so it is answered there';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, v_actor, rbac.current_credential_id(), p_revision,
            'rewording answered ' || p_answer
            || case when prior is not null then ', reversing the agent''s answer' else '' end)
    returning id into t;
    if prior is not null then
        -- Back to waiting, with later rows: the agent's answer stays in the history.
        if cur.method = 'new' then
            select e.claim_id into old from claims.expresses e
             where e.tx = prior and e.revision_id = p_revision and e.claim_key = p_claim_key and e.op = 'retract';
            insert into claims.expresses (revision_id, claim_key, claim_id, method, status, op, tx)
            values (p_revision, p_claim_key, cur.claim_id, cur.method, cur.status, 'retract', t);
            for answer in select * from (
                select distinct on (a.question_id) a.* from claims.answered a
                 where a.evidence=p_revision and a.claim_key=p_claim_key order by a.question_id,a.id desc) x
                where x.op='assert' and x.claim_id=cur.claim_id loop
                insert into claims.answered(claim_id,question_id,stance,status,op,evidence,claim_key,tx)
                values(cur.claim_id,answer.question_id,answer.stance,answer.status,'retract',p_revision,p_claim_key,t),
                      (old,answer.question_id,answer.stance,answer.status,'assert',p_revision,p_claim_key,t);
            end loop;
            insert into claims.relations (src, predicate, dst, status, op, evidence, evidence2, keys, tx)
            select src, predicate, dst, status, 'retract', evidence, evidence2, keys, t
              from claims.relations where tx = prior and op = 'assert';
        else
            old := cur.claim_id;
        end if;
        insert into claims.expresses (revision_id, claim_key, claim_id, method, status, tx)
        values (p_revision, p_claim_key, old, 'reworded', 'proposed', t) returning * into cur;
    end if;
    if p_answer = 'same' then
        insert into claims.expresses (revision_id, claim_key, claim_id, method, status, tx)
        values (p_revision, p_claim_key, cur.claim_id, 'reworded', 'confirmed', t);
        return cur.claim_id;
    end if;
    insert into claims.expresses (revision_id, claim_key, claim_id, method, status, op, tx)
    values (p_revision, p_claim_key, cur.claim_id, 'reworded', 'proposed', 'retract', t);
    insert into claims.claims (tx) values (t) returning id into cid;
    insert into claims.expresses (revision_id, claim_key, claim_id, method, status, tx)
    values (p_revision, p_claim_key, cid, 'new', 'confirmed', t);
    -- The frame was projected while this occurrence still proposed the old identity. Move each active
    -- question assertion to the writer's new identity with two append-only rows, preserving the old reading.
    for answer in select * from (
        select distinct on (a.question_id) a.* from claims.answered a
         where a.evidence=p_revision and a.claim_key=p_claim_key order by a.question_id,a.id desc) x
        where x.op='assert' and x.claim_id=cur.claim_id loop
        insert into claims.answered(claim_id,question_id,stance,status,op,evidence,claim_key,tx)
        values(cur.claim_id,answer.question_id,answer.stance,answer.status,'retract',p_revision,p_claim_key,t),
              (cid,answer.question_id,answer.stance,answer.status,'assert',p_revision,p_claim_key,t);
    end loop;
    if p_supersedes then
        pred := coalesce(r.predecessor_id,
                         (select v.id from research.revisions v where v.work_id = r.work_id and v.number = r.number - 1));
        insert into claims.relations (src, predicate, dst, status, evidence, evidence2, keys, tx)
        values (cid, 'supersedes', cur.claim_id, case when v_actor = 'person' then 'confirmed' else 'proposed' end,
                p_revision, pred, jsonb_build_object('src', p_claim_key, 'dst', p_claim_key), t);
    end if;
    return cid;
end;
$$;

-- Every answer recorded for a revision's reworded claims, oldest first, to the work's owner: which answer, when,
-- and who recorded it, person or agent, with the credential an agent used (REM-622). claims.tx grants nobody its
-- credential column, so this is how the owner reviews what their agent recorded, and reverses it if it is wrong.
create or replace function claims.rewording_answers(p_revision uuid)
returns table (claim_key text, answer text, at timestamptz, actor_kind text, credential_id uuid, reverses_agent boolean)
language sql stable security definer set search_path = pg_catalog, public as $$
    select k.claim_key, split_part(split_part(x.reason, ' ', 3), ',', 1), x.at, x.actor_kind, x.credential_id,
           x.reason like '%, reversing the agent''s answer'
      from claims.tx x
      join research.revisions v on v.id = x.revision_id
      join research.works o on o.id = v.work_id
      cross join lateral (select distinct e.claim_key from claims.expresses e where e.tx = x.id) k
     where x.revision_id = p_revision and x.reason like 'rewording answered %'
       and o.owner_id = rbac.current_user_id()
     order by x.id, k.claim_key;
$$;

-- The reworded claims of a revision waiting for an answer, with the earlier and the new wording.
create or replace function claims.rewordings(p_revision uuid)
returns table (claim_key text, claim uuid, was text, now text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select e.claim_key, e.claim_id, pc.text, c.text
      from (select distinct on (x.claim_key) x.* from claims.expresses x
             where x.revision_id = p_revision and x.part = 1 order by x.claim_key, x.id desc) e
      join research.claims c on c.revision_id = e.revision_id and c.claim_key = e.claim_key
      join research.revisions v on v.id = e.revision_id
      left join research.claims pc on pc.claim_key = e.claim_key
       and pc.revision_id = coalesce(v.predecessor_id,
                                     (select p.id from research.revisions p where p.work_id = v.work_id and p.number = v.number - 1))
     where e.op = 'assert' and e.method = 'reworded' and e.status = 'proposed'
     order by e.claim_key;
$$;
grant execute on function claims.answer_rewording(uuid, text, text, boolean), claims.rewordings(uuid),
    claims.rewording_answers(uuid) to authenticated;

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
comment on table claims.predicates is
    'The predicates an assertion may use, with the kinds they relate and whether each is transitive or symmetric.';
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
comment on table claims.relations is
    'A typed assertion between two claims, with its predicate, review status, evidence and the spans it rests on.';
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
        -- comparison-and-trust.md *Stance labels*, moved here from the application's validator (REM-479). The frame
        -- match is the proposer's judgement of each slot (same, overlaps, differs, unknown); a slot nobody checked is
        -- unknown, never same. uncertain is not a relation: it is what a pair is when a requirement is missing.
        -- Readability first, so no rule below can say anything about a revision the caller may not read.
        if not research.revision_readable(p_evidence)
           or (p_evidence2 is not null and not research.revision_readable(p_evidence2)) then
            raise no_data_found using message = 'Research revision not found';
        end if;
        if p_evidence2 is null or (select work_id from research.revisions where id = p_evidence2)
                                = (select work_id from research.revisions where id = p_evidence) then
            raise check_violation using message = 'A comparison pairs claims from two different works';
        end if;
        if exists (select 1 from jsonb_each_text(coalesce(p_spans->'frame_match', '{}'::jsonb)) m
                    where m.key not in ('subject', 'outcome', 'population', 'setting', 'period', 'comparator', 'evidence_type')
                       or m.value not in ('same', 'overlaps', 'differs', 'unknown')) then
            raise check_violation using message = 'frame_match names the seven slots, each same, overlaps, differs or unknown';
        end if;
        if p_predicate in ('agrees', 'contradicts') and not (
               (select bool_and(coalesce(p_spans->'frame_match'->>k, 'unknown') = 'same')
                  from unnest(array['subject', 'outcome', 'evidence_type']) k)
           and (select bool_and(coalesce(p_spans->'frame_match'->>k, 'unknown') in ('same', 'overlaps'))
                  from unnest(array['population', 'period']) k)) then
            raise check_violation using message = p_predicate || ' needs the same question: subject, outcome and '
                'evidence_type same, population and period same or overlapping',
                hint = 'A differing slot is different_scope; a missing one is uncertain, which is not a relation';
        end if;
        if p_predicate in ('agrees', 'contradicts', 'same_source_opposite')
           and (coalesce(p_spans->>'src', '') = '' or coalesce(p_spans->>'dst', '') = '') then
            raise check_violation using message = p_predicate || ' needs a quoted span from both passages';
        end if;
        if p_predicate = 'contradicts' and exists (
               select 1 from unnest(array['subject', 'outcome', 'population', 'setting', 'period', 'comparator',
                                          'evidence_type']) k
                where coalesce(p_spans->'frame_match'->>k, 'unknown') not in ('same', 'overlaps')) then
            raise check_violation using message = 'contradicts needs every frame slot same or overlaps';
        end if;
        if p_predicate = 'different_scope' and not exists (
               select 1 from jsonb_each_text(coalesce(p_spans->'frame_match', '{}'::jsonb)) m where m.value = 'differs') then
            raise check_violation using message = 'different_scope names the slot that differs: mark it differs in frame_match';
        end if;
        if p_predicate = 'same_source_opposite' and not (
               coalesce(p_spans->>'shared_origin', '') <> ''
           and exists (select 1 from claims.cites c join claims.origins o on o.id = c.origin_id
                        where c.revision_id = p_evidence and c.claim_key = p_src_key
                          and o.key = claims.study_key(p_spans->>'shared_origin'))
           and exists (select 1 from claims.cites c join claims.origins o on o.id = c.origin_id
                        where c.revision_id = p_evidence2 and c.claim_key = p_dst_key
                          and o.key = claims.study_key(p_spans->>'shared_origin'))) then
            raise check_violation using message = 'same_source_opposite needs shared_origin, an origin both claims cite';
        end if;
    elsif p_predicate = 'same_as' then
        -- graph.md §5: judged, never computed, and carrying what was judged. Both occurrences, a span quoted from
        -- each, and the slots compared for both sides, so a reader can see why they were called substitutable.
        if p_evidence2 is null then
            raise check_violation using message = 'same_as names an occurrence on each side: pass both revisions';
        end if;
        if coalesce(p_spans->>'src', '') = '' or coalesce(p_spans->>'dst', '') = '' then
            raise check_violation using message = 'same_as quotes a span from each occurrence (spans.src, spans.dst)';
        end if;
        if exists (select 1 from unnest(array['src', 'dst']) side, unnest(array['subject', 'predicate', 'object',
                                                                              'scope', 'polarity', 'modality']) slot
                    where not coalesce(p_spans->'slots'->side ? slot, false)) then
            raise check_violation using message = 'same_as records the slots it compared for both sides',
                hint = 'spans.slots.src and spans.slots.dst each name subject, predicate, object, scope, polarity and modality';
        end if;
    end if;
    if v_status not in ('proposed', 'confirmed', 'disputed') then
        raise check_violation using message = 'Unknown status', detail = v_status;
    end if;
    if v_status = 'confirmed' and v_actor <> 'person' then
        raise insufficient_privilege using message = 'Only a person confirms a relation; an agent proposes it',
            hint = 'human_only';
    end if;
    -- A comparison's author compares works they may read, which need not be their own (REM-479); every other
    -- relation is asserted from a revision of the caller's own work.
    -- A comparison also labels a pair qualifies (comparison-and-trust.md): across two works that is a reader's label
    -- like the comparative ones, where within one work it is the writer's argument.
    if v_pred.kind = 'comparative'
       or (p_predicate = 'qualifies' and p_evidence2 is not null
           and (select work_id from research.revisions where id = p_evidence2)
               is distinct from (select work_id from research.revisions where id = p_evidence)) then
        if not research.revision_readable(p_evidence) then
            raise no_data_found using message = 'Research revision not found';
        end if;
    elsif not exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
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
    if p_predicate = 'same_as' and (
           position(p_spans->>'src' in (select text from research.claims where revision_id = p_evidence and claim_key = p_src_key)) = 0
        or position(p_spans->>'dst' in (select text from research.claims where revision_id = p_evidence2 and claim_key = p_dst_key)) = 0) then
        raise check_violation using message = 'Each span must be words its occurrence says';
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
    if not found then
        raise no_data_found using message = 'Relation not found';
    end if;
    if not exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
                    where v.id = r.evidence and w.owner_id = v_user)
       and not exists (select 1 from claims.relations f join claims.tx t on t.id = f.tx
                        where f.src = r.src and f.predicate = r.predicate and f.dst = r.dst and f.evidence = r.evidence
                          and f.evidence2 is not distinct from r.evidence2 and f.keys = r.keys and t.actor_id = v_user) then
        -- The other side (graph.md §5): the owner of the second revision may dispute, as a person, and do nothing
        -- else. A dispute is a later row; the assertion it answers stays in the history.
        if r.evidence2 is null or not exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
                                               where v.id = r.evidence2 and w.owner_id = v_user) then
            raise no_data_found using message = 'Relation not found';
        end if;
        if p_retract or p_status is distinct from 'disputed' then
            raise insufficient_privilege using message = 'The other side of a relation may only dispute it',
                hint = 'no_grant';
        end if;
        if v_actor <> 'person' then
            raise insufficient_privilege using message = 'Only a person disputes a relation', hint = 'human_only';
        end if;
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
-- 10a. Frames and questions (graph.md §7, REM-476). A frame is what an occurrence says about the question it
--      answers; it lives in the revision's document and is projected here, one row per framed occurrence, never
--      updated. A question is identified by its normalised subject and outcome and by any refining slot; a
--      question with refining slots names the broader one it refines. Which question a claim answers is an
--      assertion with a stance: the platform asserts it from the slots, confirmed because slot matching is
--      computed, with stance `unknown` because a stance is judged.
-- ------------------------------------------------------------
create table if not exists claims.frames (
    revision_id   uuid not null,
    claim_key     text not null,
    subject       text,
    outcome       text,
    population    text,
    setting       text,
    period        text,
    comparator    text,
    evidence_type text,
    direction     text,
    magnitude     text,
    frame         jsonb not null check (jsonb_typeof(frame) = 'object'),
    primary key (revision_id, claim_key),
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key) on delete cascade
);
comment on table claims.frames is
    'A claim''s comparable slots — subject, outcome, population, setting, period, comparator, direction, magnitude — which is what makes agreement checkable.';

create table if not exists claims.questions (
    id          uuid primary key default uuidv7(),
    subject     text check (length(subject) > 0),
    outcome     text check (length(outcome) > 0),
    refinements jsonb not null default '{}'::jsonb check (jsonb_typeof(refinements) = 'object'),
    refines     uuid references claims.questions(id),
    key         text not null unique,
    tx          bigint not null references claims.tx(id),
    check ((refinements = '{}'::jsonb) = (refines is null))
);
comment on table claims.questions is
    'The question two claims must share before they can be compared, minted from a frame''s subject and outcome, or from a phrasing alone (graph.md §7).';
create index if not exists questions_refines on claims.questions (refines) where refines is not null;
-- A question minted from a phrasing (specs/build-knit-dream/coalescing.md): a polar question in plain words, with no
-- frame yet. A database installed before carries subject and outcome as required columns, so they are relaxed here
-- and the rule moves to a check: a question has a frame (subject and outcome) or a phrasing, and a phrased question
-- is keyed by its normalised words.
alter table claims.questions add column if not exists phrasing text;
alter table claims.questions alter column subject drop not null;
alter table claims.questions alter column outcome drop not null;
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'questions_framed_or_phrased'
                                               and conrelid = 'claims.questions'::regclass) then
        alter table claims.questions add constraint questions_framed_or_phrased check (
            (subject is not null and outcome is not null)
            or (phrasing is not null and length(phrasing) between 10 and 200 and right(phrasing, 1) = '?'
                and key = 'q:' || claims.normalised(phrasing)));
    end if;
end $$;

create table if not exists claims.answered (
    id          bigint generated always as identity primary key,
    claim_id    uuid not null references claims.claims(id),
    question_id uuid not null references claims.questions(id),
    stance      text not null check (stance in ('yes', 'no', 'depends', 'unknown')),
    status      text not null check (status in ('proposed', 'confirmed', 'disputed')),
    op          text not null default 'assert' check (op in ('assert', 'retract')),
    evidence    uuid not null references research.revisions(id) on delete cascade,
    claim_key   text not null,
    tx          bigint not null references claims.tx(id),
    p           real check (p between 0 and 1)
);
comment on table claims.answered is
    'The stance a claim takes on a question: computed from its frame when a revision is projected, or recorded when a person answers whether a reworded claim is still the same one.';
-- The judge's probability for a proposed stance (coalescing.md §5.4), when a model proposed it; null otherwise.
alter table claims.answered add column if not exists p real check (p between 0 and 1);
create index if not exists answered_question on claims.answered (question_id, claim_id, id desc);
create index if not exists answered_claim on claims.answered (claim_id);
create index if not exists answered_evidence on claims.answered (evidence);

-- The refining slots of a frame, normalised and without the empty ones. direction and magnitude are the answer,
-- not the question, and origin is evidence, so none of them refines.
create or replace function claims.refinements(p_frame jsonb) returns jsonb
language sql immutable parallel safe set search_path = pg_catalog as $$
    select coalesce(jsonb_object_agg(k, claims.normalised(p_frame->>k) order by k), '{}'::jsonb)
      from unnest(array['population', 'setting', 'period', 'comparator', 'evidence_type']) k
     where nullif(btrim(coalesce(p_frame->>k, '')), '') is not null;
$$;

-- The question a subject, an outcome and refining slots identify, minted under p_tx when none exists yet. A refined
-- question mints its broader one first, so `refines` always names a row.
create or replace function claims.question_for(p_subject text, p_outcome text, p_refinements jsonb, p_tx bigint)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    k    text := claims.normalised(p_subject) || '|' || claims.normalised(p_outcome) || '|' || p_refinements::text;
    base uuid;
    q    uuid;
begin
    select id into q from claims.questions where key = k;
    if found then
        return q;
    end if;
    if p_refinements <> '{}'::jsonb then
        base := claims.question_for(p_subject, p_outcome, '{}'::jsonb, p_tx);
    end if;
    insert into claims.questions (subject, outcome, refinements, refines, key, tx)
    values (btrim(p_subject), btrim(p_outcome), p_refinements, base, k, p_tx)
    on conflict (key) do nothing
    returning id into q;
    if q is null then
        select id into q from claims.questions where key = k;
    end if;
    return q;
end;
$$;

-- A revision's frames and the questions they answer. Only an occurrence with no frame row yet is projected, so a
-- rebuild and a replay write nothing. A frame without both subject and outcome is kept and answers nothing.
create or replace function claims.project_frames(p_revision uuid) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    d   jsonb;
    c   jsonb;
    f   jsonb;
    t   bigint;
    cid uuid;
    q   uuid;
    n   int := 0;
begin
    select document into d from research.revisions where id = p_revision;
    for c in select value from jsonb_array_elements(coalesce(d->'claims', '[]'::jsonb)) loop
        f := c->'frame';
        continue when f is null or jsonb_typeof(f) <> 'object' or f = '{}'::jsonb;
        continue when exists (select 1 from claims.frames x where x.revision_id = p_revision and x.claim_key = c->>'id');
        continue when not exists (select 1 from research.claims x where x.revision_id = p_revision and x.claim_key = c->>'id');
        insert into claims.frames (revision_id, claim_key, subject, outcome, population, setting, period, comparator,
                                   evidence_type, direction, magnitude, frame)
        values (p_revision, c->>'id', nullif(btrim(f->>'subject'), ''), nullif(btrim(f->>'outcome'), ''),
                nullif(btrim(f->>'population'), ''), nullif(btrim(f->>'setting'), ''), nullif(btrim(f->>'period'), ''),
                nullif(btrim(f->>'comparator'), ''), nullif(btrim(f->>'evidence_type'), ''),
                nullif(btrim(f->>'direction'), ''), nullif(btrim(f->>'magnitude'), ''), f);
        n := n + 1;
        continue when nullif(btrim(coalesce(f->>'subject', '')), '') is null
                   or nullif(btrim(coalesce(f->>'outcome', '')), '') is null;
        select x.claim_id into cid from claims.expresses x
         where x.revision_id = p_revision and x.claim_key = c->>'id' and x.part = 1 order by x.id desc limit 1;
        continue when cid is null;
        if t is null then
            insert into claims.tx (actor_kind, revision_id, reason)
            values ('platform', p_revision, 'frames of ' || (select label from research.revisions where id = p_revision))
            returning id into t;
        end if;
        q := claims.question_for(f->>'subject', f->>'outcome', claims.refinements(f), t);
        insert into claims.answered (claim_id, question_id, stance, status, evidence, claim_key, tx)
        values (cid, q, 'unknown', 'confirmed', p_revision, c->>'id', t);
    end loop;
    return n;
end;
$$;

-- History and access: a frame and an answer are readable with their revision; a question when a readable answer
-- names it or a question it refines (graph.md §9).
do $$
declare t text;
begin
    foreach t in array array['claims.frames', 'claims.questions', 'claims.answered'] loop
        execute format('create or replace trigger trg_refuse_rewrite before update or delete on %s '
                       'for each row execute function research.refuse_rewrite()', t);
        execute format('create or replace trigger trg_refuse_truncate before truncate on %s '
                       'for each statement execute function research.refuse_rewrite()', t);
    end loop;
end $$;
alter table claims.frames enable row level security;
drop policy if exists frames_readable on claims.frames;
create policy frames_readable on claims.frames for select using (research.revision_readable(revision_id));
alter table claims.answered enable row level security;
drop policy if exists answered_readable on claims.answered;
create policy answered_readable on claims.answered for select using (research.revision_readable(evidence));
alter table claims.questions enable row level security;
drop policy if exists questions_readable on claims.questions;
-- A policy on claims.questions cannot read claims.questions under its own policy, so the refinement walk is a
-- definer that applies the one rule itself: a readable revision answers the question or one that refines it.
create or replace function claims.question_readable(p_question uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select exists (select 1 from claims.answered a
                    where a.question_id in (select p_question union all
                                            select r.id from claims.questions r where r.refines = p_question)
                      and research.revision_readable(a.evidence));
$$;
create policy questions_readable on claims.questions for select using (claims.question_readable(id));
-- A policy runs as the caller, so the caller executes it; identity/closing.sql takes PUBLIC's EXECUTE away.
grant execute on function claims.question_readable(uuid) to authenticated;
grant select on claims.frames, claims.questions, claims.answered to authenticated;
revoke all on function claims.question_for(text, text, jsonb, bigint), claims.project_frames(uuid) from public;

-- ------------------------------------------------------------
-- 10a. Coalescing (specs/build-knit-dream/coalescing.md §5). A question minted from a phrasing, a stance an agent
--      proposes and the writer confirms, its withdrawal, and the web of questions that more than one work answers.
--      Coalescing never merges claims: it joins them through the questions they answer.
-- ------------------------------------------------------------

-- The question a polar phrasing names, minted when none has those normalised words. Anyone who may write research
-- may pose one. A posed question is readable only once a readable claim answers it (claims.question_readable), so
-- the id this returns says that the words exist as a question and nothing about who answers it.
create or replace function claims.pose_question(p_phrasing text, p_reason text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'insert');
    v_text text := regexp_replace(btrim(coalesce(p_phrasing, '')), '\s+', ' ', 'g');
    k      text;
    q      uuid;
    t      bigint;
begin
    if length(v_text) not between 10 and 200 or right(v_text, 1) <> '?' then
        raise check_violation using
            message = 'A question is one sentence of 10 to 200 characters that ends in a question mark';
    end if;
    k := 'q:' || claims.normalised(v_text);
    select id into q from claims.questions where key = k;
    if found then
        return q;
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), coalesce(nullif(p_reason, ''), 'posed'))
    returning id into t;
    insert into claims.questions (phrasing, key, tx) values (v_text, k, t)
    on conflict (key) do nothing
    returning id into q;
    if q is null then
        select id into q from claims.questions where key = k;
    end if;
    return q;
end;
$$;

-- A claim's stance on a question, from a revision the caller may read. A stance is a reading of what the writer
-- meant, so an agent's or another reader's lands `proposed`, and the writer's own, as a person, lands `confirmed`
-- (coalescing.md §7). p is the judge's probability when a model proposed it.
create or replace function claims.propose_answer(p_revision uuid, p_claim_key text, p_question uuid, p_stance text,
                                                 p_p real default null, p_reason text default null) returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user  uuid := rbac.require('research', 'insert');
    v_actor text := rbac.current_actor();
    v_claim uuid;
    v_own   boolean;
    t       bigint;
    v_id    bigint;
begin
    if p_stance is null or p_stance not in ('yes', 'no', 'depends') then
        raise check_violation using message = 'A stance is yes, no or depends';
    end if;
    if not research.revision_readable(p_revision) then
        raise no_data_found using message = 'Research revision not found';
    end if;
    if not exists (select 1 from claims.questions where id = p_question) then
        raise no_data_found using message = 'Question not found';
    end if;
    select x.claim_id into v_claim from claims.expresses x
     where x.revision_id = p_revision and x.claim_key = p_claim_key and x.part = 1 order by x.id desc limit 1;
    if v_claim is null then
        raise foreign_key_violation using message = 'The claim must be an occurrence in its evidence revision',
            detail = coalesce(p_claim_key, '');
    end if;
    v_own := exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
                      where v.id = p_revision and w.owner_id = v_user);
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, v_actor, rbac.current_credential_id(), p_revision, coalesce(nullif(p_reason, ''), 'answered'))
    returning id into t;
    insert into claims.answered (claim_id, question_id, stance, status, evidence, claim_key, tx, p)
    values (v_claim, p_question, p_stance, case when v_actor = 'person' and v_own then 'confirmed' else 'proposed' end,
            p_revision, p_claim_key, t, p_p)
    returning id into v_id;
    return v_id;
end;
$$;

-- Take a stance back: a retraction row after the answer, which leaves the earlier rows in place. The caller must have
-- made the stance being withdrawn, or own the work it was made from. A nightly run withdraws what it no longer finds.
create or replace function claims.withdraw_answer(p_revision uuid, p_claim_key text, p_question uuid,
                                                  p_reason text default null) returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'insert');
    v_last claims.answered;
    t      bigint;
    v_id   bigint;
begin
    select a.* into v_last from claims.answered a
     where a.evidence = p_revision and a.claim_key = p_claim_key and a.question_id = p_question
     order by a.id desc limit 1;
    if v_last.id is null or v_last.op = 'retract' then
        raise no_data_found using message = 'No stance to withdraw';
    end if;
    if not exists (select 1 from claims.tx x where x.id = v_last.tx and x.actor_id = v_user)
       and not exists (select 1 from research.revisions v join research.works w on w.id = v.work_id
                        where v.id = p_revision and w.owner_id = v_user) then
        raise insufficient_privilege using message = 'Only whoever made a stance, or the work''s owner, withdraws it',
            hint = 'no_grant';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), p_revision,
            coalesce(nullif(p_reason, ''), 'withdrawn'))
    returning id into t;
    insert into claims.answered (claim_id, question_id, stance, status, op, evidence, claim_key, tx)
    values (v_last.claim_id, v_last.question_id, v_last.stance, v_last.status, 'retract', p_revision, p_claim_key, t)
    returning id into v_id;
    return v_id;
end;
$$;

-- The questions the caller can see answered from at least p_min_works works, each with its answers: one per claim,
-- the latest assertion as of p_at, stance unknown left out.
--
-- A definer that asks research.revision_readable once per revision. It was an invoker, and row security then asked it
-- once per answered row and again through claims.tx's policy, which re-reads claims.answered: on the dev instance
-- (25,567 answers from 4,463 revisions) a caller waited 3.3 s where the owner took 24 ms, and under load the
-- authenticator's 30 s timeout failed search_research. Nothing else changes what a caller sees: an answer's tx is
-- readable because the answer is (tx_readable), its revision and work rows are readable because the revision is,
-- and its question is readable because a readable revision answers it (question_readable).
create or replace function claims.question_web(p_at timestamptz default now(), p_min_works int default 2)
returns table (question uuid, phrasing text, subject text, outcome text, works int, answers jsonb)
language sql stable security definer set search_path = pg_catalog, public as $$
    with revisions as materialized (select distinct a.evidence from claims.answered a),
    readable as materialized (select r.evidence from revisions r where research.revision_readable(r.evidence)),
    latest as (
        select distinct on (a.claim_id, a.question_id)
               a.claim_id, a.question_id, a.stance, a.status, a.op, a.evidence, a.claim_key, a.p
          from claims.answered a join readable using (evidence) join claims.tx t on t.id = a.tx
         where t.at <= p_at
         order by a.claim_id, a.question_id, t.at desc, a.id desc),
    live as (
        select l.*, w.public_id as work
          from latest l
          join research.revisions v on v.id = l.evidence
          join research.works w on w.id = v.work_id
         where l.op = 'assert' and l.stance <> 'unknown')
    select q.id, q.phrasing, q.subject, q.outcome, count(distinct live.work)::int,
           jsonb_agg(jsonb_build_object('claim', live.claim_id, 'work', live.work, 'revision_id', live.evidence,
                                        'claim_key', live.claim_key, 'stance', live.stance,
                                        'status', live.status, 'p', live.p)
                     order by live.work, live.claim_key)
      from live join claims.questions q on q.id = live.question_id
     group by q.id, q.phrasing, q.subject, q.outcome
    having count(distinct live.work) >= greatest(coalesce(p_min_works, 2), 1)
     order by count(distinct live.work) desc, q.id;
$$;
grant execute on function claims.pose_question(text, text), claims.propose_answer(uuid, text, uuid, text, real, text),
                          claims.withdraw_answer(uuid, text, uuid, text), claims.question_web(timestamptz, int)
    to authenticated;

-- ------------------------------------------------------------
-- 10a2. Finding a question by meaning (REM-998). A person asks "does agent memory need valid time?" and the graph
--       either names the question already holding that argument, with its stances as of a date, or says there is
--       none close enough.
--
-- WHAT WAS MISSING WAS IN THE ENGINE, NOT ONLY THE SURFACE. A question had no searchable text and no vector: it was
-- in no lexical or semantic source, so the only way to find one was the words of its key, which is what the
-- application's search does. Reproduced on 19 October: the top hit for the question above was one about clinical
-- methods being "valid" in another hospital, matched on one shared word. Claims were already a corpus
-- (research.claims, §12 below); the questions they answer were not.
--
-- So a question gets one text, its phrasing or else its frame's subject and outcome, and that text is registered
-- as the semantic corpus `questions`, like chunks and claims. Its vectors live in the model's space,
-- keyed by the question's id, and claims.questions_to_embed lists the ones a space still lacks -- the rows an
-- `embed:` matrix fans out over (claims.install_question_embed_workflow). Readability is the question's own policy
-- (claims.question_readable): a question nobody you can read answers is not found, by meaning or by words.
--
-- DISTANCE RANKS AND NEVER DECIDES, the rule claims.candidates already states. find_question returns the nearest
-- questions with their distance and whether each falls inside the caller's floor; "none close enough" is an answer
-- the caller reads off `within`, and the nearest question is still shown so the caller can see what it missed.
-- The floor has no default, for the reason candidates gives.
-- ------------------------------------------------------------
alter table claims.questions add column if not exists search_text text
    generated always as (coalesce(phrasing, subject || ': ' || outcome)) stored;
comment on column claims.questions.search_text is
    'The words a question is found by: its phrasing, or its frame''s subject and outcome. Derived, never written.';

do $$
begin
    if to_regclass('aiq.semantic_sources') is not null then
        insert into aiq.semantic_sources (name, source_table, content_col)
        values ('questions', 'claims.questions', 'search_text')
        on conflict (name) do update
           set source_table = excluded.source_table,
               content_col  = excluded.content_col,
               shipped = excluded.shipped or semantic_sources.shipped;
    end if;
end $$;
-- Not a lexical source as well: aiq.register_lexical_source adds a generated tsvector over the content column, and
-- a generated column cannot read another one. Finding a question by its words is what failed above.

-- The questions the caller may read that a model's space has no vector for, shaped as an `embed:` matrix's rows:
-- chunk_id is what aiq.land_embeddings keys the space by. Invoker, so a run sees what its owner may read and an
-- operator's run sees all of it.
create or replace function claims.questions_to_embed(p_model text, p_limit int default 500)
returns table (chunk_id uuid, text text)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    v_tbl text;
begin
    if not exists (select 1 from aiq.embedding_models where name = p_model) then
        raise no_data_found using message = format('embedding model %s is not registered', p_model);
    end if;
    v_tbl := aiq.embedding_space_name(p_model);
    if to_regclass('aiq.' || quote_ident(v_tbl)) is null then
        return query select q.id, q.search_text from claims.questions q
                      order by q.id limit least(greatest(p_limit, 1), 5000);
        return;
    end if;
    return query execute format(
        'select q.id, q.search_text from claims.questions q
          where not exists (select 1 from aiq.%I e where e.chunk_id = q.id)
          order by q.id limit $1', v_tbl)
        using least(greatest(p_limit, 1), 5000);
end;
$$;

-- The questions nearest a text's vector, each with its stances as of p_at: how many of the claims answering it say
-- yes, no or depends, from how many works. The vector arrives alongside, as it does for aiq.query; embedding is an
-- external model call and this schema makes none.
create or replace function claims.find_question(p_embedding vector, p_max_distance float8, p_limit int default 5,
                                                p_model text default null, p_at timestamptz default now())
returns table (question uuid, phrasing text, distance float8, within boolean,
               yes int, no int, depends int, works int)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    m     aiq.embedding_models;
    v_tbl text;
begin
    if p_max_distance is null then
        raise check_violation using
            message = 'find_question needs a distance floor: whether a question is close enough is the caller''s call',
            hint = 'the number is meaningful only against the model that produced the vectors';
    end if;
    if p_embedding is null then
        raise check_violation using message = 'find_question needs the text''s vector: embed it with the model and pass it';
    end if;
    if p_model is null then
        select * into m from aiq.embedding_models where is_default;
    else
        select * into m from aiq.embedding_models where name = p_model;
    end if;
    if m.name is null then
        raise no_data_found using message = format('embedding model %s is not registered', coalesce(p_model, '(the default)'));
    end if;
    if vector_dims(p_embedding) <> m.dim then
        raise data_exception using message = format('the vector has %s dimensions and model %s expects %s',
                                                    vector_dims(p_embedding), m.name, m.dim);
    end if;
    v_tbl := aiq.embedding_space_name(m.name);
    if to_regclass('aiq.' || quote_ident(v_tbl)) is null then
        raise no_data_found using message = format('embedding model %s is registered but its space does not exist', m.name);
    end if;
    return query execute format($q$
        with near as (
            select q.id, q.search_text, (e.embedding <=> $1)::float8 as d
              from aiq.%I e join claims.questions q on q.id = e.chunk_id
             order by e.embedding <=> $1 limit $2),
        latest as (
            select distinct on (a.claim_id, a.question_id) a.question_id, a.stance, a.op, a.evidence
              from claims.answered a join claims.tx t on t.id = a.tx
             where a.question_id in (select id from near) and t.at <= $3
             order by a.claim_id, a.question_id, t.at desc, a.id desc)
        select n.id, n.search_text, n.d, n.d <= $4,
               count(*) filter (where l.stance = 'yes' and l.op = 'assert')::int,
               count(*) filter (where l.stance = 'no' and l.op = 'assert')::int,
               count(*) filter (where l.stance = 'depends' and l.op = 'assert')::int,
               count(distinct v.work_id) filter (where l.op = 'assert' and l.stance <> 'unknown')::int
          from near n
          left join latest l on l.question_id = n.id
          left join research.revisions v on v.id = l.evidence
         group by n.id, n.search_text, n.d
         order by n.d, n.id$q$, v_tbl)
        using p_embedding, least(greatest(coalesce(p_limit, 5), 1), 50), p_at, p_max_distance;
end;
$$;

-- What changed a question's answer between two dates: each claim whose latest stance at p_from differs from its
-- latest at p_to -- added, withdrawn or changed -- with when the later one was made and by what kind of actor (a
-- transaction's reason is not granted to readers, claims.tx). Invoker: an answer from a revision the caller cannot
-- read is not part of the change they see.
create or replace function claims.stance_changes(p_question uuid, p_from timestamptz, p_to timestamptz default now())
returns table (claim uuid, revision_id uuid, claim_key text, stance_then text, stance_now text, change text,
               changed_at timestamptz, actor_kind text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with at_from as (
        select distinct on (a.claim_id) a.claim_id, a.stance, a.op
          from claims.answered a join claims.tx t on t.id = a.tx
         where a.question_id = p_question and t.at <= p_from
         order by a.claim_id, t.at desc, a.id desc),
    at_to as (
        select distinct on (a.claim_id) a.claim_id, a.stance, a.op, a.evidence, a.claim_key, t.at, t.actor_kind
          from claims.answered a join claims.tx t on t.id = a.tx
         where a.question_id = p_question and t.at <= p_to
         order by a.claim_id, t.at desc, a.id desc),
    paired as (
        select coalesce(n.claim_id, f.claim_id) as claim, n.evidence, n.claim_key,
               case when f.op = 'assert' and f.stance <> 'unknown' then f.stance end as s_then,
               case when n.op = 'assert' and n.stance <> 'unknown' then n.stance end as s_now,
               n.at, n.actor_kind
          from at_to n full join at_from f on f.claim_id = n.claim_id)
    select p.claim, p.evidence, p.claim_key, p.s_then, p.s_now,
           case when p.s_then is null then 'added' when p.s_now is null then 'withdrawn' else 'changed' end,
           p.at, p.actor_kind
      from paired p
     where p.s_then is distinct from p.s_now
     order by p.at, p.claim;
$$;

-- The workflow that keeps a model's space current: one `embed:` child per question the space lacks, landed by
-- aiq.land_embeddings. Run as an operator it indexes every question; run as a person, what they can read.
--
-- ONLY FOR A MODEL SERVED OVER HTTP. An `embed:` step compiles to an HTTP call, and the compiler refuses one for a
-- model that runs inside the worker (fastembed), because there is nothing to call. The worker's `embed` op embeds
-- a resource's chunks by resource id, and a question is not a resource, so a deployment whose only model runs in
-- the worker cannot index questions yet: that needs a worker op over claims.questions_to_embed.
create or replace function claims.install_question_embed_workflow(p_model text default null,
                                                                  p_name text default 'embed_questions')
returns text
language plpgsql set search_path = pg_catalog, public as $$
declare
    v_model text := p_model;
begin
    if v_model is null then
        select name into v_model from aiq.embedding_models where is_default;
    end if;
    if v_model is null or not exists (select 1 from aiq.embedding_models where name = v_model) then
        raise no_data_found using message = format('embedding model %s is not registered', coalesce(v_model, '(the default)'));
    end if;
    perform workflow.define_yaml(format($y$
name: %1$s
steps:
  - id: embed
    matrix:
      rows: "select chunk_id, text from claims.questions_to_embed('%2$s')"
      max_fanout: 500
      template:
        embed:
          text: '{{item.text}}'
          model: %2$s
  - id: land
    needs: [embed]
    sql: {function: land_embeddings, args: ['{{steps.embed.result.task_id}}']}
$y$, p_name, v_model));
    return format('%s: embeds the questions a %s space lacks', p_name, v_model);
end;
$$;

grant execute on function claims.questions_to_embed(text, int),
                          claims.find_question(vector, float8, int, text, timestamptz),
                          claims.stance_changes(uuid, timestamptz, timestamptz)
    to authenticated;
revoke all on function claims.install_question_embed_workflow(text, text) from public;

-- ------------------------------------------------------------
-- 10a3. A remembered fact bears on a question (REM-996). The memory graph (aiq.edges: "Priya Raman prefers DuckDB")
--       and the questions graph ("Should a small analytics team move its warehouse off Postgres?") sat side by side
--       with nothing joining them. claims.bears_on is that join.
--
-- A LINK, NEVER A VERDICT. A row says a fact bears on a question, who proposed it and with what probability, and,
-- later, whether a person confirmed or disputed it. It carries no stance: what the fact says about the question is
-- read from the fact, by whoever reads it, and a stored stance would be a content verdict the graph made for them.
-- Proposals come from a decider (Jev) through claims.install_fact_question_workflow; a person confirms. Later rows
-- supersede earlier ones for the same pair, and none is rewritten.
--
-- READABLE WITH BOTH ENDS. A link is visible to a caller who may read the fact (aiq.edges' own policy, asked as the
-- caller) and the question (claims.question_readable), so a link can never disclose either.
--
-- THE CANDIDATES ARE PICKED BY DISTANCE, THE LINK BY THE DECIDER. A fact (an aiq.edges row, as words through
-- claims.fact_texts) is a semantic corpus like the questions; claims.facts_to_link offers each unlinked fact its nearest questions in one model's
-- space, and the decider chooses among them or "none of these". Distance proposes where to look; it never links.
-- ------------------------------------------------------------
create or replace view claims.fact_texts with (security_invoker = true) as
select e.id,
       concat_ws(' ', coalesce(s.summary, sk.key), replace(e.relation, '_', ' '), coalesce(d.summary, dk.key)) as content,
       e.src_id, e.dst_id, e.relation, e.valid_from, e.valid_to
  from aiq.edges e
  join aiq.nodes s on s.id = e.src_id
  join aiq.nodes d on d.id = e.dst_id
  left join lateral (select k.key from aiq.node_keys k where k.node_id = s.id and k.kind = 'canonical' limit 1) sk on true
  left join lateral (select k.key from aiq.node_keys k where k.node_id = d.id and k.kind = 'canonical' limit 1) dk on true;
comment on view claims.fact_texts is
    'A remembered fact as words: its subject, relation and object, read through aiq.edges'' own policy.';
grant select on claims.fact_texts to authenticated;

do $$
begin
    if to_regclass('aiq.semantic_sources') is not null then
        -- The source is aiq.edges itself, not the view: a semantic source is a table (its delete trigger
        -- forgets the vector), and naming the edges makes a vector readable exactly when its edge is. The
        -- content column is only the relation, so SEMANTIC FROM facts returns ids to read through fact_texts.
        insert into aiq.semantic_sources (name, source_table, content_col)
        values ('facts', 'aiq.edges', 'relation')
        on conflict (name) do update
           set source_table = excluded.source_table,
               content_col  = excluded.content_col,
               shipped = excluded.shipped or semantic_sources.shipped;
    end if;
end $$;

create table if not exists claims.bears_on (
    id          bigint generated always as identity primary key,
    edge_id     uuid not null references aiq.edges(id) on delete cascade,
    question_id uuid not null references claims.questions(id),
    status      text not null check (status in ('proposed', 'confirmed', 'disputed')),
    p           real check (p between 0 and 1),
    tx          bigint not null references claims.tx(id)
);
comment on table claims.bears_on is
    'That a remembered fact bears on a question: proposed by a decider or a reader, confirmed or disputed by a person. Never a stance.';
create index if not exists bears_on_edge on claims.bears_on (edge_id, question_id, id desc);
create index if not exists bears_on_question on claims.bears_on (question_id, edge_id, id desc);
-- Rows are never rewritten, and a later row supersedes. Deletes are not refused: the only delete is the cascade
-- from an edge that was itself removed, and a link to a fact that no longer exists has nothing left to say.
create or replace trigger trg_refuse_rewrite before update on claims.bears_on
    for each row execute function research.refuse_rewrite();
create or replace trigger trg_refuse_truncate before truncate on claims.bears_on
    for each statement execute function research.refuse_rewrite();
alter table claims.bears_on enable row level security;
drop policy if exists bears_on_readable on claims.bears_on;
create policy bears_on_readable on claims.bears_on for select
    using (exists (select 1 from aiq.edges e where e.id = claims.bears_on.edge_id)
           and claims.question_readable(question_id));
grant select on claims.bears_on to authenticated;

-- Whether the caller may read an edge, for the definers below, which see every row. It states aiq.edges'
-- edges_via_endpoints policy in the terms of the node and resource policies it reads through, because a definer
-- cannot ask a policy as its caller. A COPY, so research/38 compares it with the policy for each caller it tests.
create or replace function claims.edge_readable(p_edge uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select exists (
        select 1 from aiq.edges e
          join aiq.nodes s on s.id = e.src_id
          join aiq.nodes d on d.id = e.dst_id
         where e.id = p_edge
           and (s.visibility = 'public' or s.owner_id = rbac.current_user_id()
                or (s.visibility = 'org' and s.org_id in (select rbac.current_org_ids())))
           and (d.visibility = 'public' or d.owner_id = rbac.current_user_id()
                or (d.visibility = 'org' and d.org_id in (select rbac.current_org_ids())))
           and case
                   when jsonb_typeof(e.provenance->'sources') is distinct from 'array' then true
                   when jsonb_array_length(e.provenance->'sources') = 0 then true
                   else exists (
                       select 1 from jsonb_array_elements(e.provenance->'sources') src
                        where not (src ? 'resource_id')
                           or exists (select 1 from content.resources r
                                       where r.id = case when pg_input_is_valid(src->>'resource_id', 'uuid')
                                                         then (src->>'resource_id')::uuid end
                                         and (r.visibility = 'public' or r.owner_id = rbac.current_user_id()
                                              or (r.visibility = 'org' and r.org_id in (select rbac.current_org_ids())))))
               end);
$$;

-- A proposed link, by anyone who may write research and read both ends. An agent's lands proposed; so does a
-- person's, because proposing and confirming are different acts and one call should not do both.
create or replace function claims.propose_bears_on(p_edge uuid, p_question uuid, p_p real default null,
                                                   p_reason text default null) returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'insert');
    t      bigint;
    v_id   bigint;
begin
    if not claims.edge_readable(p_edge) then
        raise no_data_found using message = 'Fact not found';
    end if;
    if not claims.question_readable(p_question) then
        raise no_data_found using message = 'Question not found';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), coalesce(nullif(p_reason, ''), 'bears on'))
    returning id into t;
    insert into claims.bears_on (edge_id, question_id, status, p, tx)
    values (p_edge, p_question, 'proposed', p_p, t) returning id into v_id;
    return v_id;
end;
$$;

-- A person's verdict on a link: confirmed or disputed, as a later row (the claims graph's own status words). Human only: whether a fact bears on a question
-- is a judgement, and an agent's judgement is what `proposed` already records.
create or replace function claims.review_bears_on(p_edge uuid, p_question uuid, p_status text,
                                                  p_reason text default null) returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'insert');
    t      bigint;
    v_id   bigint;
begin
    if rbac.current_actor() <> 'person' then
        raise insufficient_privilege using message = 'Only a person confirms or disputes a link', hint = 'human_only';
    end if;
    if p_status is null or p_status not in ('confirmed', 'disputed') then
        raise check_violation using message = 'A review is confirmed or disputed';
    end if;
    if not claims.edge_readable(p_edge) or not claims.question_readable(p_question) then
        raise no_data_found using message = 'Link not found';
    end if;
    if not exists (select 1 from claims.bears_on where edge_id = p_edge and question_id = p_question) then
        raise no_data_found using message = 'Nothing proposed links that fact to that question';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, reason)
    values (v_user, 'person', rbac.current_credential_id(), coalesce(nullif(p_reason, ''), p_status))
    returning id into t;
    insert into claims.bears_on (edge_id, question_id, status, tx)
    values (p_edge, p_question, p_status, t) returning id into v_id;
    return v_id;
end;
$$;

-- From a fact, the questions it bears on as of p_at, each with the link's current status and the question's stances.
create or replace function claims.questions_of_fact(p_edge uuid, p_at timestamptz default now())
returns table (question uuid, phrasing text, status text, p real, linked_at timestamptz,
               yes int, no int, depends int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with link as (
        select distinct on (b.question_id) b.question_id, b.status, b.p, t.at
          from claims.bears_on b join claims.tx t on t.id = b.tx
         where b.edge_id = p_edge and t.at <= p_at
         order by b.question_id, t.at desc, b.id desc),
    answer as (
        select distinct on (a.claim_id, a.question_id) a.question_id, a.stance, a.op
          from claims.answered a join claims.tx t on t.id = a.tx
         where a.question_id in (select question_id from link) and t.at <= p_at
         order by a.claim_id, a.question_id, t.at desc, a.id desc)
    select l.question_id, q.search_text, l.status, l.p, l.at,
           count(*) filter (where s.stance = 'yes' and s.op = 'assert')::int,
           count(*) filter (where s.stance = 'no' and s.op = 'assert')::int,
           count(*) filter (where s.stance = 'depends' and s.op = 'assert')::int
      from link l join claims.questions q on q.id = l.question_id
      left join answer s on s.question_id = l.question_id
     where l.status <> 'disputed'
     group by l.question_id, q.search_text, l.status, l.p, l.at
     order by (l.status = 'confirmed') desc, l.p desc nulls last;
$$;

-- From a question, the facts that bear on it as of p_at, as words, with each link's status.
create or replace function claims.facts_on_question(p_question uuid, p_at timestamptz default now())
returns table (fact uuid, content text, relation text, status text, p real, linked_at timestamptz,
               fact_valid_from timestamptz, fact_valid_to timestamptz)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with link as (
        select distinct on (b.edge_id) b.edge_id, b.status, b.p, t.at
          from claims.bears_on b join claims.tx t on t.id = b.tx
         where b.question_id = p_question and t.at <= p_at
         order by b.edge_id, t.at desc, b.id desc)
    select l.edge_id, f.content, f.relation, l.status, l.p, l.at, f.valid_from, f.valid_to
      from link l join claims.fact_texts f on f.id = l.edge_id
     where l.status <> 'disputed'
     order by (l.status = 'confirmed') desc, l.p desc nulls last;
$$;

-- The current facts a model's space has no vector for, as an `embed:` matrix's rows.
create or replace function claims.facts_to_embed(p_model text, p_limit int default 500)
returns table (chunk_id uuid, text text)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    v_tbl text;
begin
    if not exists (select 1 from aiq.embedding_models where name = p_model) then
        raise no_data_found using message = format('embedding model %s is not registered', p_model);
    end if;
    v_tbl := aiq.embedding_space_name(p_model);
    if to_regclass('aiq.' || quote_ident(v_tbl)) is null then
        return query select f.id, f.content from claims.fact_texts f where f.valid_to is null
                      order by f.id limit least(greatest(p_limit, 1), 5000);
        return;
    end if;
    return query execute format(
        'select f.id, f.content from claims.fact_texts f
          where f.valid_to is null and not exists (select 1 from aiq.%I e where e.chunk_id = f.id)
          order by f.id limit $1', v_tbl)
        using least(greatest(p_limit, 1), 5000);
end;
$$;

-- Each current fact with a vector and no link yet, with its k nearest questions in the same space: the options a
-- decider chooses among, plus "none of these", already shaped as the decider's request body. The body names the
-- decider's model from claims.deciders, so the workflow carries no model of its own to disagree with.
create table if not exists claims.deciders (
    name           text primary key,
    endpoint       text not null check (endpoint ~ '^https://'),
    model          text not null,
    credential_ref text not null
);
comment on table claims.deciders is
    'A typed-decision service the claims graph may ask to choose among options. A row is the configuration; the key is the worker''s, by name.';
insert into claims.deciders (name, endpoint, model, credential_ref)
values ('jev', 'https://api.typesafe.ai/v1/systemone', 'jev-1.13.0', 'JEV_API_KEY')
on conflict (name) do nothing;
-- Configuration every caller may read (it names services and a credential's name, never a secret), under a
-- policy that says so, because a readable table with none is refused (rbac/05).
alter table claims.deciders enable row level security;
drop policy if exists deciders_readable on claims.deciders;
create policy deciders_readable on claims.deciders for select using (true);
grant select on claims.deciders to authenticated;

create or replace function claims.facts_to_link(p_model text, p_decider text default 'jev', p_k int default 5,
                                                p_limit int default 100)
returns table (edge_id uuid, fact text, candidates jsonb, body jsonb)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    v_tbl text;
    d     claims.deciders;
begin
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', coalesce(p_decider, '(none)')),
            hint = 'insert a row into claims.deciders: its endpoint, model and the worker credential it calls with';
    end if;
    v_tbl := aiq.embedding_space_name(p_model);
    if to_regclass('aiq.' || quote_ident(v_tbl)) is null then
        raise no_data_found using message = format('embedding model %s has no space', p_model);
    end if;
    return query execute format($q$
        select f.id, f.content, c.candidates,
               jsonb_build_object(
                   'model', $4::text,
                   'state', jsonb_build_object('fact', f.content),
                   'questions', jsonb_build_object('bears_on', jsonb_build_object(
                       'type', 'choice',
                       'instructions', 'Which question does `fact` bear on, as evidence a person answering it would want?',
                       'criteria', c.options || jsonb_build_object('none_of_these',
                           'The fact bears on none of these questions.'))))
          from claims.fact_texts f
          join aiq.%1$I fe on fe.chunk_id = f.id
          cross join lateral (
              select jsonb_object_agg(k.key, jsonb_build_object('id', k.id, 'text', k.search_text)) as candidates,
                     jsonb_object_agg(k.key, k.search_text) as options
                from (select 'q' || lpad((row_number() over (order by e.embedding <=> fe.embedding))::text, 2, '0') as key,
                             q.id, q.search_text
                        from aiq.%1$I e join claims.questions q on q.id = e.chunk_id
                       order by e.embedding <=> fe.embedding limit $1) k) c
         where f.valid_to is null
           and c.candidates is not null
           and not exists (select 1 from claims.bears_on b where b.edge_id = f.id)
         order by f.id limit $2$q$, v_tbl)
        using least(greatest(coalesce(p_k, 5), 1), 20), least(greatest(coalesce(p_limit, 100), 1), 500),
              p_decider, d.model;
end;
$$;

-- The fan-in: each child's choice becomes a proposed link when it names a candidate at ASSIGN or above, the bar
-- the application's question job calibrated on 6 October (0.5: recall 0.57, precision at least 0.86 of hand links).
-- A child that chose none of these, or chose below the bar, proposes nothing.
create or replace function claims.land_bears_on(p_matrix_task uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_run   uuid := workflow.assert_task_in_current_run(p_matrix_task);
    v_owner uuid := workflow.run_owner_of(v_run);
    c       record;
    v_key   text;
    v_p     real;
    t       bigint;
    n       int := 0;
    none    int := 0;
    p_bar   constant real := 0.5;
begin
    for c in
        select ch.input->'item' as item, ch.output->'result'->'answers'->'bears_on' as answer
          from workflow.tasks ch
         where ch.matrix_parent_id = p_matrix_task and ch.status = 'succeeded'
    loop
        select k, v::real into v_key, v_p
          from jsonb_each_text(coalesce(c.answer->'probabilities', '{}'::jsonb)) x(k, v)
         where k <> 'none_of_these'
         order by v::real desc limit 1;
        if v_key is null or v_p < p_bar or not (c.item->'candidates' ? v_key) then
            none := none + 1;
            continue;
        end if;
        if t is null then
            insert into claims.tx (actor_id, actor_kind, reason)
            values (v_owner, 'agent', 'bears on, proposed by run ' || v_run::text)
            returning id into t;
        end if;
        insert into claims.bears_on (edge_id, question_id, status, p, tx)
        values ((c.item->>'edge_id')::uuid, (c.item->'candidates'->v_key->>'id')::uuid, 'proposed', v_p, t);
        n := n + 1;
    end loop;
    return jsonb_build_object('proposed', n, 'no_link', none);
end;
$$;
select workflow.register_step_function(
    'land_bears_on', 'claims.land_bears_on', array['uuid'], 120000,
    'Propose the links an earlier matrix of decider choices made, above the bar');
revoke execute on function claims.land_bears_on(uuid) from public;

-- The proposal step as a workflow: embed what the space lacks (questions and facts), offer each unlinked fact its
-- nearest questions, ask the decider, and land what it chose. Refused, by name, when the decider is not configured.
create or replace function claims.install_fact_question_workflow(p_model text, p_decider text default 'jev',
                                                                 p_name text default 'link_facts_to_questions')
returns text
language plpgsql set search_path = pg_catalog, public as $$
declare
    d claims.deciders;
begin
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', coalesce(p_decider, '(none)')),
            hint = 'insert a row into claims.deciders: its endpoint, model and the worker credential it calls with';
    end if;
    if not exists (select 1 from aiq.embedding_models where name = p_model) then
        raise no_data_found using message = format('embedding model %s is not registered', p_model);
    end if;
    perform workflow.define_yaml(format($y$
name: %1$s
steps:
  - id: embed_questions
    matrix:
      rows: "select chunk_id, text from claims.questions_to_embed('%2$s')"
      max_fanout: 500
      template:
        embed:
          text: '{{item.text}}'
          model: %2$s
  - id: land_questions
    needs: [embed_questions]
    sql: {function: land_embeddings, args: ['{{steps.embed_questions.result.task_id}}']}
  - id: embed_facts
    matrix:
      rows: "select chunk_id, text from claims.facts_to_embed('%2$s')"
      max_fanout: 500
      template:
        embed:
          text: '{{item.text}}'
          model: %2$s
  - id: land_facts
    needs: [embed_facts]
    sql: {function: land_embeddings, args: ['{{steps.embed_facts.result.task_id}}']}
  - id: link
    needs: [land_questions, land_facts]
    matrix:
      rows: "select edge_id, fact, candidates, body from claims.facts_to_link('%2$s', '%3$s')"
      max_fanout: 500
      continue_on: failed
      template:
        rest:
          url: %4$s
          method: POST
          credential_ref: %5$s
          body: '{{item.body}}'
  - id: land
    needs: [link]
    sql: {function: land_bears_on, args: ['{{steps.link.result.task_id}}']}
$y$, p_name, p_model, p_decider, d.endpoint, d.credential_ref));
    return format('%s: links facts to questions in the %s space, chosen by %s', p_name, p_model, p_decider);
end;
$$;
revoke all on function claims.install_fact_question_workflow(text, text, text) from public;

grant execute on function claims.propose_bears_on(uuid, uuid, real, text),
                          claims.review_bears_on(uuid, uuid, text, text),
                          claims.questions_of_fact(uuid, timestamptz),
                          claims.facts_on_question(uuid, timestamptz),
                          claims.facts_to_embed(text, int),
                          claims.facts_to_link(text, text, int, int)
    to authenticated;
revoke all on function claims.edge_readable(uuid) from public;
grant execute on function claims.edge_readable(uuid) to authenticated;

-- ------------------------------------------------------------
-- 10b. Origins (graph.md §3, REM-477). The study, dataset or document evidence descends from, as an entity keyed
--      by claims.study_key -- the application's REM-430 key, moved here -- so two packages that read one study
--      cite one origin however they word it. An occurrence cites an origin through a source's origin text, its
--      address, or its frame's origin. A source naming the study two ways is evidence that the two keys are one
--      study: the platform asserts that in claims.origin_links, and neither origin is rewritten.
-- ------------------------------------------------------------

-- One key per study, whatever wording names it: its DOI when the text carries one, else its web address without
-- scheme, www, query or trailing slash, else its words folded to lower case. Byte for byte the application's
-- study_key (percolate-application api/percolate_application/related.py), which is what makes an origin minted
-- here the study the application already groups by.
create or replace function claims.study_key(p_text text) returns text
language sql immutable parallel safe set search_path = pg_catalog as $$
    select case
        when coalesce(p_text, '') = '' then ''
        when p_text ~* '\m10\.\d{4,9}/[^\s"<>]+' then
            'doi:' || lower(rtrim((regexp_match(p_text, '\m(10\.\d{4,9}/[^\s"<>]+)', 'i'))[1], '.,;)'))
        when p_text ~* 'https?://[^\s"<>]+' then
            'url:' || rtrim(split_part(split_part(regexp_replace(lower((regexp_match(p_text, '(https?://[^\s"<>]+)', 'i'))[1]),
                                                                 '^https?://(www\.)?', ''), '?', 1), '#', 1), '/')
        else coalesce('title:' || nullif(array_to_string(array(select m[1] from regexp_matches(lower(p_text), '([a-z0-9]+)', 'g') m), ' '), ''), '')
    end;
$$;

create table if not exists claims.origins (
    id    uuid primary key default uuidv7(),
    key   text not null unique check (key ~ '^(doi|url|title):.'),
    label text not null,
    tx    bigint not null references claims.tx(id)
);
comment on table claims.origins is
    'A source resolved to a canonical origin, so two citations of the same thing are one origin.';

create table if not exists claims.cites (
    id          bigint generated always as identity primary key,
    revision_id uuid not null,
    claim_key   text not null,
    source_key  text not null,
    via         text not null check (via in ('origin', 'url', 'frame')),
    origin_id   uuid not null references claims.origins(id),
    tx          bigint not null references claims.tx(id),
    unique (revision_id, claim_key, source_key, via),
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key) on delete cascade
);
comment on table claims.cites is
    'That a revision''s claim cites a source, resolved to its origin, which is what makes attribution derivable without a column for it.';
create index if not exists cites_origin on claims.cites (origin_id);

-- Two origins that name one study. `a` and `b` are ordered (a < b), so one pair is one statement.
create table if not exists claims.origin_links (
    id          bigint generated always as identity primary key,
    a           uuid not null references claims.origins(id),
    b           uuid not null references claims.origins(id),
    status      text not null check (status in ('proposed', 'confirmed', 'disputed')),
    op          text not null default 'assert' check (op in ('assert', 'retract')),
    evidence    uuid not null references research.revisions(id) on delete cascade,
    source_key  text not null,
    tx          bigint not null references claims.tx(id),
    check (a < b)
);
comment on table claims.origin_links is
    'Two origins the platform derived as one study, from a claim that cites the same source by both key and URL. Written confirmed by claims.project_cites and by nothing else, so the proposed and disputed the status column admits are unreachable.';
create index if not exists origin_links_a on claims.origin_links (a);
create index if not exists origin_links_b on claims.origin_links (b);

-- The origin a key names, minted under p_tx with p_label when none exists yet.
create or replace function claims.origin_for(p_key text, p_label text, p_tx bigint) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o uuid;
begin
    select id into o from claims.origins where key = p_key;
    if found then
        return o;
    end if;
    insert into claims.origins (key, label, tx) values (p_key, coalesce(nullif(btrim(p_label), ''), p_key), p_tx)
    on conflict (key) do nothing returning id into o;
    return coalesce(o, (select id from claims.origins where key = p_key));
end;
$$;

-- A revision's citations as cites, and the links a two-key source asserts. Only what is not there yet is written.
create or replace function claims.project_cites(p_revision uuid) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    t  bigint;
    r  record;
    k1 text;
    k2 text;
    o1 uuid;
    o2 uuid;
    n  int := 0;
begin
    for r in select c.claim_key, s.source_key, s.origin, s.url
               from research.citations c
               join research.sources s on s.revision_id = c.revision_id and s.source_key = c.source_key
              where c.revision_id = p_revision
             union all
             select f.claim_key, '', f.frame->>'origin', ''
               from claims.frames f
              where f.revision_id = p_revision and coalesce(f.frame->>'origin', '') <> ''
             order by 1, 2 loop
        continue when exists (select 1 from claims.cites x where x.revision_id = p_revision
                                  and x.claim_key = r.claim_key and x.source_key = r.source_key);
        k1 := claims.study_key(btrim(coalesce(r.origin, '')));
        k2 := claims.study_key(btrim(coalesce(r.url, '')));
        continue when k1 = '' and k2 = '';
        if t is null then
            insert into claims.tx (actor_kind, revision_id, reason)
            values ('platform', p_revision, 'citations of ' || (select label from research.revisions where id = p_revision))
            returning id into t;
        end if;
        o1 := null;
        o2 := null;
        if k1 <> '' then
            o1 := claims.origin_for(k1, r.origin, t);
            insert into claims.cites (revision_id, claim_key, source_key, via, origin_id, tx)
            values (p_revision, r.claim_key, r.source_key, case when r.source_key = '' then 'frame' else 'origin' end, o1, t)
            on conflict do nothing;
            n := n + 1;
        end if;
        if k2 <> '' then
            o2 := claims.origin_for(k2, coalesce(nullif(btrim(r.origin), ''), r.url), t);
            insert into claims.cites (revision_id, claim_key, source_key, via, origin_id, tx)
            values (p_revision, r.claim_key, r.source_key, 'url', o2, t)
            on conflict do nothing;
            n := n + 1;
        end if;
        if o1 is not null and o2 is not null and o1 <> o2
           and not exists (select 1 from claims.origin_links l
                            where l.a = least(o1, o2) and l.b = greatest(o1, o2) and l.evidence = p_revision) then
            insert into claims.origin_links (a, b, status, evidence, source_key, tx)
            values (least(o1, o2), greatest(o1, o2), 'confirmed', p_revision, r.source_key, t);
        end if;
    end loop;
    return n;
end;
$$;

do $$
declare t text;
begin
    foreach t in array array['claims.origins', 'claims.cites', 'claims.origin_links'] loop
        execute format('create or replace trigger trg_refuse_rewrite before update or delete on %s '
                       'for each row execute function research.refuse_rewrite()', t);
        execute format('create or replace trigger trg_refuse_truncate before truncate on %s '
                       'for each statement execute function research.refuse_rewrite()', t);
    end loop;
end $$;

-- Access: a citation and a link are readable with their revision; an origin when a readable citation names it.
alter table claims.cites enable row level security;
drop policy if exists cites_readable on claims.cites;
create policy cites_readable on claims.cites for select using (research.revision_readable(revision_id));
alter table claims.origin_links enable row level security;
drop policy if exists origin_links_readable on claims.origin_links;
create policy origin_links_readable on claims.origin_links for select using (research.revision_readable(evidence));
alter table claims.origins enable row level security;
-- The policy asks a function, not an inline exists. Inline, the planner may hash the subquery: on statistics that
-- say cites is tiny it computed every readable citation, research.revision_readable on each row, to answer for one
-- origin, so claims.study_of grew with every unrelated package after an ANALYZE (REM-1003). A function with SET is
-- never inlined, so each origin asks only about its own citations, through cites_origin.
create or replace function claims.origin_readable(p_origin uuid) returns boolean
language sql stable security invoker cost 1000 set search_path = pg_catalog, public as $$
    select exists (select 1 from claims.cites c where c.origin_id = p_origin);
$$;
drop policy if exists origins_readable on claims.origins;
create policy origins_readable on claims.origins for select using (claims.origin_readable(id));
grant execute on function claims.origin_readable(uuid) to authenticated;
grant select on claims.origins, claims.cites, claims.origin_links to authenticated;
revoke all on function claims.origin_for(text, text, bigint), claims.project_cites(uuid) from public;

-- ------------------------------------------------------------
-- 10d. Event resolutions (graph.md §12, REM-480). Whether a claim turned out right, settled by something that
--      happened and can be cited. tradecraft.resolutions' fields, adapted: the value, the event, what settled it,
--      when it was checked and how, and who ran it (the transaction). Any reader of the claim may propose one; only
--      a person holding research:resolve confirms or disputes it. Nothing here computes a reliability score:
--      graph.md §18 holds that until 200 confirmed resolutions across 20 origins exist.
-- ------------------------------------------------------------
insert into rbac.permission_kinds (resource, action, checked_by, human_only, every_person) values
    ('research', 'resolve', 'function claims.review_resolution', true, false)
on conflict (resource, action) do update
    set checked_by = excluded.checked_by, human_only = excluded.human_only, every_person = excluded.every_person;

create table if not exists claims.resolutions (
    id           bigint generated always as identity primary key,
    restates     bigint references claims.resolutions(id),
    claim_id     uuid not null references claims.claims(id),
    value        text not null check (value in ('held', 'failed', 'partly', 'unresolvable')),
    event        text not null check (length(btrim(event)) > 0),
    evidence_ref text not null check (length(btrim(evidence_ref)) > 0),
    checked_on   date not null,
    method       text not null check (length(btrim(method)) > 0),
    status       text not null check (status in ('proposed', 'confirmed', 'disputed')),
    evidence     uuid not null references research.revisions(id) on delete cascade,
    tx           bigint not null references claims.tx(id),
    check (restates is null or restates < id)
);
comment on table claims.resolutions is
    'Whether a claim held, failed, partly held or could not be resolved, settled by a citable event, with the date it was checked, the method and its review status.';
create index if not exists resolutions_claim on claims.resolutions (claim_id, id desc);
create index if not exists resolutions_restates on claims.resolutions (restates) where restates is not null;

-- A reader proposes: the evidence revision is one they may read that expresses the claim, so the resolution is
-- readable to exactly the people who can read what it resolves.
create or replace function claims.propose_resolution(p_claim uuid, p_evidence uuid, p_value text, p_event text,
                                                     p_evidence_ref text, p_checked_on date, p_method text)
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'select');
    t      bigint;
    v_id   bigint;
begin
    if not research.revision_readable(p_evidence)
       or not exists (select 1 from claims.expresses e where e.revision_id = p_evidence and e.claim_id = p_claim) then
        raise no_data_found using message = 'Claim not found in that revision';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), p_evidence, 'resolution proposed')
    returning id into t;
    insert into claims.resolutions (claim_id, value, event, evidence_ref, checked_on, method, status, evidence, tx)
    values (p_claim, p_value, p_event, p_evidence_ref, p_checked_on, p_method, 'proposed', p_evidence, t)
    returning id into v_id;
    return v_id;
end;
$$;

-- A resolver confirms or disputes a proposal: a later row restating it with the new status. The proposal stays.
create or replace function claims.review_resolution(p_resolution bigint, p_status text, p_reason text default null)
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'resolve');
    r      claims.resolutions;
    t      bigint;
    v_id   bigint;
begin
    if p_status not in ('confirmed', 'disputed') then
        raise check_violation using message = 'A review confirms or disputes', detail = p_status;
    end if;
    select * into r from claims.resolutions where id = p_resolution and restates is null;
    if not found or not research.revision_readable(r.evidence) then
        raise no_data_found using message = 'Resolution not found';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), r.evidence,
            coalesce(nullif(btrim(p_reason), ''), 'resolution ' || p_status))
    returning id into t;
    insert into claims.resolutions (restates, claim_id, value, event, evidence_ref, checked_on, method, status, evidence, tx)
    values (r.id, r.claim_id, r.value, r.event, r.evidence_ref, r.checked_on, r.method, p_status, r.evidence, t)
    returning id into v_id;
    return v_id;
end;
$$;

do $$
begin
    execute 'create or replace trigger trg_refuse_rewrite before update or delete on claims.resolutions '
            'for each row execute function research.refuse_rewrite()';
    execute 'create or replace trigger trg_refuse_truncate before truncate on claims.resolutions '
            'for each statement execute function research.refuse_rewrite()';
end $$;
alter table claims.resolutions enable row level security;
drop policy if exists resolutions_readable on claims.resolutions;
create policy resolutions_readable on claims.resolutions for select using (research.revision_readable(evidence));
grant select on claims.resolutions to authenticated;
grant execute on function claims.propose_resolution(uuid, uuid, text, text, text, date, text),
                          claims.review_resolution(bigint, text, text) to authenticated;

-- ------------------------------------------------------------
-- 10e. Consensus (graph.md §12, REM-496). Independent work converging on a position, recorded apart from event
--      resolutions so it never counts as a checked outcome. The independent studies behind it are counted here from
--      origin entities, never taken from the proposer and never from package counts: the studies cited by readable
--      occurrences of the claim, of its confirmed identity set, and of claims confirmed to agree with it, each study
--      once. A person holding research:resolve confirms, disputes or reopens it; a confirmed contradicts from a
--      study it did not count, asserted after it was confirmed, is reported as dissent. Nothing computes
--      reliability from it.
-- ------------------------------------------------------------
create table if not exists claims.consensus (
    id           bigint generated always as identity primary key,
    restates     bigint references claims.consensus(id),
    claim_id     uuid not null references claims.claims(id),
    value        text not null check (value in ('holds', 'rejected')),
    studies      uuid[] not null,
    since        date not null,
    status       text not null check (status in ('proposed', 'confirmed', 'disputed', 'reopened')),
    evidence     uuid not null references research.revisions(id) on delete cascade,
    tx           bigint not null references claims.tx(id),
    check (restates is null or restates < id),
    check (restates is not null or status = 'proposed')
);
comment on table claims.consensus is
    'What a body of studies is asserted to hold on a claim, with what it rests on and its review status.';
create index if not exists consensus_claim on claims.consensus (claim_id, id desc);
create index if not exists consensus_restates on claims.consensus (restates) where restates is not null;

-- The independent studies behind a claim's position, as the caller may read them.
create or replace function claims.consensus_studies(p_claim uuid, p_at timestamptz default now()) returns uuid[]
language sql stable security invoker set search_path = pg_catalog, public as $$
    with members as (
        select i as claim from claims.identity_set(p_claim, p_at) i
        union
        select case when r.src = p_claim then r.dst else r.src end
          from claims.relations_at(p_claim, p_at) r where r.predicate = 'agrees' and r.status = 'confirmed')
    select coalesce(array_agg(distinct e.study order by e.study), '{}')
      from members m cross join lateral claims.evidence(m.claim, p_at) e;
$$;

-- The proposal runs as the caller, so the studies are counted under their row security; record_consensus then
-- writes it, and refuses a study that is not behind the claim at all, so a caller can undercount but never invent one.
create or replace function claims.propose_consensus(p_claim uuid, p_evidence uuid, p_value text, p_since date)
returns bigint
language sql volatile security invoker set search_path = pg_catalog, public as $$
    select claims.record_consensus(p_claim, p_evidence, p_value, p_since, claims.consensus_studies(p_claim));
$$;

create or replace function claims.record_consensus(p_claim uuid, p_evidence uuid, p_value text, p_since date,
                                                   p_studies uuid[])
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'select');
    t      bigint;
    v_id   bigint;
begin
    if not research.revision_readable(p_evidence)
       or not exists (select 1 from claims.expresses e where e.revision_id = p_evidence and e.claim_id = p_claim) then
        raise no_data_found using message = 'Claim not found in that revision';
    end if;
    if not (coalesce(p_studies, '{}') <@ claims.consensus_studies(p_claim)) then
        raise check_violation using message = 'A study named is not behind this claim';
    end if;
    if cardinality(coalesce(p_studies, '{}')) < 2 then
        raise check_violation using message = 'A consensus needs at least two independent studies',
            detail = cardinality(coalesce(p_studies, '{}'))::text;
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), p_evidence, 'consensus proposed')
    returning id into t;
    insert into claims.consensus (claim_id, value, studies, since, status, evidence, tx)
    values (p_claim, p_value, p_studies, p_since, 'proposed', p_evidence, t)
    returning id into v_id;
    return v_id;
end;
$$;

create or replace function claims.review_consensus(p_consensus bigint, p_status text, p_reason text default null)
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'resolve');
    c      claims.consensus;
    t      bigint;
    v_id   bigint;
begin
    if p_status not in ('confirmed', 'disputed', 'reopened') then
        raise check_violation using message = 'A review confirms, disputes or reopens', detail = p_status;
    end if;
    select * into c from claims.consensus where id = p_consensus and restates is null;
    if not found or not research.revision_readable(c.evidence) then
        raise no_data_found using message = 'Consensus not found';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, revision_id, reason)
    values (v_user, rbac.current_actor(), rbac.current_credential_id(), c.evidence,
            coalesce(nullif(btrim(p_reason), ''), 'consensus ' || p_status))
    returning id into t;
    insert into claims.consensus (restates, claim_id, value, studies, since, status, evidence, tx)
    values (c.id, c.claim_id, c.value, c.studies, c.since, p_status, c.evidence, t)
    returning id into v_id;
    return v_id;
end;
$$;

do $$
begin
    execute 'create or replace trigger trg_refuse_rewrite before update or delete on claims.consensus '
            'for each row execute function research.refuse_rewrite()';
    execute 'create or replace trigger trg_refuse_truncate before truncate on claims.consensus '
            'for each statement execute function research.refuse_rewrite()';
end $$;
alter table claims.consensus enable row level security;
drop policy if exists consensus_readable on claims.consensus;
create policy consensus_readable on claims.consensus for select using (research.revision_readable(evidence));
grant select on claims.consensus to authenticated;
grant execute on function claims.consensus_studies(uuid, timestamptz),
                          claims.propose_consensus(uuid, uuid, text, date),
                          claims.record_consensus(uuid, uuid, text, date, uuid[]),
                          claims.review_consensus(bigint, text, text) to authenticated;

-- A claim's consensus as it stands, and any dissent since it was confirmed: a confirmed contradicts touching the
-- claim or its identity set, asserted after the confirmation, from a claim whose studies the consensus did not
-- count. Dissent is reported, not acted on; a resolver reopens.
create or replace function claims.consensus_of(p_claim uuid, p_at timestamptz default now())
returns table (consensus bigint, value text, studies int, since date, status text, confirmed_at timestamptz,
               dissent bigint[])
language sql stable security invoker set search_path = pg_catalog, public as $$
    with c as (
        select p.id, p.value, p.studies, p.since,
               coalesce(l.status, p.status) as status,
               (select min(rt.at) from claims.consensus r join claims.tx rt on rt.id = r.tx
                 where r.restates = p.id and r.status = 'confirmed' and rt.at <= p_at) as confirmed_at,
               (select min(r.tx) from claims.consensus r join claims.tx rt on rt.id = r.tx
                 where r.restates = p.id and r.status = 'confirmed' and rt.at <= p_at) as confirmed_tx
          from claims.consensus p join claims.tx pt on pt.id = p.tx
          left join lateral (select r.status from claims.consensus r join claims.tx rt on rt.id = r.tx
                              where r.restates = p.id and rt.at <= p_at order by r.id desc limit 1) l on true
         where p.claim_id = p_claim and p.restates is null and pt.at <= p_at)
    select c.id, c.value, cardinality(c.studies), c.since, c.status, c.confirmed_at,
           (select array_agg(r.id order by r.id)
              from claims.identity_set(p_claim, p_at) m
              cross join lateral claims.relations_at(m, p_at) r
             where c.confirmed_tx is not null and r.predicate = 'contradicts' and r.status = 'confirmed'
               -- after the confirmation: transactions are numbered in the order they were made
               and (select x.tx from claims.relations x where x.id = r.id) > c.confirmed_tx
               and exists (select 1 from claims.evidence(case when r.src = m then r.dst else r.src end, p_at) e
                            where not e.study = any (c.studies)))
      from c;
$$;
grant execute on function claims.consensus_of(uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 10c. Erasure (graph.md §13, REM-481). research.erase_work deletes a work, and the cascade takes its occurrences
--      and every assertion evidenced by one of its revisions: expresses, frames, cites, answered, relations and
--      origin links. An assertion also made from another work is its own row there and survives. What the cascade
--      cannot reach is swept here: claims no occurrence expresses any more, origins and questions nothing cites or
--      answers any more, and the transactions only those rows named. An origin or question another work still cites
--      or answers stays, because it is that work's evidence too. The tombstone is counts, with no text.
-- ------------------------------------------------------------
create table if not exists claims.erasures (
    erasure_id  bigint primary key references research.erasures(id),
    counts      jsonb not null check (jsonb_typeof(counts) = 'object'),
    at          timestamptz not null default now()
);
comment on table claims.erasures is
    'The tombstone for what an erasure removed from the graph: counts, no text.';

-- What of the claims graph rests on these revisions, counted before they go.
create or replace function claims.graph_counts(p_revisions uuid[]) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'occurrences', (select count(*) from research.claims where revision_id = any (p_revisions)),
        'expresses',   (select count(*) from claims.expresses where revision_id = any (p_revisions)),
        'frames',      (select count(*) from claims.frames where revision_id = any (p_revisions)),
        'cites',       (select count(*) from claims.cites where revision_id = any (p_revisions)),
        'answered',    (select count(*) from claims.answered where evidence = any (p_revisions)),
        'relations',   (select count(*) from claims.relations where evidence = any (p_revisions) or evidence2 = any (p_revisions)),
        'origin_links',(select count(*) from claims.origin_links where evidence = any (p_revisions)),
        'resolutions', (select count(*) from claims.resolutions where evidence = any (p_revisions)),
        'consensus',   (select count(*) from claims.consensus where evidence = any (p_revisions)));
$$;

-- After the cascade: remove what only the erased revisions minted and nothing names any more.
create or replace function claims.sweep_erased(p_revisions uuid[]) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    task_ids uuid[];
    txs  bigint[];
    n_c  int;
    n_o  int;
    n_q  int := 0;
    n_q1 int;
    n_t  int;
begin
    if not exists (select 1 from research.erasures where xact = pg_current_xact_id()) then
        raise insufficient_privilege using message = 'Only research.erase_work sweeps the claims graph';
    end if;
    select array_agg(id) into txs from claims.tx where revision_id = any (p_revisions);
    delete from claims.claims c where c.tx = any (txs)
       and not exists (select 1 from claims.expresses e where e.claim_id = c.id)
       and not exists (select 1 from claims.relations r where r.src = c.id or r.dst = c.id)
       and not exists (select 1 from claims.answered a where a.claim_id = c.id)
       and not exists (select 1 from claims.resolutions r where r.claim_id = c.id)
       and not exists (select 1 from claims.consensus r where r.claim_id = c.id);
    get diagnostics n_c = row_count;
    delete from claims.origins o
     where not exists (select 1 from claims.cites c where c.origin_id = o.id)
       and not exists (select 1 from claims.origin_links l where l.a = o.id or l.b = o.id)
       and o.tx = any (txs);
    get diagnostics n_o = row_count;
    -- A refined question goes before the broader one it names, so repeat until nothing more goes.
    loop
        delete from claims.questions q
         where q.tx = any (txs)
           and not exists (select 1 from claims.answered a where a.question_id = q.id)
           and not exists (select 1 from claims.questions r where r.refines = q.id);
        get diagnostics n_q1 = row_count;
        exit when n_q1 = 0;
        n_q := n_q + n_q1;
    end loop;
    select array_agg(distinct task_id) into task_ids from claims.execution_receipts where tx = any(txs);
    delete from claims.tx t where t.id = any (txs)
       and not exists (select 1 from claims.claims x where x.tx = t.id)
       and not exists (select 1 from claims.expresses x where x.tx = t.id)
       and not exists (select 1 from claims.relations x where x.tx = t.id)
       and not exists (select 1 from claims.answered x where x.tx = t.id)
       and not exists (select 1 from claims.cites x where x.tx = t.id)
       and not exists (select 1 from claims.origin_links x where x.tx = t.id)
       and not exists (select 1 from claims.origins x where x.tx = t.id)
       and not exists (select 1 from claims.questions x where x.tx = t.id)
       and not exists (select 1 from claims.resolutions x where x.tx = t.id)
       and not exists (select 1 from claims.consensus x where x.tx = t.id);
    get diagnostics n_t = row_count;
    delete from claims.execution_results x where x.task_id = any(task_ids)
       and not exists(select 1 from claims.execution_receipts r where r.task_id=x.task_id);
    return jsonb_build_object('claims', n_c, 'origins', n_o, 'questions', n_q, 'transactions', n_t);
end;
$$;
revoke all on function claims.graph_counts(uuid[]), claims.sweep_erased(uuid[]) from public;
alter table claims.erasures enable row level security;

-- ------------------------------------------------------------
-- 11. Who asserted, and when, behind a row the caller may read (graph.md §9). An actor sees their own transactions;
--     anybody else sees a transaction's id, time and actor kind when a link or relation they may read names it, and
--     never its actor, credential or reason.
-- ------------------------------------------------------------
-- A function for the same reason as claims.origin_readable (REM-1003): the indexes below stop the planner hashing
-- these tables only while it believes they are large. After an ANALYZE of a small graph it hashed them again.
create or replace function claims.tx_named_by_readable(p_tx bigint) returns boolean
language sql stable security invoker cost 1000 set search_path = pg_catalog, public as $$
    select exists (select 1 from claims.expresses e where e.tx = p_tx)
        or exists (select 1 from claims.relations r where r.tx = p_tx)
        or exists (select 1 from claims.answered a where a.tx = p_tx)
        or exists (select 1 from claims.cites c where c.tx = p_tx)
        or exists (select 1 from claims.origin_links l where l.tx = p_tx)
        or exists (select 1 from claims.resolutions r where r.tx = p_tx)
        or exists (select 1 from claims.consensus c where c.tx = p_tx);
$$;
drop policy if exists tx_readable on claims.tx;
create policy tx_readable on claims.tx for select using (
    actor_id = rbac.current_user_id() or claims.tx_named_by_readable(id));
grant execute on function claims.tx_named_by_readable(bigint) to authenticated;
grant select (id, at, actor_kind) on claims.tx to authenticated;
-- Each exists above finds the rows naming one transaction. Without these the planner hashed every table whole, so
-- one tx read ran research.revision_readable on every row in the graph: a claim page took 3.3 s on production with
-- 700 occurrences in all, growing with every unrelated package (REM-626).
create index if not exists expresses_tx on claims.expresses (tx);
create index if not exists relations_tx on claims.relations (tx);
create index if not exists answered_tx on claims.answered (tx);
create index if not exists cites_tx on claims.cites (tx);
create index if not exists origin_links_tx on claims.origin_links (tx);
create index if not exists resolutions_tx on claims.resolutions (tx);
create index if not exists consensus_tx on claims.consensus (tx);

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

-- The questions a claim answered at p_at: the latest answered row per (evidence, question), retractions dropped.
create or replace function claims.answers_of(p_claim uuid, p_at timestamptz default now())
returns table (question_id uuid, stance text, status text, evidence uuid, claim_key text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select x.question_id, x.stance, x.status, x.evidence, x.claim_key
      from (select distinct on (a.evidence, a.question_id) a.question_id, a.stance, a.status, a.op, a.evidence, a.claim_key
              from claims.answered a join claims.tx t on t.id = a.tx
             where a.claim_id = p_claim and t.at <= p_at
             order by a.evidence, a.question_id, a.id desc) x
     where x.op = 'assert';
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

-- Claim text is a metric space, and the extension says so rather than leaving each deployment to say it: a claim
-- has a space by construction, aiq's orphan-vector triggers reach it when research.erase_work deletes a revision,
-- and aiq.police_embedding_spaces writes research.claims' own read policy into the space, so a claim's vector is
-- readable to exactly the callers who may read the claim. No lexical source: 3,299 sentences across 483 arXiv
-- papers repeat no cross-paper phrase and a lexical blocker proposes 97.7% of pairs, so a tsvector column and a GIN
-- index on every claim would buy nothing (graph.md §5 *Did you mean*).
--
-- WHAT THIS ROW WIDENS, and what holds it shut. police_embedding_spaces ORs one branch per registered source into
-- every space's read policy, so from here `exists (select 1 from research.claims s where s.id = <space>.chunk_id)`
-- is evaluated on emb_ tables holding no claims. A caller who could put a chosen id into research.claims could
-- therefore read the vector of somebody's chunk or skill out of the content space. Two things stop it, and the
-- order matters because only the first is a property of the TABLE:
--
--   1. No web-facing role can write it. `authenticated` holds SELECT and nothing else on research.claims; there is
--      no insert grant to authenticated, api_viewer or web_anon; and exactly one function in the extension inserts
--      into it -- research.project, security definer, reachable by none of the three.
--   2. On that one path the id is percolate.uuidv5(revision, 'claim:' || claim_key), and content.resource_chunks
--      and agentic.skills default theirs to uuidv7(). A version 5 uuid can never equal a version 7 one.
--
-- The second is the weaker leg and reads stronger: research.claims.id has NO DEFAULT, so it is the call site that
-- makes ids version 5, not the column. An import path that carried an external id into research.claims, or a
-- default added to the column, would leave only leg 1 -- so a change to either is a change to this policy.
--
-- WHAT THIS ROW COSTS, and it is not what the ordering suggests. Every registered source is a branch of every
-- space's policy, and before REM-659 the planner hashed each branch -- reading the whole source table once per
-- query, with that table's own RLS per row. Adding research.claims took a top-5 query on an eleven-vector chunk
-- space from 0.4 ms to 443 ms, on a space holding no claims. `order by src.name` does not save the content path:
-- a hashed subplan is built whether or not an earlier branch would have matched. The fix is in
-- aiq.police_embedding_spaces -- `offset 0` on each branch keeps it correlated, so a candidate vector costs one
-- index probe -- and it was found by exercising this registration at 3,909 claims rather than at fixture size.
do $$
begin
    if to_regclass('aiq.semantic_sources') is not null then
        insert into aiq.semantic_sources (name, source_table, content_col)
        values ('claims', 'research.claims', 'text')
        on conflict (name) do update
           set source_table = excluded.source_table,
               content_col  = excluded.content_col,
               shipped = excluded.shipped or semantic_sources.shipped;
    end if;
end $$;

-- ------------------------------------------------------------
-- 12a. Did you mean (graph.md §5 *Did you mean*, REM-659). The claims nearest an occurrence that the caller may
--      read, so an agent or a person can be asked whether one of them is the same claim. Until this existed,
--      sameness across works waited for somebody to already suspect a pair: `claims.rewordings` finds its one
--      candidate by claim_key inside a work, and nothing looked across works at all.
--
-- DISTANCE RANKS AND NEVER DECIDES, which is aiq.node_resolutions' rule one schema along -- embedding proximity is
-- legitimate for proposing a merge and forbidden as a scoring input. This returns a distance and no score, writes
-- nothing, and asserts nothing; the answer is claims.assert_relation, where an agent's lands proposed and identity
-- does not move until a person confirms. Measured over 483 arXiv papers and 3,909 claims: inside the retrieved
-- band, distance cannot tell a relation from an unrelated pair (AUC 0.58 on 53 labelled pairs, interval spanning
-- chance). It is good for "here are three to look at" and nothing else.
--
-- FOUR EXCLUSIONS, and each is a join or a predicate below.
--   * The occurrence itself.
--   * Its own work. That pair is the rewording question, which claims.rewordings already asks by claim_key.
--   * Anything in a revision the caller may not read. research.claims carries that policy and this function is
--     security invoker, so the horizon costs no predicate here -- identity is per visibility horizon (REM-434).
--   * Any pair that already carries a relation, in either direction and at any status. Without it an answered
--     challenge is asked again on every insert. A relation the caller cannot READ does not exclude, which is the
--     same rule stated once more: a pair somebody else answered privately is still an open question for you.
--
-- A claim in the space that no claims.expresses row links to is dropped rather than returned with a null claim_id:
-- the lateral is a cross join. An unprojected claim is therefore invisible here, which is the intent -- a claim
-- with no identity cannot be said to be the same as anything -- and it filters before the LIMIT, so it costs the
-- caller no rows.
--
-- WHY THIS READS THE SPACE RATHER THAN CALLING aiq.semantic_in. semantic_in takes a source, a vector and a limit
-- and pushes no predicate down, so the exclusions would have to be applied to its result -- after its LIMIT. A
-- caller asking for five would get however many of five survived, with nothing saying so, and an agent reading a
-- big public corpus would often get none. The predicates and the ORDER BY belong in one query. The identifier is derived from
-- aiq.embedding_models and never from an argument.
--
-- THE FLOOR HAS NO DEFAULT. A distance cut is meaningful only against the model that produced the vectors, and a
-- default would be one model's number on another's scale. graph.md carries what a floor costs.
-- ------------------------------------------------------------
create or replace function claims.candidates(p_revision uuid, p_claim_key text, p_max_distance float8,
                                             p_limit int default 5, p_embedding vector default null,
                                             p_model text default null)
returns table (claim_id uuid, claim_key text, revision_id uuid, text text, distance float8)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    m     aiq.embedding_models;
    v_tbl text;
    v_id  uuid;
    v_cid uuid;
    v_work uuid;
    v_vec vector;
begin
    -- A null floor is the defect this whole function is written against, arriving through the front door: the
    -- filter is `distance <= p_max_distance`, which is NULL for every row, so the caller receives nothing and
    -- nothing says why. Refused rather than defaulted, because a distance cut is meaningful only against the model
    -- that produced the vectors and there is no number to default it to. (REM-659, found in review by a reader of
    -- the body rather than by the gate, which is now this function's own lesson applied to itself.)
    if p_max_distance is null then
        raise check_violation using
            message = 'candidates needs a distance floor: a null one matches nothing and says nothing',
            hint = 'specs/claims/graph.md §5 carries what a floor costs; the number is meaningful only '
                   'against the model that produced the vectors';
    end if;
    select c.id, v.work_id into v_id, v_work
      from research.claims c join research.revisions v on v.id = c.revision_id
     where c.revision_id = p_revision and c.claim_key = p_claim_key;
    if not found then
        raise no_data_found using message = 'Claim not found in that revision';
    end if;
    select x.claim_id into v_cid from claims.expresses x
     where x.revision_id = p_revision and x.claim_key = p_claim_key and x.part = 1 and x.op = 'assert'
     order by x.id desc limit 1;

    if p_model is null then
        select * into m from aiq.embedding_models where is_default;
        if not found then
            raise no_data_found using message = 'no default embedding model -- set one, or name a model explicitly';
        end if;
    else
        select * into m from aiq.embedding_models where name = p_model;
        if not found then
            raise no_data_found using message = format('embedding model %s is not registered', p_model);
        end if;
    end if;
    v_tbl := aiq.embedding_space_name(m.name);
    if to_regclass('aiq.' || quote_ident(v_tbl)) is null then
        raise no_data_found using
            message = format('embedding model %s is registered but its space does not exist', m.name),
            hint = format('create it with aiq.register_embedding_space(%L)', m.name);
    end if;

    -- The vector arrives alongside, as it does for aiq.query: embedding is an external model call and this schema
    -- makes none. An occurrence already in a space needs no argument; one being written passes its own.
    v_vec := p_embedding;
    if v_vec is null then
        execute format('select embedding from aiq.%I where chunk_id = $1', v_tbl) into v_vec using v_id;
    end if;
    if v_vec is null then
        raise no_data_found using
            message = format('%s has no vector in %s and none was passed', p_claim_key, m.name),
            hint = format('embed its text with %s and pass it as p_embedding', m.name);
    end if;
    if vector_dims(v_vec) <> m.dim then
        raise check_violation using
            message = format('the vector has %s dimensions and model %s expects %s -- embedded with the wrong model?',
                             vector_dims(v_vec), m.name, m.dim);
    end if;

    -- THE OPPOSITE CHOICE FROM aiq.semantic_in, AND THE REASON IS THE QUESTION: this leaves hnsw.iterative_scan
    -- alone.
    -- semantic_in forces strict_order because an empty answer to a search looks like "there is nothing", and for
    -- a tenant holding a small share of a large corpus that is wrong. Here an empty answer is the RIGHT answer
    -- 99% of the time -- 41 of 3,909 claims had any neighbour at all -- and forcing the scan to resume means
    -- walking the whole index to prove a negative, on every save.
    --
    -- Measured over 483 arXiv papers and 3,909 claims, one call for a claim with no neighbour:
    --
    --     forcing strict_order      232 ms      the whole corpus, 3,909 calls: 29 minutes
    --     leaving it alone           13 ms      the whole corpus:               55 seconds
    --
    -- And it costs no recall at this scale, which was checked rather than assumed: at p_limit 10 the bounded scan
    -- returns every pair an exhaustive one returns, and one more. At p_limit 3 the two differ by one pair in each
    -- direction, and both are top-k truncation inside a dense cluster rather than a scan that stopped early.
    --
    -- What a caller gives up is the guarantee semantic_in buys: a neighbourhood crowded with claims this caller
    -- may not read can hide a readable one past the scan's bound. They raise hnsw.iterative_scan themselves
    -- through aiq.set_scan_order when they want that, and the floor already puts recall below one by design
    -- (graph.md §5 *Did you mean*).

    return query execute format($q$
        select e2.claim_id, c.claim_key, c.revision_id, c.text, (s.embedding <=> $1)::float8
          from aiq.%I s
          join research.claims c on c.id = s.chunk_id
          join research.revisions v on v.id = c.revision_id
          cross join lateral (select x.claim_id from claims.expresses x
                               where x.revision_id = c.revision_id and x.claim_key = c.claim_key
                                 and x.part = 1 and x.op = 'assert'
                               order by x.id desc limit 1) e2
         where c.id <> $2 and v.work_id <> $3 and (s.embedding <=> $1) <= $4
           and ($5::uuid is null or not exists (
                   select 1 from claims.relations r
                    where (r.src = $5 and r.dst = e2.claim_id) or (r.src = e2.claim_id and r.dst = $5)))
         order by s.embedding <=> $1
         limit $6$q$, v_tbl)
      using v_vec, v_id, v_work, p_max_distance, v_cid, greatest(coalesce(p_limit, 5), 1);
end;
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
        'questions', (select jsonb_agg(distinct a.question_id) from claims.answers_of(p_id, p_at) a))
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

-- Every readable claim answering a question or a question that refines it, grouped by stance (graph.md §10). A claim
-- answers once however many revisions say so: its stance is the latest readable assertion's.
create or replace function claims.answers(p_question uuid, p_at timestamptz default now())
returns table (stance text, claims jsonb)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with recursive qs(id) as (
        select p_question
        union
        select q.id from claims.questions q join qs on q.refines = qs.id),
    latest as (
        select distinct on (a.claim_id) a.claim_id, a.question_id, a.stance, a.status, a.op, a.evidence, a.claim_key, t.at
          from claims.answered a join claims.tx t on t.id = a.tx
         where a.question_id in (select id from qs) and t.at <= p_at
         order by a.claim_id, t.at desc, a.id desc)
    select l.stance, jsonb_agg(jsonb_build_object('claim', l.claim_id, 'question', l.question_id,
                                                  'revision_id', l.evidence, 'claim_key', l.claim_key,
                                                  'status', l.status) order by l.at, l.claim_id)
      from latest l where l.op = 'assert'
     group by l.stance order by l.stance;
$$;

-- REM-584: reduce an occurrence by its key BEFORE asking which claim it expresses.
-- A reassignment is a later row with a different claim_id; filtering that id first resurrects the old link.
create or replace function claims.occurrences_at(p_claim uuid, p_at timestamptz, p_revisions uuid[])
returns setof claims.expresses
language sql stable security invoker set search_path = pg_catalog, public as $$
    select x.* from (
        select distinct on (e.revision_id, e.claim_key, e.part) e.*
          from claims.expresses e join claims.tx t on t.id = e.tx
         where (p_revisions is null or e.revision_id = any(p_revisions)) and t.at <= p_at
           and (e.revision_id, e.claim_key, e.part) in
               (select revision_id, claim_key, part from claims.expresses where claim_id = p_claim)
         order by e.revision_id, e.claim_key, e.part, e.id desc
    ) x where x.claim_id = p_claim and x.op = 'assert';
$$;

-- Each evidence/source assertion has its own history. One source withdrawing its link does not withdraw
-- another source's assertion of that pair. Present RLS applies before reduction, including in historical reads.
create or replace function claims.origin_links_at(p_at timestamptz, p_revisions uuid[])
returns setof claims.origin_links
language sql stable security invoker set search_path = pg_catalog, public as $$
    select x.* from (
        select distinct on (l.a, l.b, l.evidence, l.source_key) l.*
          from claims.origin_links l join claims.tx t on t.id = l.tx
         where t.at <= p_at and (p_revisions is null or l.evidence = any(p_revisions))
         order by l.a, l.b, l.evidence, l.source_key, l.id desc
    ) x where x.op = 'assert' and x.status = 'confirmed';
$$;

-- How many of a work's claims carry a frame, in the revision the caller is shown (graph.md §7): frame coverage as a
-- number. Null when the caller may read no revision of the work.
create or replace function claims.frame_coverage(p_public_id text)
returns table (revision_id uuid, claims int, framed int, answering int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select h.rev, (select count(*)::int from research.claims c where c.revision_id = h.rev),
           (select count(*)::int from claims.frames f where f.revision_id = h.rev),
           (select count(distinct a.claim_key)::int from
               (select distinct on (x.claim_key,x.question_id) x.* from claims.answered x join claims.tx t on t.id=x.tx
                 where x.evidence=h.rev and t.at<=now() order by x.claim_key,x.question_id,x.id desc) a
             where a.op='assert' and exists(select 1 from claims.occurrences_at(a.claim_id,now(),array[h.rev]) o
                                            where o.claim_key=a.claim_key))
      from (select research.visible_head(w.id) as rev from research.works w where w.public_id = p_public_id) h
     where h.rev is not null;
$$;

-- The confirmed-or-not link rows that touch any of p_origins, among those the caller may read: exactly what
-- origin_links_readable admits, fetched by origin first and checked second. Under row security the planner put the
-- policy's research.revision_readable ahead of the endpoint test on a sequential scan, so on the statistics of a
-- small graph every link in it was checked to find the one or two incident to an origin (REM-1003). A definer reads
-- the incident rows through origin_links_a/_b and applies the policy's own test to those rows only.
create or replace function claims.readable_links_of(p_origins uuid[], p_revisions uuid[])
returns setof claims.origin_links
language sql stable security definer cost 1000 rows 10 set search_path = pg_catalog, public as $$
    with incident as materialized (
        select l.* from claims.origin_links l where l.a = any(p_origins)
        union
        select l.* from claims.origin_links l where l.b = any(p_origins))
    select i.* from incident i
     where (p_revisions is null or i.evidence = any(p_revisions))
       and research.revision_readable(i.evidence);
$$;
revoke all on function claims.readable_links_of(uuid[], uuid[]) from public;
grant execute on function claims.readable_links_of(uuid[], uuid[]) to authenticated;

-- The study an origin names, as one representative origin (graph.md §3, REM-477). A DOI or an address is strong
-- identity, and two strong keys joined by a link name one study, because a link is only ever asserted from one
-- source carrying both. A title is weak: two different documents can carry one title ("Our theory manuscript"
-- labelled both a paper and its data file on the live corpus). So a title never bridges two strong keys: it
-- belongs to a study only when every strong key it is linked to is in that one study, and otherwise stands alone.
-- Only links the caller may read are walked.
create or replace function claims.study_of(p_origin uuid, p_at timestamptz, p_revisions uuid[]) returns uuid
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    k     text;
    comps uuid[];
    seen uuid[] := array[p_origin];
    frontier uuid[] := array[p_origin];
    reached uuid[];
begin
    select key into k from claims.origins where id = p_origin;
    if k is null then
        return null;
    end if;
    if k ~ '^(doi|url):' then
        -- Reduce only incident assertions. Reducing the entire caller-visible graph at each hop caused
        -- application claim pages to exceed 30 seconds with fewer than 200 unrelated revisions (REM-606).
        -- Materialize the RLS-filtered candidates before joining tx, whose own RLS checks assertion access.
        loop
            with candidates as materialized (
                select l.* from claims.readable_links_of(frontier, p_revisions) l),
            latest as (
                select distinct on (l.a,l.b,l.evidence,l.source_key) l.*
                  from candidates l cross join lateral
                       (select t.at from claims.tx t where t.id=l.tx offset 0) t where t.at<=p_at
                 order by l.a,l.b,l.evidence,l.source_key,l.id desc)
            select array_agg(distinct n.id) into reached
              from latest l cross join lateral (values(l.a),(l.b)) endpoint(id)
              cross join lateral (select n.id,n.key from claims.origins n
                                    where n.id=endpoint.id offset 0) n
             where l.op='assert' and l.status='confirmed' and n.key ~ '^(doi|url):'
               and not (n.id=any(seen));
            exit when reached is null;
            seen := seen || reached;
            frontier := reached;
        end loop;
        return (select min(o::text)::uuid from unnest(seen) o);
    end if;
    with candidates as materialized (
        select l.* from claims.readable_links_of(array[p_origin], p_revisions) l),
    latest as (
        select distinct on (l.a,l.b,l.evidence,l.source_key) l.*
          from candidates l cross join lateral
               (select t.at from claims.tx t where t.id=l.tx offset 0) t where t.at<=p_at
         order by l.a,l.b,l.evidence,l.source_key,l.id desc),
    neighbors as (
        select distinct n.id from latest l
          cross join lateral (select n.id,n.key from claims.origins n
                               where n.id=case when l.a=p_origin then l.b else l.a end offset 0) n
         where n.key ~ '^(doi|url):' and l.status='confirmed' and l.op='assert')
    select array_agg(distinct claims.study_of(n.id, p_at, p_revisions)) into comps
      from neighbors n;
    return case when cardinality(comps) = 1 then comps[1] else p_origin end;
end;
$$;

-- The study each source of one occurrence names: a source with a strong key is that key's study, and one with only
-- a title is its title's. The frame's origin counts as a source of its own (source_key '').
create or replace function claims.source_studies(p_revision uuid, p_claim_key text, p_at timestamptz, p_revisions uuid[])
returns table (source_key text, study uuid)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select c.source_key,
           coalesce(min(claims.study_of(c.origin_id, p_at, p_revisions)::text) filter (where o.key ~ '^(doi|url):'),
                    min(claims.study_of(c.origin_id, p_at, p_revisions)::text))::uuid
      from claims.cites c join claims.origins o on o.id = c.origin_id join claims.tx t on t.id = c.tx
     where c.revision_id = p_revision and c.claim_key = p_claim_key and t.at <= p_at
       and (p_revisions is null or c.revision_id = any(p_revisions))
     group by c.source_key;
$$;

-- A claim's evidence grouped by study (graph.md §10): one row per independent study, with the keys that name it
-- and how many readable occurrences of the claim cite it. The number of rows is the number of independent origins;
-- ten packages repeating one study are one row.
create or replace function claims.evidence(p_claim uuid, p_at timestamptz, p_revisions uuid[])
returns table (study uuid, keys text[], citing_occurrences int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    -- Resolve each cited origin once. Inlining the study traversal into both the grouped source read and
    -- its correlated keys subquery repeated RLS checks until ordinary published claims timed out (REM-615).
    with occ as materialized (
        select distinct e.revision_id, e.claim_key from claims.occurrences_at(p_claim, p_at, p_revisions) e),
    cited as materialized (
        select c.revision_id, c.claim_key, c.source_key, c.origin_id, og.key
          from occ o cross join lateral (
              select c.* from claims.cites c
               where c.revision_id=o.revision_id and c.claim_key=o.claim_key offset 0) c
          cross join lateral (select og.key from claims.origins og where og.id=c.origin_id offset 0) og
          cross join lateral (select ct.at from claims.tx ct where ct.id=c.tx offset 0) ct
         where ct.at <= p_at),
    origin_studies as materialized (
        select o.origin_id, claims.study_of(o.origin_id, p_at, p_revisions) as study
          from (select distinct origin_id from cited) o),
    named as materialized (
        select c.*, s.study from cited c join origin_studies s using (origin_id)),
    sources as materialized (
        select revision_id, claim_key, source_key,
               coalesce(min(study::text) filter (where key ~ '^(doi|url):'), min(study::text))::uuid as study
          from named group by revision_id, claim_key, source_key)
    select s.study,
           (select array_agg(distinct n.key order by n.key) from named n where n.study=s.study),
           count(distinct (s.revision_id, s.claim_key))::int
      from sources s where s.study is not null group by s.study;
$$;

-- Compatibility signatures keep all readable revisions, with corrected assertion-time semantics.
create or replace function claims.study_of(p_origin uuid) returns uuid
language sql stable security invoker set search_path = pg_catalog, public as $$
    select claims.study_of(p_origin, now(), null);
$$;
create or replace function claims.source_studies(p_revision uuid, p_claim_key text)
returns table (source_key text, study uuid)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from claims.source_studies(p_revision, p_claim_key, now(), null);
$$;
create or replace function claims.evidence(p_claim uuid, p_at timestamptz default now())
returns table (study uuid, keys text[], citing_occurrences int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from claims.evidence(p_claim, p_at, null);
$$;

-- The versioned entry point. Legacy graph functions retain their all-readable-revisions scope.
-- Cutoffs use transaction timestamps and highest statement id as the tie-breaker; neither is a commit clock.
create or replace function claims.reading(p_claim uuid, p_mode text default 'current',
                                         p_revisions uuid[] default null, p_at timestamptz default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    cutoff timestamptz := coalesce(p_at, now());
    selected uuid[];
    occurrences jsonb;
    edges jsonb;
    members uuid[];
    answer_rows jsonb;
begin
    if p_mode is null or p_mode not in ('current', 'pinned', 'historical')
       or (p_mode = 'current' and p_at is not null)
       or (p_mode = 'historical' and p_at is null)
       or (p_mode = 'pinned' and p_revisions is null)
       or (p_mode <> 'pinned' and p_revisions is not null) then
        raise invalid_parameter_value using message = 'Choose current, pinned revisions with optional cutoff, or historical with cutoff';
    end if;
    if p_mode = 'pinned' then
        -- Refuse the whole request for a missing or denied input, without disclosing which it was.
        if exists (select 1 from unnest(p_revisions) r where not coalesce(research.revision_readable(r), false)) then
            return null;
        end if;
        select coalesce(array_agg(distinct r.id order by r.id), '{}') into selected
          from research.revisions r where r.id = any(p_revisions) and r.created_at <= cutoff;
    elsif p_mode = 'current' then
        select coalesce(array_agg(h.id order by h.id), '{}') into selected
          from research.works w cross join lateral (select research.visible_head(w.id) id) h
         where h.id is not null and research.revision_readable(h.id);
    else
        -- trust_state owns visibility history and present access. Its head is the owned/org view; shown is public.
        select coalesce(array_agg(r.id order by r.id), '{}') into selected
          from research.works w cross join lateral (select research.trust_state(w.public_id, cutoff) v) h
          join research.revisions r on r.work_id = w.id and r.label = coalesce(h.v->>'head', h.v->>'shown')
         where research.revision_readable(r.id);
    end if;
    select jsonb_agg(jsonb_build_object('revision_id', e.revision_id, 'claim_key', e.claim_key,
                    'part', e.part, 'status', e.status, 'method', e.method, 'text', coalesce(e.gloss, c.text))
                    order by e.revision_id, e.claim_key, e.part) into occurrences
      from claims.occurrences_at(p_claim, cutoff, selected) e
      join research.claims c on (c.revision_id, c.claim_key) = (e.revision_id, e.claim_key);
    if occurrences is null then return null; end if;
    -- UNION is node reachability, not path enumeration. C2 adds serving budgets and completion metadata.
    with recursive ids(id) as (
        select p_claim union
        select case when r.src = i.id then r.dst else r.src end
          from ids i cross join lateral claims.relations_at(i.id, cutoff) r
         where r.predicate = 'same_as' and r.status = 'confirmed'
           and r.evidence = any(selected) and (r.evidence2 is null or r.evidence2 = any(selected))
    ) select array_agg(id order by id) into members from ids;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.id), '[]') into edges
      from claims.relations_at(p_claim, cutoff) r
     where r.evidence = any(selected) and (r.evidence2 is null or r.evidence2 = any(selected));
    -- An answer belongs to its occurrence, even if that occurrence has since changed claim identity.
    select coalesce(jsonb_agg(jsonb_build_object('question_id', a.question_id, 'stance', a.stance,
                         'status', a.status, 'evidence', a.evidence, 'claim_key', a.claim_key)
                         order by a.evidence, a.claim_key, a.question_id), '[]') into answer_rows
      from (select distinct on (x.evidence, x.claim_key, x.question_id) x.*
              from claims.answered x join claims.tx t on t.id = x.tx
             where x.evidence = any(selected) and t.at <= cutoff
             order by x.evidence, x.claim_key, x.question_id, x.id desc) a
     where a.op = 'assert' and a.claim_id = p_claim
       and exists (select 1 from claims.occurrences_at(p_claim, cutoff, selected) o
                    where (o.revision_id, o.claim_key) = (a.evidence, a.claim_key));
    return jsonb_build_object('contract_version', '1', 'claim_id', p_claim, 'mode', p_mode,
        'cutoff', cutoff, 'selected_revisions', selected, 'occurrences', occurrences,
        'identity_set', members, 'relations', edges, 'answers', answer_rows,
        'evidence', coalesce((select jsonb_agg(to_jsonb(e) order by e.study)
                               from claims.evidence(p_claim, cutoff, selected) e), '[]'::jsonb));
end;
$$;

grant execute on function claims.occurrences_at(uuid, timestamptz, uuid[]),
    claims.origin_links_at(timestamptz, uuid[]), claims.study_of(uuid, timestamptz, uuid[]),
    claims.source_studies(uuid, text, timestamptz, uuid[]), claims.evidence(uuid, timestamptz, uuid[]),
    claims.reading(uuid, text, uuid[], timestamptz) to authenticated;

-- The readable works whose shown revision cites the same study as one occurrence (REM-219's question, answered from
-- origins): one row per study the occurrence cites, with the works and claims citing it. independent_evidence is 1
-- per row, however many works repeat it.
create or replace function claims.same_study(p_revision uuid, p_claim_key text)
returns table (study uuid, keys text[], works jsonb, independent_evidence int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with mine as (select distinct s.study from claims.source_studies(p_revision, p_claim_key) s where s.study is not null),
         heads as (select w.public_id, research.visible_head(w.id) as rev from research.works w
                    where w.id <> (select v.work_id from research.revisions v where v.id = p_revision)),
         theirs as (select distinct h.public_id, c.revision_id, c.claim_key, s.study
                      from heads h join (select distinct revision_id, claim_key from claims.cites) c on c.revision_id = h.rev
                      cross join lateral claims.source_studies(c.revision_id, c.claim_key) s)
    select m.study,
           (select array_agg(distinct o.key order by o.key) from claims.cites c join claims.origins o on o.id = c.origin_id
             where c.revision_id = p_revision and c.claim_key = p_claim_key and claims.study_of(c.origin_id) = m.study),
           jsonb_agg(distinct jsonb_build_object('package_id', t.public_id, 'revision_id', t.revision_id, 'claim_key', t.claim_key)),
           1
      from mine m join theirs t on t.study = m.study
     group by m.study;
$$;

-- A claim's resolutions as they stand: each proposal with its latest status.
create or replace function claims.resolutions_of(p_claim uuid, p_at timestamptz default now())
returns table (resolution bigint, value text, event text, evidence_ref text, checked_on date, method text,
               status text, proposed_by text, at timestamptz)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select p.id, p.value, p.event, p.evidence_ref, p.checked_on, p.method,
           coalesce((select r.status from claims.resolutions r join claims.tx rt on rt.id = r.tx
                      where r.restates = p.id and rt.at <= p_at order by r.id desc limit 1), p.status),
           pt.actor_kind, pt.at
      from claims.resolutions p join claims.tx pt on pt.id = p.tx
     where p.claim_id = p_claim and p.restates is null and pt.at <= p_at;
$$;

-- An origin's record: the confirmed resolutions of the readable claims that cite its study, counted by value. A
-- claim counts once however many revisions cite the study. A tally, never a score (graph.md §12).
create or replace function claims.origin_record(p_origin uuid)
returns table (value text, claims int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with study as (select claims.study_of(p_origin) as s),
         citing as (select distinct e.claim_id
                      from claims.cites c
                      cross join lateral (
                          select distinct on (x.part) x.claim_id,x.op from claims.expresses x join claims.tx t on t.id=x.tx
                           where x.revision_id=c.revision_id and x.claim_key=c.claim_key and t.at<=now()
                           order by x.part,x.id desc) e
                     where e.op='assert' and claims.study_of(c.origin_id) = (select s from study)),
         settled as (select distinct on (p.claim_id) p.claim_id, p.value
                       from claims.resolutions p
                      where p.restates is null and p.claim_id in (select claim_id from citing)
                        and (select r.status from claims.resolutions r where r.restates = p.id order by r.id desc limit 1) = 'confirmed'
                      order by p.claim_id, p.id desc)
    select value, count(*)::int from settled group by value order by value;
$$;

grant execute on function claims.resolutions_of(uuid, timestamptz), claims.origin_record(uuid) to authenticated;

grant execute on function claims.study_of(uuid), claims.source_studies(uuid, text), claims.evidence(uuid, timestamptz),
                          claims.same_study(uuid, text) to authenticated;

grant execute on function claims.answers_of(uuid, timestamptz), claims.answers(uuid, timestamptz),
                          claims.frame_coverage(text) to authenticated;

grant execute on function claims.relations_at(uuid, timestamptz), claims.claim(uuid, timestamptz),
                          claims.identity_set(uuid, timestamptz),
                          claims.neighbourhood(uuid, text[], int, timestamptz), claims.rests_on(uuid, timestamptz),
                          claims.challenged_through(uuid, timestamptz), claims.history(uuid),
                          claims.candidates(uuid, text, float8, int, vector, text),
                          claims.revision_diff(uuid, uuid) to authenticated;

-- REM-590. Detached execution identity survives workflow retention. No prompts, credentials or raw SQL
-- enter the public projection. Unknown provider versions and missing results remain unknown.
create table if not exists claims.execution_receipts (
    tx bigint primary key references claims.tx(id) on delete cascade,
    kind text not null check (kind in ('manual','projection','workflow','untracked_agent')),
    run_id uuid,
    task_id uuid,
    step_key text,
    attempt int,
    method text not null,
    method_version text not null,
    recorded_at timestamptz not null default now(),
    check ((kind='workflow') = (run_id is not null))
);
comment on table claims.execution_receipts is
    'Which run, task, step and attempt produced a transaction, and by what method at what version.';
alter table claims.execution_receipts enable row level security;
-- Result attachment and erasure find one task attempt, rather than scanning the assertion history.
create index if not exists execution_receipts_task on claims.execution_receipts(task_id,attempt) where task_id is not null;
create table if not exists claims.execution_inputs (
    tx bigint not null references claims.execution_receipts(tx) on delete cascade,
    revision_id uuid not null,
    content_hash text not null,
    primary key(tx,revision_id)
);
comment on table claims.execution_inputs is
    'The exact revision content a machine assertion ran over, by hash.';
alter table claims.execution_inputs enable row level security;
create or replace function claims.capture_execution() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    rid uuid := nullif(current_setting('workflow.current_run_id',true),'')::uuid;
    tid uuid := coalesce(nullif(current_setting('workflow.current_task_id',true),'')::uuid,
                         nullif(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'workflow_task_id','')::uuid);
    token jsonb := coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}');
    task workflow.tasks;
    actor uuid := coalesce(new.actor_id, rbac.current_user_id());
    source text;
begin
    if tid is not null then
        select * into task from workflow.tasks where id=tid;
        if not found or task.status not in ('running','waiting_external')
           or (rid is not null and rid <> task.run_id) then
            raise check_violation using message='An assertion records only an executing workflow task';
        end if;
        if nullif(current_setting('workflow.current_task_id',true),'') is null
           and (task.claimed_by is distinct from token->>'workflow_worker_id'
                or task.attempts is distinct from (token->>'workflow_attempt')::int) then
            raise check_violation using message='An assertion records only its dispatching task attempt';
        end if;
        rid := task.run_id;
    end if;
    if rid is not null and (actor is null or workflow.run_owner_of(rid) is distinct from actor) then
        raise check_violation using message='An assertion workflow run belongs to its actor';
    end if;
    source := case when rid is not null then 'workflow' when new.actor_kind='platform' then 'projection'
                   when new.actor_kind='person' then 'manual' else 'untracked_agent' end;
    insert into claims.execution_receipts(tx,kind,run_id,task_id,step_key,attempt,method,method_version)
    values(new.id,source,rid,tid,task.step_key,task.attempts,
           case when source='workflow' then 'workflow.' || coalesce(task.kind,'unknown_step') else source end,
           'claims-execution/1');
    insert into claims.execution_inputs(tx,revision_id,content_hash)
    select new.id,id,content_hash from research.revisions where id=new.revision_id;
    return new;
end;
$$;
create or replace trigger trg_capture_execution after insert on claims.tx
for each row execute function claims.capture_execution();
revoke all on function claims.capture_execution() from public;

-- A comparison has a second input. Capture its immutable hash when the assertion is written, not when read.
create or replace function claims.capture_execution_inputs() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    insert into claims.execution_inputs(tx,revision_id,content_hash)
    select new.tx,id,content_hash from research.revisions where id in (new.evidence,new.evidence2)
    on conflict do nothing;
    return new;
end;
$$;
create or replace trigger trg_capture_execution_inputs after insert on claims.relations
for each row execute function claims.capture_execution_inputs();
revoke all on function claims.capture_execution_inputs() from public;

-- A snapshot of the producer's usage, not a new quota/spend counter. Results arrive after assertions.
-- No live workflow FK: retention may remove the task. Assertion erasure removes its receipt normally.
create table if not exists claims.execution_results (
    task_id uuid not null,
    attempt int not null,
    agent_run_id uuid not null,
    method_version text not null,
    model text,
    model_version text,
    evaluation_resource uuid,
    usage jsonb not null check (jsonb_typeof(usage)='object'),
    recorded_at timestamptz not null default now(),
    primary key(task_id,attempt,agent_run_id)
);
comment on table claims.execution_results is
    'What a machine extraction actually cost and used: model, version, usage and the evaluation it was scored against.';
alter table claims.execution_results enable row level security;
-- Only the trusted runtime/worker can attach provider metadata. A caller can name neither a model nor usage
-- on an assertion; a stale dispatch attempt cannot attach a result to the worker that replaced it.
create or replace function claims.record_execution_result(p_task uuid, p_worker text, p_attempt int,
    p_agent_run uuid, p_method_version text, p_model text, p_model_version text, p_usage jsonb,
    p_evaluation_resource uuid default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare task workflow.tasks; safe_usage jsonb; existing claims.execution_results;
begin
    select * into task from workflow.tasks where id=p_task for update;
    if not found or task.status not in ('running','waiting_external') or p_worker is null
       or task.claimed_by is distinct from p_worker or task.attempts is distinct from p_attempt then
        raise insufficient_privilege using message='Execution results belong to the current task lease';
    end if;
    -- Keep assertion provenance, not a second archive of every model call made by the installation.
    if not exists(select 1 from claims.execution_receipts r where r.task_id=p_task and r.attempt=p_attempt) then
        return;
    end if;
    select coalesce(jsonb_object_agg(key,value),'{}') into safe_usage from jsonb_each(p_usage)
     where key in ('input_tokens','output_tokens','requests','tool_calls','cache_read_tokens','cache_write_tokens')
       and jsonb_typeof(value)='number' and (value::text)::numeric >= 0;
    select * into existing from claims.execution_results
     where task_id=p_task and attempt=p_attempt and agent_run_id=p_agent_run;
    if found then
        if (existing.method_version,existing.model,existing.model_version,existing.usage,existing.evaluation_resource)
            is distinct from (p_method_version,p_model,p_model_version,safe_usage,p_evaluation_resource) then
            raise check_violation using message='An execution result retry must match its recorded result';
        end if;
        return;
    end if;
    insert into claims.execution_results(task_id,attempt,agent_run_id,method_version,model,model_version,evaluation_resource,usage)
    values(p_task,p_attempt,p_agent_run,p_method_version,p_model,p_model_version,p_evaluation_resource,safe_usage);
end;
$$;
revoke all on function claims.record_execution_result(uuid,text,int,uuid,text,text,text,jsonb,uuid) from public;
grant usage on schema claims to worker;
grant execute on function claims.record_execution_result(uuid,text,int,uuid,text,text,text,jsonb,uuid) to worker;

do $$ declare t text; begin
    foreach t in array array['claims.execution_receipts','claims.execution_inputs','claims.execution_results'] loop
        execute format('create or replace trigger trg_refuse_rewrite before update or delete on %s for each row execute function research.refuse_rewrite()',t);
        execute format('create or replace trigger trg_refuse_truncate before truncate on %s for each statement execute function research.refuse_rewrite()',t);
    end loop;
end $$;

-- A receipt is read only through a currently readable assertion. The view never accepts a run id as authority.
-- Keep raw receipt rows private: revision hashes of an inaccessible input are also protected content metadata.
create or replace function claims.execution_receipt(p_tx bigint) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r claims.execution_receipts; results jsonb; artifacts jsonb; actor uuid; visible boolean;
begin
    if not rbac.may('research','select') then return null; end if;
    select * into r from claims.execution_receipts where tx=p_tx;
    if not found then return null; end if;
    select actor_id into actor from claims.tx where id=p_tx;
    -- Repeat the tx policy's evidence checks under explicit revision permissions because this is a definer.
    visible := actor=rbac.current_user_id()
        or exists(select 1 from claims.expresses e where e.tx=p_tx and research.revision_readable(e.revision_id))
        or exists(select 1 from claims.relations e where e.tx=p_tx and research.revision_readable(e.evidence)
                    and (e.evidence2 is null or research.revision_readable(e.evidence2)))
        or exists(select 1 from claims.answered e where e.tx=p_tx and research.revision_readable(e.evidence))
        or exists(select 1 from claims.cites e where e.tx=p_tx and research.revision_readable(e.revision_id))
        or exists(select 1 from claims.origin_links e where e.tx=p_tx and research.revision_readable(e.evidence))
        or exists(select 1 from claims.resolutions e where e.tx=p_tx and research.revision_readable(e.evidence))
        or exists(select 1 from claims.consensus e where e.tx=p_tx and research.revision_readable(e.evidence));
    if not coalesce(visible,false) then return null; end if;
    select jsonb_agg(jsonb_build_object('agent_run_id',x.agent_run_id,'method_version',x.method_version,
                'model',x.model,'model_version',x.model_version,'usage',x.usage,'recorded_at',x.recorded_at) order by x.agent_run_id),
           jsonb_agg(case when x.evaluation_resource is null then jsonb_build_object('status','not_recorded')
                when exists(select 1 from content.resolve_file(x.evaluation_resource)) then
                    jsonb_build_object('status','available','resource_id',x.evaluation_resource)
                else jsonb_build_object('status','unavailable') end order by x.agent_run_id)
      into results,artifacts from claims.execution_results x where x.task_id=r.task_id and x.attempt=r.attempt;
    return jsonb_build_object('contract_version','1','kind',r.kind,'recorded_at',r.recorded_at,
        'run_id',r.run_id,'task_id',r.task_id,'step_key',r.step_key,'attempt',r.attempt,
        'method',r.method,'method_version',r.method_version,
        'inputs',coalesce((select jsonb_agg(case when research.revision_readable(i.revision_id) then
                         jsonb_build_object('status','available','revision_id',i.revision_id,'content_hash',i.content_hash)
                     else jsonb_build_object('status','unavailable') end order by i.revision_id)
                        from claims.execution_inputs i where i.tx=p_tx),'[]'::jsonb),
        'execution',case when results is null then jsonb_build_object('status','unavailable') else
            jsonb_build_object('status','available','scope','workflow_task_attempt','runs',results) end,
        'evaluation_artifacts',coalesce(artifacts,'[]'::jsonb));
end;
$$;
revoke all on function claims.execution_receipt(bigint) from public;
grant execute on function claims.execution_receipt(bigint) to authenticated;

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
do $$
declare v uuid;
begin
    for v in select r.id from research.revisions r
              where jsonb_path_exists(r.document, '$.claims[*].frame')
                and exists (select 1 from research.claims c where c.revision_id = r.id)
                and not exists (select 1 from claims.frames f where f.revision_id = r.id)
              order by r.work_id, r.number loop
        perform claims.project_frames(v);
    end loop;
end $$;
do $$
declare v uuid;
begin
    for v in select distinct c.revision_id from research.citations c
              where not exists (select 1 from claims.cites x where x.revision_id = c.revision_id) loop
        perform claims.project_cites(v);
    end loop;
end $$;
