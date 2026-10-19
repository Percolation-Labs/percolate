create schema if not exists team;
create table if not exists team.people (id uuid primary key default gen_random_uuid(), name text not null unique);
select aiq.register_entity_table('person', 'team.people', 'n.name', 'n.name', 'rbac.shared_org_id()');
select aiq.register_graph_vocabulary($v$[{"relation": "works_on", "single_valued": true}, {"relation": "prefers"}]$v$) ->> 'relations' as relations;

select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Harbour Rewrite"}, {"k":"tool","n":"Postgres"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}, {"s":0,"t":2,"r":"prefers"}]}$g$,
 '{"agent":"knit","run_id":"jan-12","valid_from":"2026-01-12T10:00:00Z"}') ->> 'edges_new' as jan_12;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"P. Raman"}, {"k":"tool","n":"DuckDB"}],
  "edges": [{"s":0,"t":1,"r":"prefers"}]}$g$,
 '{"agent":"knit","run_id":"mar-03","valid_from":"2026-03-03T15:00:00Z"}') ->> 'edges_new' as mar_03;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Tide Dashboard"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}]}$g$,
 '{"agent":"knit","run_id":"jun-02","valid_from":"2026-06-02T08:30:00Z"}') ->> 'edges_new' as jun_02;

insert into team.people (name) values ('Priya Raman') on conflict do nothing;
select jsonb_pretty(aiq.dream() - 'since' - 'until') as dream;

select kind, evidence ->> 'key' as name, status,
       (select string_agg(c ->> 'key', ', ') from jsonb_array_elements(evidence -> 'candidates') c) as candidates
  from aiq.judgements order by queued_at, name;
