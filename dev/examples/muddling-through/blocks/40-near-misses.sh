# Step 4: explore the near misses. A decider's "no" just under the gate is often a "yes" it was not sure of. With
# settings.near_miss = {band: 0.35, every: 3}, every third travel takes the best rejected clue whose P is at least
# 0.35, when one still leads somewhere unread.
#
# walk-0's six instruction questions ask for an instruction the user gave, which the walk can only reach through
# leads the decider doubts. Each runs twice, offline from its complete replay ($0): accepted clues only, then with
# near misses. Both stop at, and are counted at, the same 1,600 reads.
# walk-0's replay answers every lead, so any settings work; the walk is pinned to span 2 and cap 10, the defaults
# before 0.2.33, which the article's counts were taken under.
# Twelve walks, four at a time, each in its own connection: a walk runs to its end inside start_workflow. Twelve at
# once ran Postgres out of memory on an 8 GB Docker VM.
# Ten waves of 160 is the 1,600 reads both are counted at.
n=0
for q in $(psql "$P8_DSN" -Atc "select r.metadata->>'id' from content.resources r
                                where r.uri like 'question:walk-0/%' and r.metadata->>'phrasing' = 'instruction'"); do
  for arm in '{}' '{"near_miss": {"band": 0.35, "every": 3}}'; do
    psql "$P8_DSN" -Atc "
      select workflow.start_workflow('walk', jsonb_build_object(
               'question', jsonb_build_object('id', r.metadata->>'id', 'text', r.metadata->>'text'), 'nodes', 'world_item', 'prefix', 'walk-0/',
               'replay', 'replay:' || (r.metadata->>'id'), 'offline', true,
               'settings', jsonb_build_object('wave', 160, 'waves', 10, 'span', 2, 'cap', 10) || '$arm'::jsonb))
        from content.resources r where r.uri = 'question:$q'" > /dev/null &
    n=$((n + 1)); [ $((n % 4)) = 0 ] && wait
  done
done
wait
until [ "$(psql "$P8_DSN" -Atc "select count(*) from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
                                 where d.name = 'walk' and r.status = 'running'")" = 0 ]; do sleep 2; done

psql "$P8_DSN" -v labels="$(python3 build/labels.py samples/walk-0/questions.jsonl --where phrasing=instruction)" <<'SQL'
-- Each question's two walks, and the evidence each had read by read 1,600. The harness passes the world's answer key
-- for the six questions; the walks never held it.
-- aiq.walk_state(run) builds a walk's state from its rows once; the walk_state_* views read from that one state.
with runs as materialized (
  select r.id, r.input->'question'->>'id' as question,
         case when r.input->'settings' ? 'near_miss' then 'near misses' else 'accepted only' end as arm,
         aiq.walk_state(r.id) as st
    from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
   where d.name = 'walk' and (:'labels')::jsonb ? (r.input->'question'->>'id')),
found as (
  select question, arm, c.walk as read, c.labelled as evidence,
         (select count(*) from aiq.walk_state_clues(st) where decision = 'rejected' and state = 'travelled') as near_misses
    from runs,
         aiq.walk_coverage(runs.id, array(select jsonb_array_elements_text((:'labels')::jsonb -> runs.question)),
                           array[1600]) c)
select arm, sum(read) as evidence_read_by_1600, sum(evidence) as evidence, sum(near_misses) as near_misses_travelled
  from found group by arm order by arm;
SQL
