# Step 1: the walk beside plain search, for the same number of reads.
#
# "How did my focus on ... change over the sessions?" asks about 27 of the 1,058 exchanges in 1M:35. The walk is a
# workflow: search reads the first ten, then each wave Jev judges the clues the last wave's reads raised, and the wave
# travels the accepted ones. 'offline' answers every clue from the sample's replay document, so this costs $0; drop
# it, with JEV_API_KEY bound to the worker, to judge new clues live.
# The recorded verdicts were given under span 2 and cap 10, the defaults before 0.2.33, so the walk is pinned to them:
# under wider settings it would raise leads its replay never judged.
# The question is named by its words, and walked as its document's node. The replay is the sample's recorded verdicts
# for it, stored under the same words.
Q='How did my focus on different aspects of the holiday celebration evolve throughout our conversations in order? Mention ONLY and ONLY seven items.'
RUN=$(psql "$P8_DSN" -At -v q="$Q" <<'SQL'
select workflow.start_workflow('walk', jsonb_build_object(
         'question', jsonb_build_object('node_id', n.id, 'text', r.title), 'channel', 'beam-1m35',
         'replay', (select v.id from content.resources v join content.channels vc on vc.id = v.channel_id
                     where vc.name = 'walk-replays' and v.title = r.title),
         'offline', true, 'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'span', 2, 'cap', 10)))
  from content.resources r
  join content.channels c on c.id = r.channel_id and c.name = 'walk-questions'
  join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
 where r.title = :'q';
SQL
)
until [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$RUN'")" != running ]; do sleep 2; done

# Evaluation harness, not product: the benchmark's answer key, read from the sample's file and passed in.
psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 harness/labels.py samples/beam/questions.jsonl 1M:35:event_ordering:0)" <<'SQL'
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
