select round, entity_type, resolved, jsonb_pretty(path) as path
  from aiq.iterated_join('tool/duckdb', 'person', 3);
select round, resolved, path ->> 'reason' as reason
  from aiq.iterated_join('tool/duckdb', 'company', 2);
