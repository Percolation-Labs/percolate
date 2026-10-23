-- ============================================================
-- Tags, their dual questions, and a resource's links to tags and questions (REM-1144;
-- ai-query-layer/tripartite-search.md).
--
-- Sirsh's rule: ONE tags table, ONE claims layer and ONE questions table, shared by every store, and the fewest
-- tables that represent the thing (M-20261023-152402-6909). So this file adds one table, claims.tags, and no link
-- table: a link is an edge in aiq.edges, the graph's one table of typed, weighted, provenanced, retractable links
-- between two nodes. Tags and questions become node types through aiq.register_entity_table (a registry row, not
-- a table), as content.resources already is ('document'), and the links are three relations in the catalogue:
--
--   document  tagged  tag        a resource carries a tag; weight is the decider's probability
--   document  answers question   a resource holds an answer to a question; weight likewise
--   tag       dual    question   a tag's dual question; weight is what training moves, retirement sets valid_to
--
-- A later dreaming edge (a split node refining its parent, a provisional tag) is another catalogue row on the
-- same table. provenance carries who decided ('decider') and how a dual came to be ('origin': seed, trained or
-- person), with the claims.tx of the write.
--
-- AFTER claims/schema.sql, whose claims.tx and claims.questions these use, and after the content plane, whose
-- resources are already projected as 'document' nodes.
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

-- ------------------------------------------------------------
-- Reading. A taxonomy is shared vocabulary, so its tags are readable by anyone signed in. A link is an edge, read
-- through aiq.edges' own policy: visible when both its nodes are, so a resource's link is visible exactly when the
-- resource is.
-- ------------------------------------------------------------
alter table claims.tags enable row level security;
drop policy if exists tags_readable on claims.tags;
create policy tags_readable on claims.tags for select using (true);
grant select on claims.tags to authenticated;

-- claims.question_readable (claims/schema.sql) admits a tag's live dual and a question a readable resource links to.

-- A tag is a word or two, not a sentence, so it is found by its words and never embedded (Sirsh, 23 Oct): a
-- lexical source over its label. Not the path, whose parent words would match every child. Claims and questions,
-- which are sentences, keep their vectors (claims/schema.sql installs the workflow that embeds them).
do $$
begin
    perform aiq.register_lexical_source('tags', 'claims.tags', 'label', 'english');
end $$;

-- ------------------------------------------------------------
-- The nodes and the relations. A tag's and a question's node is public with no summary: a node says only that the
-- thing exists, and its words are read from its own table under that table's policy. The canonical keys carry a
-- kind prefix so that resolving a mention ('fitness') never lands on a tag.
-- ------------------------------------------------------------
select aiq.register_entity_table(
    p_entity_type     => 'tag',
    p_source_table    => 'claims.tags',
    p_key_expr        => $$'tag:' || n.source || '/' || n.source_version || '/' || n.key$$,
    p_summary_expr    => 'null',
    p_org_expr        => 'null',
    p_visibility_expr => $$'public'$$);
select aiq.register_entity_table(
    p_entity_type     => 'question',
    p_source_table    => 'claims.questions',
    p_key_expr        => $$'question:' || n.id$$,
    p_summary_expr    => 'null',
    p_org_expr        => 'null',
    p_visibility_expr => $$'public'$$);
-- Questions minted before this registration have no node until it is rebuilt.
select aiq.rebuild_entity_type('question');
-- Every registered type takes the shipped vocabulary's triples (world-model-ingestion/graph.sql), and an upgrade
-- replays graph.sql after these registrations exist; asking here gives a fresh install the same catalogue, as
-- ai-query-layer/catalogue.sql does for db_object.
select aiq.register_graph_vocabulary();

insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description, is_symmetric) values
    ('document', 'tagged',  'tag',      'tags',        'a resource carries the tag; weight is the decider''s probability (REM-1144)', false),
    ('document', 'answers', 'question', 'answered_by', 'a resource holds an answer to the question, or part of one; weight is the decider''s probability (REM-1144)', false),
    ('tag',      'dual',    'question', 'dual_of',     'the question a tag stands for; weight is what training moves, and a retired dual is retracted (REM-1144)', false)
