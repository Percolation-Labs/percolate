-- GRAPH SURFACE, part 6 -- what "an edge holds" means, on every read path.
--
-- Three defects with one shape: a rule about edges written in several places,
-- and the places disagreeing.
--
--   REM-51  "does this edge hold now" had four spellings, and graph_neighbors,
--           graph_walk, the (since removed) property graph and the compiled traversals used
--           none -- so a retracted edge went on answering. A rename made with
--           the projection triggers off survived the rebuild meant to repair
--           it, because the rebuild carried its own copy of the projection.
--   REM-65  a retraction later undone vanished: one row per triple holds one
--           interval, so an as-of read inside the retraction saw the edge.
--   REM-60  "withdraw what this derivation owns" was scoped by relation name,
--           so one package's refresh retracted another package's edges.
--
-- And the tenancy defect found while fixing the first: aiq.edges_current and
-- aiq.node_current ran as their owner and bypassed RLS (§3).
--
-- Reads the committed sample (`dev/init/04-graph-sample.sql`). Every section
-- writes inside the one transaction and the file rolls back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

do $$
begin
    if not exists (select 1 from aiq.entity_registry where entity_type = 'company'
                    and source_table = 'demo.companies') then
        raise exception 'the graph sample is not loaded (dev/init/04-graph-sample.sql)';
    end if;
    if to_regprocedure('p8_graph_paths(uuid,uuid,int,int,int,bool,text,bigint)') is null then
        raise exception 'the installed percolate_parser does not declare the graph '
            'algorithms; §1 and §4 are about them (see query/11''s preamble)';
    end if;
end $$;

-- A small helper for the rest of the file: the id of the one edge between two
-- canonical keys on a relation, whatever its validity.
create function pg_temp.edge_id(p_src text, p_dst text, p_rel text) returns uuid
language sql as $$
    select e.id from aiq.edges e
      join aiq.node_keys s on s.node_id = e.src_id and s.key = p_src and s.kind = 'canonical'
      join aiq.node_keys d on d.node_id = e.dst_id and d.key = p_dst and d.kind = 'canonical'
     where e.relation = p_rel
$$;

-- ---------------------------------------------------------------------
-- WHETHER THE COMPILED HALF IS CURRENT. Section 1 asserts one property over
-- eight read paths, and four of them run in Rust -- so against an image whose
-- .so predates the schema, half this section fails for a reason that is not
-- this commit's. Deferring the whole FILE would stand down sections 2 to 5,
-- which are pure SQL and have nothing to do with the parser; so the four
-- compiled assertions defer one at a time and say so. run.sh counts every
-- DEFERRED: notice, reports it beside the skips, and refuses it outright once
-- the two halves agree -- which is what keeps this from being a mute.
--
-- TWO QUESTIONS, AND THE VERSION ANSWERS ONLY THE FIRST (REM-139). Whether the
-- .so is from a different RELEASE than the schema, pg_extension can say. Whether
-- it is from a different COMMIT of the same unreleased release, it cannot: one
-- 0.2.0 is compiled from many commits, so both halves read 0.2.0 while the .so
-- predates the very fix these assertions cover. Measured 2026-09-12 -- the .so
-- was dated 2026-09-11T12:00:20Z and `2d54769` landed ten hours after it, and
-- section 1 reported the graph wrong on a database built from origin/main.
--
-- A test file cannot see that for itself: it may read pg_extension, which is the
-- label that provably does not move, and it may not stat a file or read a git
-- log. So `dev/tests/run.sh` compares the .so's mtime to the newest commit
-- touching extension/percolate_parser/ and passes the verdict in as
-- `percolate.parser_behind`. `yes` stands these assertions down.
--
-- UNKNOWN ASSERTS, deliberately. A DSN run cannot stat the .so and a direct
-- psql sets no GUC at all, so both arrive here as absent -- and absent behaves
-- exactly as this file behaved before, which is the property that keeps the
-- change from turning a real red green anywhere the evidence is missing. The
-- banner says which of the two you got.
create or replace function pg_temp.parser_current() returns boolean language sql stable as $$
    select coalesce((select p.extversion = c.extversion
                       from pg_catalog.pg_extension p, pg_catalog.pg_extension c
                      where p.extname = 'percolate_parser' and c.extname = 'percolate'), false)
       and coalesce(current_setting('percolate.parser_behind', true), 'absent') <> 'yes';
