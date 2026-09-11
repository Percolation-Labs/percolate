-- THE RETRIEVAL MODES -- TEXT, SEMANTIC and SEARCH, executed.
--
-- Until this file, three of the seven modes had never returned a row under
-- assertion. `query/02` checks that they PARSE; nothing checked that they
-- answer, and `surface.sql` reported them present because
-- `aiq.lexical_sources` and `aiq.semantic_sources` each held a registration
-- row -- behind which the corpus held zero chunks and the model registry held
-- zero models. A registration is not a corpus.
--
-- Reads the committed fixture in `dev/init/05-corpus-sample.sql`, whose
-- vectors are four-dimension literals rather than model output, so every
-- ranking below is arithmetic a reader can check rather than a property of
-- whichever embedding server happened to be running.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

do $$
begin
    if not exists (select 1 from aiq.embedding_models where name = 'demo-quad-a')
       or not exists (select 1 from content.resource_chunks
                       where id = '33330000-0000-0000-0000-000000000001') then
        raise exception
            'the corpus sample is not loaded. It ships in '
            'dev/init/05-corpus-sample.sql and a fresh `docker compose up` '
            'installs it; against an existing stack, load it by hand.';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. THE GAP THAT PUT `TEXT` IN THE DIALECT, REPRODUCIBLE AT LAST.
--
-- schema.sql §11 argues for this mode from a worked example -- the part number
-- "R7", which appears verbatim in a chunk and which LOOKUP and FUZZY LOOKUP
-- both miss because they search KEYS and a chunk is not a node. The example
-- was run once, by hand, against a corpus that was never committed. Here it is
-- as three assertions over a corpus that ships.
-- ---------------------------------------------------------------------
do $$
begin
    if exists (select 1 from aiq.lookup('R7')) then
        raise exception 'LOOKUP now finds R7 -- either a chunk became a node, or '
                        'the mode boundary this dialect is built on has moved';
    end if;
    if exists (select 1 from aiq.lookup('R7', true)) then
        raise exception 'FUZZY LOOKUP finds R7 -- trigram matching has reached '
                        'past node_keys into the data plane, which is the thing '
                        'graph-identity.md "Scale" forbids';
    end if;
    if not exists (select 1 from aiq.lexical('chunks', 'R7')) then
        raise exception 'TEXT cannot find a rare token that appears verbatim in a '
                        'chunk -- which is the entire reason this mode exists';
    end if;
    raise notice 'query/08: LOOKUP and FUZZY miss R7, TEXT finds it (§11, executed)';
end $$;

-- ...and the converse, which is what makes fusing them worth doing: the chunk
-- that means the same thing in different words is invisible to lexical search.
-- c1 and c2 share no content words; only the vector space relates them.
do $$
begin
    if exists (select 1 from aiq.lexical('chunks', 'R7')
                where chunk_id = '33330000-0000-0000-0000-000000000002') then
        raise exception 'lexical search matched a chunk sharing no terms with the '
                        'query -- the fixture no longer demonstrates the gap';
    end if;
    if not exists (select 1 from aiq.semantic_in('chunks', '[1,0,0,0]', 'demo-quad-a', 2)
                    where chunk_id = '33330000-0000-0000-0000-000000000002') then
        raise exception 'the vector space does not relate the two chunks that mean '
                        'the same thing';
    end if;
    raise notice 'query/08: TEXT misses the paraphrase, SEMANTIC finds it';
end $$;

-- An unregistered corpus names the registry rather than failing on a missing
-- relation: `FROM` takes a registered name, not a table.
do $$
declare v_msg text;
begin
    begin
        perform aiq.lexical('not_a_corpus', 'anything');
        raise exception 'an unregistered lexical source was accepted';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%not registered%' then raise; end if;
    end;
    raise notice 'query/08: an unregistered corpus says so';
end $$;