on conflict (src_type, relation, dst_type) do update
    set inverse_label = excluded.inverse_label, description = excluded.description, is_symmetric = excluded.is_symmetric;

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
    -- A hierarchy is a tree: a parent chain that returns to its start is refused, with the whole call.
    if exists (
        with recursive up(start, id, depth) as (
            select c.id, c.parent_id, 1 from claims.tags c
             where c.source = p_source and c.source_version = p_version and c.parent_id is not null
            union all
            select u.start, p.parent_id, u.depth + 1 from up u join claims.tags p on p.id = u.id
             where p.parent_id is not null and u.id <> u.start and u.depth < 1000)
        select 1 from up where id = start) then
        raise check_violation using message = 'a taxonomy''s parents form a cycle; a hierarchy is a tree';
    end if;
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
            insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
            select nt.id, nq.id, 'dual', 1, jsonb_build_object('origin', 'seed', 'tx', t)
              from aiq.nodes nt, aiq.nodes nq
             where nt.entity_type = 'tag' and nt.entity_id = v_tag
               and nq.entity_type = 'question' and nq.entity_id = v_q
            on conflict (src_id, dst_id, relation) do nothing;
            if found then v_pairs := v_pairs + 1; end if;
        end loop;
    end loop;
    -- New seeded questions wait for vectors; tags are found by their words and need none.
    if v_qs > 0 and to_regprocedure('aiq.queue_source_embedding(text,text)') is not null then
        perform aiq.queue_source_embedding('a taxonomy''s seeded questions');
    end if;
    return jsonb_build_object('tags', v_tags, 'questions_minted', v_qs, 'duals', v_pairs,
                              'phrasings_skipped', v_skip, 'tx', t);
end;
$$;

-- Training moves a dual: a new weight, a new dual, or a retirement (the edge's valid_to). One write per call, with
-- its tx and reason in the edge's provenance.
create or replace function claims.train_dual(p_tag uuid, p_question uuid, p_weight real, p_retire boolean default false,
                                             p_reason text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    t      bigint;
    v_src  uuid;
    v_dst  uuid;
begin
    if not rbac.is_operator() then
        raise insufficient_privilege using message = 'A dual is shared vocabulary: only an operator or its trainer moves one';
    end if;
    if p_weight is null or p_weight not between 0 and 1 then
        raise check_violation using message = 'a dual''s weight is between 0 and 1';
    end if;
    select id into v_src from aiq.nodes where entity_type = 'tag' and entity_id = p_tag;
    select id into v_dst from aiq.nodes where entity_type = 'question' and entity_id = p_question;
    if v_src is null or v_dst is null then
        raise foreign_key_violation using message = 'train_dual names a tag or a question that does not exist';
    end if;
    insert into claims.tx (actor_kind, reason) values ('platform', coalesce(nullif(p_reason, ''), 'dual trained'))
    returning id into t;
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance, valid_to)
    values (v_src, v_dst, 'dual', p_weight, jsonb_build_object('origin', 'trained', 'tx', t),
            case when p_retire then now() end)
    on conflict (src_id, dst_id, relation) do update
        set weight = excluded.weight, provenance = excluded.provenance, valid_to = excluded.valid_to;
end;
$$;

-- A decider's links from resources the caller may write, each to exactly one tag or question:
--   [{"resource_id", "tag_id" | "question_id", "p"}]
-- p is the edge's weight; a link with no p is asserted as certain (a person, a rule) and weighs 1. A repeated link
-- takes the newer probability and is current again if it had been retracted. A resource the caller may not write,
-- or one that is not ready and so has no node, refuses the whole call.
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
                where num_nonnulls(x->>'tag_id', x->>'question_id') <> 1
                   or ((x->>'p') is not null and (x->>'p')::real not between 0 and 1)) then
        raise check_violation using message = 'a link names exactly one tag_id or question_id, and a p between 0 and 1';
    end if;
    if exists (select 1 from jsonb_array_elements(p_links) x
                left join content.resources r on r.id = (x->>'resource_id')::uuid
                where r.id is null or not (rbac.is_operator() or rbac.may_write(r.owner_id, r.org_id, r.visibility))) then
        raise insufficient_privilege using message = 'a link names a resource the caller may not write';
    end if;
    if exists (select 1 from jsonb_array_elements(p_links) x
                where not exists (select 1 from aiq.nodes n where n.entity_type = 'document'
                                     and n.entity_id = (x->>'resource_id')::uuid)) then
        raise check_violation using message = 'a link names a resource that is not ready, so it is not in the graph yet';
    end if;
    insert into claims.tx (actor_id, actor_kind, credential_id, reason)
    values (rbac.current_user_id(), case when rbac.current_user_id() is null then 'platform' else rbac.current_actor() end,
            rbac.current_credential_id(), coalesce(nullif(p_reason, ''), 'links from ' || p_decider))
    returning id into t;
    -- One call can name a link twice (two seeded keys sharing one phrasing mint one question): the higher p stands.
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
    select distinct on (nr.id, nd.id, y.relation)
           nr.id, nd.id, y.relation, coalesce(y.p, 1), jsonb_build_object('decider', p_decider, 'tx', t)
      from (select (x->>'resource_id')::uuid as resource_id,
                   case when x ? 'tag_id' and x->>'tag_id' is not null then 'tag' else 'question' end as dst_type,
                   coalesce(x->>'tag_id', x->>'question_id')::uuid as dst,
                   case when x ? 'tag_id' and x->>'tag_id' is not null then 'tagged' else 'answers' end as relation,
                   (x->>'p')::real as p
              from jsonb_array_elements(p_links) x) y
      join aiq.nodes nr on nr.entity_type = 'document' and nr.entity_id = y.resource_id
      join aiq.nodes nd on nd.entity_type = y.dst_type and nd.entity_id = y.dst
     order by nr.id, nd.id, y.relation, y.p desc nulls first
    on conflict (src_id, dst_id, relation) do update
        set weight = excluded.weight, provenance = excluded.provenance, valid_to = null;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- ------------------------------------------------------------
