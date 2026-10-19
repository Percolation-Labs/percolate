-- A write to the graph is seen by the next read on the same connection (REM-994).
--
-- The compiled snapshot is reused while the caller's identity and the tables'
-- modification counters are unchanged, and the counters come from the stats
-- collector, which never shows a backend its own open transaction's writes. So
-- an edge written and then asked for came back absent until
-- aiq.graph_snapshot(true) was called by hand. graph-algorithms.sql now drops
-- the writing backend's snapshot from a statement-level trigger on aiq.nodes,
-- aiq.edges and rbac.org_members.
--
-- Each check reads first, so a snapshot exists to go stale, then writes, then
-- reads again on the same connection with no refresh in between:
--   1. an edge added is reached;
--   2. an edge removed is no longer reached;
--   3. the trigger cannot make a write fail for a role the compiled drop is not
--      granted to: it runs as an owner that holds it.
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

do $$
begin
    if to_regprocedure('p8_graph_ppr(uuid[],float8,float8,int,int,bool,text,bigint)') is null then
        raise exception 'the graph algorithms are not installed: query/17 reads through aiq.related()';
    end if;
end $$;

-- A node the walk from acme does not reach, and a relation to reach it by.
select k.key as isolated from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
 where k.kind = 'canonical' and n.entity_type = 'document'
   and k.key not in (select key from aiq.related(array['acme'], 200))
 order by k.key limit 1 \gset
insert into aiq.relation_types (src_type, relation, dst_type)
values ('company', 'q17_cites', 'document') on conflict do nothing;

-- 1. Added, then read.
select set_config('q17.isolated', :'isolated', true);
select count(*) as reached_before from aiq.related(array['acme'], 200) where key = :'isolated' \gset
insert into aiq.edges (src_id, dst_id, relation)
select (select node_id from aiq.node_keys where key = 'acme' and kind = 'canonical'),
       (select node_id from aiq.node_keys where key = :'isolated' and kind = 'canonical'), 'q17_cites';
select count(*) as reached_after_insert from aiq.related(array['acme'], 200) where key = :'isolated' \gset

-- 2. Removed, then read.
delete from aiq.edges where relation = 'q17_cites';
select count(*) as reached_after_delete from aiq.related(array['acme'], 200) where key = :'isolated' \gset

-- psql does not substitute its variables inside a dollar-quoted body, so the
-- three counts reach the check through a table.
create temp table q17_counts on commit drop as
select :reached_before::int as before, :reached_after_insert::int as after_ins,
       :reached_after_delete::int as after_del;

do $$
declare before int; after_ins int; after_del int;
begin
    select c.before, c.after_ins, c.after_del into before, after_ins, after_del from q17_counts c;
    if before is distinct from 0 then
        raise exception 'query/17: % was reached from acme before the edge existed', current_setting('q17.isolated');
    end if;
    if after_ins is distinct from 1 then
        raise exception 'an edge written on this connection was not seen by its next read (reached % times): '
            'the snapshot was served from before the write', after_ins;
    end if;
    if after_del is distinct from 0 then
        raise exception 'an edge deleted on this connection was still seen by its next read (reached % times)', after_del;
    end if;
end $$;

-- 3. The trigger runs as an owner that may drop, so it cannot fail a writer
--    the compiled drop is not granted to.
do $$
declare v_def boolean; v_owner name;
begin
    select p.prosecdef, pg_get_userbyid(p.proowner) into v_def, v_owner
      from pg_proc p where p.oid = 'aiq.graph_snapshot_invalidate()'::regprocedure;
    if v_def is distinct from true then
        raise exception 'aiq.graph_snapshot_invalidate is not SECURITY DEFINER: a writer without the graph '
            'algorithms would fail on it';
    end if;
    if not has_function_privilege(v_owner, 'p8_graph_snapshot_drop()', 'execute') then
        raise exception 'aiq.graph_snapshot_invalidate''s owner % cannot run p8_graph_snapshot_drop()', v_owner;
    end if;
    if (select count(*) from pg_trigger where tgname = 'graph_snapshot_invalidate'
          and tgrelid in ('aiq.nodes'::regclass, 'aiq.edges'::regclass, 'rbac.org_members'::regclass)) <> 3 then
        raise exception 'graph_snapshot_invalidate is not on all three of aiq.nodes, aiq.edges and rbac.org_members';
    end if;
    raise notice 'query/17: a write on this connection is seen by its next read, added and removed';
end $$;

rollback;
