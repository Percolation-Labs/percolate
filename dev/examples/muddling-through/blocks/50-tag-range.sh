# Tag range, part 1: how far tags reach in the ladder conversation, from the index's own links. No walk and no model.
# The study's tagger gave the same counts for 1M:22 (639, 603, 310, 190); the parts by route come from a walk's rows (REM-1210).
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
