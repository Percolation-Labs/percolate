# Step 3: a real miss, explained. Walk the ladder question, answering every clue from the sample's recorded verdicts
# (offline, so no model is asked and the walk is the same each time), then ask why the answer is incomplete. The
# question is named by its words and walked as its document's node; its answer key comes from the sample's file, and
# the walk never holds it.
# In the study the ladder message was the miss. Here every read raises clues, so the walk reaches it, and the miss
# is the moving help: behind open leads ranked too low, with 'moving' rejected just under the gate (REM-1206).
# The recorded verdicts were given under span 2 and cap 10, the defaults before 0.2.33, so the walk is pinned to them:
# under wider settings it would raise leads its replay never judged.
Q='Considering my budget, tool priorities, ladder needs, and moving help, how should I sequence and allocate resources to complete my DIY projects safely and efficiently?'
RUN=$(psql "$P8_DSN" -Atq -v q="$Q" <<'SQL'
select workflow.start_workflow('walk', jsonb_build_object(
         'channel', 'beam-1m22',
         'question', jsonb_build_object('node_id', n.id, 'text', r.title),
         'replay', (select v.id from content.resources v join content.channels vc on vc.id = v.channel_id
                     where vc.name = 'walk-replays' and v.title = r.title),
         'offline', true, 'settings', jsonb_build_object('span', 2, 'cap', 10)))
  from content.resources r
  join content.channels c on c.id = r.channel_id and c.name = 'walk-questions'
  join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
 where r.title = :'q';
SQL
)
# The walk runs in the stack's worker; wait for it to finish.
until [ "$(psql "$P8_DSN" -Atc "select status not in ('pending', 'running') from workflow.runs where id = '$RUN'")" = t ]; do
  sleep 2
done

# Evaluation harness, not product: the benchmark's answer key, read from the sample's file and passed in.
psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 harness/labels.py samples/beam/questions.jsonl 1M:22:multi_session_reasoning:1)" <<'SQL'
-- Each wave: reads so far, how many accepted leads were left open, and how fresh the last reads were.
select wave, total_reads as reads, accepted, fresh, open_leads from aiq.walk_waves(:'run') order by wave;

-- Why the answer is incomplete, from the run's own rows: each piece of evidence it did not read, and why.
select * from aiq.walk_why(:'run', :'labelled');

-- The near misses beside them: leads to the unread evidence that Jev rejected just under the gate (0.5).
with unread as (select doc from aiq.walk_why(:'run', :'labelled'))
select u.doc as evidence, c.key as lead, round(c.p::numeric, 2) as p
  from unread u
  join aiq.walk_clues(:'run') c on u.doc = any(c.targets)
 where c.decision = 'rejected' and c.p >= 0.4
 order by u.doc, c.p desc, c.key desc;
SQL
