-- RESOLUTION, EDGE STANDING AND THE CATALOGUE -- the surface that arrived from
-- an application and had, until this file, only that application's tests.
--
-- That is the gap worth naming. `aiq.resolve_mention` and the rest shipped in
-- core with their assertions living in `applications/percolate-self-model/
-- tests.sql`, which is a file core does not run and a directory core does not
-- require. Delete the application and the extension keeps the code and loses
-- every check on it.
--
-- The characteristic failure on this surface is the one dev/tests/README.md
-- names for the whole query layer: not a crash, a WRONG ANSWER. A resolver that
-- confidently returns the wrong node, a view that reports an edge as unused
-- when it has answered a hundred questions, a catalogue that says a view
-- depends on things it has never read.
\set ON_ERROR_STOP on
begin;

-- A fixture of our own, because these assertions are about behaviour at
-- boundaries -- one match, two matches, no matches, a short name, a degree-1
-- node -- and no shared sample contains all of those on purpose.
create schema if not exists t14;
create table t14.things (id uuid primary key default gen_random_uuid(), key text);
insert into t14.things (key) values
    ('t14.alphakey'), ('t14.betakey'), ('other.betakey'), ('ab'), ('t14/gamma.sql');
-- The names are long enough to clear the entropy gate on purpose. The first
-- draft used `alpha` and `beta`, which are five and four characters, and the
-- suffix assertions failed with `escalate:low-entropy` -- correctly, because
-- the gate sits in front of the guessing steps. A fixture that cannot reach
-- the code under test is the oldest way to write a passing test of nothing.
select aiq.register_entity_table('t14_thing', 't14.things', 'n.key');
select aiq.rebuild_entity_type('t14_thing');

-- ------------------------------------------------------------------
-- 1. EXACT WINS AT ANY LENGTH, and the entropy gate does not apply to it.
--    `ab` is two characters and would fail has_high_entropy; an exact match is
--    an identity, not a guess, so it must resolve anyway. Getting this wrong
--    makes every short key in a registry unreachable by its own name.
-- ------------------------------------------------------------------
do $$
declare m text;
begin
    select method into m from aiq.resolve_mention('ab', 't14_thing') limit 1;
    if m is distinct from 'exact' then
        raise exception 'a two-character EXACT key resolved as %, not exact', m;
    end if;
end $$;

-- ------------------------------------------------------------------
-- 2. THE DROPPED QUALIFICATION resolves, and to the right node -- and 3. the
--    gate DOES cover it, because a suffix match is a guess that a qualifier
--    was dropped rather than an identity.
-- ------------------------------------------------------------------
do $$
declare m text; k text;
begin
    select method, matched_key into m, k
      from aiq.resolve_mention('alphakey', 't14_thing') limit 1;
    if m is distinct from 'suffix' or k is distinct from 't14.alphakey' then
        raise exception 'a dropped qualification gave % / %, wanted suffix / t14.alphakey', m, k;
    end if;

    -- `beta` is the last segment of BOTH t14.betakey and other.betakey. Two
    -- candidates is a question a similarity score cannot answer, and reporting
    -- it as absent asks a model the wrong one.
    select method into m from aiq.resolve_mention('betakey', 't14_thing') limit 1;
    if m is distinct from 'escalate:ambiguous' then
        raise exception 'two suffix candidates reported %, not ambiguous', m;
    end if;
end $$;

-- ------------------------------------------------------------------
-- 4. THE SEPARATORS ARE A PARAMETER. `.` and `/` are what this extension
--    writes; they are not what qualification IS. A caller whose keys are
--    qualified with `::` must be able to say so.
-- ------------------------------------------------------------------
do $$
declare m text;
begin
    insert into t14.things (key) values ('pkg::deltakey');
    perform aiq.rebuild_entity_type('t14_thing');

    select method into m from aiq.resolve_mention('deltakey', 't14_thing') limit 1;
    -- `is not distinct from`, not `=`. resolve_mention always returns a row, so
    -- m cannot be NULL here -- but `if NULL then` does not fire, so an `=` that
    -- relies on that is an assertion which stops working the moment the
    -- function it tests stops answering. dev/assertion-audit.py caught this
    -- one in this very file.
    if m is not distinct from 'suffix' then
        raise exception '`::` was treated as a separator by default; the default set is . and /';
    end if;

    select method into m
      from aiq.resolve_mention('deltakey', 't14_thing', 0.62, array['::']) limit 1;
    if m is distinct from 'suffix' then
        raise exception 'the separator parameter was ignored: got % with :: passed', m;
    end if;