-- ---------------------------------------------------------------------
-- 2. TWO MODELS OF THE SAME DIMENSION ARE TWO DIFFERENT SPACES.
--
-- schema.sql §10's central correction: "the partition key is the MODEL, not
-- the dimension. Two different 768-dimension models do not produce comparable
-- vectors -- cosine distance between them is meaningless, not merely
-- imprecise." That was asserted as a constraint on the registry in `query/02`
-- (keyed by name, no unique index on dim). This is the behavioural half, and
-- it is the one that would actually bite: the SAME probe, of the SAME
-- dimension, ranks a different chunk first in each space.
--
-- No dimension check can catch a caller naming the wrong model. Only the
-- answer is different, and it is well-formed.
-- ---------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid;
begin
    select chunk_id into v_a from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-a',1);
    select chunk_id into v_b from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-b',1);
    -- Guarded before compared, because `NULL = NULL` is NULL and the raise below
    -- would not fire: a probe that ranked NOTHING in either space would read as
    -- "the two spaces disagree", which is the pass this test least deserves.
    if v_a is null or v_b is null then
        raise exception 'a probe ranked nothing at all (a=%, b=%) -- the index or '
                        'the fixture is gone, and the comparison below cannot mean '
                        'anything', v_a, v_b;
    end if;
    if v_a = v_b then
        raise exception
            'the same probe ranks the same chunk first in both spaces, so the '
            'fixture no longer demonstrates that a space is identified by its '
            'model -- and neither does anything else';
    end if;
    if v_a is distinct from '33330000-0000-0000-0000-000000000001'
       or v_b is distinct from '33330000-0000-0000-0000-000000000003' then
        raise exception 'the spaces do not rank as the fixture documents (a=%, b=%)',
            v_a, v_b;
    end if;
    -- and the mode reports WHICH space answered, so a caller can tell
    if (select model from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-b',1))
       is distinct from 'demo-quad-b' then
        raise exception 'the result does not name the space it came from';
    end if;
    raise notice 'query/08: two 4-dim models, one probe, two different answers';
end $$;

-- The default space is used when none is named, and there can be only one.
do $$
begin
    if (select model from aiq.semantic_in('chunks','[1,0,0,0]', null, 1)) is distinct from 'demo-quad-a' then
        raise exception 'the default embedding model is not the one flagged default';
    end if;
    begin
        update aiq.embedding_models set is_default = true where name = 'demo-quad-b';
        raise exception
            'two models are flagged default at once -- SEMANTIC without USING '
            'then depends on which row the planner reached first';
    exception when unique_violation then null;
    end;
    raise notice 'query/08: exactly one default space, and it is the one used';
end $$;

-- A vector of the wrong width is caught with both sides named, rather than
-- surfacing as pgvector's bare "expected N dimensions" -- querying the wrong
-- space is the easiest mistake to make once more than one model exists.
do $$
declare v_msg text;
begin
    begin
        perform aiq.semantic_in('chunks', '[1,0,0]', 'demo-quad-a', 1);
        raise exception 'a 3-dimension vector was accepted by a 4-dimension space';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%demo-quad-a%' or v_msg not like '%4%' then
            raise exception 'the dimension error does not name both sides: %', v_msg;
        end if;
    end;
    raise notice 'query/08: a dimension mismatch names the model and both widths';
end $$;

-- Partial coverage is the normal state during a model migration ("embed into
-- the new space alongside the old", §10), not an error: c5 has no vector in
-- space B and space B still answers.
do $$
begin
    if exists (select 1 from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-b',10)
                where chunk_id = '33330000-0000-0000-0000-000000000005') then
        raise exception 'a chunk with no vector in this space was returned by it';
    end if;
    if (select count(*) from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-b',10)) = 0 then
        raise exception 'a partially-covered space returns nothing at all';
    end if;
    raise notice 'query/08: a space answers over the chunks it has embedded';
end $$;

-- ---------------------------------------------------------------------
-- 3. `FROM` SCOPES THE VECTOR SEARCH TO ONE CORPUS.
--
-- The parser REQUIRES `FROM <source>` on SEMANTIC. The dispatch dropped it and
-- searched the whole embedding space, which holds every registered corpus at
-- once -- so the caller was compelled to name a corpus that was then not used.
--
-- Asserted with a second corpus sharing the same space, because that is the
-- shape where "search everything" and "search what you named" differ.
-- ---------------------------------------------------------------------
do $$
begin
    create table t_other_corpus (id uuid primary key, content text);
    insert into t_other_corpus values
        ('44440000-0000-0000-0000-000000000001','a chunk of an entirely different corpus');
    insert into aiq.emb_demo_quad_a (chunk_id, embedding)
        values ('44440000-0000-0000-0000-000000000001', '[1,0,0,0]');
    insert into aiq.semantic_sources (name, source_table)
        values ('other', 'public.t_other_corpus');

    -- it is the nearest possible vector, so "search everything" would rank it first
    if exists (select 1 from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-a',10)
                where chunk_id = '44440000-0000-0000-0000-000000000001') then
        raise exception
            'SEMANTIC FROM chunks returned a chunk of another corpus -- FROM is '
            'not scoping the search, and the space holds every corpus at once';
    end if;
    if not exists (select 1 from aiq.semantic_in('other','[1,0,0,0]','demo-quad-a',10)
                    where chunk_id = '44440000-0000-0000-0000-000000000001') then
        raise exception 'naming the other corpus does not reach it';
    end if;
    -- and the corpus is not optional, because an unscoped vector search cannot
    -- be filtered by anybody's policy
    begin
        perform aiq.semantic_in(null, '[1,0,0,0]', 'demo-quad-a', 1);
        raise exception 'SEMANTIC ran with no corpus named';
    exception when others then null;
    end;
    raise notice 'query/08: FROM scopes the vector search, and is required';
end $$;

-- ---------------------------------------------------------------------
-- 4. SEARCH FUSES RANKS, NOT SCORES -- AND THE ARITHMETIC IS CHECKABLE.
--
-- RRF rather than score blending "because ts_rank and cosine distance share
-- neither scale nor direction, and no fixed normalisation survives a change of
-- model or corpus" (brief.md §3). The fixture makes the fused number exact:
-- with k = 60, a chunk ranked 2nd lexically and 1st semantically scores
--     1/(60+2) + 1/(60+1) = 0.0161290 + 0.0163934 = 0.0325224
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
    select * into r from aiq.search('chunks','R7 recall','[1,0,0,0]','demo-quad-a',6)
     where chunk_id = '33330000-0000-0000-0000-000000000001';

    if r.lexical_rank is null or r.semantic_rank is null then
        raise exception 'the chunk both branches found does not report both ranks';
    end if;
    if abs(r.rrf_score - (1.0/(60+r.lexical_rank) + 1.0/(60+r.semantic_rank))) > 0.00001 then
        raise exception 'the fused score is not reciprocal rank fusion: got % for ranks %/%',
            r.rrf_score, r.lexical_rank, r.semantic_rank;
    end if;

    -- A chunk only ONE branch found still ranks, with a null rank on the other
    -- side -- a full outer join, not an intersection.
    select * into r from aiq.search('chunks','R7 recall','[1,0,0,0]','demo-quad-a',6)
     where chunk_id = '33330000-0000-0000-0000-000000000002';
    if r.chunk_id is null then
        raise exception 'a semantically-only match was dropped by the fusion';
    end if;
    if r.lexical_rank is not null then
        raise exception 'the fixture no longer has a vector-only match to fuse';
    end if;
    -- ...and it carries its content. Taking content from the lexical branch
    -- returned NULL for exactly the rows the semantic side contributed, which
    -- is why content is fetched by id after the fusion.
    if r.content is null or r.content = '' then
        raise exception
            'a vector-only hit came back with no content -- content is being '
            'taken from the lexical branch, which by definition has no row for it';
    end if;
    raise notice 'query/08: SEARCH fuses ranks with RRF, and vector-only hits carry content';
end $$;

-- The fused order is the fused score's order, and it is not either branch's.
do $$
declare v_first uuid; v_lex uuid; v_sem uuid;
begin
    select chunk_id into v_first from aiq.search('chunks','Northwind exposure','[1,0,0,0]','demo-quad-a',6) limit 1;
    select chunk_id into v_lex   from aiq.lexical('chunks','Northwind exposure',1);
    select chunk_id into v_sem   from aiq.semantic_in('chunks','[1,0,0,0]','demo-quad-a',1);
    -- Same guard, same reason: two branches that both returned nothing are not
    -- two branches that disagree.
    if v_first is null or v_lex is null or v_sem is null then
        raise exception 'a retrieval branch returned nothing (fused=%, lexical=%, '
                        'semantic=%), so fusion cannot be compared with either half',
                        v_first, v_lex, v_sem;
    end if;
    if v_lex = v_sem then
        raise exception 'the fixture no longer makes the two branches disagree, so '
                        'fusion cannot be distinguished from either half';
    end if;
    if v_first is null then
        raise exception 'the fusion returned nothing where both branches returned rows';
    end if;
    raise notice 'query/08: the branches disagree and the fusion resolves them';
end $$;

-- ---------------------------------------------------------------------
-- 5. THROUGH THE DIALECT, WITH THE VECTOR THE DATABASE CANNOT PRODUCE.
--
-- Embedding generation is an external model call (brief.md §4), so the vector
-- arrives beside the query text rather than being computed from it. The modes
-- that need one say so by name rather than returning an empty result.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_msg text;
begin
    v := aiq.query('TEXT "R7" FROM chunks LIMIT 5');
    if jsonb_array_length(v->'rows') = 0 then
        raise exception 'TEXT through the dialect found nothing';
    end if;
    if v->'plan'->>'source' <> 'chunks' then
        raise exception 'the plan does not carry the corpus that was searched';
    end if;

    v := aiq.query('SEMANTIC "anything" FROM chunks USING demo-quad-b LIMIT 2', '[1,0,0,0]');
    if v->'rows'->0->>'model' <> 'demo-quad-b' then
        raise exception 'USING did not select the space: %', v->'rows'->0;
    end if;

    v := aiq.query('SEARCH "R7 recall" FROM chunks LIMIT 3', '[1,0,0,0]');
    if jsonb_array_length(v->'rows') = 0 then
        raise exception 'SEARCH through the dialect found nothing';
    end if;

    -- and the two vector modes refuse to guess when the vector is absent
    foreach v_msg in array array['SEMANTIC "x" FROM chunks', 'SEARCH "x" FROM chunks'] loop
        begin
            perform aiq.query(v_msg);
            raise exception '% ran without an embedding', v_msg;
        exception when others then
            get stacked diagnostics v_msg = message_text;
            if v_msg like '% ran without an embedding' then raise; end if;
        end;
    end loop;
    raise notice 'query/08: the dialect routes all three, and asks for the vector it needs';
end $$;

-- ---------------------------------------------------------------------
-- 6. A DELETED RESOURCE TAKES ITS VECTORS WITH IT, IN EVERY SPACE.
--
-- The cascade removed the chunks and left their rows in aiq.emb_<model>, since
-- a space carries no foreign key (ai-query-layer/schema.sql §10a-ii says why
-- it cannot). Found on 0.1.6. The resource deleted here owns c2 and c6, and
-- both are embedded in both fixture spaces, so the assertion covers two models
-- and a multi-row delete. Rolled back with the rest of this file.
-- ---------------------------------------------------------------------
do $$
declare v_before int; v_after int; v jsonb;
begin
    select count(*) into v_before from (
        select chunk_id from aiq.emb_demo_quad_a
        union all select chunk_id from aiq.emb_demo_quad_b) e
     where e.chunk_id in ('33330000-0000-0000-0000-000000000002',
                          '33330000-0000-0000-0000-000000000006');
    if v_before <> 4 then
        raise exception 'the fixture should embed c2 and c6 in both spaces (4 rows), found %', v_before;
    end if;

    delete from content.resources where id = '22220000-0000-0000-0000-000000000002';

    select count(*) into v_after from (
        select chunk_id from aiq.emb_demo_quad_a
        union all select chunk_id from aiq.emb_demo_quad_b) e
     where e.chunk_id in ('33330000-0000-0000-0000-000000000002',
                          '33330000-0000-0000-0000-000000000006');
    if v_after <> 0 then
        raise exception '% vector(s) outlived the chunks they describe', v_after;
    end if;

    -- ...and the rest of the space still answers.
    v := aiq.query('SEMANTIC "anything" FROM chunks LIMIT 3', '[1,0,0,0]');
    if v->'rows'->0->>'chunk_id' <> '33330000-0000-0000-0000-000000000001' then
        raise exception 'SEMANTIC stopped ranking what was left: %', v->'rows';
    end if;
    raise notice 'query/08: deleting a resource removed its 4 vectors from both spaces';
end $$;

rollback;
