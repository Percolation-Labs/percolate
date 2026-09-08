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
                    where claimed_kind = 'ttype_org' and key = 'a company that does not exist') then
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
    if not exists (select 1 from aiq.soft_nodes where claimed_kind='ttype_org' and key='ambi ltd') then
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
     where s.claimed_kind='ord' and s.key='alpha';
    select n.id into v_n2 from aiq.nodes n join aiq.soft_nodes s
      on s.id = n.entity_id and n.entity_type='soft'
     where s.claimed_kind='ord' and s.key='beta';

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
-- 7. A RELATION OUTSIDE THE VOCABULARY IS NOT WRITTEN -- and is NAMED.
--    The vocabulary is closed for extraction.md's reason: an extractor that
--    can emit anything cannot be checked, costed, or swapped. What changed is
--    only the blast radius. This used to raise, which aborted the transaction
--    and discarded every node and every valid edge the document produced -- so
--    the assertion below is now "the edge did not land AND the document did",
--    which is the property the closed vocabulary was always for.
-- ---------------------------------------------------------------------
do $$
declare v_r jsonb;
begin
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"A"},{"k":"ord","n":"B"}],
      "edges": [{"s":0,"t":1,"r":"vibes_with"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    if (v_r->>'edges_new')::int <> 0 then
        raise exception 'an out-of-vocabulary relation was written: %', v_r;
    end if;
    if (v_r->'edges_dropped_unknown_relation') <> '["vibes_with"]'::jsonb then
        raise exception 'the refused relation was not named in the receipt: %', v_r;
    end if;
    if (v_r->>'nodes')::int <> 2 then
        raise exception 'the nodes went with the bad edge: %', v_r;
    end if;
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
    if v_key is distinct from 't_shipments/abc-771' then
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
      on s.id=n.entity_id and n.entity_type='soft' where s.claimed_kind='corr' and s.key='p';
    select n.id into v_n2 from aiq.nodes n join aiq.soft_nodes s
      on s.id=n.entity_id and n.entity_type='soft' where s.claimed_kind='corr' and s.key='q';

    select jsonb_array_length(provenance->'sources') into v_srcs
      from aiq.edges where src_id=v_n1 and dst_id=v_n2 and relation='supplies';
    if v_srcs is distinct from 2 then
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
     where s.claimed_kind='ttype_org' and s.key='zephyr haulage';
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
    if v_w is distinct from 1.0 then
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
      -- owner_id and visibility are scope, not adjacency. The invariant is
      -- about a column POINTING AT ANOTHER NODE -- that is what would put
      -- edges in two places and reverse README.md's rejection of the kv_store
      -- cache. `resolved_node_id` is on the allow-list because it is the one
      -- such pointer the design does want; who may read the row is not one at
      -- all, and it sits beside org_id for the same reason org_id does.
      and c.column_name not in ('id','claimed_kind','key','label','attrs','org_id',
                                'owner_id','visibility',
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
-- The shared tier (org_id = rbac.shared_org_id()) stays resolvable by everyone, because
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
                        'org filter must admit the shared tier (rbac.shared_org_id())';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- A RE-REGISTRATION THAT NAMES NO WEIGHT KEEPS THE TUNED ONE.
--
-- Asserted rather than trusted because the failure is SILENT and lands late:
-- aiq.upsert_graph seeds a new edge from machine_weight and then merges with
-- `greatest(edges.weight, excluded.weight)`, so a reset demotes nothing that
-- already exists and every edge written afterwards carries the prior. Nothing
-- raises, no count changes, and the graph is quietly retuned. The shape that
-- triggers it is the shape every bootstrap has -- and the one this collection
-- ships, since the vocabulary at the foot of graph.sql re-registers on every
-- ALTER EXTENSION percolate UPDATE.
-- ---------------------------------------------------------------------
do $$
declare v_w real; v_d text;
begin
    perform aiq.register_graph_vocabulary(
        '[{"relation":"tuned_rel","machine_weight":0.9,"description":"tuned by hand"}]'::jsonb);

    -- The idempotent bootstrap runs a second time and names no weight.
    perform aiq.register_graph_vocabulary('[{"relation":"tuned_rel"}]'::jsonb);

    select machine_weight, description into v_w, v_d
      from aiq.graph_vocabulary where relation = 'tuned_rel';
    -- Compared as `real`, which is the column's type: `0.9` on its own is
    -- numeric, and 0.9::real is 0.89999997615814209, so the untyped literal
    -- makes this assertion fail against a column holding exactly what it was
    -- given. A test that cries wolf is worse than no test.
    if v_w is distinct from 0.9::real then
        raise exception
            're-registering without a weight reset machine_weight to % -- an absent '
            'value and an explicit 0.5 have become the same value again', v_w;
    end if;
    if v_d <> 'tuned by hand' then
        raise exception 'description lost its protection: %', v_d;
    end if;

    -- ...and a caller who MEANS to change it still can. A fix that made the
    -- column write-once would pass the assertion above and be worse.
    perform aiq.register_graph_vocabulary(
        '[{"relation":"tuned_rel","machine_weight":0.2}]'::jsonb);
    select machine_weight into v_w from aiq.graph_vocabulary where relation = 'tuned_rel';
    if v_w is distinct from 0.2::real then
        raise exception 'an explicit weight did not take: %', v_w;
    end if;
    raise notice 'graph-index: a re-registration without a weight preserves the tuned one';
end $$;

-- ---------------------------------------------------------------------
-- SYMMETRY AND INVERSES ARE REACHABLE THROUGH THE REGISTRATION PAYLOAD.
--
-- The mechanism has always been in aiq.relation_types and register_graph_
-- vocabulary wrote four columns and no others, so no consumer -- and no
-- shipped relation -- could declare either. The assertion is that the ONE
-- path a consumer has now carries them, and carries them to every triple,
-- because is_symmetric is a property of the term and this table is keyed by
-- the triple.
-- ---------------------------------------------------------------------
do $$
declare v_n int; v_sym int; v_inv int;
begin
    perform aiq.register_graph_vocabulary($j$[
      {"relation":"sym_rel", "machine_weight":0.7, "is_symmetric":true},
      {"relation":"fwd_rel", "machine_weight":0.7, "inverse_label":"bwd_rel"}]$j$::jsonb);

    select count(*) filter (where relation = 'sym_rel' and is_symmetric),
           count(*) filter (where relation = 'sym_rel'),
           count(*) filter (where relation = 'fwd_rel' and inverse_label = 'bwd_rel')
      into v_sym, v_n, v_inv
      from aiq.relation_types;
    if v_sym = 0 or v_sym <> v_n then
        raise exception
            'symmetry reached % of the % triples generated for the term -- it is a '
            'property of the relation, not of the (src,relation,dst) triple', v_sym, v_n;
    end if;
    if v_inv <> v_n then
        raise exception 'the inverse label reached % of % triples', v_inv, v_n;
    end if;

    -- A REFRESH must not un-declare them. This is the no-payload call every
    -- consumer makes after registering a new entity table, and resetting the
    -- columns to their defaults here would be the machine_weight bug again.
    perform aiq.register_graph_vocabulary();
    select count(*) filter (where relation = 'sym_rel' and is_symmetric)
      into v_sym from aiq.relation_types;
    if v_sym <> v_n then
        raise exception 'a refresh un-declared symmetry on % of % triples',
            v_n - v_sym, v_n;
    end if;
    raise notice 'graph-index: symmetry and inverses reach every triple, and survive a refresh';
end $$;

-- ---------------------------------------------------------------------
-- A TERM CANNOT DECLARE SYMMETRY TWO WAYS -- absence inherits, disagreement raises.
-- ---------------------------------------------------------------------
do $$
declare v_sym boolean;
begin
    -- Says nothing -> inherits the term's value. This is the case that makes
    -- the rule usable: a writer cataloguing a new type pair should not have to
    -- know what the term already decided.
    insert into aiq.relation_types (src_type, relation, dst_type)
    values ('soft', 'sym_rel', 'ttype_org')
    on conflict (src_type, relation, dst_type) do nothing;
    select is_symmetric into v_sym from aiq.relation_types
     where src_type = 'soft' and relation = 'sym_rel' and dst_type = 'ttype_org';
    if not coalesce(v_sym, false) then
        raise exception 'a new triple did not inherit its term''s symmetry';
    end if;

    -- Says the opposite -> refused. The failure this prevents is a wrong
    -- number, not an error: check_edge_catalogue reads symmetry with bool_or
    -- over the term, so a split term normalises an edge or not depending on
    -- which types are at its ends.
    begin
        insert into aiq.relation_types (src_type, relation, dst_type, is_symmetric)
        values ('lake', 'sym_rel', 'lake', false);
        raise exception 'a term was allowed to declare symmetry two ways';
    exception when others then
        if sqlerrm like '%allowed to declare symmetry two ways%' then raise; end if;
    end;
    raise notice 'graph-index: a split term is refused and an absent one inherits';
end $$;

-- ---------------------------------------------------------------------
-- ONE BAD RELATION NO LONGER LOSES THE WHOLE DOCUMENT.
--
-- Measured before the fix, on this exact shape: 4 nodes and 4 valid edges
-- discarded for 1 invented relation, because the refusal raised and the
-- transaction went with it. The vocabulary stays closed -- the edge is still
-- not written -- but a receipt naming what was dropped is the difference
-- between a gap you can act on and a document that silently never arrived.
-- ---------------------------------------------------------------------
do $$
declare v_r jsonb;
begin
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Beta Ltd"},{"k":"ord","n":"Gadget"},
                {"k":"ord","n":"Sam Poe"},{"k":"ord","n":"Gamma SA"}],
      "edges": [{"s":0,"t":1,"r":"owns"},
                {"s":2,"t":0,"r":"affiliated_with"},
                {"s":1,"t":0,"r":"owned_by"},
                {"s":3,"t":1,"r":"supplies"},
                {"s":3,"t":0,"r":"party_to"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);

    if (v_r->>'nodes')::int <> 4 then
        raise exception 'the document was lost for one bad edge: %', v_r;
    end if;

    -- `owned_by` is `owns`'s declared inverse, so it is FLIPPED rather than
    -- dropped -- all eight of the edges this lost on a real 159-document run
    -- were this exact case.
    if (v_r->>'edges_flipped_to_inverse')::int <> 1 then
        raise exception 'an edge naming a declared inverse was not flipped: %', v_r;
    end if;
    if jsonb_array_length(v_r->'edges_dropped_unknown_relation') <> 0 then
        raise exception 'a recoverable inverse was counted as dropped: %', v_r;
    end if;
    -- The flip stored the FORWARD form, in the forward direction: Gadget
    -- owned_by Beta is Beta owns Gadget, not a second `owned_by` row.
    if not exists (
        select 1 from aiq.edges e
          join aiq.node_keys s on s.node_id = e.src_id and s.key = 'ord/beta ltd'
          join aiq.node_keys d on d.node_id = e.dst_id and d.key = 'ord/gadget'
         where e.relation = 'owns') then
        raise exception 'the flipped edge was not stored in its forward orientation';
    end if;
    raise notice 'graph-index: an inverse is recovered and the document survives';
end $$;

do $$
declare v_r jsonb;
begin
    -- ...and a relation that is nobody's inverse is dropped, NAMED, and does
    -- not take the rest of the payload with it.
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Delta Ltd"},{"k":"ord","n":"Sprocket"}],
      "edges": [{"s":0,"t":1,"r":"owns"},
                {"s":0,"t":1,"r":"reticulates"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);

    if (v_r->'edges_dropped_unknown_relation') <> '["reticulates"]'::jsonb then
        raise exception 'the dropped relation was not named in the receipt: %', v_r;
    end if;
    if (v_r->>'edges_new')::int <> 1 then
        raise exception 'the valid edge did not survive the invalid one: %', v_r;
    end if;
    -- And an out-of-range ORDINAL still raises. That one is a wiring bug, not
    -- a model artefact, and the distinction is the whole basis of the change.
    begin
        perform aiq.upsert_graph($g${
          "nodes": [{"k":"ord","n":"Only One"}],
          "edges": [{"s":0,"t":7,"r":"owns"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
        raise exception 'an out-of-range ordinal was tolerated';
    exception when others then
        if sqlerrm like '%out-of-range ordinal was tolerated%' then raise; end if;
    end;
    raise notice 'graph-index: an unknown relation is dropped and named, a bad ordinal still raises';
end $$;

-- ---------------------------------------------------------------------
-- 14. A FRESH ASSERTION REVIVES A RETRACTED EDGE.
--
-- 0.2.0 made `valid_to` load-bearing: the graph forgets on purpose rather than
-- by DELETE, and `aiq.edges_current` is what a live read means. But edge
-- identity is still `(src, dst, relation)` with no time in it, so a retracted
-- edge and its re-assertion are the SAME ROW and the conflict branch in
-- `upsert_graph` is that row's only writer.
--
-- The failure this pins is the quiet kind §9 and §11 are also about. Before
-- the fix the branch touched provenance and weight alone: a second document
-- asserting the edge got its source appended, `edges_merged` counted it, the
-- receipt reported success -- and `valid_to` stayed set, so the edge never came
-- back into `edges_current`. A source returned and the graph did not, with
-- nothing raised and nothing visible in the return value.
--
-- Both halves are asserted, because a revival that is not reported is only
-- half a fix: a caller retracting on a schedule needs to see its retractions
-- being undone, not infer it from a count that stopped falling.
-- ---------------------------------------------------------------------
do $$
declare v_r jsonb; v_edge uuid;
begin
    perform aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Revival Alpha"},{"k":"ord","n":"Revival Beta"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb,
      '{"agent":"t","resource_id":"11111111-1111-1111-1111-111111111111"}'::jsonb);

    select e.id into v_edge from aiq.edges e
      join aiq.node_keys s on s.node_id = e.src_id and s.key = 'ord/revival alpha'
      join aiq.node_keys d on d.node_id = e.dst_id and d.key = 'ord/revival beta'
     where e.relation = 'owns';
    if v_edge is null then
        raise exception 'the edge this assertion is about did not land';
    end if;

    -- Retraction, the way 0.2.0 offers it: there is no aiq function, the
    -- column IS the interface, and a consumer sets it.
    update aiq.edges set valid_to = now() where id = v_edge;
    if exists (select 1 from aiq.edges_current where id = v_edge) then
        raise exception 'a retracted edge is still current -- edges_current is not filtering';
    end if;

    -- A DIFFERENT document says it again. The source came back.
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Revival Alpha"},{"k":"ord","n":"Revival Beta"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb,
      '{"agent":"t","resource_id":"22222222-2222-2222-2222-222222222222"}'::jsonb);

    if not exists (select 1 from aiq.edges_current where id = v_edge) then
        raise exception
            're-assertion did not revive the retracted edge. The upsert reported '
            '%, and every one of those numbers is true -- the edge is simply '
            'still invisible to every live read. This is the silent half; the '
            'fix is `valid_to = null` in the conflict branch of upsert_graph.', v_r;
    end if;
    if (v_r->>'edges_revived')::int <> 1 then
        raise exception 'the revival was not reported in the receipt: %', v_r;
    end if;
    -- It is a merge, not a new edge, and the retraction gap is auditable in
    -- provenance because one row can only hold one interval.
    if (v_r->>'edges_merged')::int <> 1 or (v_r->>'edges_new')::int <> 0 then
        raise exception 'a revival must count as a merge, not a new edge: %', v_r;
    end if;
    if jsonb_array_length(
           (select provenance->'sources' from aiq.edges where id = v_edge)) <> 2 then
        raise exception 'the two assertions either side of the retraction are not both recorded';
    end if;

    -- And an ordinary merge on a LIVE edge reports no revival, or the counter
    -- means nothing.
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Revival Alpha"},{"k":"ord","n":"Revival Beta"}],
      "edges": [{"s":0,"t":1,"r":"owns"}]}$g$::jsonb,
      '{"agent":"t","resource_id":"33333333-3333-3333-3333-333333333333"}'::jsonb);
    if (v_r->>'edges_revived')::int <> 0 then
        raise exception 'a merge onto a live edge was counted as a revival: %', v_r;
    end if;

    raise notice 'graph-index: a re-assertion revives a retracted edge and says so';
end $$;

-- ---------------------------------------------------------------------
-- 15. THE CATALOGUE TELLS THE TRUTH ABOUT WHAT IT ACCEPTS.
--
-- `graph_vocabulary` holds forward names only, and `upsert_graph` also takes
-- any of their `inverse_label`s and stores them flipped. A consumer told to
-- pre-filter its extractor's output against the vocabulary therefore discards
-- exactly the edges the flip exists to recover -- which is not hypothetical:
-- percolate-coherence did it, and its own counter reported the drops as a
-- vocabulary gap while the substrate would have landed them.
--
-- `graph_accepted_relations` is the discoverable answer, and this pins that it
-- agrees with the resolution `upsert_graph` actually performs rather than
-- being a second, drifting copy of it.
-- ---------------------------------------------------------------------
do $$
declare v_r jsonb; v_fwd text; v_inv text;
begin
    -- A relation in the vocabulary that has an inverse: the inverse must be
    -- offered as accepted, and must say what it is stored as.
    select rt.relation, rt.inverse_label into v_fwd, v_inv
      from aiq.relation_types rt
      join aiq.graph_vocabulary gv on gv.relation = rt.relation
     where rt.inverse_label is not null
       and not exists (select 1 from aiq.graph_vocabulary v where v.relation = rt.inverse_label)
     limit 1;
    if v_fwd is null then
        raise exception 'the fixture has no vocabulary relation with an inverse to test';
    end if;

    if not exists (select 1 from aiq.graph_accepted_relations
                    where accepted = v_inv and stored_as = v_fwd and flipped) then
        raise exception
            'upsert_graph accepts % and stores it as %, and '
            'graph_accepted_relations does not say so', v_inv, v_fwd;
    end if;

    -- Every forward name is accepted as itself, unflipped.
    if exists (select 1 from aiq.graph_vocabulary gv
                where not exists (select 1 from aiq.graph_accepted_relations a
                                   where a.accepted = gv.relation
                                     and a.stored_as = gv.relation
                                     and not a.flipped)) then
        raise exception 'a vocabulary relation is not listed as accepted as itself';
    end if;

    -- And the view does not over-promise: a name it does not list must still
    -- be dropped by upsert_graph, or a consumer trusting it lands nothing.
    v_r := aiq.upsert_graph($g${
      "nodes": [{"k":"ord","n":"Accepted Alpha"},{"k":"ord","n":"Accepted Beta"}],
      "edges": [{"s":0,"t":1,"r":"reticulates"}]}$g$::jsonb, '{"agent":"t"}'::jsonb);
    if exists (select 1 from aiq.graph_accepted_relations where accepted = 'reticulates') then
        raise exception 'the view lists a relation upsert_graph does not accept';
    end if;
    if (v_r->'edges_dropped_unknown_relation') <> '["reticulates"]'::jsonb then
        raise exception 'a relation absent from the view was not dropped: %', v_r;
    end if;

    raise notice 'graph-index: the accepted-relations view matches what upsert_graph resolves';
end $$;

rollback;
\echo 'graph-index: all assertions passed'