end $$;

-- ------------------------------------------------------------------
-- 5. THE ENTROPY THRESHOLDS ARE PARAMETERS, for the same reason: 1.5 and 6
--    were measured against somebody else's corpus.
-- ------------------------------------------------------------------
do $$
begin
    -- `rep` is three characters and one word, so the length arm refuses it
    -- without ever computing an entropy. `report` would NOT do here: it is six
    -- characters, clears the length arm, and its entropy is 2.25 -- which the
    -- first draft of this assertion got wrong, and the test said so.
    if aiq.has_high_entropy('rep') then
        raise exception 'a three-character single word passed the default gate';
    end if;
    if not aiq.has_high_entropy('rep', 1.5, 3) then
        raise exception 'the minimum-length parameter was ignored';
    end if;
    if aiq.has_high_entropy('abcdefgh', 99.0) then
        raise exception 'the entropy-threshold parameter was ignored';
    end if;
end $$;

-- ------------------------------------------------------------------
-- 6. STANDING DISTINGUISHES NEVER USED FROM LOAD-BEARING, and `neighbours`
--    is what moves an edge between them. An edge that answers questions is a
--    different object from one that merely still holds, and consolidation that
--    cannot tell them apart deletes the wrong one.
-- ------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; v_e uuid; v_standing text; v_recall bigint; v_probe bigint;
begin
    select node_id into v_a from aiq.node_keys where key = 't14.alphakey';
    select node_id into v_b from aiq.node_keys where key = 't14.betakey';
    insert into aiq.relation_types (src_type, relation, dst_type, description)
         values ('t14_thing','t14_links','t14_thing','fixture relation')
      on conflict do nothing;
    perform aiq.register_graph_vocabulary();
    insert into aiq.edges (src_id, dst_id, relation, weight)
         values (v_a, v_b, 't14_links', 1.0) returning id into v_e;

    select standing into v_standing from aiq.edge_standing where id = v_e;
    if v_standing is distinct from 'never used' then
        raise exception 'a brand new edge has standing %, wanted never used', v_standing;
    end if;

    -- a PROBE must not make it look used
    perform aiq.neighbours('t14.alphakey', true);
    select recall_count, probe_count into v_recall, v_probe from aiq.edges where id = v_e;
    if v_recall is distinct from 0::bigint then
        raise exception 'a probe left recall_count at %, wanted 0 -- a NULL here '
                        'means the edge row vanished, which is also a failure',
                        coalesce(v_recall::text, 'NULL');
    end if;
    if v_probe = 0 then
        raise exception 'a probe did not increment probe_count';
    end if;
    select standing into v_standing from aiq.edge_standing where id = v_e;
    if v_standing is distinct from 'only ever probed' then
        raise exception 'after a probe the standing is %, wanted only ever probed', v_standing;
    end if;

    -- and a real read must
    perform aiq.neighbours('t14.alphakey');
    select standing into v_standing from aiq.edge_standing where id = v_e;
    if v_standing is distinct from 'load-bearing' then
        raise exception 'after a real read the standing is %, wanted load-bearing', v_standing;
    end if;
end $$;

-- ------------------------------------------------------------------
-- 7. DEGREE ONE CANNOT BE RULED ON. The disparity null has no variance when a
--    node has a single incident edge, so alpha is 1 by construction. NULL says
--    "no evidence either way"; a number would say "evidence of no effect", and
--    only one of those is true.
-- ------------------------------------------------------------------
do $$
declare v_alpha numeric; v_k int;
begin
    select alpha_src, k_src into v_alpha, v_k from aiq.edge_disparity
     where relation = 't14_links' limit 1;
    if v_k <> 1 then
        raise exception 'the fixture edge has degree % at src, expected 1', v_k;
    end if;
    if v_alpha is not null then
        raise exception 'degree 1 returned alpha %, expected null', v_alpha;
    end if;
