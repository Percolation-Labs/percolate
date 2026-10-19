-- The LangGraph tour's fleet loads in one block and is read only by its owner.
--
-- The tour's harbourmaster is told to start with SCHEMA and then query, through
-- harbour-query, which is query-mcp forwarding the caller's token to
-- aiq.query and, for SQL, to aiq.sql_passthrough. No fleet existed for it to
-- find (REM-984). The block between the markers below is the one the article
-- prints, verbatim: the article's own test should match it. What this file
-- asks of it:
--
--   1. it loads the counts it prints (a second paste changing nothing was
--      measured on a live stack, not here: the block is pasted once);
--   2. SCHEMA "sql" shows the agent its three tables, with row security on;
--   3. the tour user's sql_passthrough -- the call harbour-query makes, and the
--      one the article has the reader type -- returns the fleet;
--   4. another person, with rows of their own in the same tables, sees only
--      theirs, and the tour user does not see them.
--
-- Users are made here rather than by bootstrap_admin, which refuses once any
-- role has been granted. One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

insert into rbac.users (id, email, status) values
    ('01a10000-0000-7000-8000-00000000f1ee', 'me@example.com', 'active'),
    ('01a10000-0000-7000-8000-00000000f1ef', 'fleet-stranger@example.test', 'active')
on conflict (email) do nothing;

-- ---- the article's block, verbatim ------------------------------------------
-- Percolate: the fleet the harbourmaster queries. Synthetic, CC0-1.0.
do $$ begin
  if not exists (select 1 from rbac.users where email = 'me@example.com') then
    raise exception 'run the bootstrap_admin step first: the fleet belongs to me@example.com';
  end if;
end $$;

create schema if not exists fleet;
comment on schema fleet is
  'A synthetic fleet for the LangGraph tour, released under CC0-1.0. Ships, operators and berths are '
  'invented; the ports are real. Every IMO number fails the IMO check digit, so none is a real ship.';

create table if not exists fleet.vessels (
  id int primary key, name text not null unique, imo text not null unique,
  operator text not null, type text not null, gross_tonnage int not null,
  owner_id uuid not null);
create table if not exists fleet.berths (
  id int primary key, port text not null, code text not null,
  max_draught_m numeric(4,1) not null, length_m int not null,
  owner_id uuid not null, unique (port, code));
create table if not exists fleet.port_calls (
  id int primary key, vessel_id int not null references fleet.vessels,
  berth_id int not null references fleet.berths,
  arrived_at timestamptz not null, departed_at timestamptz,  -- null: alongside now
  purpose text not null, owner_id uuid not null);
comment on column fleet.port_calls.departed_at is 'null while the vessel is still alongside';
comment on table fleet.vessels    is 'Synthetic tour data (CC0-1.0): the fleet. IMO numbers fail the check digit on purpose.';
comment on table fleet.berths     is 'Synthetic tour data (CC0-1.0): berths at real ports, with invented codes and sizes.';
comment on table fleet.port_calls is 'Synthetic tour data (CC0-1.0): one row per call; departed_at is null while alongside.';

with me as (select id from rbac.users where email = 'me@example.com')
insert into fleet.vessels select v.*, me.id from me, (values
  (1, 'Meridian Dawn',  '9331802', 'Meridian Line',    'container ship',  38200),
  (2, 'Meridian Star',  '9331803', 'Meridian Line',    'container ship',  38200),
  (3, 'Bulk Harmony',   '9407711', 'Meridian Bulk',    'bulk carrier',    31900),
  (4, 'Aurora Kestrel', '9214578', 'Kestrel Shipping', 'general cargo',    8450),
  (5, 'Kestrel Tern',   '9512340', 'Kestrel Shipping', 'general cargo',    8450),
  (6, 'Nordvik Spirit', '9620012', 'Nordvik Chartering', 'product tanker', 23400))
  v(id, name, imo, operator, type, gross_tonnage)
on conflict (id) do nothing;

