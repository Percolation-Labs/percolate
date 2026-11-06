-- A COUNT AGREES WITH TEXT (REM-1315).
--
-- The MCP probe that tells a caller "412 rows match and you saw 10" counted TEXT with plainto_tsquery, every word,
-- while TEXT matches any word (REM-1145), so on the Mem0 fixture it counted 1 where TEXT returned 40.
-- aiq.lexical_match is what TEXT matches, as one tsquery, and aiq.lexical matches through it. What is held:
--
--   1. for a multi-word query, the rows counted with aiq.lexical_match are exactly the rows aiq.lexical returns;
--   2. that is more than every-word matching counts, so the test sees the difference it is about;
--   3. a query of stop words is NULL and counts nothing.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into content.channels (name, kind, visibility) values ('query68', 'manual', 'public');
select content.register_text('query68', 'query68:' || k, jsonb_build_array(jsonb_build_object('content', t)), k,
                             'query68:' || k, null, '{}')
  from (values ('a', 'Lucy kept garlic on the sill'),
               ('b', 'Lucy slept with the window open'),
               ('c', 'garlic hung from every door'),
               ('d', 'the count arrived at Whitby')) v(k, t);

do $$
declare q text := 'Lucy''s garlic'; returned uuid[]; counted uuid[]; every int; n int;
begin
    select array_agg(chunk_id order by chunk_id) into returned
      from aiq.lexical('chunks', q, 1000, '{"channel": "query68"}');
    select array_agg(c.id order by c.id) into counted
      from content.resource_chunks c join content.resources r on r.id = c.resource_id
     where r.uri like 'query68:%' and c.search_tsv @@ aiq.lexical_match('english', q);
    if counted is distinct from returned then
        raise exception 'aiq.lexical_match counted % but TEXT returned %', counted, returned;
    end if;
    if cardinality(returned) <> 3 then
        raise exception 'TEXT returned % rows for a question sharing a word with 3', cardinality(returned);
    end if;

    select count(*) into every
      from content.resource_chunks c join content.resources r on r.id = c.resource_id
     where r.uri like 'query68:%' and c.search_tsv @@ plainto_tsquery('english', q);
    if every >= cardinality(returned) then
        raise exception 'every-word matching counted % against TEXT''s %, so this cannot tell them apart',
            every, cardinality(returned);
    end if;

    if aiq.lexical_match('english', 'is it the of to') is not null then
        raise exception 'a query of stop words is not NULL';
    end if;
    raise notice 'query/68: a count with aiq.lexical_match agrees with TEXT, row for row';
end $$;

rollback;
