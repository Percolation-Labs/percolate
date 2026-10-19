-- psql, as p8: a context block is a query, so it is a function anyone may call and that runs as its caller
create schema if not exists memory;
grant usage on schema memory to authenticated;
create or replace function memory.context(p_name text) returns text
language sql stable security invoker as $$
  select string_agg(format('- %s %s %s (%s to %s)', s.summary, replace(e.relation, '_', ' '), d.summary,
                           e.valid_from::date, coalesce(e.valid_to::date::text, 'now')),
                    E'\n' order by e.valid_to nulls last, e.valid_from)
    from aiq.lookup(p_name) l
    join aiq.edges e on e.src_id = l.node_id
    join aiq.nodes s on s.id = e.src_id
    join aiq.nodes d on d.id = e.dst_id
$$;
grant execute on function memory.context(text) to authenticated;