with me as (select id from rbac.users where email = 'me@example.com')
insert into fleet.berths select b.*, me.id from me, (values
  (1, 'Rotterdam',  'Amazonehaven 4', 15.0, 380),
  (2, 'Rotterdam',  'Waalhaven 2',    11.5, 240),
  (3, 'Felixstowe', 'Trinity 6',      14.5, 350),
  (4, 'Felixstowe', 'Landguard 1',     9.0, 180),
  (5, 'Gothenburg', 'Skandia 3',      13.0, 300),
  (6, 'Gothenburg', 'Energy Port 9',  12.0, 230))
  b(id, port, code, max_draught_m, length_m)
on conflict (id) do nothing;

with me as (select id from rbac.users where email = 'me@example.com')
insert into fleet.port_calls select c.*, me.id from me, (values
  ( 1, 1, 1, timestamptz '2026-10-02 06:10Z', timestamptz '2026-10-03 21:40Z', 'discharge'),
  ( 2, 1, 3, timestamptz '2026-10-09 14:00Z', timestamptz '2026-10-10 18:25Z', 'load'),
  ( 3, 2, 3, timestamptz '2026-10-04 08:30Z', timestamptz '2026-10-05 19:00Z', 'discharge'),
  ( 4, 2, 1, timestamptz '2026-10-17 05:45Z', null,                           'load'),
  ( 5, 3, 2, timestamptz '2026-10-06 11:20Z', timestamptz '2026-10-09 07:15Z', 'discharge'),
  ( 6, 3, 5, timestamptz '2026-10-15 16:00Z', null,                           'repairs'),
  ( 7, 4, 4, timestamptz '2026-10-01 09:00Z', timestamptz '2026-10-01 22:30Z', 'load'),
  ( 8, 4, 6, timestamptz '2026-10-12 07:40Z', timestamptz '2026-10-13 12:10Z', 'bunkers'),
  ( 9, 5, 2, timestamptz '2026-10-18 13:15Z', null,                           'discharge'),
  (10, 6, 6, timestamptz '2026-10-08 03:50Z', timestamptz '2026-10-08 20:05Z', 'discharge'),
  (11, 6, 2, timestamptz '2026-10-14 10:30Z', timestamptz '2026-10-16 02:00Z', 'load'))
  c(id, vessel_id, berth_id, arrived_at, departed_at, purpose)
on conflict (id) do nothing;

-- Readable by its owner and nobody else, through the same policy shape the extension's own tables use.
grant usage on schema fleet to authenticated;
grant select on fleet.vessels, fleet.berths, fleet.port_calls to authenticated;
alter table fleet.vessels    enable row level security;
alter table fleet.berths     enable row level security;
alter table fleet.port_calls enable row level security;
drop policy if exists owner_reads on fleet.vessels;
drop policy if exists owner_reads on fleet.berths;
drop policy if exists owner_reads on fleet.port_calls;
create policy owner_reads on fleet.vessels    for select using (owner_id = (select rbac.current_user_id()));
create policy owner_reads on fleet.berths     for select using (owner_id = (select rbac.current_user_id()));
create policy owner_reads on fleet.port_calls for select using (owner_id = (select rbac.current_user_id()));

select (select count(*) from fleet.vessels) as vessels, (select count(*) from fleet.berths) as berths,
       (select count(*) from fleet.port_calls) as port_calls;
-- ---- end of the article's block ---------------------------------------------

-- 1. What it loaded.
do $$ begin
    if (select count(*) from fleet.vessels) <> 6 or (select count(*) from fleet.berths) <> 6
       or (select count(*) from fleet.port_calls) <> 11 then
        raise exception 'the fleet block did not load 6 vessels, 6 berths and 11 port calls';
    end if;
end $$;

-- Somebody else's rows in the same tables, including one alongside now, so the
-- tour user's answer has something to leave out.
insert into fleet.vessels    values (99, 'Someone Else', '9999990', 'Elsewhere Line', 'tug', 300, '01a10000-0000-7000-8000-00000000f1ef');
insert into fleet.berths     values (99, 'Rotterdam', 'Private 1', 5.0, 50, '01a10000-0000-7000-8000-00000000f1ef');
insert into fleet.port_calls values (99, 99, 99, now(), null, 'towage', '01a10000-0000-7000-8000-00000000f1ef');

