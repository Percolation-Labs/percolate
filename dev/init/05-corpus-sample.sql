-- Sample: the corpus, and two embedding spaces, as data.
--
-- The retrieval half of the dialect -- TEXT, SEMANTIC, SEARCH -- had the same
-- debt the graph half had, one layer worse. `aiq.lexical_sources` and
-- `aiq.semantic_sources` each carried a row registering `chunks`, and
-- `surface.sql` checked those rows and passed; behind them
-- `content.resource_chunks` held ZERO rows and `aiq.embedding_models` held
-- zero models. Three of the seven modes had never returned a row to anybody,
-- and the audit was reporting them present.
--
-- So this file is the corpus, and the thing that makes it possible to commit:
--
--   THE VECTORS ARE LITERALS, NOT MODEL OUTPUT.
--
-- Embedding generation is an external model call and structurally cannot
-- happen inside Postgres (brief.md §4), so a fixture that needed real
-- embeddings would need a model server running to be reproducible -- which is
-- exactly the "works on the machine where somebody ran it" failure this pair
-- of sample files exists to end. Four-dimension hand-written unit vectors are
-- not a model's output and are not pretending to be. They are chosen so that
-- every ranking assertion in dev/tests/query/07-09 is arithmetic a reader can
-- check by eye, and so that the ORDER is the fixture's point rather than an
-- artefact of whichever model happened to be installed.
--
-- Two models, BOTH four-dimensional, is the other deliberate choice.
-- `schema.sql` §10's central correction is that a space is identified by its
-- MODEL and never by its dimension -- "two different 768-dimension models do
-- not produce comparable vectors; cosine distance between them is
-- meaningless, not merely imprecise." Two same-dimension models whose spaces
-- rank the SAME query vector differently is that sentence made executable: a
-- caller who names the wrong model gets a confident, well-formed, wrong
-- answer, and no dimension check can catch it.
--
-- Runs as app_owner at initdb, after the extension. Idempotent; safe to re-run:
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8experiment \
--         < dev/init/05-corpus-sample.sql

set role app_owner;

do $$
begin
    if to_regprocedure('aiq.register_embedding_space(text)') is null
       or to_regclass('content.resource_chunks') is null then
        raise warning
            'skipping the corpus sample: this database image predates '
            'aiq.register_embedding_space or the content plane. Everything '
            'else installed normally. Rebuild: dev/build-image.sh';
        return;
    end if;
end $$;

-- ------------------------------------------------------------
-- 1. A channel and three resources -- shared, org A, org B.
--
-- Tenancy is carried by content.resources.org_id and inherited by chunks
-- (content's own policy: chunks are visible via their resource, the same
-- shape aiq.node_keys uses). The corpus needs it because the interesting
-- question about SEMANTIC is not "does cosine distance work" -- it is whether
-- a caller can learn that a chunk exists in a tenant they cannot read.
-- ------------------------------------------------------------
-- visibility IS SPELLED OUT ON EVERY ROW BELOW, and having to write it is the
-- change worth noticing rather than a chore. This fixture used to say tenancy
-- with `org_id` alone: null meant "every tenant reads this" and a uuid meant
-- "only that one". The null tier was doing two jobs -- deliberately shared, and
-- nobody filled it in -- and world-model-ingestion/schema.sql measured a real
-- cross-tenant read through the second. Now the shared rows say `public`
-- because they are shared on purpose, and a row that says nothing is private.
--
-- And the null tier itself is gone: org_id is NOT NULL and the shared tier is
-- rbac.shared_org_id() (specs/identity/spec.md §4). The rows below name it,
-- which is the whole difference -- a reader can no longer mistake "shared" for
-- "nobody filled it in", because there is nothing left to fill in.
insert into content.channels (id, name, kind, org_id, visibility) values
    ('11110000-0000-0000-0000-000000000001','sample-corpus','manual',
     rbac.shared_org_id(),'public')
on conflict (id) do update set name = excluded.name, visibility = excluded.visibility;

insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility) values
    ('22220000-0000-0000-0000-000000000001','11110000-0000-0000-0000-000000000001',
     'rec-r7','memo://recall/r7','R7 recall notice','ready',rbac.shared_org_id(),'public'),
    ('22220000-0000-0000-0000-000000000002','11110000-0000-0000-0000-000000000001',
     'rec-eng','memo://engineering/actuators','Actuator failure analysis','ready',rbac.shared_org_id(),'public'),
    ('22220000-0000-0000-0000-000000000003','11110000-0000-0000-0000-000000000001',
     'rec-fin','memo://finance/q3','Q3 revenue commentary','ready',rbac.shared_org_id(),'public'),
    -- Org-scoped, and it MENTIONS THE SAME RARE TOKEN as the shared one. That
    -- is what makes the tenancy assertions sharp: a leak shows up as an extra
    -- hit for a query the other tenant is entitled to run.
    ('22220000-0000-0000-0000-000000000004','11110000-0000-0000-0000-000000000001',
     'rec-nw','memo://northwind/exposure','Northwind R7 exposure','ready',
     'a0000000-0000-0000-0000-00000000000a','org'),
    ('22220000-0000-0000-0000-000000000005','11110000-0000-0000-0000-000000000001',
     'rec-eg','memo://eastgate/position','Eastgate position note','ready',
     'a0000000-0000-0000-0000-00000000000b','org')
on conflict (id) do update set
    title = excluded.title, status = excluded.status, org_id = excluded.org_id,
    visibility = excluded.visibility, uri = excluded.uri;

-- ------------------------------------------------------------
-- 2. The chunks.
--
-- Written to make the three modes disagree, because a corpus where they agree
-- proves nothing about fusing them:
--
--   c1  the rare token, verbatim              -- TEXT finds it, SEMANTIC need not
--   c2  the same MEANING, no shared words     -- SEMANTIC finds it, TEXT cannot
--   c3  a distractor sharing neither          -- both should rank it last
--   c4  the rare token, in another tenant     -- neither may return it to org B
--   c5  another tenant again
--   c6  ties the corpus to the graph sample
--
-- c1/c2 is §11's "R7" story made reproducible: LOOKUP and FUZZY LOOKUP both
-- return zero for `R7` because they search KEYS and a chunk is not a node.
-- ------------------------------------------------------------
insert into content.resource_chunks (id, resource_id, ordinal, content) values
    ('33330000-0000-0000-0000-000000000001','22220000-0000-0000-0000-000000000001',0,
     'The R7 robotic arm may fail under sustained load; a recall notice is pending.'),
    ('33330000-0000-0000-0000-000000000002','22220000-0000-0000-0000-000000000002',0,
     'Prolonged stress on the mechanical actuator is the leading cause of returns.'),
    ('33330000-0000-0000-0000-000000000003','22220000-0000-0000-0000-000000000003',0,
     'Quarterly revenue rose on strong industrial demand across the sector.'),
    ('33330000-0000-0000-0000-000000000004','22220000-0000-0000-0000-000000000004',0,
     'Northwind internal: our R7 recall exposure is material this quarter.'),
    ('33330000-0000-0000-0000-000000000005','22220000-0000-0000-0000-000000000005',0,
     'Eastgate holds no position in industrial robotics at this time.'),
    ('33330000-0000-0000-0000-000000000006','22220000-0000-0000-0000-000000000002',1,
     'Borealis mining output fell sharply after the strike began.')
on conflict (id) do update set content = excluded.content;

-- ------------------------------------------------------------
-- 3. Registration: the lexical source and the two embedding spaces.
--
-- register_lexical_source() adds the generated tsvector column and its GIN
-- index to the CONSUMER's table -- so TEXT works on a corpus this layer does
-- not own, which is the whole point of registering one by name.
-- ------------------------------------------------------------
select aiq.register_lexical_source('chunks', 'content.resource_chunks', 'content', 'english');

insert into aiq.semantic_sources (name, source_table, content_col, embedding_col)
values ('chunks', 'content.resource_chunks', 'content', 'embedding')
on conflict (name) do update set source_table = excluded.source_table;

-- provider NULL, not 'fixture'. These vectors are written by hand below; there
-- is no service that produces them, and saying so is what the null means. The
-- old spelling invented a provider name to satisfy a NOT NULL, which nothing
-- could have resolved -- found the moment embedding_models.provider gained a
-- foreign key onto embedding_providers.
insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes) values
    ('demo-quad-a', 4, null, 'vector_cosine_ops', true,
     'four literal dimensions, not a model. See dev/init/05-corpus-sample.sql.'),
    ('demo-quad-b', 4, null, 'vector_cosine_ops', false,
     'the same four dimensions, a DIFFERENT space -- two models of equal size '
     'whose vectors are not comparable, which is schema.sql §10''s whole point.')
