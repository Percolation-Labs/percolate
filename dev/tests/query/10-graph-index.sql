-- GRAPH INDEXING -- the write path an extractor's output takes into the
-- registry (`world-model-ingestion/graph-index.md` §10's assertions).
--
-- The characteristic failure of this half is a graph that landed but is
-- WRONG IN A WAY NOTHING RAISES: an edge wired to the wrong endpoint because
-- an ordinal moved, a machine-invented row in a human's table, a promotion
-- that quietly deleted the edges it was supposed to keep. Every assertion
-- below names the invariant it holds up, and every one fails again if the
-- corresponding guard is removed.
--
-- Requires graph.sql applied and aiq.register_graph_vocabulary() run.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

-- A throwaway typed table, registered, so the `pg` residence is exercised
-- against something this file created rather than against the committed
-- sample -- and so eviction/promotion can be run without touching it.
create table demo_t_org (
    id     uuid primary key default gen_random_uuid(),
    name   text not null,
    org_id uuid
);
select aiq.register_entity_table('ttype_org', 'public.demo_t_org', 'n.name', 'n.name', 'n.org_id');
insert into demo_t_org (name) values ('Northgate Freight');
-- The catalogue has to admit the new type, or every edge into it raises. This
-- IS the refresh obligation graph-index.md §5.3 names; running it here is the
-- test that the remedy works, not a setup detail.
select aiq.register_graph_vocabulary();

-- ---------------------------------------------------------------------
-- 1. A REGISTERED KIND THAT RESOLVES LANDS ON THE REAL TYPED VERTEX (G2, (a)).
-- ---------------------------------------------------------------------
do $$
declare v_r jsonb; v_node uuid;
begin
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Northgate Freight"},
                {"k":"widgetry","n":"Blue Programme"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb,
      '{"agent":"t"}'::jsonb);

    if (v_r->'residence'->>'pg')::int <> 1 or (v_r->'residence'->>'soft')::int <> 1 then
        raise exception 'expected one pg and one soft node, got %', v_r->'residence';
    end if;

    select entity_id into v_node from aiq.nodes
     where id = (v_r->'node_ids'->>0)::uuid and entity_type = 'ttype_org';
    if v_node is null then
        raise exception 'a resolved kind did not land on its typed vertex';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. AN UNRESOLVED NAME UNDER A REGISTERED KIND CREATES NO TYPED ROW (G2).
--
-- The temptation this refuses is to create the company. A machine-created row
-- in a human's table bypasses that table's owner, its inclusion predicate and
-- its projection -- so the extractor gets a CANDIDATE carrying the kind it
-- claimed, and binding that to a real row is entity resolution's job.
-- ---------------------------------------------------------------------
do $$
declare v_before int; v_after int; v_r jsonb;
begin
    select count(*) into v_before from demo_t_org;
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"A Company That Does Not Exist"},
                {"k":"ttype_org","n":"Northgate Freight"}],
      "edges": [{"s":0,"t":1,"r":"supplies"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    select count(*) into v_after from demo_t_org;

    if v_after <> v_before then
        raise exception 'the extractor CREATED A ROW in a registered typed table';
    end if;
    if not exists (select 1 from aiq.soft_nodes
                    where kind = 'ttype_org' and key = 'a company that does not exist') then
        raise exception 'an unresolved registered kind did not become a candidate '
                        'carrying its claimed kind';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. AN AMBIGUOUS RESOLUTION IS A MISS, NOT A COIN FLIP.
--
-- add_node_key already refuses an ambiguous target rather than picking one.
-- Picking is wrong silently; a candidate is wrong visibly.
-- ---------------------------------------------------------------------
insert into demo_t_org (name) values ('Ambi Ltd (North)'), ('Ambi Ltd (South)');
select aiq.add_node_key('ambi ltd (north)', 'ambi ltd', 'short');
select aiq.add_node_key('ambi ltd (south)', 'ambi ltd', 'short');
do $$
begin
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Ambi Ltd"}], "edges": []}$g$::jsonb, '{"agent":"t"}'::jsonb);
    if not exists (select 1 from aiq.soft_nodes where kind='ttype_org' and key='ambi ltd') then
        raise exception 'an ambiguous short key resolved to ONE of its matches '
                        'instead of becoming a candidate';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. G5: ORDINALS ARE POSITIONAL, AND THAT IS A REAL CONSTRAINT.
--
-- Asserted as a NEGATIVE. The same payload with its node list reordered must
-- produce a DIFFERENT graph -- which is exactly why nothing may filter, sort
-- or dedupe that list between the model and the resolver. If this assertion
-- ever passes "both the same", ordinals have stopped being positional and the
-- rest of the design is resting on something that is no longer true.
-- ---------------------------------------------------------------------
do $$
declare v_a jsonb; v_b jsonb; v_n1 uuid; v_n2 uuid;
begin
    v_a := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Alpha"},{"k":"ord","n":"Beta"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    v_b := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Beta"},{"k":"ord","n":"Alpha"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);

    select n.id into v_n1 from aiq.nodes n join aiq.soft_nodes s
      on s.id = n.entity_id and n.entity_type='soft'
     where s.kind='ord' and s.key='alpha';
    select n.id into v_n2 from aiq.nodes n join aiq.soft_nodes s
      on s.id = n.entity_id and n.entity_type='soft'
     where s.kind='ord' and s.key='beta';

    -- Both directions now exist: alpha->beta from the first, beta->alpha from
    -- the reordered second. Two edges, not one.
    if (select count(*) from aiq.edges
         where relation='owns' and src_id in (v_n1,v_n2) and dst_id in (v_n1,v_n2)) <> 2 then
        raise exception 'reordering the node list did NOT change the edges written -- '
                        'ordinals are no longer positional, and G5 is stale';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. AN OUT-OF-RANGE ORDINAL RAISES. It does not skip the edge: a dropped
--    edge is a hole in a graph that still answers questions.
-- ---------------------------------------------------------------------
do $$
begin
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Solo"}],
      "edges": [{"s":0,"t":4,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    raise exception 'an out-of-range ordinal was accepted';
exception when others then
    if sqlerrm not like '%only 1 nodes were emitted%' then raise; end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. A SELF-EDGE IS DROPPED AND COUNTED -- never silently.
-- ---------------------------------------------------------------------
do $$
declare v_r jsonb;
begin
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Selfy"},{"k":"ord","n":"Selfy"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    if (v_r->>'self_edges_dropped')::int <> 1 then
        raise exception 'a self-edge was not reported in the receipt: %', v_r;
    end if;
    if (v_r->>'edges_new')::int <> 0 then
        raise exception 'a self-edge was written';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. A RELATION OUTSIDE THE VOCABULARY IS REFUSED.
--    The vocabulary is closed for extraction.md's reason: an extractor that
--    can emit anything cannot be checked, costed, or swapped.
-- ---------------------------------------------------------------------
do $$
begin
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"A"},{"k":"ord","n":"B"}],
      "edges": [{"s":0,"t":1,"r":"vibes_with"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    raise exception 'an out-of-vocabulary relation was accepted';
exception when others then
    if sqlerrm not like '%not in aiq.graph_vocabulary%' then raise; end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. THE LAKE RESIDENCE: a kind naming a registered dataset becomes a
--    reference whose key carries NO scheme (G4), and a pinned `lake:` kind
--    naming no dataset is REFUSED rather than downgraded -- a pinned
--    residence is a claim by the extractor's author, not by the model.
-- ---------------------------------------------------------------------
insert into content.datasets (name, bucket, prefix, columns)
values ('t_shipments', 'test', 'ds/t_shipments', '[]'::jsonb)
on conflict (org_id, name) do nothing;

do $$
declare v_r jsonb; v_key text;
begin
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"lake:t_shipments","n":"ABC-771"},{"k":"ord","n":"Depot"}],
      "edges": [{"s":0,"t":1,"r":"located_in"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    if (v_r->'residence'->>'lake')::int <> 1 then
        raise exception 'a registered dataset kind did not take the lake residence: %', v_r;
    end if;

    select key into v_key from aiq.node_keys
     where node_id = (v_r->'node_ids'->>0)::uuid and kind = 'canonical';
    if v_key <> 't_shipments/abc-771' then
        raise exception 'lake key is %, expected t_shipments/abc-771 -- the residence '
                        'scheme must be stripped before the key (G4)', v_key;
    end if;
end $$;

do $$
begin
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"lake:no_such_dataset","n":"X"}], "edges": []}$g$::jsonb,
      '{"agent":"t"}'::jsonb);
    raise exception 'a pinned lake residence with no dataset was silently downgraded';
