-- loads: research-platform/schema.sql
-- An agent publishes through a delegation (agents-and-workflows.md, "Delegated publication"). Publishing stays
-- human-only, and a person may hand it to one of their own credentials, in one org, and take it back:
--
--   1. without a delegation the owner's agent is refused research:publish as human_only, with the grant in hand;
--   2. only a person delegates, only a delegable kind, only to their own live credential, only where they may act;
--   3. the delegated credential may publish in that org, and not in another, and no other credential of theirs may;
--   4. the exposure records the person as author and the credential that acted;
--   5. the grant is still asked: revoking it refuses the agent though the delegation is live;
--   6. revoking the delegation refuses the agent again and leaves the credential's other scopes working;
--   7. revoking the credential refuses it, publishing and withdrawing alike;
--   8. delegable is only for human-only kinds;
--   9. a delegated agent MOVES its own entry's pin (REM-423), and withdraws it (REM-532).
--
-- One transaction, rolled back. Claims are set as the superuser between blocks.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000d0a001', 'delegation-owner@example.test',    'active'),
    ('00000000-0000-4000-8000-000000d0a002', 'delegation-stranger@example.test', 'active');
insert into rbac.orgs (id, slug, name) values
    ('00000000-0000-4000-8000-000000d0f001', 'delegation-blog',  'A publication'),
    ('00000000-0000-4000-8000-000000d0f002', 'delegation-other', 'Another publication');
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-000000d0f001', '00000000-0000-4000-8000-000000d0a001'),
    ('00000000-0000-4000-8000-000000d0f002', '00000000-0000-4000-8000-000000d0a001');
insert into rbac.roles (name, description) values ('delegation-publisher', 'adds research to a publication (test)')
on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('delegation-publisher', 'research', 'publish')
on conflict do nothing;
-- The owner publishes in the blog only; membership of the other org carries no grant.
insert into rbac.grants (user_id, role, application, org_id, basis) values
    ('00000000-0000-4000-8000-000000d0a001', 'delegation-publisher', 'percolate', '00000000-0000-4000-8000-000000d0f001', 'operator');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-000000d0a001', 'delegation-publisher');
-- Two agent credentials for the owner, holding only the scopes a connected agent has, and one for the stranger.
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-000000d0c001', '00000000-0000-4000-8000-000000d0a001', 'desktop', 'delegation-k1', '{packages:read-own,packages:create-private}'),
    ('00000000-0000-4000-8000-000000d0c002', '00000000-0000-4000-8000-000000d0a001', 'laptop',  'delegation-k2', '{packages:read-own,packages:create-private}'),
    ('00000000-0000-4000-8000-000000d0c003', '00000000-0000-4000-8000-000000d0a002', 'theirs',  'delegation-k3', '{packages:read-own,packages:create-private}');

create temp table delegation_ids (name text primary key, id uuid) on commit drop;
grant all on delegation_ids to authenticated;

-- The owner's agent saves a package to publish.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "Written with an agent", "summary": "What the publication shows.",
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "A published claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A source", "url": "https://example.com/delegated", "origin": "Published", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp-delegation-one');


