-- ============================================================
-- Which edges are load-bearing, and which weights are.
--
-- `aiq.edges` already records two things nothing reads back: `recall_count`
-- and `probe_count`, written by `aiq.note_recall` and `aiq.note_probe`. The
-- counters shipped in core and the three views that make sense of them shipped
-- inside one application, which is the wrong way round -- every graph wants to
-- know which of its edges answer questions, and none of it is domain-specific.
--
-- Three separate questions, deliberately not fused into a score:
--
--   STANDING     has this edge ever answered a real question
--   DISPARITY    is this edge's weight distinguishable from a null that
--                partitions a node's strength uniformly
--   NEIGHBOURS   read a node's neighbourhood AND record that you did
--
-- A single "importance" number over the three would be a weight fitted against
-- nothing, and this collection's rule is that such a number is not eligible for
-- core. Each view reports its own evidence and lets the caller combine them.
--
-- TENANCY. Everything here reads `aiq.edges`, `aiq.edges_current` and
-- `aiq.node_keys`, all of which carry row-level security, and everything here
-- is SECURITY INVOKER. `aiq.neighbours` writes -- it increments a counter --
-- and it must remain INVOKER for the same reason it must be allowed to write:
-- a caller may only ever mark edges they can already read.
-- ============================================================

-- IS THIS TRAFFIC REAL? A session declares itself a probe, and the default is
-- that it is NOT -- because the failure to guard against is a probe silently
-- counting as use, and a default of `false` makes forgetting to set it produce
-- the loud error rather than the quiet one.
--
-- `set local percolate.probe = 'on'` outside a transaction silently does
-- nothing, which is how a probe once counted as real traffic for a week. The
-- separate entry point on aiq.note_probe exists so that a caller states the
-- intent rather than setting a variable and hoping.
create or replace function aiq.is_probe() returns boolean
language sql stable as $$
    select coalesce(current_setting('percolate.probe', true), 'off')
           in ('on','true','1');
$$;

-- WHAT AN EDGE'S HISTORY OF USE SAYS ABOUT IT. An edge that is merely still
-- true is a different object from one that is stale and load-bearing, and
-- until the counters existed the two were indistinguishable.
--
-- `only ever probed` is its own state rather than folded into `never used`,
-- because they call for opposite actions: the first says the monitoring found
-- it and nobody else did, the second says nothing has ever looked.
-- SECURITY INVOKER, EXPLICITLY. A view's default is to run as its OWNER, and
-- the owner here is `app_owner`, which owns `aiq.edges` and is therefore not
-- subject to its row-level security (the table is RLS-enabled but not FORCE
-- RLS, and a table owner bypasses its own policies). A view left on the default
-- would hand every org's edges to any caller granted select on it.
--
-- This instance cannot demonstrate that, because every edge in it carries a
-- null org_id and is shared by the design's own rule -- which is exactly why
-- the setting is stated rather than tested into existence. A tenancy property
-- that holds only because the data happens to be single-tenant is not a
-- property.
create or replace view aiq.edge_standing with (security_invoker = true) as
select e.id, e.relation,
       coalesce(e.provenance->>'from', 'unknown') as source,
       e.weight, e.recall_count, e.probe_count,
       e.valid_from::date as asserted, e.last_recalled_at,
       case
           when not aiq.edge_is_current(e.valid_from, e.valid_to, now())
                                                          then 'retracted'
           when e.recall_count = 0 and e.probe_count > 0  then 'only ever probed'
           when e.recall_count = 0                        then 'never used'
           else 'load-bearing' end as standing
from aiq.edges e;

-- THE DISPARITY FILTER, Serrano et al's backbone extraction.
--
-- For node i with degree k and strength s, an incident edge's normalised
-- weight is p = w/s. Under the null that the strength is partitioned uniformly
-- at random across the k incident edges, the probability of seeing a share at
-- least this large is (1 - p)^(k-1). Small alpha means the weight is not what
-- a uniform split would produce.
--
-- REPORTED, NOT APPLIED. The view returns alpha for both endpoints and filters
-- nothing: the significance level is the caller's decision and a graph has no
-- business choosing it. Fusing a threshold in here would be the same mistake as
-- fusing the three views into a score.
--
-- DEGREE 1 CANNOT BE RULED ON -- the null has no variance when a node has one
-- incident edge, so alpha is 1 by construction. Returned as NULL rather than
-- folded into "not significant", because "no evidence either way" and "evidence
-- of no effect" are different states and only one of them is evidence.
create or replace view aiq.edge_disparity with (security_invoker = true) as
with strength as (
    -- Undirected, because the null is per-node and a node's incident set is
    -- what the strength is partitioned across regardless of direction.
    select node_id, sum(weight) as s, count(*) as k
    from (select src_id as node_id, weight from aiq.edges_current
          union all
          select dst_id, weight from aiq.edges_current) x
    group by node_id)
select e.id, e.src_id, e.dst_id, e.relation, e.weight,
       ss.k as k_src, ds.k as k_dst,
       case when ss.k > 1
            then power(1 - (e.weight / nullif(ss.s,0))::numeric, ss.k - 1) end as alpha_src,
       case when ds.k > 1
            then power(1 - (e.weight / nullif(ds.s,0))::numeric, ds.k - 1) end as alpha_dst
from aiq.edges_current e
join strength ss on ss.node_id = e.src_id
join strength ds on ds.node_id = e.dst_id;

-- THE READ PATH THAT COUNTS. A caller asking a real question about a node gets
-- its neighbourhood and, as a side effect, marks the edges it actually used.
--
-- A function rather than a view, because a view cannot record that it was read
-- and a trigger does not fire on SELECT. The write is the point: an edge that
-- answers questions is different from one that merely still holds, and nothing
-- else can tell them apart.
--
-- DEPTH ONE, and not a parameter. A depth-n traversal that marks everything it
-- walked would credit edges the caller never looked at, which is the opposite
-- of what the counter is for. Callers wanting reach have `aiq.query`'s GRAPH
-- mode and the compiled algorithms; this one is small on purpose.
create or replace function aiq.neighbours(p_key text, p_probe boolean default false)
returns table (relation text, direction text, other_key text, weight real,
               recall_count bigint, provenance jsonb)
language plpgsql stable as $$
declare v_node uuid;
begin
    select node_id into v_node from aiq.node_keys
     where key = p_key and kind = 'canonical' limit 1;
    if v_node is null then return; end if;

    return query
    with touched as (
        select e.id, e.relation, 'out'::text as direction, e.dst_id as other,
               e.weight, e.recall_count, e.provenance
          from aiq.edges_current e where e.src_id = v_node
        union all
        select e.id, e.relation, 'in', e.src_id, e.weight, e.recall_count,
               e.provenance
          from aiq.edges_current e where e.dst_id = v_node),
    noted as (
        select case when p_probe
                    then aiq.note_probe(array(select id from touched))
                    else aiq.note_recall(array(select id from touched)) end)
    select t.relation, t.direction, k.key, t.weight, t.recall_count, t.provenance
      from touched t
      join aiq.node_keys k on k.node_id = t.other and k.kind = 'canonical'
      cross join noted;
end $$;

comment on view aiq.edge_standing is
    'Per edge: whether it has ever answered a real question, only ever been '
    'probed, never been used, or been retracted.';
comment on view aiq.edge_disparity is
    'Serrano backbone extraction: alpha per endpoint under a uniform-partition '
    'null. Reports, never filters -- the significance level is the caller''s.';
comment on function aiq.neighbours(text, boolean) is
    'A node''s depth-one neighbourhood, recording that the edges were read.';