create temp table fleet_answers (who text, rows jsonb, schema jsonb, counts jsonb) on commit drop;
grant insert on fleet_answers to authenticated;

-- Claims before the role, each time: authenticated cannot read rbac.users,
-- and set_config is revoked from it (cff8674). me@example.com may already exist
-- with an id of its own, so it is looked up rather than assumed.
select id as tour_user from rbac.users where email = 'me@example.com' \gset
select set_config('request.jwt.claims',
    json_build_object('sub', :'tour_user', 'role', 'authenticated')::text, true);
set local role authenticated;
insert into fleet_answers select 'tour',
    aiq.sql_passthrough('select v.name, b.port, b.code as berth from fleet.port_calls c join fleet.vessels v on v.id = c.vessel_id join fleet.berths b on b.id = c.berth_id where c.departed_at is null order by c.arrived_at'),
    aiq.query('SCHEMA "sql" FROM port_calls'),
    aiq.sql_passthrough('select (select count(*) from fleet.vessels) as vessels, (select count(*) from fleet.berths) as berths, (select count(*) from fleet.port_calls) as port_calls');
reset role;
select set_config('request.jwt.claims',
    json_build_object('sub', '01a10000-0000-7000-8000-00000000f1ef', 'role', 'authenticated')::text, true);
set local role authenticated;
insert into fleet_answers select 'stranger',
    aiq.sql_passthrough('select v.name from fleet.port_calls c join fleet.vessels v on v.id = c.vessel_id where c.departed_at is null'),
    null,
    aiq.sql_passthrough('select (select count(*) from fleet.vessels) as vessels, (select count(*) from fleet.berths) as berths, (select count(*) from fleet.port_calls) as port_calls');
reset role;

do $$
declare t jsonb; s jsonb; r jsonb; tc jsonb; rc jsonb;
begin
    select rows, schema, counts into t, s, tc from fleet_answers where who = 'tour';
    select rows, counts into r, rc from fleet_answers where who = 'stranger';
    -- 2. The agent's first look finds the table, under row security.
    if not exists (select 1 from jsonb_array_elements(s #> '{schema,doc,derived,relations}') x
                   where x->>'schema' = 'fleet' and x->>'name' = 'port_calls'
                     and (x->>'row_level_security')::boolean) then
        raise exception 'SCHEMA "sql" did not show fleet.port_calls with row security on: %', s #> '{schema,doc,derived}';
    end if;
    -- 3. The tool's call, as the tour user: the three vessels alongside, in order.
    if t is distinct from '[{"name": "Bulk Harmony", "port": "Gothenburg", "berth": "Skandia 3"},
                            {"name": "Meridian Star", "port": "Rotterdam", "berth": "Amazonehaven 4"},
                            {"name": "Kestrel Tern", "port": "Rotterdam", "berth": "Waalhaven 2"}]'::jsonb then
        raise exception 'the tour user''s alongside query returned %', t;
    end if;
    -- 4. Each table on its own, for each person. A join alone would hide a
    --    table whose policy admits everyone: the other owner's port call joins
    --    to a vessel the tour user cannot see, and drops out of the join.
    if tc is distinct from '[{"vessels": 6, "berths": 6, "port_calls": 11}]'::jsonb then
        raise exception 'the tour user counts %, not only their own 6, 6 and 11', tc;
    end if;
    if rc is distinct from '[{"vessels": 1, "berths": 1, "port_calls": 1}]'::jsonb then
        raise exception 'the other owner counts %, not only their own 1, 1 and 1', rc;
    end if;
    -- The other owner sees their tug and nothing of the tour's.
    if r is distinct from '[{"name": "Someone Else"}]'::jsonb then
        raise exception 'another owner''s alongside query returned %', r;
    end if;
    raise notice 'query/16: the tour fleet loads, SCHEMA shows it under row security, and each owner reads only their own';
end $$;

rollback;
