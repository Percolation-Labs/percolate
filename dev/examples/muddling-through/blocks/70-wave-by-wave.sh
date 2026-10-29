# Step 1, wave by wave (run last, so nothing it reads changes what earlier steps capture): the walk from step 1, read back from its own rows. Nothing here walks again; every function
# reads the run's task rows, so the same query works on a walk still running.
RUN=$(psql "$P8_DSN" -Atc "
  select id from workflow.runs
   where input->'question'->>'id' = '1M:35:event_ordering:0' and status = 'succeeded'
   order by created_at limit 1")

psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 build/labels.py samples/beam/questions.jsonl 1M:35:event_ordering:0)" <<'SQL'
-- What the walk is asked, and what search hands it first: the top ten of search's order, each with the start of what
-- the user said. ev marks the exchanges the benchmark's answer key names, passed in by the harness; the walk never
-- holds it.
select s.rank, s.doc, case when s.doc = any(:'labelled'::text[]) then 'ev' else '' end as ev,
       left(r.metadata->>'terms_text', 60) as said
  from aiq.walk_search_order(:'run') s
  join content.resources r on r.uri = s.doc
 where s.rank <= 10 order by s.rank;

-- Wave 1 judges the leads those ten reads raised: a shared term, the exchanges beside one in its sitting, its nearest
-- in meaning. Jev's P for each; 0.5 accepts. The best eight, and how many there were.
select key, kind, cardinality(targets) as leads_to, round(p::numeric, 2) as p, decision
  from aiq.walk_clues(:'run') where wave = 1
 order by p desc, key limit 8;
select count(*) as judged, count(*) filter (where decision = 'accepted') as accepted,
       round(max(p) filter (where decision = 'rejected')::numeric, 2) as best_rejected
  from aiq.walk_clues(:'run') where wave = 1;

-- What waves 1 to 3 read, by the kind of lead that brought each exchange in, and how many were evidence.
select w.wave, split_part(w.via, ':', 1) as route, count(*) as reads,
       count(*) filter (where w.doc = any(:'labelled'::text[])) as evidence
  from aiq.walk_reads(:'run') w
 where w.wave between 1 and 3
 group by 1, 2 order by 1, 2;
SQL
