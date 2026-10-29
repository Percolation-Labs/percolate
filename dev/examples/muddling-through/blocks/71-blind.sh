# Step 1, run three ways (last, so its twenty replay documents join the stack after every other step has run).
# Search's order, the walk, and the walk with its choices made blind: the same workflow on the
# same graph, but every lead the conversation could raise gets a P drawn at random from this question's own verdicts.
# The blind walk accepts leads at the same rate and follows them by the same rules, for no reason the question gives.
# If the walk's lead over search comes from reading, the blind walks lose it. Twenty blind walks, offline: $0, a few
# minutes. Pinned to span 2 and cap 10 like step 1, the settings its verdicts were recorded under. Each blind walk is
# started as a control of step 1's walk, so it is found by that relation, not by a name.
Q='How did my focus on different aspects of the holiday celebration evolve throughout our conversations in order? Mention ONLY and ONLY seven items.'
WALK=$(psql "$P8_DSN" -At -v q="$Q" <<'SQL'
select run from aiq.walk_runs where question_text = :'q' and status = 'succeeded' and control_of is null
 order by created_at limit 1;
SQL
)
psql "$P8_DSN" -Atq -v walk="$WALK" <<'SQL'
select setseed(0.1204);
-- One replay document per blind walk: a P for every possible lead (a term, the exchanges beside one, its nearest),
-- each drawn from the P values Jev gave this question's leads, in the verdicts step 1's walk replayed.
with w as (select * from aiq.walk_runs where run = :'walk'),
g as (select aiq.walk_graph(jsonb_build_object('channel', r.input->>'channel')) as g
        from w join workflow.runs r on r.id = w.run),
keys as (select 'term:' || t as key from g, jsonb_object_keys(g->'post') t
         union all
         select kind || ':' || d from g, jsonb_object_keys(g->'beside') d, unnest(array['next', 'near']) kind),
pool as (select array_agg(value::real) as ps
           from w join content.resource_chunks c on c.resource_id = w.replays,
                jsonb_each_text((c.content::jsonb)->'verdicts')),
docs as (select i, jsonb_build_object('model', 'blind', 'task', aiq.walk_task(), 'verdicts',
                  jsonb_object_agg(k.key, pool.ps[1 + floor(random() * cardinality(pool.ps))::int])) as doc
           from generate_series(1, 20) i, keys k, pool group by i),
res as (insert into content.resources (channel_id, uri, title, org_id, visibility, metadata)
        select o.channel_id, 'replay:blind:' || :'walk' || ':' || d.i, 'blind replay ' || d.i, o.org_id, o.visibility,
               jsonb_build_object('control_of', :'walk', 'i', d.i)
          from w join content.resources o on o.id = w.replays, docs d
        returning id, (metadata->>'i')::int as i)
insert into content.resource_chunks (resource_id, ordinal, content)
select res.id, 0, d.doc::text from res join docs d on d.i = res.i;
SQL
for DOC in $(psql "$P8_DSN" -At -v walk="$WALK" <<< "select id from content.resources
                                                     where metadata->>'control_of' = :'walk' order by (metadata->>'i')::int"); do
  psql "$P8_DSN" -Atq -v walk="$WALK" -v doc="$DOC" > /dev/null <<'SQL'
select workflow.start_workflow('walk', jsonb_build_object(
         'question', r.input->'question', 'channel', r.input->>'channel',
         'replay', :'doc', 'control_of', :'walk', 'offline', true,
         'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'span', 2, 'cap', 10)))
  from workflow.runs r where r.id = :'walk';
SQL
done
until [ "$(psql "$P8_DSN" -At -v walk="$WALK" <<< "select count(*) from aiq.walk_runs where control_of = :'walk' and status = 'running'")" = 0 ]; do
  sleep 2
done

# Evaluation harness, not product: the benchmark's answer key, read from the sample's file and passed in.
psql "$P8_DSN" -v walk="$WALK" -v labelled="$(python3 harness/labels.py samples/beam/questions.jsonl 1M:35:event_ordering:0)" <<'SQL'
-- Evidence read by 50, 100 and 500 reads: search's order, the walk, and the twenty blind walks (their mean and range,
-- and how many did at least as well as the walk), each counted by aiq.walk_coverage.
with runs as (select run as id, run <> :'walk' as blind
                from aiq.walk_runs where (run = :'walk' or control_of = :'walk') and status = 'succeeded'),
seen as (select r.id, r.blind, c.k as n, c.walk as found, c.search
           from runs r, aiq.walk_coverage(r.id, :'labelled', array[50, 100, 500]) c)
select w.n as reads, w.search, w.found as walk, round(avg(b.found), 1) as blind_mean, min(b.found) as blind_min, max(b.found) as blind_max,
       count(*) filter (where b.found >= w.found) as blind_as_good, count(b.*) as blind_walks
  from seen w join seen b on b.blind and b.n = w.n
 where not w.blind
 group by w.n, w.search, w.found order by w.n;

-- The evidence the walk read that search's own top 500 does not hold (no rank: not among its 2,000 hits), each with
-- its node's summary: the exchange and the start of what the user said.
select w.via, s.rank as search_rank, left(n.summary, 90) as said
  from aiq.walk_reads(:'walk') w
  cross join lateral aiq.lookup(w.doc) l
  join aiq.nodes n on n.id = l.node_id
  left join aiq.walk_search_order(:'walk') s on s.doc = w.doc
 where w.doc = any(:'labelled'::text[]) and (s.rank is null or s.rank > 500)
 order by w.wave, w.ord;
SQL
