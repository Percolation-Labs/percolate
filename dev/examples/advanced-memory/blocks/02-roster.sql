create schema if not exists team;
create table if not exists team.people (id uuid primary key default gen_random_uuid(), name text not null unique);
select aiq.register_entity_table('person', 'team.people', 'n.name', 'n.name', 'rbac.shared_org_id()');

select aiq.register_graph_vocabulary($v$[
  {"relation": "works_on", "single_valued": true},
  {"relation": "prefers"},
  {"relation": "member_of"}
]$v$) ->> 'relations' as relations;
