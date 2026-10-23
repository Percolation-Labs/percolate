-- ============================================================
-- Tags, their dual questions, and the canonical links from a resource to a tag, a question or a claim
-- (REM-1144; ai-query-layer/tripartite-search.md).
--
-- Sirsh's rule: ONE tags table, ONE claims layer and ONE questions table, shared by every store, so any store
-- gets its tag, claim and question relationships by writing links. This file adds the tags table, the tag's dual
-- questions and the link from a generic resource; brews and long-form pieces take the same pattern later.
--
--   claims.tags           a taxonomy node: its source (iab, schema.org, a person's own), the source's version,
--                         its key there, its path, and its parent in the same source and version
--   claims.tag_questions  a tag's dual questions in claims.questions, with a weight that training moves and a
--                         retirement, so the question space is updated over time without touching the tags
--   claims.resource_links a resource linked to exactly one tag, question or claim, with the decider's probability
--
-- AFTER claims/schema.sql, whose claims.tx, claims.questions and claims.claims these reference, and after the
-- content plane, whose content.resources they link.
-- ============================================================

create table if not exists claims.tags (
    id             uuid primary key default uuidv7(),
    source         text not null check (source ~ '^[a-z0-9][a-z0-9_.-]{0,40}$'),
    source_version text not null check (length(source_version) between 1 and 40),
    key            text not null check (length(key) between 1 and 200),
    label          text not null check (length(label) between 1 and 200),
    path           text not null check (length(path) between 1 and 1000),
    parent_id      uuid,
    description    text check (length(description) between 1 and 2000),
    tx             bigint not null references claims.tx(id),
    unique (source, source_version, key),
    unique (id, source, source_version),
    -- A parent is in the same taxonomy and version: a hierarchy never crosses sources.
    foreign key (parent_id, source, source_version) references claims.tags (id, source, source_version),
    check (parent_id is distinct from id)
);
comment on table claims.tags is
    'A taxonomy node, shared by every store: its source and version, its key there, its path, and its parent in the same taxonomy.';
create index if not exists tags_parent on claims.tags (parent_id) where parent_id is not null;

-- What a tag is found by: its path, and its description when it has one. A semantic source, as claims.questions is.
alter table claims.tags add column if not exists search_text text
    generated always as (path || coalesce(': ' || description, '')) stored;

create table if not exists claims.tag_questions (
    tag_id      uuid not null references claims.tags(id) on delete cascade,
    question_id uuid not null references claims.questions(id),
    weight      real not null default 1 check (weight between 0 and 1),
    origin      text not null check (origin in ('seed', 'trained', 'person')),
    retired_at  timestamptz,
    tx          bigint not null references claims.tx(id),
    primary key (tag_id, question_id)
);
comment on table claims.tag_questions is
    'A tag''s dual questions: seeded with the taxonomy, then re-weighted, added or retired by training, each change with its tx.';
create index if not exists tag_questions_question on claims.tag_questions (question_id);

create table if not exists claims.resource_links (
    id          bigint generated always as identity primary key,
    resource_id uuid not null references content.resources(id) on delete cascade,
    tag_id      uuid references claims.tags(id) on delete cascade,
    question_id uuid references claims.questions(id),
    claim_id    uuid references claims.claims(id),
    p           real check (p between 0 and 1),
    decider     text not null check (length(decider) between 1 and 200),
    tx          bigint not null references claims.tx(id),
    check (num_nonnulls(tag_id, question_id, claim_id) = 1),
    unique nulls not distinct (resource_id, tag_id, question_id, claim_id)
);
comment on table claims.resource_links is
    'A resource linked to exactly one tag, question or claim, with the probability the decider gave and who decided: the canonical link a search expands along.';
create index if not exists resource_links_tag on claims.resource_links (tag_id, p desc) where tag_id is not null;
create index if not exists resource_links_question on claims.resource_links (question_id, p desc) where question_id is not null;
create index if not exists resource_links_claim on claims.resource_links (claim_id) where claim_id is not null;
create index if not exists resource_links_resource on claims.resource_links (resource_id);

-- ------------------------------------------------------------
-- Reading. A taxonomy is shared vocabulary, so its tags and their dual questions are readable by anyone signed in.
-- A link is readable when its resource is, through the resource's own policy.
-- ------------------------------------------------------------
alter table claims.tags enable row level security;
alter table claims.tag_questions enable row level security;
alter table claims.resource_links enable row level security;
drop policy if exists tags_readable on claims.tags;
create policy tags_readable on claims.tags for select using (true);
drop policy if exists tag_questions_readable on claims.tag_questions;
create policy tag_questions_readable on claims.tag_questions for select using (true);
drop policy if exists resource_links_via_resource on claims.resource_links;
create policy resource_links_via_resource on claims.resource_links for select
    using (exists (select 1 from content.resources r where r.id = resource_links.resource_id));
grant select on claims.tags, claims.tag_questions, claims.resource_links to authenticated;

-- claims.question_readable (claims/schema.sql) admits a tag's live dual and a question a readable resource links to.

do $$
begin
    if to_regclass('aiq.semantic_sources') is not null then
        insert into aiq.semantic_sources (name, source_table, content_col)
        values ('tags', 'claims.tags', 'search_text')
        on conflict (name) do update
           set source_table = excluded.source_table,
               content_col  = excluded.content_col,
               shipped = excluded.shipped or semantic_sources.shipped;
    end if;
end $$;

-- ------------------------------------------------------------
-- Writing. Every write is a function with its tx, as every claims write is.
-- ------------------------------------------------------------

-- A taxonomy, or a new version of one, in one call: each element is
--   {"key", "label", "path", "parent" (the parent's key, optional), "description" (optional),
--    "questions": ["What is my current employer?", ...] (optional, the tag's seeded duals)}
-- Parents may come in any order. A question is minted the way claims.pose_question mints one (keyed by its
-- normalised words, so two tags can share a dual), and a phrasing pose_question would refuse is counted and
-- skipped rather than failing the taxonomy. A taxonomy is shared vocabulary, so only an operator installs one.
create or replace function claims.put_taxonomy(p_source text, p_version text, p_tags jsonb, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    t        bigint;
    v_tags   int;
    v_qs     int := 0;
    v_pairs  int := 0;
    v_skip   int := 0;
    e        jsonb;
    q        text;
    v_text   text;
    k        text;
    v_q      uuid;
    v_tag    uuid;
begin
    if not rbac.is_operator() then
        raise insufficient_privilege using message = 'A taxonomy is shared vocabulary: only an operator installs one';
    end if;
    if jsonb_typeof(p_tags) is distinct from 'array' or jsonb_array_length(p_tags) = 0 then
        raise check_violation using message = 'put_taxonomy needs a non-empty array of tags';
    end if;
    insert into claims.tx (actor_kind, reason)
    values ('platform', coalesce(nullif(p_reason, ''), format('taxonomy %s %s', p_source, p_version)))
    returning id into t;

    insert into claims.tags (source, source_version, key, label, path, description, tx)
    select p_source, p_version, x->>'key', x->>'label', x->>'path', nullif(x->>'description', ''), t
      from jsonb_array_elements(p_tags) x
    on conflict (source, source_version, key) do update
        set label = excluded.label, path = excluded.path, description = excluded.description, tx = excluded.tx;
    get diagnostics v_tags = row_count;

    update claims.tags c set parent_id = p.id
      from jsonb_array_elements(p_tags) x
      join claims.tags p on p.source = p_source and p.source_version = p_version and p.key = x->>'parent'
     where c.source = p_source and c.source_version = p_version and c.key = x->>'key'
       and x->>'parent' is not null and c.parent_id is distinct from p.id;
    if exists (select 1 from jsonb_array_elements(p_tags) x
                where x->>'parent' is not null
                  and not exists (select 1 from claims.tags p where p.source = p_source
                                     and p.source_version = p_version and p.key = x->>'parent')) then
        raise foreign_key_violation using message = 'a tag names a parent key that is not in this taxonomy';
    end if;

    for e in select x from jsonb_array_elements(p_tags) x where jsonb_typeof(x->'questions') = 'array' loop
        select id into v_tag from claims.tags
         where source = p_source and source_version = p_version and key = e->>'key';
        for q in select jsonb_array_elements_text(e->'questions') loop
            v_text := regexp_replace(btrim(q), '\s+', ' ', 'g');
            if length(v_text) not between 10 and 200 or right(v_text, 1) <> '?' then
                v_skip := v_skip + 1;
                continue;
            end if;
            k := 'q:' || claims.normalised(v_text);
            insert into claims.questions (phrasing, key, tx) values (v_text, k, t)
            on conflict (key) do nothing returning id into v_q;
            if v_q is null then
                select id into v_q from claims.questions where key = k;
            else
                v_qs := v_qs + 1;
            end if;
            insert into claims.tag_questions (tag_id, question_id, origin, tx)
            values (v_tag, v_q, 'seed', t)
            on conflict (tag_id, question_id) do nothing;
            if found then v_pairs := v_pairs + 1; end if;
        end loop;
    end loop;
    if v_qs > 0 and to_regprocedure('aiq.queue_source_embedding(text,text)') is not null then
        perform aiq.queue_source_embedding('a taxonomy''s seeded questions');
    end if;
    return jsonb_build_object('tags', v_tags, 'questions_minted', v_qs, 'duals', v_pairs,
                              'phrasings_skipped', v_skip, 'tx', t);
end;
$$;

-- Training moves a dual: a new weight, a new dual, or a retirement. One row per call, with its tx and reason.
create or replace function claims.train_dual(p_tag uuid, p_question uuid, p_weight real, p_retire boolean default false,
                                             p_reason text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    t bigint;
begin
    if not rbac.is_operator() then
        raise insufficient_privilege using message = 'A dual is shared vocabulary: only an operator or its trainer moves one';
    end if;
    insert into claims.tx (actor_kind, reason) values ('platform', coalesce(nullif(p_reason, ''), 'dual trained'))
    returning id into t;
    insert into claims.tag_questions (tag_id, question_id, weight, origin, retired_at, tx)
    values (p_tag, p_question, p_weight, 'trained', case when p_retire then now() end, t)
    on conflict (tag_id, question_id) do update
        set weight = excluded.weight, retired_at = excluded.retired_at, tx = excluded.tx;
end;
$$;

-- A decider's links from resources the caller may write, each to exactly one tag, question or claim:
--   [{"resource_id", "tag_id" | "question_id" | "claim_id", "p"}]
-- A repeated link takes the newer probability. A resource the caller may not write refuses the whole call.
create or replace function claims.link_resources(p_decider text, p_links jsonb, p_reason text default null)
returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    t   bigint;
    v_n int;
begin
    if jsonb_typeof(p_links) is distinct from 'array' then
        raise check_violation using message = 'link_resources needs an array of links';
    end if;
    if exists (select 1 from jsonb_array_elements(p_links) x
                left join content.resources r on r.id = (x->>'resource_id')::uuid
                where r.id is null or not (rbac.is_operator() or rbac.may_write(r.owner_id, r.org_id, r.visibility))) then
        raise insufficient_privilege using message = 'a link names a resource the caller may not write';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, reason)
    values (rbac.current_user_id(), case when rbac.current_user_id() is null then 'platform' else rbac.current_actor() end,
            rbac.current_credential_id(), coalesce(nullif(p_reason, ''), 'links from ' || p_decider))
    returning id into t;
    -- One call can name a link twice (two seeded keys sharing one phrasing mint one question): the higher p stands.
    insert into claims.resource_links (resource_id, tag_id, question_id, claim_id, p, decider, tx)
    select distinct on (y.resource_id, y.tag_id, y.question_id, y.claim_id)
           y.resource_id, y.tag_id, y.question_id, y.claim_id, y.p, p_decider, t
      from (select (x->>'resource_id')::uuid as resource_id, (x->>'tag_id')::uuid as tag_id,
                   (x->>'question_id')::uuid as question_id, (x->>'claim_id')::uuid as claim_id, (x->>'p')::real as p
              from jsonb_array_elements(p_links) x) y
     order by y.resource_id, y.tag_id, y.question_id, y.claim_id, y.p desc nulls last
    on conflict (resource_id, tag_id, question_id, claim_id) do update
        set p = excluded.p, decider = excluded.decider, tx = excluded.tx;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- ------------------------------------------------------------
-- The search (tripartite-search.md §2). Documents, tags and questions are searched at once; a tag or question hit
-- expands one hop along claims.resource_links to the resources it links; the lists fuse by reciprocal rank.
--
-- Invoker, so every arm reads as the caller and a resource the caller cannot read never takes a rank.
-- p_scope narrows the resources as aiq.search does (a memory's agent and run). p_layers chooses the arms, so the
-- primary-store-only search is the same function with p_layers => '{documents}'. A caller that has chosen its own
-- tags or questions (a decision model, a person) passes them in p_tags / p_questions as [{"id", "w"}] in place of
-- the nearest by vector. Only the resources store is linked today; brews and long-form refuse until they are.
-- ------------------------------------------------------------
create or replace function claims.search_leads(
    p_query       text,
    p_vector      vector,
    p_model       text,
    p_scope       jsonb   default null,
    p_layers      text[]  default '{documents,tags,questions}',
    p_documents   text    default 'semantic',
    p_budget      int     default 20,
    p_k_tags      int     default 3,
    p_k_questions int     default 5,
    p_min_p       real    default 0.5,
    p_tags        jsonb   default null,
    p_questions   jsonb   default null,
    p_stores      text[]  default '{resources}'
) returns table (resource_id uuid, score real, rank int, document_rank int, tag_rank int, question_rank int,
                 path jsonb)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    v_pool int := 5000;
begin
    if p_stores is distinct from '{resources}'::text[] then
        raise feature_not_supported using
            message = 'search_leads links only the resources store so far',
            hint = 'brews and long-form pieces take the same links next (tripartite-search.md §5)';
    end if;
    if p_layers is null or cardinality(p_layers) = 0
       or exists (select 1 from unnest(p_layers) l where l not in ('documents', 'tags', 'questions')) then
        raise check_violation using message = 'p_layers names documents, tags and or questions';
    end if;
    if p_documents not in ('semantic', 'lexical', 'hybrid') then
        raise check_violation using message = 'p_documents is semantic, lexical or hybrid';
    end if;

    return query
    with docs_chunks as (
        select s.chunk_id, row_number() over (order by s.distance, s.chunk_id)::int as r
          from aiq.semantic_in('chunks', p_vector, p_model, v_pool, p_scope) s
         where 'documents' = any(p_layers) and p_documents = 'semantic'
        union all
        select l.chunk_id, row_number() over (order by l.score desc, l.chunk_id)::int
          from aiq.lexical('chunks', p_query, v_pool, p_scope) l
         where 'documents' = any(p_layers) and p_documents = 'lexical'
        union all
        select h.chunk_id, row_number() over (order by h.rrf_score desc, h.chunk_id)::int
          from aiq.search('chunks', p_query, p_vector, p_model, v_pool, 60, p_scope) h
         where 'documents' = any(p_layers) and p_documents = 'hybrid'
    ),
    docs as (
        select c.resource_id, row_number() over (order by min(d.r), c.resource_id)::int as r
          from docs_chunks d join content.resource_chunks c on c.id = d.chunk_id
         group by c.resource_id
    ),
    tag_hits as (
        select (x->>'id')::uuid as id, coalesce((x->>'w')::real, 1) as w
          from jsonb_array_elements(coalesce(p_tags, '[]')) x
         where 'tags' = any(p_layers) and p_tags is not null
        union all
        select s.chunk_id, (1 - s.distance)::real
          from aiq.semantic_in('tags', p_vector, p_model, p_k_tags) s
         where 'tags' = any(p_layers) and p_tags is null
    ),
    question_hits as (
        select (x->>'id')::uuid as id, coalesce((x->>'w')::real, 1) as w
          from jsonb_array_elements(coalesce(p_questions, '[]')) x
         where 'questions' = any(p_layers) and p_questions is not null
        union all
        select s.chunk_id, (1 - s.distance)::real
          from aiq.semantic_in('questions', p_vector, p_model, p_k_questions) s
         where 'questions' = any(p_layers) and p_questions is null
    ),
    in_scope as (
        select r.id from content.resources r
         where p_scope is null or r.metadata @> p_scope
    ),
    via_tags as (
        select distinct on (l.resource_id) l.resource_id, h.w * l.p as s,
               jsonb_build_array(jsonb_build_object('via', 'tag', 'id', h.id, 'sim', h.w, 'p', l.p)) as path
          from tag_hits h join claims.resource_links l on l.tag_id = h.id and l.p >= p_min_p
          join in_scope i on i.id = l.resource_id
         order by l.resource_id, h.w * l.p desc
    ),
    via_questions as (
        select distinct on (l.resource_id) l.resource_id, h.w * l.p as s,
               jsonb_build_array(jsonb_build_object('via', 'question', 'id', h.id, 'sim', h.w, 'p', l.p)) as path
          from question_hits h join claims.resource_links l on l.question_id = h.id and l.p >= p_min_p
          join in_scope i on i.id = l.resource_id
         order by l.resource_id, h.w * l.p desc
    ),
    tags_ranked as (
        select v.resource_id, v.path, row_number() over (order by v.s desc, v.resource_id)::int as r from via_tags v
    ),
    questions_ranked as (
        select v.resource_id, v.path, row_number() over (order by v.s desc, v.resource_id)::int as r from via_questions v
    ),
    fused as (
        select coalesce(d.resource_id, t.resource_id, q.resource_id) as resource_id,
               (coalesce(1.0 / (60 + d.r), 0) + coalesce(1.0 / (60 + t.r), 0) + coalesce(1.0 / (60 + q.r), 0))::real as s,
               d.r as dr, t.r as tr, q.r as qr,
               case when d.r is not null and d.r <= least(coalesce(t.r, d.r), coalesce(q.r, d.r)) then '[]'::jsonb
                    when t.r is not null and t.r <= coalesce(q.r, t.r) then t.path
                    else q.path end as path
          from docs d
          full join tags_ranked t on t.resource_id = d.resource_id
          full join questions_ranked q on q.resource_id = coalesce(d.resource_id, t.resource_id)
    )
    select f.resource_id, f.s, (row_number() over (order by f.s desc, f.resource_id))::int, f.dr, f.tr, f.qr, f.path
      from fused f
     order by f.s desc, f.resource_id
     limit greatest(p_budget, 1);
end;
$$;
grant execute on function claims.search_leads(text, vector, text, jsonb, text[], text, int, int, int, real, jsonb, jsonb, text[])
    to authenticated;