on conflict (name) do update set dim = excluded.dim, provider = excluded.provider,
    distance_op = excluded.distance_op, notes = excluded.notes;

select aiq.register_embedding_space('demo-quad-a');
select aiq.register_embedding_space('demo-quad-b');

-- ------------------------------------------------------------
-- 4. The vectors.
--
-- Cosine distance, so only DIRECTION matters. The probe used throughout the
-- tests is [1,0,0,0].
--
-- Space A -- "meaning" axis. The probe points at the recall story, so c1 and
-- c2 (which share a meaning and no words) are near it and the finance chunk is
-- orthogonal:
--     c1 [1,0,0,0]      distance 0.0   -- exactly the probe
--     c2 [0.8,0.6,0,0]  distance 0.2
--     c4 [0.6,0.8,0,0]  distance 0.4   -- org A, same story
--     c6 [0,1,0,0]      distance 1.0   -- orthogonal
--     c3 [0,0,1,0]      distance 1.0
--     c5 [0,0,0,1]      distance 1.0
--
-- Space B -- the SAME six chunks, the SAME dimension, a different arrangement.
-- The identical probe now lands on the finance chunk. Nothing about the vector
-- says which space it belongs to, which is precisely why the model names the
-- space and the dimension cannot.
--     c3 [1,0,0,0]      distance 0.0
--     c6 [0.8,0.6,0,0]  distance 0.2
--     c1 [0,1,0,0]      distance 1.0
-- ------------------------------------------------------------
insert into aiq.emb_demo_quad_a (chunk_id, embedding) values
    ('33330000-0000-0000-0000-000000000001','[1,0,0,0]'),
    ('33330000-0000-0000-0000-000000000002','[0.8,0.6,0,0]'),
    ('33330000-0000-0000-0000-000000000003','[0,0,1,0]'),
    ('33330000-0000-0000-0000-000000000004','[0.6,0.8,0,0]'),
    ('33330000-0000-0000-0000-000000000005','[0,0,0,1]'),
    ('33330000-0000-0000-0000-000000000006','[0,1,0,0]')
on conflict (chunk_id) do update set embedding = excluded.embedding;

-- Deliberately NOT the same six: c5 has no vector in space B. A chunk is
-- embedded in a space or it is not, and "migrate models by embedding into the
-- new space alongside the old" (§10) means partial coverage is the normal
-- state during a migration, not an error.
insert into aiq.emb_demo_quad_b (chunk_id, embedding) values
    ('33330000-0000-0000-0000-000000000003','[1,0,0,0]'),
    ('33330000-0000-0000-0000-000000000006','[0.8,0.6,0,0]'),
    ('33330000-0000-0000-0000-000000000001','[0,1,0,0]'),
    ('33330000-0000-0000-0000-000000000002','[0,0,1,0]'),
    ('33330000-0000-0000-0000-000000000004','[0,0,0,1]')
on conflict (chunk_id) do update set embedding = excluded.embedding;

-- ------------------------------------------------------------
-- 5. Grants. Same reasoning as the graph sample: the query functions are
--    SECURITY INVOKER, so a caller needs real access to the consumer's tables,
--    and integration-rbac.sql §3b is explicit that the aiq schema must not
--    reach into a consumer schema and decide who may read it.
--
--    content's own RLS is left exactly as the content plane defines it --
--    resources are org-scoped, chunks inherit from their resource -- because
--    the tenancy assertions in dev/tests/query/09 are about whether the
--    RETRIEVAL modes respect a consumer's policy, and rewriting that policy
--    here would make them assert against a fixture instead of a system.
-- ------------------------------------------------------------
grant usage on schema content to authenticated, api_viewer;
grant select on content.resources, content.resource_chunks, content.channels
    to authenticated, api_viewer;

do $$
begin
    raise notice 'corpus sample: % chunks (% shared, % org-scoped), % in space A, % in space B',
        (select count(*) from content.resource_chunks),
        (select count(*) from content.resource_chunks c
          join content.resources r on r.id = c.resource_id
          where r.org_id = rbac.shared_org_id()),
        (select count(*) from content.resource_chunks c
          join content.resources r on r.id = c.resource_id
          where r.org_id <> rbac.shared_org_id()),
        (select count(*) from aiq.emb_demo_quad_a),
        (select count(*) from aiq.emb_demo_quad_b);
end $$;

reset role;
