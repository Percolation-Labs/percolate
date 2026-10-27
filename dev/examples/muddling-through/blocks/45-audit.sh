# The audit: every walk steps 1 to 4 ran, asked why its answer is incomplete. aiq.walk_audit needs no answer key: it
# says why the walk stopped and whether it earned the certificate (cold, with no accepted lead open). aiq.walk_why
# takes the key from the run's question and gives each piece of evidence the walk did not read one reason: (a) no
# lead to it was ever offered, (b) every lead to it was rejected, (c) a lead to it was still open or queued when the
# walk stopped, or (?) a lead to it was never judged. Step 3 reads one walk's reasons row by row; here they are counted.
psql "$P8_DSN" <<'SQL'
with runs as (
  select r.id, r.created_at, coalesce(r.input->'question'->>'id', r.input->'question'->>'qid') as question,
         case when r.input->'settings'->>'wave' = '320' then 'step 2'
              when r.input->'question'->>'phrasing' = 'instruction'
              then 'step 4, ' || case when r.input->'settings' ? 'near_miss' then 'near misses' else 'accepted only' end
              when r.input->'question'->>'id' = '1M:35:event_ordering:0' then 'step 1'
              when r.input->'question'->>'qid' = '1M:22:multi_session_reasoning:1' then 'step 3' end as step
    from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
   where d.name in ('walk', 'walk_20') and r.status = 'succeeded'),
why as (
  select r.id, w.letter from runs r cross join lateral aiq.walk_why(r.id) w)
select r.step, r.question, a->>'state' as state,
       (a->'reads')::int as reads,
       jsonb_array_length(aiq.walk_summary(r.id)->'question'->'gold') as evidence,
       count(*) filter (where w.letter = 'a') as a,
       count(*) filter (where w.letter = 'b') as b,
       count(*) filter (where w.letter = 'c') as c,
       count(*) filter (where w.letter = '?') as unjudged
  from runs r
  cross join lateral aiq.walk_audit(r.id) a
  left join why w on w.id = r.id
 where r.step is not null
 group by r.step, r.question, r.id, a
 order by r.step, r.question;
SQL
