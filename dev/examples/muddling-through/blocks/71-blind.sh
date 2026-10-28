# Step 1, run three ways (last, so its twenty replay documents join the stack after every other step has run).
# Search's order, the walk, and the walk with its choices made blind: the same workflow on the
# same graph, but every lead the conversation could raise gets a P drawn at random from this question's own verdicts.
# The blind walk accepts leads at the same rate and follows them by the same rules, for no reason the question gives.
# If the walk's lead over search comes from reading, the blind walks lose it. Twenty blind walks, offline: $0, a few
# minutes. Pinned to span 2 and cap 10 like step 1, the settings its verdicts were recorded under.
psql "$P8_DSN" -Atq <<'SQL'
select setseed(0.1204);
-- One replay document per blind walk: a P for every possible lead (a term, the exchanges beside one, its nearest),
-- each drawn from the P values Jev gave this question's leads.
with q as (select metadata as m from content.resources where uri = 'question:1M:35:event_ordering:0'),
g as (select aiq.walk_graph(jsonb_build_object('channel', m->>'channel', 'question', m)) as g from q),
keys as (select 'term:' || t as key from g, jsonb_object_keys(g->'post') t
         union all
         select kind || ':' || d from g, jsonb_object_keys(g->'beside') d, unnest(array['next', 'near']) kind),
pool as (select array_agg(value::real) as ps
           from content.resources o join content.resource_chunks c on c.resource_id = o.id,
                jsonb_each_text((c.content::jsonb)->'verdicts'->'1M:35:event_ordering:0')
          where o.uri = 'replay:1M:35:event_ordering:0'),
docs as (select i, jsonb_build_object('model', 'blind', 'task', aiq.walk_task(), 'verdicts',
                  jsonb_build_object('1M:35:event_ordering:0',
                    jsonb_object_agg(k.key, pool.ps[1 + floor(random() * cardinality(pool.ps))::int]))) as doc
           from generate_series(1, 20) i, keys k, pool group by i),
res as (insert into content.resources (channel_id, uri, title, org_id, visibility)
        select r.channel_id, 'replay:blind:' || d.i, 'blind replay ' || d.i, r.org_id, r.visibility
          from content.resources r, docs d where r.uri = 'replay:1M:35:event_ordering:0'
        returning id, uri)
insert into content.resource_chunks (resource_id, ordinal, content)
select res.id, 0, d.doc::text from res join docs d on res.uri = 'replay:blind:' || d.i;
SQL
for i in $(seq 1 20); do
  RUN=$(psql "$P8_DSN" -Atc "
    select workflow.start_workflow('walk', jsonb_build_object(
             'question', r.metadata, 'channel', r.metadata->>'channel',
             'replay', 'replay:blind:$i', 'offline', true,
             'settings', jsonb_build_object('span', 2, 'cap', 10)))
      from content.resources r where r.uri = 'question:1M:35:event_ordering:0'")
  until [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$RUN'")" != running ]; do sleep 2; done
done

psql "$P8_DSN" <<'SQL'
-- Evidence read by 50, 100 and 500 reads: search's order, the walk, and the twenty blind walks (their mean and range,
-- and how many did at least as well as the walk).
with gold as (select jsonb_array_elements_text(r.metadata->'gold') as doc
                from content.resources r where r.uri = 'question:1M:35:event_ordering:0'),
runs as (select id, coalesce(input->>'replay', '') like 'replay:blind:%' as blind
           from workflow.runs where input->'question'->>'id' = '1M:35:event_ordering:0' and status = 'succeeded'),
seen as (select r.id, r.blind, n.n,
                (select count(*) from (select doc, row_number() over (order by wave, ord) k from aiq.walk_reads(r.id)) w
                   join gold using (doc) where w.k <= n.n) as found
           from runs r, (values (50), (100), (500)) n(n))
select w.n as reads,
       (select count(*) from aiq.walk_search_order(w.id) s join gold using (doc) where s.rank <= w.n) as search,
       w.found as walk, round(avg(b.found), 1) as blind_mean, min(b.found) as blind_min, max(b.found) as blind_max,
       count(*) filter (where b.found >= w.found) as blind_as_good, count(b.*) as blind_walks
  from seen w join seen b on b.blind and b.n = w.n
 where not w.blind
 group by w.n, w.id, w.found order by w.n;

-- The evidence the walk read that search's own top 500 does not hold (no rank: not among its 2,000 hits).
with gold as (select jsonb_array_elements_text(r.metadata->'gold') as doc
                from content.resources r where r.uri = 'question:1M:35:event_ordering:0'),
walk as (select id from workflow.runs where input->'question'->>'id' = '1M:35:event_ordering:0'
            and status = 'succeeded' and input->>'replay' = 'replay:1M:35:event_ordering:0' order by created_at limit 1)
select w.doc, w.via, s.rank as search_rank, left(r.metadata->>'terms_text', 70) as said
  from walk, aiq.walk_reads(walk.id) w join gold g using (doc)
  join content.resources r on r.uri = w.doc
  left join aiq.walk_search_order(walk.id) s on s.doc = w.doc
 where s.rank is null or s.rank > 500
 order by w.wave, w.ord;
SQL