$$;

-- 1. A RETRACTED EDGE STOPS ANSWERING, ON EVERY READ PATH (REM-51).
--
-- acme -competes_with-> ndlr is retracted a minute ago. Each path below
-- returned it before the fix; aiq.edges_current was the only one that did not.
-- An as-of read from before the retraction still sees it, because retraction
-- is history and not deletion.
-- ---------------------------------------------------------------------
do $$
declare
    v_edge uuid := pg_temp.edge_id('acme', 'ndlr', 'competes_with');
    v_acme uuid; v_ndlr uuid; n int; v jsonb;
begin
    if v_edge is null then
        raise exception 'the fixture no longer has acme -competes_with-> ndlr';
    end if;
    select node_id into v_acme from aiq.lookup('acme');
    select node_id into v_ndlr from aiq.lookup('ndlr');
    -- BOTH ENDS SET EXPLICITLY. The assertion at the end reads the graph as of
    -- before the retraction, and "before" has to be inside the edge's own
    -- validity: dated only by `valid_to`, it depended on how long ago the
    -- fixture happened to be loaded, which is minutes on a fresh database.
    update aiq.edges
       set valid_from = now() - interval '2 days', valid_to = now() - interval '1 day'
     where id = v_edge;
    perform aiq.graph_snapshot(true);

    select count(*) into n from aiq.graph_neighbors(v_acme, 'competes_with') g where g.neighbor_id = v_ndlr;
    if n <> 0 then raise exception 'graph_neighbors (out) returned a retracted edge'; end if;
    select count(*) into n from aiq.graph_neighbors(v_ndlr) g where g.neighbor_id = v_acme and g.direction = 'in';
    if n <> 0 then raise exception 'graph_neighbors (in) returned a retracted edge'; end if;
    select count(*) into n from aiq.graph_walk(v_acme, 1, 'competes_with') w where w.node_id = v_ndlr;
    if n <> 0 then raise exception 'graph_walk crossed a retracted edge'; end if;
    select count(*) into n from jsonb_array_elements(aiq.query('GRAPH "acme"')->'rows') r
     where r->>'key' = 'ndlr' and r->>'relation' = 'competes_with';
    if n <> 0 then raise exception 'p8ql GRAPH returned a retracted edge'; end if;

    if pg_temp.parser_current() then
        v := aiq.graph_paths('acme', 'ndlr', 1, 1, 250, 'competes_with');
        if jsonb_array_length(v->'paths') <> 0 then
            raise exception 'graph_paths with no as_of crossed a retracted edge: %', v->'paths';
        end if;
        select count(*) into n from aiq.related(array['acme'], 25, 'competes_with', 250, null, true) r
         where r.node_id = v_ndlr;
        if n <> 0 then raise exception 'related ranked a node reachable only by a retracted edge'; end if;
        select count(*) into n from aiq.graph_induced(array[v_acme, v_ndlr], 'competes_with');
        if n <> 0 then raise exception 'graph_induced returned a retracted edge'; end if;

        v := aiq.graph_paths('acme', 'ndlr', 1, 1, 250, 'competes_with', now() - interval '36 hours');
        if jsonb_array_length(v->'paths') <> 1 then
            raise exception 'an as-of read from before the retraction lost the edge -- retraction '
                'must be history, not deletion';
        end if;
        raise notice 'query/15: a retracted edge is gone from neighbours, walk, PGQ, GRAPH, '
                     'paths, related and induced, and still there as of before';
    else
        -- WHY %s AND NOT TWO VERSIONS. Printing both numbers read as
        -- "the compiled parser (0.2.0) predates the extension SQL (0.2.0)"
        -- in the case that is now detectable, which is a notice that
        -- contradicts itself. Name the lag that was actually found.
        raise notice 'DEFERRED: query/15 §1 graph_paths, related and graph_induced -- %, '
                     'and REM-51''s filter lives in the .so. The five SQL read paths '
                     'above were checked.',
            case current_setting('percolate.parser_behind', true)
                when 'yes' then 'the .so is older than the crate it was built from'
                else format('the compiled parser (%s) predates the extension SQL (%s)',
                            (select extversion from pg_catalog.pg_extension
                              where extname = 'percolate_parser'),
                            (select extversion from pg_catalog.pg_extension
                              where extname = 'percolate'))
            end;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. A REBUILD APPLIES THE SAME PROJECTION AS THE TRIGGER (REM-51).
