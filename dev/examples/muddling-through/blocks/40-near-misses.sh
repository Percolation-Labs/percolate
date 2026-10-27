# Step 4: explore the near misses. A decider's "no" just under the gate is often a "yes" it was not sure of. With
# settings.near_miss = {band: 0.35, every: 3}, every third travel takes the best rejected clue whose P is at least
# 0.35, when one still leads somewhere unread.
#
# walk-0's six instruction questions ask for an instruction the user gave, which the walk can only reach through
# leads the decider doubts. Each runs twice, offline from its complete replay ($0): accepted clues only, then with
# near misses. Both stop at, and are counted at, the same 1,600 reads.
# Twelve walks, each in its own connection so they run side by side: a walk runs to its end inside start_workflow.
# Ten waves of 160 is the 1,600 reads both are counted at.
for q in $(psql "$P8_DSN" -Atc "select r.metadata->>'id' from content.resources r
                                where r.uri like 'question:walk-0/%' and r.metadata->>'phrasing' = 'instruction'"); do
  for arm in '{}' '{"near_miss": {"band": 0.35, "every": 3}}'; do
    psql "$P8_DSN" -Atc "
      select workflow.start_workflow('walk', jsonb_build_object(
               'question', r.metadata, 'nodes', 'world_item', 'prefix', 'walk-0/',
               'replay', 'replay:' || (r.metadata->>'id'), 'offline', true,
               'settings', jsonb_build_object('wave', 160, 'waves', 10) || '$arm'::jsonb))
        from content.resources r where r.uri = 'question:$q'" > /dev/null &
  done
done
wait
until [ "$(psql "$P8_DSN" -Atc "select count(*) from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
                                 where d.name = 'walk' and r.status = 'running'")" = 0 ]; do sleep 2; done

psql "$P8_DSN" <<'SQL'
-- Each question's two walks, and the evidence each had read by read 1,600. The answer key rides in the run's question.
-- aiq.walk_state(run) builds a walk's state from its rows once; the walk_state_* views read from that one state.
with runs as materialized (
  select r.id, r.input->'question'->>'id' as question,
         case when r.input->'settings' ? 'near_miss' then 'near misses' else 'accepted only' end as arm,
         aiq.walk_state(r.id) as st
    from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
   where d.name = 'walk' and r.input->'question'->>'phrasing' = 'instruction'),
found as (
  select question, arm,
         (select count(*) from (select doc, row_number() over (order by wave, ord) as n from aiq.walk_state_reads(st)) x
           where x.n <= 1600
             and x.doc in (select jsonb_array_elements_text(st->'question'->'gold'))) as read,
         jsonb_array_length(st->'question'->'gold') as evidence,
         (select count(*) from aiq.walk_state_clues(st) where decision = 'rejected' and state = 'travelled') as near_misses
    from runs)
select arm, sum(read) as evidence_read_by_1600, sum(evidence) as evidence, sum(near_misses) as near_misses_travelled
  from found group by arm order by arm;
SQL
