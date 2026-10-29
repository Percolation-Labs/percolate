# Step 1: the walk beside plain search, for the same number of reads.
#
# "How did my focus on ... change over the sessions?" asks about 27 of the 1,058 exchanges in 1M:35. The walk is a
# workflow: search reads the first ten, then each wave Jev judges the clues the last wave's reads raised, and the wave
# travels the accepted ones. 'offline' answers every clue from the sample's replay document, so this costs $0; drop
# it, with JEV_API_KEY bound to the worker, to judge new clues live.
# The recorded verdicts were given under span 2 and cap 10, the defaults before 0.2.33, so the walk is pinned to them:
# under wider settings it would raise leads its replay never judged.
RUN=$(psql "$P8_DSN" -Atc "
  select workflow.start_workflow('walk', jsonb_build_object(
           'question', jsonb_build_object('id', r.metadata->>'id', 'text', r.metadata->>'text'), 'channel', r.metadata->>'channel',
           'replay', 'replay:' || (r.metadata->>'id'), 'offline', true,
           'settings', jsonb_build_object('span', 2, 'cap', 10)))
    from content.resources r where r.uri = 'question:1M:35:event_ordering:0'")
until [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$RUN'")" != running ]; do sleep 2; done

# The answer key is the benchmark's: the harness reads it from the sample's file and passes it in, and the walk never
# holds it.
psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 build/labels.py samples/beam/questions.jsonl 1M:35:event_ordering:0)" <<'SQL'
-- Each step of the run is a task row; each wave judged its clues, then read.
select step_key, status from workflow.tasks where run_id = :'run' and status <> 'skipped' order by created_at;

-- What each wave did: reads, the clues it judged and accepted, and the accepted leads still open.
select wave, reads, judged, accepted, open_leads, total_reads from aiq.walk_waves(:'run');

-- The walk beside plain search: of the labelled evidence, how much the walk had read by the end of each wave, and
-- how much search's own top N held, for the same N.
select w.wave, c.k as reads, c.walk as walk_found, c.search as search_found, c.labelled as evidence
  from aiq.walk_waves(:'run') w
  join aiq.walk_coverage(:'run', :'labelled', array(select total_reads from aiq.walk_waves(:'run'))) c
    on c.k = w.total_reads
 order by w.wave;
SQL