--
-- A rename made while the triggers are off -- what a bulk load does -- and
-- then aiq.rebuild_entity_type. The rebuild had its own copy of the
-- projection with no superseded-key delete, so the node kept two canonical
-- keys and the old one went on resolving.
--
-- As the sample's loader, because disabling a trigger is the table owner's.
-- ---------------------------------------------------------------------
reset role;
do $$
declare n int;
begin
    alter table demo.companies disable trigger trg_aiq_project_upd;
    update demo.companies set ticker = 'ACMX' where ticker = 'ACME';
    alter table demo.companies enable trigger trg_aiq_project_upd;
    perform aiq.rebuild_entity_type('company');

    select count(*) into n
      from aiq.node_keys k join aiq.nodes nd on nd.id = k.node_id
      join demo.companies c on c.id = nd.entity_id and nd.entity_type = 'company'
     where c.ticker = 'ACMX' and k.kind = 'canonical';
    if n <> 1 then
        raise exception 'after a rename and a rebuild the node has % canonical keys, not 1', n;
    end if;
    if exists (select 1 from aiq.lookup('acme') l where l.match_kind = 'canonical') then
        raise exception 'the old canonical key still resolves after the rebuild';
    end if;
    update demo.companies set ticker = 'ACME' where ticker = 'ACMX';
    raise notice 'query/15: a rebuild removes a superseded canonical key, as the trigger does';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE "CURRENT" VIEWS APPLY THE CALLER'S POLICIES.
--
-- Both ran as app_owner, which owns aiq.edges and aiq.nodes, and a table's
-- owner is not subject to its policies -- so org A read org B's edges through
-- edges_current (15 rows against 14 through the table). rbac/02 §2b refuses
-- the shape; this is the behaviour.
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","orgs":["a0000000-0000-0000-0000-00000000000a"]}';
do $$
declare v_table bigint; v_view bigint; v_nodes bigint; v_nview bigint;
begin
    select count(*) into v_table from aiq.edges where aiq.edge_is_current(valid_from, valid_to, now());
    select count(*) into v_view  from aiq.edges_current;
    select count(*) into v_nodes from aiq.nodes;
    select count(*) into v_nview from aiq.node_current;
    if v_view <> v_table then
        raise exception 'aiq.edges_current shows org A % edges and aiq.edges shows it % -- '
            'the view is not applying the caller''s policies', v_view, v_table;
    end if;
    if v_nview <> v_nodes then
        raise exception 'aiq.node_current shows org A % nodes and aiq.nodes shows it %',
            v_nview, v_nodes;
    end if;
    raise notice 'query/15: edges_current and node_current show org A what its policies do (% edges, % nodes)',
        v_view, v_nodes;
end $$;
reset request.jwt.claims;
reset role;
set local role app_owner;

-- ---------------------------------------------------------------------
-- 4. AN UNDONE RETRACTION IS A HOLE IN AN AS-OF READ (REM-65).
--
-- acme -partners_with-> ndlr: asserted ten days ago, retracted six days ago,
-- re-asserted now through the ingestion upsert's own conflict shape. The
-- revival used to overwrite the retraction, so an as-of read four days ago
-- saw an edge nobody believed then. Relative to now() because a revival is
-- dated by the transaction that makes it.
-- ---------------------------------------------------------------------
do $$
declare
    v_acme uuid; v_ndlr uuid; v_edge uuid; v jsonb; n int;
    t0 timestamptz := now();
