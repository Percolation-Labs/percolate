-- loads: research-platform/schema.sql
-- Exercise the runtime authority, including an upgrade from the first adapter.
\set ON_ERROR_STOP on
begin;
do $$ begin
 if not exists(select 1 from pg_roles where rolname='app_provisioner') then
  create role app_provisioner nologin;
 end if;
end $$;
\i /tmp/schema.sql

set local session authorization app_provisioner;
select rbac.provision_application_user('a1300000-0000-4000-8000-000000000001');
select rbac.provision_application_credential('a1300000-0000-4000-8000-000000000002',
 'a1300000-0000-4000-8000-000000000001','provisioning test','{packages:read-own}');
select rbac.grant_application_role('a1300000-0000-4000-8000-000000000001','provision-test-list',
 'research','list','operator','original six-argument client');
do $$ begin
 begin
  insert into rbac.users(id,email) values('a1300000-0000-4000-8000-000000000099','not-allowed@example.invalid');
  raise exception 'provisioner wrote a table directly';
 exception when insufficient_privilege then null; end;
 begin
  perform rbac.grant_application_role('a1300000-0000-4000-8000-000000000001','provision-test-admin','users','admin','operator',null);
  raise exception 'provisioner issued an administrator';
 exception when insufficient_privilege then null; end;
end $$;
reset session authorization;
select rbac.revoke_grant(id,'review regression') from rbac.grants
 where user_id='a1300000-0000-4000-8000-000000000001' and role='provision-test-list';
insert into rbac.api_keys(id,user_id,label,key_hash,scopes) values
 ('a1300000-0000-4000-8000-000000000003','a1300000-0000-4000-8000-000000000001','legacy',
  'app-token:a1300000-0000-4000-8000-000000000003','{}'),
 ('a1300000-0000-4000-8000-000000000004','a1300000-0000-4000-8000-000000000001','native','native-key-not-app-created','{}');
insert into rbac.orgs(id,slug,name) values('a1300000-0000-4000-8000-000000000010','provision-test-org','Provisioning test');
update rbac.users set status='disabled' where id='a1300000-0000-4000-8000-000000000001';

set local session authorization app_provisioner;
select rbac.provision_application_user('a1300000-0000-4000-8000-000000000001');
select rbac.revoke_application_credential(k) from unnest(array[
 'a1300000-0000-4000-8000-000000000002'::uuid,'a1300000-0000-4000-8000-000000000003'::uuid,
 'a1300000-0000-4000-8000-000000000004'::uuid]) as keys(k);
select rbac.provision_application_credential('a1300000-0000-4000-8000-000000000002',
 'a1300000-0000-4000-8000-000000000001','retry','{packages:create-private}');
select rbac.grant_application_role('a1300000-0000-4000-8000-000000000001','provision-test-list',
 'research','list','operator','new client retry','hub',null);
select rbac.declare_application('hub','2','[{"resource":"draft","action":"submit","human_only":true}]');
select rbac.grant_application_role('a1300000-0000-4000-8000-000000000001','provision-test-writer',
 'hub.draft','submit','invitation','scoped grant','hub','a1300000-0000-4000-8000-000000000010');
reset session authorization;
do $$ begin
 assert (select status='disabled' from rbac.users where id='a1300000-0000-4000-8000-000000000001');
 assert (select revoked_at is not null and scopes='{packages:read-own}'::text[] from rbac.api_keys where id='a1300000-0000-4000-8000-000000000002');
 assert (select revoked_at is not null from rbac.api_keys where id='a1300000-0000-4000-8000-000000000003');
 assert (select revoked_at is null from rbac.api_keys where id='a1300000-0000-4000-8000-000000000004'), 'native keys are outside application provisioning';
 assert (select count(*)=1 and bool_and(revoked_at is not null) from rbac.grants
  where user_id='a1300000-0000-4000-8000-000000000001' and role='provision-test-list'), 'retry must retain legacy revocation';
 assert not exists(select 1 from rbac.user_roles where user_id='a1300000-0000-4000-8000-000000000001' and role='provision-test-list');
 assert exists(select 1 from rbac.grants where user_id='a1300000-0000-4000-8000-000000000001' and role='provision-test-writer'
  and application='hub' and org_id='a1300000-0000-4000-8000-000000000010');
end $$;
rollback;