end $$;

-- ------------------------------------------------------------------
-- 8. THE ESTIMATOR IS A BETA POSTERIOR MEAN, and its prior is a parameter.
--    No observations must give the prior and not certainty.
-- ------------------------------------------------------------------
do $$
begin
    if aiq.reliability(0, 0) <> 0.5 then
        raise exception 'no observations gave %, wanted the 0.5 prior', aiq.reliability(0,0);
    end if;
    if aiq.reliability(1, 0) <> round(2.0/3.0, 4) then
        raise exception 'Laplace on one confirmation gave %', aiq.reliability(1,0);
    end if;
    if aiq.reliability(1, 0, 0.5, 0.5) <> 0.75 then
        raise exception 'the prior parameters were ignored: Jeffreys gave %',
                        aiq.reliability(1,0,0.5,0.5);
    end if;
end $$;

-- ------------------------------------------------------------------
-- 9. THE VIEWS ARE SECURITY INVOKER, asserted on the catalogue rather than by
--    reading rows, because this instance may hold one org's data and a tenancy
--    property that holds only because the data is single-tenant is not a
--    property.
--
--    A view runs as its OWNER by default; app_owner owns aiq.edges and is not
--    subject to its RLS, so a view left on the default hands every org's edges
--    to any caller granted select on it.
-- ------------------------------------------------------------------
do $$
declare v text; bad text[] := '{}';
begin
    foreach v in array array['edge_standing','edge_disparity','source_reliability'] loop
        if coalesce((select option_value from pg_class c,
                            pg_options_to_table(c.reloptions)
                      where c.relname = v and c.relnamespace = 'aiq'::regnamespace
                        and option_name = 'security_invoker'), 'false') <> 'true' then
            bad := bad || v;
        end if;
    end loop;
    if array_length(bad, 1) > 0 then
        raise exception 'these views run as their owner and bypass the caller''s RLS: %',
                        array_to_string(bad, ', ');
    end if;
end $$;

-- ------------------------------------------------------------------
-- 10. THE CATALOGUE IS OPT-IN, IDEMPOTENT, AND DOES NOT INVENT DEPENDENCIES.
--
--     The last clause is a regression test. A column row carries its TABLE's
--     oid, so a dependency join over `any(oids)` matches every column of a
--     table as well as the table: 33,272 of 37,145 dependency edges in the
--     corpus this was found on pointed at a column, which is ninety per cent
--     of the graph being an artefact of how columns are keyed.
-- ------------------------------------------------------------------
do $$
declare n1 int; n2 int; bad int;
begin
    perform aiq.refresh_catalogue(array['aiq']);
    select count(*) into n1 from aiq.db_objects;
    if n1 = 0 then
        raise exception 'refresh_catalogue populated nothing for schema aiq';
    end if;

    -- CONVERGENCE, NOT IDEMPOTENCE, and the difference is a real property
    -- rather than a weakened assertion. Registering the entity type creates
    -- two functions in `aiq` -- the projection triggers register_entity_table
    -- writes -- so the FIRST call changes the schema it is cataloguing and the
    -- second sees two more objects than the first. It is stable from there:
    -- 346, 348, 348, 348. Cataloguing a schema that the cataloguing extends is
    -- self-referential, and the honest assertion is that it settles.
    perform aiq.refresh_catalogue(array['aiq']);
    select count(*) into n1 from aiq.db_objects;
    perform aiq.refresh_catalogue(array['aiq']);
    select count(*) into n2 from aiq.db_objects;
    if n1 <> n2 then
        raise exception 'refresh_catalogue does not settle: % objects became % on '
                        'the third and fourth calls', n1, n2;
    end if;

    select count(*) into bad
      from aiq.edges e
      join aiq.nodes n  on n.id = e.dst_id and n.entity_type = 'db_object'
      join aiq.db_objects o on o.id = n.entity_id
     where e.relation = 'depends_on' and o.kind not in ('table','view','matview');
    if bad > 0 then
        raise exception '% dependency edges point at something that is not a relation '
                        '-- a column row carries its table''s oid and the join matched it', bad;
    end if;
end $$;

rollback;
