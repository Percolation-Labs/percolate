# Step 1, wave by wave (run last, so nothing it reads changes what earlier steps capture): the walk from step 1, read back from its own rows. Nothing here walks again; every function
# reads the run's task rows, so the same query works on a walk still running.
Q='How did my focus on different aspects of the holiday celebration evolve throughout our conversations in order? Mention ONLY and ONLY seven items.'
RUN=$(psql "$P8_DSN" -At -v q="$Q" <<'SQL'
select run from aiq.walk_runs where question_text = :'q' and status = 'succeeded' and control_of is null
 order by created_at limit 1;
SQL
)

# Evaluation harness, not product: the benchmark's answer key, read from the sample's file and passed in.
psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 harness/labels.py samples/beam/questions.jsonl 1M:35:event_ordering:0)" <<'SQL'
-- What the walk is asked, and what search hands it first: the top ten of search's order, each with its node's summary:
-- the exchange and the start of what the user said. ev marks the exchanges the benchmark's answer key names, passed in by the harness; the walk never
-- holds it.
select s.rank, case when s.doc = any(:'labelled'::text[]) then 'ev' else '' end as ev, left(n.summary, 90) as said
  from aiq.walk_search_order(:'run') s
  cross join lateral aiq.lookup(s.doc) l
  join aiq.nodes n on n.id = l.node_id
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
