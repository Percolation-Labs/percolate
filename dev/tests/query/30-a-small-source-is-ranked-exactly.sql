-- A SMALL SOURCE IS RANKED EXACTLY (REM-1146).
--
-- One model space holds every source's vectors, and an HNSW scan at pgvector's default ef_search returned an
-- approximation of a small source's nearest rows: on LongMemEval S in Percolate the 4,128 questions came back with a
-- top 5 different from the exact one for 25 of 90 queries. aiq.semantic_in now ranks a source exactly when the
-- caller can read at most 20,000 of its (scoped) rows. A four-row fixture cannot make an index miss, so this holds
-- the DECISION, which is what a later edit could quietly remove, and that the exact branch orders as the distance does.

\set ON_ERROR_STOP on

begin;

do $$
declare got uuid[]; want uuid[];
begin
    if not aiq.semantic_ranks_exactly('chunks') then
        raise exception 'the six-chunk corpus sample is not ranked exactly';
    end if;
    if aiq.semantic_ranks_exactly('chunks', null, 3) then
        raise exception 'a corpus above the threshold is ranked exactly; it should go through the index';
    end if;
    if not aiq.semantic_ranks_exactly('chunks', '{"agent": "nobody"}', 3) then
        raise exception 'a scope that narrows the corpus below the threshold is not ranked exactly';
    end if;

    -- The exact branch: the order is the distance order, ties broken by id.
    select array_agg(chunk_id order by distance, chunk_id) into want
      from aiq.semantic_in('chunks', '[1,0,0,0]', 'demo-quad-a', 50);
    select array_agg(chunk_id) into got from aiq.semantic_in('chunks', '[1,0,0,0]', 'demo-quad-a', 50);
    if got is distinct from want or got is null then
        raise exception 'the exact branch returned % where the distance order is %', got, want;
    end if;
    begin
        perform aiq.semantic_ranks_exactly('content.resources; select 1');
        raise exception 'the decision accepted a name that is not a registered source';
    exception when raise_exception then
        if sqlerrm not like 'semantic source % not registered%' then raise; end if;
    end;
    raise notice 'query/30: a small or scoped source is ranked exactly, a large one through the index';
end $$;

rollback;
