-- psql, as p8: the forwarder's reference data, which everyone may read, and Ana's bookings, which only she may
create schema if not exists crm;
create table if not exists crm.ports (id uuid primary key default gen_random_uuid(), name text not null unique);
-- registered before its rows go in: the projection is a trigger, so a row is a node from the moment it is written
select aiq.register_entity_table('port', 'crm.ports', 'n.name', 'n.name', 'rbac.shared_org_id()');
-- a new entity type needs the relation catalogue widened to it, or no fact can point at a port row
select aiq.register_graph_vocabulary() ->> 'relations' as relations;
insert into crm.ports (name) values ('Rotterdam'), ('Felixstowe'), ('Gothenburg') on conflict do nothing;
-- each row is now a node, and the catalogue reaches it
select (select count(*) from aiq.nodes where entity_type = 'port') as port_nodes,
       (select count(*) from aiq.relation_types where 'port' in (src_type, dst_type)) as port_triples;

create table if not exists crm.bookings (id int primary key, departs date not null,
  port_id uuid not null references crm.ports, owner_id uuid not null);
with ana as (select id from rbac.users where email = 'ana@example.com')
insert into crm.bookings select b.id, b.departs, p.id, ana.id
  from ana, (values (1, date '2026-11-03', 'Rotterdam'), (2, date '2026-11-24', 'Felixstowe')) b(id, departs, port)
  join crm.ports p on p.name = b.port
on conflict (id) do nothing;

grant usage on schema crm to authenticated;
grant select on crm.ports, crm.bookings to authenticated;
alter table crm.bookings enable row level security;
drop policy if exists owner_reads on crm.bookings;
create policy owner_reads on crm.bookings for select using (owner_id = (select rbac.current_user_id()));
