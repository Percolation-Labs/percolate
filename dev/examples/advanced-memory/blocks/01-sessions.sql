insert into content.channels (name, kind, visibility) values ('sessions', 'manual', 'public') on conflict do nothing;
select content.register_text('sessions', 'session-2026-01-12', $j$[{"content":
  "Priya Raman, harbour analytics lead: the Harbour Rewrite stays on Postgres for now."}]$j$, 'Session, 12 January') ->> 'resource_id' as jan_12;
select content.register_text('sessions', 'session-2026-03-03', $j$[{"content":
  "P. Raman: DuckDB read a year of the harbour logs in four seconds, so I would move the harbour analytics to it."}]$j$, 'Session, 3 March') ->> 'resource_id' as mar_03;
select content.register_text('sessions', 'session-2026-06-02', $j$[{"content":
  "Priya Raman has moved from the Harbour Rewrite to the Tide Dashboard."}]$j$, 'Session, 2 June') ->> 'resource_id' as jun_02;

create schema if not exists team;
create table if not exists team.people (id uuid primary key default gen_random_uuid(), name text not null unique);
select aiq.register_entity_table('person', 'team.people', 'n.name', 'n.name', 'rbac.shared_org_id()');
select aiq.register_graph_vocabulary($v$[{"relation": "works_on", "single_valued": true}, {"relation": "prefers"}]$v$) ->> 'relations' as relations;

select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Harbour Rewrite"}, {"k":"tool","n":"Postgres"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}, {"s":0,"t":2,"r":"prefers"}]}$g$,
 jsonb_build_object('agent', 'knit', 'run_id', 'jan-12', 'valid_from', '2026-01-12T10:00:00Z',
   'resource_id', (select id from content.resources where external_id = 'session-2026-01-12'))) ->> 'edges_new' as jan_12;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"P. Raman"}, {"k":"tool","n":"DuckDB"}],
  "edges": [{"s":0,"t":1,"r":"prefers"}]}$g$,
 jsonb_build_object('agent', 'knit', 'run_id', 'mar-03', 'valid_from', '2026-03-03T15:00:00Z',
   'resource_id', (select id from content.resources where external_id = 'session-2026-03-03'))) ->> 'edges_new' as mar_03;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Tide Dashboard"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}]}$g$,
 jsonb_build_object('agent', 'knit', 'run_id', 'jun-02', 'valid_from', '2026-06-02T08:30:00Z',
   'resource_id', (select id from content.resources where external_id = 'session-2026-06-02'))) ->> 'edges_new' as jun_02;

insert into team.people (name) values ('Priya Raman') on conflict do nothing;
select jsonb_pretty(aiq.dream() - 'since' - 'until') as dream;

select kind, evidence ->> 'key' as name, status,
       (select string_agg(c ->> 'key', ', ') from jsonb_array_elements(evidence -> 'candidates') c) as candidates
  from aiq.judgements order by queued_at, name;