-- 1. The grant is held, and the agent is still refused, because publishing is the person's.
do $$
begin
    assert (rbac.decide_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f001')->>'reason') = 'human_only',
        'an agent without a delegation is refused as human_only';
end $$;

-- 2a. The agent cannot delegate to itself.
do $$
declare v_hint text;
begin
    perform rbac.delegate('00000000-0000-4000-8000-000000d0c001', 'research', 'publish', '00000000-0000-4000-8000-000000d0f001');
    assert false, 'an agent delegated to itself';
exception when insufficient_privilege then
    get stacked diagnostics v_hint = pg_exception_hint;
    assert v_hint = 'human_only', 'an agent delegating is refused as human_only, not ' || v_hint;
end $$;
reset role;
set local request.jwt.claims = '';


-- 2b. The person delegates publishing in the blog to the desktop credential; asking again returns the same one.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001"}';
set local role authenticated;
do $$
declare v_hint text; v_id uuid;
begin
    v_id := rbac.delegate('00000000-0000-4000-8000-000000d0c001', 'research', 'publish', '00000000-0000-4000-8000-000000d0f001');
    assert v_id is not null, 'a person delegates publishing to their own credential';
    assert rbac.delegate('00000000-0000-4000-8000-000000d0c001', 'research', 'publish', '00000000-0000-4000-8000-000000d0f001') = v_id,
        'delegating again returns the live delegation';
    insert into delegation_ids values ('desktop-blog', v_id);

    begin
        perform rbac.delegate('00000000-0000-4000-8000-000000d0c001', 'research', 'endorse', '00000000-0000-4000-8000-000000d0f001');
        assert false, 'endorsing was delegated';
    exception when insufficient_privilege then
        get stacked diagnostics v_hint = pg_exception_hint;
        assert v_hint = 'not_delegable', 'endorsing is not delegable, not ' || v_hint;
    end;

    begin
        perform rbac.delegate('00000000-0000-4000-8000-000000d0c003', 'research', 'publish', '00000000-0000-4000-8000-000000d0f001');
        assert false, 'a person delegated to somebody else''s credential';
    exception when no_data_found then null;
    end;

    begin
        perform rbac.delegate('00000000-0000-4000-8000-000000d0c001', 'research', 'publish', '00000000-0000-4000-8000-000000d0f002');
        assert false, 'a person delegated publishing where they may not publish';
    exception when insufficient_privilege then
        get stacked diagnostics v_hint = pg_exception_hint;
        assert v_hint = 'no_grant', 'a delegation where the person holds no grant is refused as no_grant, not ' || v_hint;
    end;

    assert (select count(*) from rbac.delegations) = 1, 'the person reads their own delegation and nothing was added by a refusal';
end $$;
reset role;
set local request.jwt.claims = '';


-- 3 and 4. The desktop credential publishes in the blog, and the exposure says who acted.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001"}';
set local role authenticated;
do $$
declare v_hint text;
begin
    assert rbac.may_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f001'),
        'the delegated credential may publish in the blog';
    assert (rbac.decide_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f002')->>'reason') = 'human_only',
        'and not in another org, where it holds no delegation';
    assert (rbac.decide('research', 'publish')->>'reason') = 'human_only',
        'decide with claims narrowed to no org counts no delegation';
    perform research.expose_for_publication('rp-delegation-one', 'draft-1', 'delegation-blog', '00000000-0000-4000-8000-000000d0f001');
end $$;
reset role;
do $$
begin
    assert (select exposed_by = '00000000-0000-4000-8000-000000d0a001' and exposed_via = '00000000-0000-4000-8000-000000d0c001'
              from research.publication_exposures where publication = 'delegation-blog'),
        'the exposure names the person as author and the credential that acted';
end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001", "org_id": "00000000-0000-4000-8000-000000d0f001"}';
do $$
begin
    assert rbac.may('research', 'publish'), 'decide with claims narrowed to the blog counts the delegation and the grant there';
end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c002"}';
do $$
begin
    assert (rbac.decide_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f001')->>'reason') = 'human_only',
        'the owner''s other credential holds no delegation and is refused';
end $$;
set local request.jwt.claims = '';


-- 5. The grant is still asked: without it the delegation opens nothing.
update rbac.grants set revoked_at = now(), revoke_reason = 'research/13: the grant behind a delegation'
 where user_id = '00000000-0000-4000-8000-000000d0a001' and role = 'delegation-publisher';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001"}';
do $$
begin
    assert (rbac.decide_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f001')->>'reason') = 'no_grant',
        'a live delegation without the grant behind it is refused as no_grant';
end $$;
set local request.jwt.claims = '';
update rbac.grants set revoked_at = null, revoke_reason = null
 where user_id = '00000000-0000-4000-8000-000000d0a001' and role = 'delegation-publisher';


-- 6. The person revokes the delegation. The agent is refused again; its own scopes still work.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a002"}';
set local role authenticated;
do $$
begin
    assert not rbac.revoke_delegation((select id from delegation_ids where name = 'desktop-blog'), 'not mine'),
        'somebody else''s delegation is not found';
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001"}';
set local role authenticated;
do $$
begin
    assert rbac.revoke_delegation((select id from delegation_ids where name = 'desktop-blog'), 'research/13: taken back'),
        'the person revokes their delegation';
    assert not rbac.revoke_delegation((select id from delegation_ids where name = 'desktop-blog'), 'again'),
        'revoking it again ends nothing';
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001"}';
do $$
begin
    assert (rbac.decide_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f001')->>'reason') = 'human_only',
        'a revoked delegation refuses the agent as human_only';
    assert rbac.may('research', 'select'), 'the credential still reads, through its own scope';
end $$;
set local request.jwt.claims = '';


-- 7. A delegation on a revoked credential opens nothing: it neither publishes nor withdraws (REM-532).
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001"}';
set local role authenticated;
select rbac.delegate('00000000-0000-4000-8000-000000d0c001', 'research', 'publish', '00000000-0000-4000-8000-000000d0f001');
reset role;
update rbac.api_keys set revoked_at = now() where id = '00000000-0000-4000-8000-000000d0c001';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001"}';
set local role authenticated;
do $$
begin
    begin
        perform research.withdraw_publication_exposure('rp-delegation-one', 'draft-1', 'delegation-blog');
        assert false, 'an agent on a revoked credential withdrew work from a publication';
    exception when insufficient_privilege then
        null;
    end;
end $$;
reset role;
do $$
begin
    assert exists (select 1 from research.publication_exposures pe join research.revisions r on r.id = pe.revision_id
                    where r.label = 'draft-1' and pe.publication = 'delegation-blog'),
        'a refused withdrawal removed the exposure';
end $$;
do $$
begin
    assert (rbac.decide_in_org('research', 'publish', '00000000-0000-4000-8000-000000d0f001')->>'reason') = 'credential_revoked',
        'a live delegation on a revoked credential is refused as credential_revoked';
end $$;
set local request.jwt.claims = '';


-- 9. A delegated agent moves the pin from one revision to another (REM-423), then withdraws it (REM-532):
-- what a delegation may put in a publication it may take out, under the same decision.
update rbac.api_keys set revoked_at = null where id = '00000000-0000-4000-8000-000000d0c001';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001"}';
set local role authenticated;
select research.revise_package('rp-delegation-one', jsonb_build_object('title', 'A correction'), 'draft-1');
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d0a001", "api_key_id": "00000000-0000-4000-8000-000000d0c001"}';
set local role authenticated;
do $$
declare v_moved jsonb;
begin
    v_moved := research.move_publication_exposure('rp-delegation-one', 'draft-1', 'draft-2',
                                                  'delegation-blog', '00000000-0000-4000-8000-000000d0f001');
    assert (v_moved->>'retired')::boolean, 'the move left the old revision exposed';
    assert (v_moved->>'revision') = 'draft-2', 'the move did not expose the new revision';
end $$;
do $$
begin
    assert exists (select 1 from research.publication_exposures pe join research.revisions r on r.id = pe.revision_id
                    where r.label = 'draft-2' and pe.publication = 'delegation-blog'),
        'the new revision is readable in the publication';
    assert not exists (select 1 from research.publication_exposures pe join research.revisions r on r.id = pe.revision_id
                        where r.label = 'draft-1' and pe.publication = 'delegation-blog'),
        'the revision moved off is no longer exposed';
end $$;
do $$
begin
    assert research.withdraw_publication_exposure('rp-delegation-one', 'draft-2', 'delegation-blog'),
        'a delegated agent could not withdraw what it published';
    assert not research.withdraw_publication_exposure('rp-delegation-one', 'draft-2', 'delegation-blog'),
        'a second withdrawal removed something';
    assert not exists (select 1 from research.publication_exposures pe join research.revisions r on r.id = pe.revision_id
                        where r.label = 'draft-2' and pe.publication = 'delegation-blog'),
        'the withdrawn revision is still exposed';
end $$;
reset role;
set local request.jwt.claims = '';

-- 8. delegable is only for human-only kinds.
do $$
begin
    begin
        update rbac.permission_kinds set delegable = true where resource = 'research' and action = 'insert';
        assert false, 'a kind every agent may already use was made delegable';
    exception when check_violation then null;
    end;
    assert (select delegable and human_only from rbac.permission_kinds where resource = 'research' and action = 'publish'),
        'research:publish is human-only and delegable';
    assert not (select delegable from rbac.permission_kinds where resource = 'research' and action = 'endorse'),
        'research:endorse is not delegable';
end $$;

rollback;
