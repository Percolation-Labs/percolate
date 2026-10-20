create schema if not exists travel;
create table if not exists travel.bookings (id int primary key, departs date not null, destination text not null, owner_id uuid not null);
with maya as (select id from rbac.users where email = 'maya@example.com')
insert into travel.bookings select b.*, maya.id from maya, (values
  (1, date '2026-03-14', 'Edinburgh'), (2, date '2026-07-02', 'Porto'), (3, date '2026-11-20', 'Madrid'))
  b(id, departs, destination)
on conflict (id) do nothing;
grant usage on schema travel to authenticated;
grant select on travel.bookings to authenticated;
alter table travel.bookings enable row level security;
drop policy if exists owner_reads on travel.bookings;
create policy owner_reads on travel.bookings for select using (owner_id = (select rbac.current_user_id()));