exception when others then
    if sqlerrm not like '%no dataset named%' then raise; end if;
end $$;

-- ---------------------------------------------------------------------
-- 9. CORROBORATION: the same edge from two documents is ONE row with two
--    provenances -- and that count is a distinct-DOCUMENT count, not a
--    mention count. It is still not a trust score.
-- ---------------------------------------------------------------------
do $$
declare v_n1 uuid; v_n2 uuid; v_srcs int;
begin
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"corr","n":"P"},{"k":"corr","n":"Q"}],
      "edges": [{"s":0,"t":1,"r":"supplies"}]}$g$::jsonb,
      '{"agent":"t","resource_id":"33330000-0000-0000-0000-000000000001"}'::jsonb);
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"corr","n":"P"},{"k":"corr","n":"Q"}],
      "edges": [{"s":0,"t":1,"r":"supplies"}]}$g$::jsonb,
      '{"agent":"t","resource_id":"33330000-0000-0000-0000-000000000002"}'::jsonb);
    -- ...and the SAME document twice must NOT double-count.
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"corr","n":"P"},{"k":"corr","n":"Q"}],
      "edges": [{"s":0,"t":1,"r":"supplies"}]}$g$::jsonb,
      '{"agent":"t","resource_id":"33330000-0000-0000-0000-000000000002"}'::jsonb);

    select n.id into v_n1 from aiq.nodes n join aiq.soft_nodes s
      on s.id=n.entity_id and n.entity_type='soft' where s.kind='corr' and s.key='p';
    select n.id into v_n2 from aiq.nodes n join aiq.soft_nodes s
      on s.id=n.entity_id and n.entity_type='soft' where s.kind='corr' and s.key='q';

    select jsonb_array_length(provenance->'sources') into v_srcs
      from aiq.edges where src_id=v_n1 and dst_id=v_n2 and relation='supplies';
    if v_srcs <> 2 then
        raise exception 'expected 2 distinct-document provenances, got % -- re-asserting '
                        'the same edge from the SAME document must not inflate it', v_srcs;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 10. PROMOTION REWRITES EDGES BEFORE IT EVICTS (G7) -- the sharp edge.
