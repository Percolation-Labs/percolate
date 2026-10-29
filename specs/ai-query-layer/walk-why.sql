-- ============================================================
-- WHY A WALK'S ANSWER IS INCOMPLETE, FROM THE RUN'S OWN ROWS (REM-1211)
--
-- A walk is a workflow run (REM-1210), and everything it did is a row: the
-- reads (aiq.walk_reads), every clue with its targets, P, gate decision and
-- state at the stop (aiq.walk_clues), each wave's temperature (aiq.walk_waves)
-- and the stop itself (aiq.walk_summary). These two functions read only those,
-- so what they say is what the walk saw. A field the run does not hold comes
-- back as 'missing', never filled in (Sirsh, M-20261026-140822-3be4).
--
--   aiq.walk_audit(run)      needs no answer key: the state at the stop, the
--                            accepted leads still open, and the rejected leads
--                            just under the gate that still point at unread
--                            documents.
--   aiq.walk_why(run, nodes) for each labelled node the walk did not read,
--                            the first of these that holds:
--        queued         (c) a travelled lead landed it; the walk stopped first
--        open           (c) an accepted lead pointing at it was open at the
--                           stop, with its rank among the open leads by P
--        rejected       (b) the best judged lead pointing at it was under the
--                           gate, with its P
--        unjudged       (?) a lead pointed at it but holds no P (an offline
--                           run), or an accepted lead neither travelled nor
--                           open, which the walk should never leave
--        never offered  (a) no clue raised in the walk pointed at it
--
-- The rules are percolate-core's percolate_core/walk/why.py, which reads the
-- same walk from a record file; dev/tests/query/33-a-walk-says-why-its-answer-is-incomplete.sql holds the two
-- to the same answers. The study's finer reasons for (a) -- a term above the
-- cap, a document linked only from a read that raised no leads -- need the
-- graph as it stood, which the run's rows do not hold, so they are not guessed.
--
-- The state at the stop is judged on the last wave that read:
--   unknown   that wave expanded no read (fresh is null): its temperature
--             says nothing
--   ran dry   a wave found nothing left to read; named by that wave, as the
--             run's stop records it, not by the last wave that read
--   warm      at least explain.cold (aiq.parameters, 0.05) of that wave's expanded reads raised a newly
--             accepted lead (sally's calibration, REM-1194); a warm walk
--             that ran out of waves says it stopped at the wave limit
--   cold      under it; with no accepted lead open it is the certificate
-- A clue nobody judged (an offline run) could not have been accepted: with no
-- clue judged the state is unknown, and while unjudged clues still point at
-- unread documents a walk earns no certificate.
-- Both functions run as the caller and read only through REM-1210's functions,
-- which read the caller's own run.
-- ============================================================

create or replace function aiq.walk_audit(p_run uuid)
returns jsonb language plpgsql stable as $$
declare
    v_summary jsonb := aiq.walk_summary(p_run);
    -- the walk rebuilt from the run's rows, once: every view below reads this build (aiq.walk_state_*)
    v_st      jsonb := aiq.walk_state(p_run);
    v_gate    real  := (v_summary #>> '{settings,gate}')::real;
    v_cold    real  := (aiq.parameter('explain.cold', (select created_at from aiq.walk_run(p_run))) #>> '{}')::real;
    v_band    real  := (aiq.parameter('explain.near_miss', (select created_at from aiq.walk_run(p_run))) #>> '{}')::real;
    v_waves   jsonb := (select jsonb_agg(to_jsonb(w) order by w.wave) from aiq.walk_state_waves(v_st) w);
    v_last    record;
    v_open    jsonb;
    v_near    jsonb;
    v_blind   int;     -- unjudged clues that still point at unread documents
    v_ending  text;
    v_state   text;
    v_judged   int;
    v_accepted int;
    v_unjudged int;
begin
    -- the last wave that read: an empty wave after it has no temperature of its own
    select (w->>'wave')::int as wave, (w->>'fresh')::real as fresh into v_last
      from jsonb_array_elements(v_waves) w where (w->>'reads')::int > 0
     order by (w->>'wave')::int desc limit 1;

    with r as (select distinct doc from aiq.walk_state_reads(v_st)),
         c as (select c.*, (select count(*) from unnest(c.targets) t where t not in (select doc from r)) as unread
                 from aiq.walk_state_clues(v_st) c)
    select count(*) filter (where p is null and unread > 0),
           coalesce(jsonb_agg(jsonb_build_array(key, p, unread) order by p desc, key)
                        filter (where state = 'open' and unread > 0), '[]'),
           coalesce(jsonb_agg(jsonb_build_array(key, p, unread) order by p desc, key)
                        -- the band as real: P is real, and real 0.35 is under numeric 0.35, which dropped every lead at 0.35
                        filter (where decision = 'rejected' and p >= v_band and p < v_gate and unread > 0), '[]'),
           count(*) filter (where p is not null),
           count(*) filter (where decision = 'accepted'),
           count(*) filter (where p is null)
      into v_blind, v_open, v_near, v_judged, v_accepted, v_unjudged
      from c;

    -- The certificate says no lead the walk could have followed is left. A clue nobody judged could not be
    -- accepted, so while one still points at unread documents there is no certificate, only the count.
    v_ending := case when jsonb_array_length(v_open) > 0 then 'accepted leads open'
                     when v_blind > 0 then format('no accepted lead open, but %s unjudged leads still point at '
                                                  'unread documents (no certificate)', v_blind)
                     else 'no accepted lead open (certificate)' end;
    v_state := case
        when v_last.wave is null
            then 'missing: the run holds no wave that read'
        when v_judged = 0 and v_unjudged > 0
            then 'unknown: no clue was judged (an offline run), so no lead could be accepted'
        when v_last.fresh is null
            then 'unknown: the last wave expanded no read, so its temperature says nothing'
        -- the stop named as the run records it: a dry stop is the wave that found nothing left to read
        when v_summary #>> '{stop,reason}' = 'dry'
            then format('ran dry at wave %s: nothing left to read; %s', v_summary #>> '{stop,wave}', v_ending)
        when v_last.fresh >= v_cold and v_summary #>> '{stop,reason}' = 'waves'
            then format('stopped at the wave limit (wave %s), still finding new accepted leads',
                        v_summary #>> '{stop,wave}')
        when v_last.fresh >= v_cold
            then 'warm: still finding new accepted leads'
        else 'cold, ' || v_ending
    end;

    return jsonb_build_object(
        'question',        coalesce(v_summary -> 'question', '"missing"'),
        'reads',           coalesce(v_summary -> 'reads', '"missing"'),
        'waves',           coalesce((select jsonb_agg(w->'reads' order by (w->>'wave')::int) from jsonb_array_elements(v_waves) w), '"missing"'),
        'stop',            coalesce(nullif(v_summary -> 'stop', 'null'), '"missing"'),  -- a JSON null is missing too
        'gate',            coalesce(to_jsonb(v_gate), '"missing"'),
        'state',           v_state,
        'last wave fresh', case when v_last.wave is null then '"missing"' else to_jsonb(v_last.fresh) end,
        'judged',          v_judged,
        'accepted',        v_accepted,
        'unjudged',        v_unjudged,
        'queued',          coalesce(jsonb_array_length(v_summary -> 'pending'), 0),
        'open',            v_open,
        'near misses',     case when v_gate is null then '"missing"' else v_near end);
end $$;

comment on function aiq.walk_audit(uuid) is
    'A walk run''s audit with no answer key: the state at the stop, the accepted leads still open and the near misses (REM-1211).';


drop function if exists aiq.walk_why(uuid, jsonb);
create or replace function aiq.walk_why(p_run uuid, p_nodes text[])
returns table (doc text, letter text, reason text, key text, p real, detail text)
language plpgsql stable as $$
declare
    v_summary jsonb := aiq.walk_summary(p_run);
    v_st      jsonb := aiq.walk_state(p_run);  -- built once, for both views below
    v_gate    real  := coalesce((v_summary #>> '{settings,gate}')::real, 0.5);
begin
    -- the labelled nodes come from the caller: a walk's question is {node_id, text} and never carries them (REM-1231)
    if p_nodes is null then
        raise exception 'no labelled nodes: pass the keys the walk should have read'
            using errcode = 'invalid_parameter_value',
                  hint = 'select * from aiq.walk_why(<run>, array[''<node key>'', ...])';
    end if;

    return query
    with r       as (select distinct w.doc from aiq.walk_state_reads(v_st) w),
         pending as (select jsonb_array_elements_text(coalesce(v_summary -> 'pending', '[]')) as doc),
         c       as (select c.*, exists (select 1 from unnest(c.targets) t where t not in (select r.doc from r)) as live
                       from aiq.walk_state_clues(v_st) c),
         opn     as (select c.key, c.p, c.targets from c where c.state = 'open' and c.live),
         gold    as (select distinct g as doc from unnest(p_nodes) g),
         unread  as (select g.doc from gold g where g.doc not in (select r.doc from r))
    select u.doc,
           case w.reason when 'queued' then 'c' when 'open' then 'c' when 'rejected' then 'b'
                         when 'unjudged' then '?' else 'a' end,
           w.reason, w.key, w.p, w.detail
      from unread u
      cross join lateral (
          select x.* from (
              select 1 as k, 'queued' as reason, null::text as key, null::real as p,
                     'a travelled lead landed it; the walk stopped before reading it' as detail
               where u.doc in (select pending.doc from pending)
              union all
              (select 2, 'open', o.key, o.p,
                      format('rank %s of %s open by P',
                             1 + (select count(*) from opn o2 where o2.p > o.p), (select count(*) from opn))
                 from opn o where u.doc = any(o.targets)
                order by o.p desc, o.key desc limit 1)
              union all
              (select 3, case when j.p < v_gate then 'rejected' else 'unjudged' end, j.key, j.p,
                      case when j.p < v_gate then null
                           else 'accepted but neither travelled nor open: the run is inconsistent' end
                 from c j where u.doc = any(j.targets) and j.p is not null
                order by j.p desc, j.key desc limit 1)
              union all
              (select 4, 'unjudged', j.key, null::real, 'no P recorded'
                 from c j where u.doc = any(j.targets) and j.p is null
                order by j.key limit 1)
              union all
              select 5, 'never offered', null, null, 'no clue raised in the walk pointed at it'
          ) x order by x.k limit 1
      ) w
     order by u.doc;
end $$;

comment on function aiq.walk_why(uuid, text[]) is
    'For each labelled node a walk run did not read: (a) never offered, (b) rejected with its P, (c) open or queued at the stop (REM-1211). The caller passes the labels; the run never holds them (REM-1231).';


-- How much of a labelled node set a run had read by each budget k, beside how much of it search's own top k held.
-- One function for every evaluation, so no query counts reads by hand (REM-1231). The labels come from the caller:
-- the run is not asked what it should have found, and the same set compares any runs, one lateral call each:
--     select r.id, c.* from runs r, aiq.walk_coverage(r.id, :'labelled', array[50, 100, 500]) c;
-- A node read twice counts once, at its first read; k past the run's last read counts every read. With no budgets,
-- one row at k = every read the run made.
create or replace function aiq.walk_coverage(p_run uuid, p_nodes text[], p_budgets int[] default null)
returns table (k int, walk int, search int, labelled int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with lab as (select distinct n from unnest(p_nodes) n),
         r   as (select doc, row_number() over (order by wave, ord) as n from aiq.walk_reads(p_run)),
         wr  as (select doc, min(n) as n from r where doc in (select n from lab) group by doc),
         sr  as (select doc, min(rank) as n from aiq.walk_search_order(p_run) where doc in (select n from lab) group by doc)
    select b.k,
           (select count(*) from wr where wr.n <= b.k)::int,
           (select count(*) from sr where sr.n <= b.k)::int,
           (select count(*) from lab)::int
      from unnest(coalesce(p_budgets, array[(select count(*) from r)::int])) with ordinality b(k, i)
     order by b.i
$$;

comment on function aiq.walk_coverage(uuid, text[], int[]) is
    'Of a labelled node set the caller passes, how many a walk run had read by each budget k, and how many search''s own top k held (REM-1231).';
