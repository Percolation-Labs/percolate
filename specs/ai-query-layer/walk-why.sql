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
--   aiq.walk_why(run, gold)  for each evidence document the walk did not read,
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
--   ran dry   the walk found nothing left to read before its last wave
--   warm      at least 0.05 of that wave's expanded reads raised a newly
--             accepted lead (sally's calibration, REM-1194)
--   cold      under 0.05; with no accepted lead open it is the certificate
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
    v_gate    real  := (v_summary #>> '{settings,gate}')::real;
    v_last    record;
    v_open    jsonb;
    v_near    jsonb;
    v_blind   int;     -- unjudged clues that still point at unread documents
    v_ending  text;
    v_state   text;
    v_counts  record;
begin
    -- the last wave that read: an empty wave after it has no temperature of its own
    select * into v_last from aiq.walk_waves(p_run) w where w.reads > 0 order by w.wave desc limit 1;

    with r as (select distinct doc from aiq.walk_reads(p_run)),
         c as (select c.*, (select count(*) from unnest(c.targets) t where t not in (select doc from r)) as unread
                 from aiq.walk_clues(p_run) c)
    select count(*) filter (where p is null and unread > 0),
           coalesce(jsonb_agg(jsonb_build_array(key, p, unread) order by p desc, key)
                        filter (where state = 'open' and unread > 0), '[]'),
           coalesce(jsonb_agg(jsonb_build_array(key, p, unread) order by p desc, key)
                        -- 0.35 as real: P is real, and real 0.35 is under numeric 0.35, which dropped every lead at 0.35
                        filter (where decision = 'rejected' and p >= 0.35::real and p < v_gate and unread > 0), '[]')
      into v_blind, v_open, v_near
      from c;

    select count(*) filter (where p is not null) as judged,
           count(*) filter (where decision = 'accepted') as accepted,
           count(*) filter (where p is null) as unjudged
      into v_counts
      from aiq.walk_clues(p_run);

    -- The certificate says no lead the walk could have followed is left. A clue nobody judged could not be
    -- accepted, so while one still points at unread documents there is no certificate, only the count.
    v_ending := case when jsonb_array_length(v_open) > 0 then 'accepted leads open'
                     when v_blind > 0 then format('no accepted lead open, but %s unjudged leads still point at '
                                                  'unread documents (no certificate)', v_blind)
                     else 'no accepted lead open (certificate)' end;
    v_state := case
        when v_last.wave is null
            then 'missing: the run holds no wave that read'
        when v_counts.judged = 0 and v_counts.unjudged > 0
            then 'unknown: no clue was judged (an offline run), so no lead could be accepted'
        when v_last.fresh is null
            then 'unknown: the last wave expanded no read, so its temperature says nothing'
        when v_summary #>> '{stop,reason}' = 'dry'
            then format('ran dry after wave %s; %s', v_last.wave, v_ending)
        when v_last.fresh >= 0.05
            then 'warm: still finding new accepted leads'
        else 'cold, ' || v_ending
    end;

    return jsonb_build_object(
        'question',        coalesce(v_summary -> 'question', '"missing"'),
        'reads',           coalesce(v_summary -> 'reads', '"missing"'),
        'waves',           (select coalesce(jsonb_agg(w.reads order by w.wave), '"missing"') from aiq.walk_waves(p_run) w),
        'stop',            coalesce(v_summary -> 'stop', '"missing"'),
        'gate',            coalesce(to_jsonb(v_gate), '"missing"'),
        'state',           v_state,
        'last wave fresh', case when v_last.wave is null then '"missing"' else to_jsonb(v_last.fresh) end,
        'judged',          v_counts.judged,
        'accepted',        v_counts.accepted,
        'unjudged',        v_counts.unjudged,
        'queued',          coalesce(jsonb_array_length(v_summary -> 'pending'), 0),
        'open',            v_open,
        'near misses',     case when v_gate is null then '"missing"' else v_near end);
end $$;

comment on function aiq.walk_audit(uuid) is
    'A walk run''s audit with no answer key: the state at the stop, the accepted leads still open and the near misses (REM-1211).';


create or replace function aiq.walk_why(p_run uuid, p_gold jsonb default null)
returns table (doc text, letter text, reason text, key text, p real, detail text)
language plpgsql stable as $$
declare
    v_summary jsonb := aiq.walk_summary(p_run);
    v_gate    real  := coalesce((v_summary #>> '{settings,gate}')::real, 0.5);
    v_gold    jsonb := p_gold;
begin
    -- the answer key is a list of document keys, or {question id: list}; with none given, the one the sample put in
    -- the run's start input (walk_summary -> question -> gold), which no step of the walk reads
    if p_gold is null then
        v_gold := v_summary #> '{question,gold}';
        if v_gold is null then
            raise exception 'no answer key: pass one, or start the walk with the question''s gold'
                using errcode = 'invalid_parameter_value',
                      hint = 'select * from aiq.walk_why(<run>, ''["<document key>", ...]'')';
        end if;
    elsif jsonb_typeof(p_gold) = 'object' then
        v_gold := p_gold -> (v_summary #>> '{question,id}');
        if v_gold is null then
            raise exception 'the answer key holds no evidence for question %', v_summary #>> '{question,id}'
                using errcode = 'invalid_parameter_value';
        end if;
    end if;
    if jsonb_typeof(v_gold) is distinct from 'array' then
        raise exception 'the answer key is a JSON list of document keys, or {question id: list}'
            using errcode = 'invalid_parameter_value';
    end if;

    return query
    with r       as (select distinct w.doc from aiq.walk_reads(p_run) w),
         pending as (select jsonb_array_elements_text(coalesce(v_summary -> 'pending', '[]')) as doc),
         c       as (select c.*, exists (select 1 from unnest(c.targets) t where t not in (select r.doc from r)) as live
                       from aiq.walk_clues(p_run) c),
         opn     as (select c.key, c.p, c.targets from c where c.state = 'open' and c.live),
         gold    as (select distinct g #>> '{}' as doc from jsonb_array_elements(v_gold) g),
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

comment on function aiq.walk_why(uuid, jsonb) is
    'For each evidence document a walk run did not read: (a) never offered, (b) rejected with its P, (c) open or queued at the stop (REM-1211). With no answer key, the run''s own question gold.';