--
-- aiq.edges cascades on node delete, so evicting a promoted candidate would
-- destroy every edge the indexer wrote about it: the entire product. And the
-- conflict is the EXPECTED state, not a corner case -- the reason a candidate
-- is promoted is usually that it and the real node were talked about in the
-- same corpus, so a shared edge is normal.
-- ---------------------------------------------------------------------
do $$
declare v_cand_soft uuid; v_cand_node uuid; v_target uuid; v_other uuid;
        v_r jsonb; v_before int; v_after int; v_srcs int;
begin
    -- A candidate and the real node BOTH have `supplies -> Northgate Freight`,
    -- so the promotion hits the unique constraint on (src,dst,relation).
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Zephyr Haulage"},
                {"k":"ttype_org","n":"Northgate Freight"},
                {"k":"ord","n":"Only The Candidate Has This"}],
      "edges": [{"s":0,"t":1,"r":"supplies"},
                {"s":0,"t":2,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Ambi Ltd (North)"},
                {"k":"ttype_org","n":"Northgate Freight"}],
      "edges": [{"s":0,"t":1,"r":"supplies"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);

    select s.id, n.id into v_cand_soft, v_cand_node
      from aiq.soft_nodes s join aiq.nodes n on n.entity_id = s.id and n.entity_type='soft'
     where s.kind='ttype_org' and s.key='zephyr haulage';
    select node_id into v_target from aiq.node_keys
     where key='ambi ltd (north)' and kind='canonical';

    -- Give the target the SAME edge the candidate has, so the repoint conflicts.
    select count(*) into v_before from aiq.edges where src_id = v_cand_node;

    v_r := aiq.promote_soft_node(v_cand_soft, v_target);

    -- The candidate's node is gone (inclusion predicate no longer satisfied)...
    if exists (select 1 from aiq.nodes where id = v_cand_node) then
        raise exception 'promotion did not evict the candidate node';
    end if;
    -- ...and its edges moved rather than cascading away.
    select count(*) into v_after from aiq.edges where src_id = v_target;
    if v_after < v_before then
        raise exception 'promotion LOST edges: candidate had %, target has % (receipt %)',
            v_before, v_after, v_r;
    end if;
    -- The conflicting edge merged its provenance instead of failing or dropping.
    select jsonb_array_length(e.provenance->'sources') into v_srcs
      from aiq.edges e
      join aiq.node_keys k on k.node_id = e.dst_id and k.kind='canonical'
     where e.src_id = v_target and e.relation='supplies' and k.key='northgate freight';
    if coalesce(v_srcs,0) < 2 then
        raise exception 'the conflicting edge did not merge both provenances (got %)', v_srcs;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 11. A MACHINE RE-ASSERTION MUST NOT DEMOTE AN AUTHORED EDGE, AND MUST NOT
--     ERASE ITS PROVENANCE. weight is read by graph_walk (product along the
--     path), so this is behaviour, not storage. Both halves were bugs the
--     first time this ran: `least` demoted an authored 1.0 to the machine
--     prior, and the provenance merge NULLed a column belonging to whoever
--     authored the edge.
-- ---------------------------------------------------------------------
do $$
declare v_w real; v_a uuid; v_b uuid; v_p jsonb;
begin
    select node_id into v_a from aiq.node_keys where key='ambi ltd (north)' and kind='canonical';
    select node_id into v_b from aiq.node_keys where key='ambi ltd (south)' and kind='canonical';
    insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
    values (v_a, v_b, 'owns', 1.0, '{"tier":"authored"}'::jsonb);

    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Ambi Ltd (North)"},{"k":"ttype_org","n":"Ambi Ltd (South)"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);

    select weight, provenance into v_w, v_p
      from aiq.edges where src_id=v_a and dst_id=v_b and relation='owns';
    if v_w <> 1.0 then
        raise exception 'a machine re-assertion demoted an authored edge to % -- weight '
                        'is the BEST tier that asserted the edge, and a cheap model '
                        'agreeing with an analyst is not evidence against them', v_w;
    end if;
    if v_p->>'tier' <> 'authored' then
        raise exception 'the machine re-assertion overwrote the authored provenance: %', v_p;
    end if;
    if jsonb_array_length(v_p->'sources') <> 1 then
        raise exception 'the machine assertion was not appended to the authored edge: %', v_p;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 12. NEITHER REFERENCE TABLE HOLDS ADJACENCY (G1).
--     This is the mechanical form of "this is not p8k8's kv_store": edges live
--     once, in aiq.edges. A column on either table referencing another node
--     reverses a rejection specs/README.md makes explicitly.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(c.table_name||'.'||c.column_name, ', ') into v_bad
    from information_schema.columns c
    where c.table_schema='aiq' and c.table_name in ('soft_nodes','lake_nodes')
      and c.column_name not in ('id','kind','key','label','attrs','org_id',
                                'first_seen_at','last_seen_at','resolved_node_id',
                                'dataset','row_key');
    if v_bad is not null then
        raise exception 'a reference table grew an unexpected column (%). If it points at '
                        'another node, adjacency has been duplicated and README.md''s '
                        'rejection of the kv_store cache has been reversed.', v_bad;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 13. A TENANT'S DOCUMENT CANNOT RESOLVE ANOTHER TENANT'S ENTITY.
--
-- The leak this closes is not obvious and was not designed against: resolution
-- happens inside aiq.upsert_graph, which is SECURITY DEFINER because it writes
-- tables the worker holds no grants on -- and a function called from inside a
-- definer runs AS THE DEFINER, so RLS does not filter it. Without an explicit
-- org argument, tenant A uploading a document that merely NAMES tenant B's
-- private company would hang a real edge on B's vertex, silently, from a
-- process that is supposed to be handling A's upload.
--
-- The shared tier (org_id is null) stays resolvable by everyone, because
-- integration-rbac.sql calls that "a real category here, not a loophole."
-- ---------------------------------------------------------------------
insert into demo_t_org (name, org_id)
values ('Tenant B Private Co', 'a0000000-0000-0000-0000-00000000000b');
do $$
declare v_r jsonb; v_hit uuid;
begin
    -- Org A's document names org B's company.
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Tenant B Private Co"},
                {"k":"ord","n":"Anything"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb,
      '{"agent":"t","org_id":"a0000000-0000-0000-0000-00000000000a"}'::jsonb);

    if (v_r->'residence'->>'pg')::int <> 0 then
        raise exception
            'a tenant''s document RESOLVED another tenant''s private entity and wrote '
            'an edge onto it. Resolution inside a SECURITY DEFINER writer is not '
            'RLS-filtered; it must be scoped by an explicit org argument.';
    end if;
    if not exists (select 1 from aiq.soft_nodes
                    where key = 'tenant b private co'
                      and org_id = 'a0000000-0000-0000-0000-00000000000a') then
        raise exception 'the unresolvable cross-tenant name did not become a '
                        'candidate in the ASKING tenant''s own scope';
    end if;

    -- ...and the shared tier is still reachable, or the fix has overshot into
    -- making every public company unresolvable.
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ttype_org","n":"Northgate Freight"},{"k":"ord","n":"Anything"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb,
      '{"agent":"t","org_id":"a0000000-0000-0000-0000-00000000000a"}'::jsonb);
    if (v_r->'residence'->>'pg')::int <> 1 then
        raise exception 'shared reference data stopped resolving for a tenant -- the '
                        'org filter must admit org_id is null';
    end if;
end $$;

rollback;
\echo 'graph-index: all assertions passed'
