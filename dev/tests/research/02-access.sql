-- Regression: a revoked key was denied by decide() but could still read private
-- documents through both a definer and table SELECT. No application in this test.
\set ON_ERROR_STOP on
begin;
insert into rbac.users(id,email,status) values
 ('a1200000-0000-4000-8000-000000000001','access-regression@example.invalid','active');
insert into rbac.api_keys(id,user_id,label,key_hash,scopes) values
 ('a1200000-0000-4000-8000-000000000002','a1200000-0000-4000-8000-000000000001','access test','access-regression-key','{research:select,research:insert}');
insert into rbac.roles(name,description) values ('access-test-lister','test'),('access-test-admin','test'),('access-test-scoped','test');
insert into rbac.role_permissions(role,resource,action) values
 ('access-test-lister','research','list'),('access-test-admin','users','admin'),('access-test-scoped','research','list');
select rbac.grant_with_basis('a1200000-0000-4000-8000-000000000001','access-test-lister','operator','test');
insert into rbac.user_roles(user_id,role) values ('a1200000-0000-4000-8000-000000000001','access-test-admin');

set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001"}';
set local role authenticated;
select research.submit_package('{"schema_version":"0.1","title":"Private test","sources":[],"claims":[],"edges":[],"visibility":"private"}',null,'rp-access-private');
select research.submit_package('{"schema_version":"0.1","title":"Public test","sources":[],"claims":[],"edges":[],"visibility":"listed"}',null,'rp-access-public');
select research.endorse((select h.revision_id from research.heads h join research.works w on w.id=h.work_id where w.public_id='rp-access-private'),'the whole argument','Read the supplied argument.');
reset role;

set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","api_key_id":"a1200000-0000-4000-8000-000000000002"}';
set local role authenticated;
do $$ begin
 assert research.get_package('rp-access-private') is not null, 'a reading key reads';
 begin
  perform research.revise_package('rp-access-public','{"schema_version":"0.1","title":"Agent replacement","visibility":"listed"}','draft-1');
  raise exception 'a private-writing key rewrote public work';
 exception when insufficient_privilege then null; end;
 begin
  perform research.revise_package('rp-access-public','{"schema_version":"0.1","title":"Agent withdrawal","visibility":"private"}','draft-1');
  raise exception 'a private-writing key withdrew public work';
 exception when insufficient_privilege then null; end;
 begin
  perform research.withdraw_endorsement((select id from research.endorsements where endorser_id=rbac.current_user_id()),'agent withdrawal');
  raise exception 'an agent withdrew a human endorsement';
 exception when insufficient_privilege then null; end;
 begin
  perform rbac.revoke_grant((select id from rbac.grants where role='access-test-lister' and user_id=rbac.current_user_id()),'agent revocation');
  raise exception 'an agent revoked a role through its person admin grant';
 exception when insufficient_privilege then null; end;
end $$;
reset role;

update rbac.api_keys set revoked_at=now() where id='a1200000-0000-4000-8000-000000000002';
set local role authenticated;
do $$ begin
 assert rbac.decide('research','select')->>'reason'='credential_revoked';
 assert research.get_package('rp-access-private') is null, 'a revoked key cannot read through the RPC';
 assert not exists(select 1 from research.works where public_id='rp-access-private'), 'RLS also refuses the key';
 assert not exists(select 1 from research.revisions where actor_id=rbac.current_user_id()), 'revision bodies are hidden too';
 assert not exists(select 1 from research.list_packages(true)), 'the listing does not disclose the private title';
end $$;
reset role;

set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","actor":"agent"}';
set local role authenticated;
do $$ begin
 assert rbac.decide('research','select')->>'reason'='credential_required';
 assert research.get_package('rp-access-private') is null;
end $$;
reset role;
set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","api_key_id":"bad-id"}';
set local role authenticated;
do $$ begin
 assert rbac.decide('research','select')->>'reason'='credential_invalid';
end $$;
reset role;

update rbac.users set status='disabled' where id='a1200000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001"}';
set local role authenticated;
do $$ begin
 assert research.get_package('rp-access-private') is null, 'disabling a person also ends private reads';
 begin
  perform rbac.grant_with_basis(rbac.current_user_id(),'access-test-lister','operator','inactive admin');
  raise exception 'an inactive person granted a role';
 exception when insufficient_privilege then null; end;
end $$;
reset role;

-- A public reader still needs no account; a denied credential is not silently
-- treated as a fresh anonymous caller by a protected operation.
set local request.jwt.claims='{}';
set local role authenticated;
do $$ begin
 assert research.get_package('rp-access-public') is not null;
 assert research.get_package('rp-access-private') is null;
end $$;
reset role;

-- Scoped ledger entries cannot turn a role into a global permission.
update rbac.users set status='active' where id='a1200000-0000-4000-8000-000000000001';
delete from rbac.user_roles where user_id='a1200000-0000-4000-8000-000000000001' and role='access-test-lister';
insert into rbac.orgs(id,slug,name) values
 ('a1200000-0000-4000-8000-000000000010','access-test-one','One'),
 ('a1200000-0000-4000-8000-000000000011','access-test-two','Two');
insert into rbac.org_members(org_id,user_id) values
 ('a1200000-0000-4000-8000-000000000010','a1200000-0000-4000-8000-000000000001'),
 ('a1200000-0000-4000-8000-000000000011','a1200000-0000-4000-8000-000000000001');
set local request.jwt.claims='';
select rbac.grant_with_basis('a1200000-0000-4000-8000-000000000001','access-test-scoped','invitation','scoped test','access-test','a1200000-0000-4000-8000-000000000010');
set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","application":"access-test","org_id":"a1200000-0000-4000-8000-000000000010"}';
set local role authenticated;
do $$ begin assert rbac.may('research','list'), 'the matching app and publication can use the grant'; end $$;
reset role;
set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","application":"other-app","org_id":"a1200000-0000-4000-8000-000000000010"}';
set local role authenticated;
do $$ begin assert not rbac.may('research','list'), 'another app cannot inherit the grant'; end $$;
reset role;
set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","application":"access-test","org_id":"a1200000-0000-4000-8000-000000000011"}';
set local role authenticated;
do $$ begin assert not rbac.may('research','list'), 'another publication cannot inherit the grant'; end $$;
reset role;
set local request.jwt.claims='{"sub":"a1200000-0000-4000-8000-000000000001","application":"access-test","org_id":"a1200000-0000-4000-8000-000000000010","orgs":[]}';
set local role authenticated;
do $$ begin assert not rbac.may('research','list'), 'credential org narrowing still intersects the grant'; end $$;
reset role;
rollback;
