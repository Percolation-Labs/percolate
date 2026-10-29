# Tag range, part 1: how far tags reach in the ladder conversation, from the index's own links. No walk and no model.
# The study's tagger gave the same counts for 1M:22 (639, 603, 310, 190).
psql "$P8_DSN" <<'SQL'
-- How far tags reach: a term's range is how many of the conversation's messages hold it (the n on its walk_term
-- edges). Most terms are short; most of their uses are in long ones; and a walk offers a term as a clue only up to
-- the cap of 10 messages.
with doc as (
  select n.id
    from aiq.nodes n
    join content.resources r on r.id = n.entity_id and n.entity_type = 'document'
    join content.channels c on c.id = r.channel_id
   where c.name = 'beam-1m22'
), term as (
  select distinct t->>'term' as term, (t->>'n')::int as n
    from aiq.edges_current e
    join doc on doc.id = e.src_id
   cross join jsonb_array_elements(e.provenance->'terms') t
   where e.relation = 'walk_term'
), banded as (
  select n, case when n <= 2 then '2' when n <= 5 then '3-5' when n <= 10 then '6-10' when n <= 30 then '11-30'
                 when n <= 100 then '31-100' when n <= 300 then '101-300' else '>300' end as range
    from term
)
select range, count(*) as terms,
       round(count(*)::numeric / sum(count(*)) over (), 3) as share_of_terms,
       round(sum(n)::numeric / sum(sum(n)) over (), 3) as share_of_uses,
       bool_and(n <= 10) as a_walk_may_offer_it
  from banded
 group by range
 order by min(n);
SQL

# Part 2: on step 3's walk of the ladder question, where the reads came from and which found evidence. One question,
# so read it as an example; the study's 150 questions are where the shares come from.
Q='Considering my budget, tool priorities, ladder needs, and moving help, how should I sequence and allocate resources to complete my DIY projects safely and efficiently?'
RUN=$(psql "$P8_DSN" -At -v q="$Q" <<'SQL'
select run from aiq.walk_runs where question_text = :'q' and status = 'succeeded' order by created_at desc limit 1;
SQL
)
# Evaluation harness, not product: the benchmark's answer key, read from the sample's file and passed in.
psql "$P8_DSN" -v run="$RUN" -v labelled="$(python3 harness/labels.py samples/beam/questions.jsonl 1M:22:multi_session_reasoning:1)" <<'SQL'
-- Where the walk's reads came from, and which found evidence: search, the next message, the nearest in meaning, or a
-- shared term, by how many messages hold it. A term held by more than 10 is never offered, so it has no row here.
with s as materialized (select aiq.walk_summary(:'run') as v),
labelled as materialized (select unnest(:'labelled'::text[]) as doc),
term as materialized (
  select distinct t->>'term' as term, (t->>'n')::int as n
    from s, content.channels c
    join content.resources r on r.channel_id = c.id
    join aiq.nodes d on d.entity_id = r.id and d.entity_type = 'document'
    join aiq.edges_current e on e.src_id = d.id and e.relation = 'walk_term'
   cross join jsonb_array_elements(e.provenance->'terms') t
   where c.name = s.v->'scope'->>'channel'
),
reads as (
  select r.doc,
         case when r.via = 'search' then 'search'
              when r.via like 'next:%' then 'next message'
              when r.via like 'near:%' then 'nearest meaning'
              when t.n <= 2 then 'term, 2 messages'
              when t.n <= 5 then 'term, 3-5 messages'
              else 'term, 6-10 messages' end as route
    from aiq.walk_reads(:'run') r
    left join term t on r.via = 'term:' || t.term
)
select route, count(*) as reads, count(*) filter (where doc in (select doc from labelled)) as evidence,
       round(100.0 * count(*) filter (where doc in (select doc from labelled)) / count(*), 1) as evidence_per_100_reads
  from reads
 group by route
 order by min(case route when 'search' then 0 when 'next message' then 1 when 'nearest meaning' then 2 else 3 end), route;
SQL
