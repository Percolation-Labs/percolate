-- AN OWNERLESS RESOURCE IN THE SHARED ORG IS AN OPERATOR'S TO CHANGE (REM-1116).
--
-- rbac.may_write let any caller write a row with no owner wherever they could
-- reach its org, and every signed-in caller reaches the shared org. So
-- content.record_chunks, which asks may_write past row security, let anyone
-- replace the chunks of what a scheduled pull, a seed or a workflow had
-- registered there. Asserted here:
--   1. a signed-in person, with resources:create or without, cannot replace an
--      ownerless shared resource's chunks, and it keeps its own;
--   2. the worker (claimless) still can;
--   3. a person still replaces chunks of their own resource;
--   4. inside a real org, an ownerless org resource stays its members' to write.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set eve   '''00000000-0000-4000-8000-000000111601'''
\set ana   '''00000000-0000-4000-8000-000000111602'''
\set org   '''00000000-0000-4000-8000-000000111610'''
\set seeded '''00000000-0000-4000-8000-000000111620'''
\set evesown '''00000000-0000-4000-8000-000000111621'''
\set orgres '''00000000-0000-4000-8000-000000111622'''
\set as_eve 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111601"}''; set local role authenticated;'
\set as_ana 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111602","org_id":"00000000-0000-4000-8000-000000111610"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:eve, 'rem1116-eve@example.test', 'active'),
    (:ana, 'rem1116-ana@example.test', 'active');
insert into rbac.orgs (id, slug, name) values (:org, 'rem1116-org', 'An org');
insert into rbac.org_members (org_id, user_id) values (:org, :ana);
insert into content.channels (name, kind, visibility) values ('rem1116', 'manual', 'public');
insert into content.resources (id, channel_id, external_id, title, owner_id, org_id, visibility)
select :seeded::uuid, id, 'rem1116-seeded', 'Seeded', null, rbac.shared_org_id(), 'public' from content.channels where name = 'rem1116'
union all
select :evesown::uuid, id, 'rem1116-eves', 'Eve''s', :eve::uuid, rbac.shared_org_id(), 'private' from content.channels where name = 'rem1116'
union all
select :orgres::uuid, id, 'rem1116-org', 'The org''s', null, :org::uuid, 'org' from content.channels where name = 'rem1116';
select content.record_chunks(:seeded, '[{"content":"as seeded"}]') \g /dev/null

create function pg_temp.refused(p_sql text, p_like text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'accepted, and should have been refused: %', p_sql;
exception when others then
    if sqlerrm not like p_like then raise; end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

-- 1. Eve, on the seeded resource.
:as_eve
select pg_temp.refused($q$select content.record_chunks('00000000-0000-4000-8000-000000111620', '[{"content":"replaced by Eve"}]')$q$,
                       'no such resource, or it is not yours');
-- 3. Eve, on her own.
select content.record_chunks(:evesown, '[{"content":"Eve''s own"}]') \g /dev/null
-- 4. Ana, a member, on her org's ownerless resource.
:as_ana
select content.record_chunks(:orgres, '[{"content":"the org''s, by a member"}]') \g /dev/null
-- 2. The worker.
reset role;
set local request.jwt.claims = '';
set local role worker;
select content.record_chunks(:seeded, '[{"content":"re-pulled by the worker"}]') \g /dev/null
reset role;
do $$
begin
    if (select string_agg(content, '|') from content.resource_chunks where resource_id = '00000000-0000-4000-8000-000000111620')
       is distinct from 're-pulled by the worker' then
        raise exception 'the seeded resource''s chunks are not the worker''s';
    end if;
    if not exists (select 1 from content.resource_chunks where resource_id = '00000000-0000-4000-8000-000000111621') then
        raise exception 'Eve could not replace the chunks of her own resource';
    end if;
    if not exists (select 1 from content.resource_chunks where resource_id = '00000000-0000-4000-8000-000000111622') then
        raise exception 'a member could not write an ownerless resource of their own org';
    end if;
end $$;

rollback;

\echo content/21: an ownerless shared resource is an operator's to change; owners and org members keep theirs