begin
    select node_id into v_acme from aiq.lookup('acme');
    select node_id into v_ndlr from aiq.lookup('ndlr');
    insert into aiq.edges (src_id, dst_id, relation, weight, valid_from, provenance)
    values (v_acme, v_ndlr, 'partners_with', 0.9, t0 - interval '10 days',
            '{"sources":[{"resource_id":"A"}]}')
    returning id into v_edge;
    update aiq.edges set valid_to = t0 - interval '6 days' where id = v_edge;
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
    values (v_acme, v_ndlr, 'partners_with', 0.9, '{"sources":[{"resource_id":"B"}]}')
    on conflict (src_id, dst_id, relation) do update
       set provenance = aiq.edges.provenance || jsonb_build_object('sources',
               coalesce(aiq.edges.provenance->'sources', '[]') || (excluded.provenance->'sources')),
           valid_to = null;

    select count(*) into n from aiq.edge_retractions
     where edge_id = v_edge and retracted_at = t0 - interval '6 days' and revived_at = t0;
    if n <> 1 then
        raise exception 'the revival recorded % holes, not 1 -- trg_record_edge_retraction '
            'did not see the retraction the upsert undid', n;
    end if;
    select count(*) into n from aiq.edge_periods where edge_id = v_edge;
    if n <> 2 then raise exception 'aiq.edge_periods has % periods for the edge, not 2', n; end if;

    perform aiq.graph_snapshot(true);
    if pg_temp.parser_current() then
        -- the four instants, as graph_paths sees them
        v := aiq.graph_paths('acme', 'ndlr', 1, 1, 250, 'partners_with', t0 - interval '11 days');
        if jsonb_array_length(v->'paths') <> 0 then raise exception 'as of before the assertion: present'; end if;
        v := aiq.graph_paths('acme', 'ndlr', 1, 1, 250, 'partners_with', t0 - interval '8 days');
        if jsonb_array_length(v->'paths') <> 1 then raise exception 'as of while believed: absent'; end if;
        v := aiq.graph_paths('acme', 'ndlr', 1, 1, 250, 'partners_with', t0 - interval '4 days');
        if jsonb_array_length(v->'paths') <> 0 then
            raise exception 'as of inside the retraction the edge was still crossed (REM-65)';
        end if;
        v := aiq.graph_paths('acme', 'ndlr', 1, 1, 250, 'partners_with');
        if jsonb_array_length(v->'paths') <> 1 then raise exception 'now, after the revival: absent'; end if;
    else
        raise notice 'DEFERRED: query/15 §4 the four as-of instants through graph_paths -- '
                     '%, and the belief-period filter lives in the .so. '
                     'aiq.edge_periods is checked below, in SQL.',
            case current_setting('percolate.parser_behind', true)
                when 'yes' then 'the .so is older than the crate it was built from'
                else 'the compiled parser predates the extension SQL'
            end;
    end if;

    -- and the same four instants in SQL, over the periods
    select count(*) into n from aiq.edge_periods
     where edge_id = v_edge and aiq.edge_is_current(valid_from, valid_to, t0 - interval '4 days');
    if n <> 0 then raise exception 'aiq.edge_periods holds the edge inside its retraction'; end if;
    select count(*) into n from aiq.edge_periods
     where edge_id = v_edge and aiq.edge_is_current(valid_from, valid_to, t0 - interval '8 days');
    if n <> 1 then raise exception 'aiq.edge_periods lost the first belief period'; end if;

    -- A retraction undone at the SAME instant is no hole: a derivation that
    -- retires what it owns and revives what still follows did not stop
    -- believing anything.
    update aiq.edges set valid_to = now() where id = v_edge;
    update aiq.edges set valid_to = null  where id = v_edge;
    select count(*) into n from aiq.edge_retractions where edge_id = v_edge;
    if n <> 1 then raise exception 'a same-instant retire-and-revive recorded a hole'; end if;
    raise notice 'query/15: an as-of read inside an undone retraction omits the edge, in SQL%',
        case when pg_temp.parser_current() then ' and in paths' else '' end;
end $$;