-- The search (tripartite-search.md §2). Documents, tags and questions are searched at once; a tag or question hit
-- expands one hop along its current edges (aiq.edges_current) to the resources it links; the lists fuse by reciprocal rank.
--
-- Invoker, so every arm reads as the caller and a resource the caller cannot read never takes a rank.
-- p_scope narrows the resources as aiq.search does (a memory's agent and run). p_layers chooses the arms, so the
-- primary-store-only search is the same function with p_layers => '{documents}'. A caller that has chosen its own
-- tags or questions (a decision model, a person) passes them in p_tags / p_questions as [{"id", "w"}]; otherwise
-- tags are the ones whose label words the query uses, and questions the nearest by vector. Only the resources store
-- is linked today; brews and long-form refuse until they are.
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
        -- Without chosen tags, the tags whose label words the query uses, the best match weighted 1.
        select l.chunk_id, (l.score / nullif(max(l.score) over (), 0))::real
          from aiq.lexical('tags', p_query, p_k_tags) l
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
    -- One hop: the hit's node, its current incoming edges of the layer's relation, and the document at the other
    -- end. Read as the caller, so an edge whose resource the caller cannot read is not there.
    links as (
        select 'tag'::text as via, h.id, h.w, n.entity_id as resource_id, e.weight as p
          from tag_hits h
          join aiq.nodes t on t.entity_type = 'tag' and t.entity_id = h.id
          join aiq.edges_current e on e.dst_id = t.id and e.relation = 'tagged' and e.weight >= p_min_p
          join aiq.nodes n on n.id = e.src_id and n.entity_type = 'document'
        union all
        select 'question', h.id, h.w, n.entity_id, e.weight
          from question_hits h
          join aiq.nodes q on q.entity_type = 'question' and q.entity_id = h.id
          join aiq.edges_current e on e.dst_id = q.id and e.relation = 'answers' and e.weight >= p_min_p
          join aiq.nodes n on n.id = e.src_id and n.entity_type = 'document'
    ),
    via_tags as (
        select distinct on (l.resource_id) l.resource_id, h_s.s,
               jsonb_build_array(jsonb_build_object('via', 'tag', 'id', l.id, 'sim', l.w, 'p', l.p)) as path
          from links l join in_scope i on i.id = l.resource_id
          cross join lateral (select l.w * l.p as s) h_s
         where l.via = 'tag'
         order by l.resource_id, h_s.s desc, l.id
    ),
    via_questions as (
        select distinct on (l.resource_id) l.resource_id, h_s.s,
               jsonb_build_array(jsonb_build_object('via', 'question', 'id', l.id, 'sim', l.w, 'p', l.p)) as path
          from links l join in_scope i on i.id = l.resource_id
          cross join lateral (select l.w * l.p as s) h_s
         where l.via = 'question'
         order by l.resource_id, h_s.s desc, l.id
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
