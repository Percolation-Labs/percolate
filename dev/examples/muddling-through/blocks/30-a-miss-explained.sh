# Step 3: a real miss, explained. Walk the ladder question, answering every clue from the sample's recorded verdicts
# (offline, so no model is asked and the walk is the same each time), then ask why the answer is incomplete. The
# question and its answer key come from the sample's own question record; the walk never reads the key.
# In the study the ladder message was the miss. Here every read raises clues, so the walk reaches it, and the miss
# is the moving help: behind open leads ranked too low, with 'moving' rejected just under the gate (REM-1206).
RUN=$(psql "$P8_DSN" -Atq <<'SQL'
select workflow.start_workflow('walk', jsonb_build_object(
         'channel', q.metadata->>'channel',
         'question', q.metadata || jsonb_build_object('id', q.metadata->>'qid', 'text', q.metadata->>'question'),
         'replay', 'replay:' || (q.metadata->>'qid'),
         'offline', true))
  from content.resources q
 where q.uri = 'question:1M:22:multi_session_reasoning:1';
SQL
)
# The walk runs in the stack's worker; wait for it to finish.
until [ "$(psql "$P8_DSN" -Atc "select status not in ('pending', 'running') from workflow.runs where id = '$RUN'")" = t ]; do
  sleep 2
done

psql "$P8_DSN" -v run="$RUN" <<'SQL'
-- Each wave: reads so far, how many accepted leads were left open, and how fresh the last reads were.
select wave, total_reads as reads, accepted, fresh, open_leads from aiq.walk_waves(:'run') order by wave;

-- Why the answer is incomplete, from the run's own rows: each piece of evidence it did not read, and why.
select * from aiq.walk_why(:'run');
SQL
