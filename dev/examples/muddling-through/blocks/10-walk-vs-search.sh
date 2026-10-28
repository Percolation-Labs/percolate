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
           'question', r.metadata, 'channel', r.metadata->>'channel',
           'replay', 'replay:' || (r.metadata->>'id'), 'offline', true,
           'settings', jsonb_build_object('span', 2, 'cap', 10)))
    from content.resources r where r.uri = 'question:1M:35:event_ordering:0'")
until [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$RUN'")" != running ]; do sleep 2; done

psql "$P8_DSN" -v run="$RUN" <<'SQL'
-- Each step of the run is a task row; each wave judged its clues, then read.
select step_key, status from workflow.tasks where run_id = :'run' and status <> 'skipped' order by created_at;

-- What each wave did: reads, the clues it judged and accepted, and the accepted leads still open.
select wave, reads, judged, accepted, open_leads, total_reads from aiq.walk_waves(:'run');

-- The walk beside plain search: the evidence the walk has read, and the evidence search's own top N holds, for the
-- same N. The answer key rides in the run's question; no step of the walk reads it.
with gold as (select jsonb_array_elements_text(aiq.walk_summary(:'run')->'question'->'gold') as doc),
     walk as (select doc, row_number() over (order by wave, ord) as n from aiq.walk_reads(:'run'))
select w.wave, w.total_reads as reads,
       (select count(*) from walk join gold using (doc) where walk.n <= w.total_reads) as walk_found,
       (select count(*) from aiq.walk_search_order(:'run') s join gold using (doc)
         where s.rank <= w.total_reads) as search_found,
       (select count(*) from gold) as evidence
  from aiq.walk_waves(:'run') w order by w.wave;
SQL
