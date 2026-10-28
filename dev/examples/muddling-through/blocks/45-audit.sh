# The audit: four of the walks steps 2 to 4 ran, chosen so that between them they show every way a walk ends.
# aiq.walk_audit needs no answer key: it says why the walk stopped and whether it earned the certificate (cold, with
# no accepted lead open). aiq.walk_why takes the benchmark's key from the harness and gives each piece of evidence the walk
# did not read one reason: (b) every lead to it was rejected, with the best P under the gate, or (c) a lead to it was
# still open when the walk stopped. The block starts no walk; it reads the runs the steps left.
psql "$P8_DSN" -v labels="$(python3 build/labels.py samples/walk-0/questions.jsonl samples/beam/questions.jsonl)" <<'SQL'
with chosen(n, step, question, near, shows) as (values
  (1, 'step 2', 'walk-0/q6', false,
      'complete: it ran dry with no accepted lead open, so it earns the certificate'),
  (2, 'step 3', '1M:22:multi_session_reasoning:1', false,
      'incomplete: the missing evidence sits behind open leads ranked too low to reach'),
  (3, 'step 4', 'walk-0/q19', false,
      'incomplete: every lead to the instruction was rejected under the gate'),
  (4, 'step 4', 'walk-0/q19', true,
      'the same question with near misses explored: the rejected leads are followed, and it reads both')),
runs as (
  select c.*, r.id
    from chosen c
    join workflow.runs r on r.input->'question'->>'id' = c.question
                        and coalesce(r.input->'settings' ? 'near_miss', false) = c.near
                        and r.status = 'succeeded'
   where c.step <> 'step 2' or r.input->'settings'->>'wave' = '320'),
audit as materialized (
  select r.n, r.step, r.shows, aiq.walk_audit(r.id) as a, cv.walk, cv.labelled,
         (select coalesce(jsonb_agg(jsonb_build_object('letter', w.letter, 'p', w.p)), '[]')
            from aiq.walk_why(r.id, l.nodes) w) as why
    from runs r,
         lateral (select array(select jsonb_array_elements_text((:'labels')::jsonb -> r.question)) as nodes) l,
         aiq.walk_coverage(r.id, l.nodes) cv)
select step, a->'question'->>'id' as question, a->>'state' as state,
       walk || ' of ' || labelled as evidence_read,
       (select count(*) from jsonb_array_elements(why) w where w->>'letter' = 'b') as rejected,
       (select round(max((w->>'p')::numeric), 2) from jsonb_array_elements(why) w where w->>'letter' = 'b') as best_p,
       (select count(*) from jsonb_array_elements(why) w where w->>'letter' = 'c') as open,
       shows
  from audit order by n;
SQL