-- ---------------------------------------------------------------------
-- 5. A DERIVATION WITHDRAWS WHAT IT SAID, AND NOTHING ELSE (REM-60).
--
-- Four `mentions` edges, three writers. The self-model's sweep retired by
-- relation name, so it took every one of these; aiq.retract_derived takes
-- only the edges the named agent asserts, and for an edge another writer also
-- asserts it takes only that agent's word.
-- ---------------------------------------------------------------------
do $$
declare
    e_self uuid; e_pgw uuid; e_shared uuid; e_old uuid; v jsonb;
begin
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
    select s.node_id, d.node_id, 'mentions', 1.0, p.prov
      from (values ('acme q3 results', 'brls',  '{"agent":"selfmodel","kind":"exact","from":"test"}'::jsonb),
                   ('borealis strike', 'acme',  '{"tier":"machine","sources":[{"agent":"theme-dreamer","run_id":"r1"}]}'),
                   ('sector rout',     'ndlr',  '{"tier":"machine","sources":[{"agent":"knit","run_id":"r1"},{"agent":"theme-dreamer","run_id":"r1"}]}'),
                   ('sector rout',     'mrdn',  '{"tier":"machine","sources":[{"agent":"theme-dreamer","run_id":"r0"}]}'))
           as p(src, dst, prov)
      join aiq.node_keys s on s.key = p.src and s.kind = 'canonical'
      join aiq.node_keys d on d.key = p.dst and d.kind = 'canonical'
    on conflict (src_id, dst_id, relation) do update set provenance = excluded.provenance, valid_to = null;
    e_self   := pg_temp.edge_id('acme q3 results', 'brls', 'mentions');
    e_pgw    := pg_temp.edge_id('borealis strike', 'acme', 'mentions');
    e_shared := pg_temp.edge_id('sector rout', 'ndlr', 'mentions');
    e_old    := pg_temp.edge_id('sector rout', 'mrdn', 'mentions');

    -- the self-model's refresh: its own edge goes, nobody else's
    v := aiq.retract_derived('selfmodel', null, array['mentions']);
    if (select valid_to from aiq.edges where id = e_self) is null then
        raise exception 'retract_derived left the named agent''s own edge standing';
    end if;
    if exists (select 1 from aiq.edges where id in (e_pgw, e_shared, e_old) and valid_to is not null) then
        raise exception 'the self-model''s withdrawal retracted another writer''s mentions edge (REM-60): %', v;
    end if;

    -- a package's dream, run r1: the edge it re-asserted in r1 stays, the one
    -- only r0 asserted goes, and the shared edge keeps knit's word without it
    v := aiq.retract_derived('theme-dreamer', null, array['mentions'], 'r1');
    if (select valid_to from aiq.edges where id = e_old) is null then
        raise exception 'an edge this agent asserted only in an earlier run survived its run-scoped withdrawal';
    end if;
    if (select valid_to from aiq.edges where id = e_pgw) is not null
       or (select valid_to from aiq.edges where id = e_shared) is not null then
        raise exception 'an edge asserted in the current run was withdrawn: %', v;
    end if;

    -- the same dreamer, withdrawing everything: the shared edge stays on knit's word
    v := aiq.retract_derived('theme-dreamer', null, array['mentions']);
    if (select valid_to from aiq.edges where id = e_shared) is not null then
        raise exception 'an edge another writer still asserts was retracted';
    end if;
    if (select provenance->'sources' from aiq.edges where id = e_shared)
         is distinct from '[{"agent":"knit","run_id":"r1"}]'::jsonb then
        raise exception 'the shared edge''s sources are %, not knit''s alone',
            (select provenance->'sources' from aiq.edges where id = e_shared);
    end if;
    if (select valid_to from aiq.edges where id = e_pgw) is null
       or (select provenance->'sources' from aiq.edges where id = e_pgw)
          is distinct from '[{"agent":"theme-dreamer","run_id":"r1"}]'::jsonb then
        raise exception 'a solely-asserted edge was not retracted with its provenance intact';
    end if;

    begin
        perform aiq.retract_derived(null);
        raise exception 'retract_derived accepted no agent';
    exception when others then
        if sqlerrm not like '%needs the agent%' then raise; end if;
    end;
    raise notice 'query/15: retract_derived withdraws one writer''s edges and one writer''s word, nothing else';
end $$;

rollback;
