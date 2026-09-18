-- loads: research-platform/schema.sql
-- Discussions (REM-507, architecture.md §5): a person posts in a thread on a
-- listed revision, one of its claims, or a resource, taking a stance; a reply
-- stays on its parent's target and claim; an agent is refused as human_only; a
-- post about a private resource is readable exactly when the resource is.
--
-- One transaction, rolled back. Claims are set before each role switch. Ids
-- travel between blocks in transaction-local settings.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000d15c01', 'discuss-owner@example.test',    'active'),
    ('00000000-0000-4000-8000-000000d15c02', 'discuss-reader@example.test',   'active'),
    ('00000000-0000-4000-8000-000000d15c03', 'discuss-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('discuss-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('discuss-lister', 'research', 'list') on conflict do nothing;
set local request.jwt.claims = '';
select rbac.grant_with_basis('00000000-0000-4000-8000-000000d15c01', 'discuss-lister', 'invitation', 'discussion test');

insert into content.channels (id, name, kind, visibility) values ('00000000-0000-4000-8000-000000d15cc1', 'discuss-channel', 'manual', 'public');
insert into content.resources (id, channel_id, uri, title, status, owner_id, visibility) values
    ('00000000-0000-4000-8000-000000d15cd1', '00000000-0000-4000-8000-000000d15cc1',
     'https://example.com/open-study', 'An open study', 'stored', '00000000-0000-4000-8000-000000d15c01', 'public'),
    ('00000000-0000-4000-8000-000000d15cd2', '00000000-0000-4000-8000-000000d15cc1',
     'https://example.com/private-notes', 'Private notes', 'stored', '00000000-0000-4000-8000-000000d15c01', 'private');

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c01"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "A listed argument", "summary": "Something to discuss.",
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "The first claim.", "source_ids": ["S1"], "locator": "P1"},
                 {"id": "C2", "kind": "Inference", "text": "The second claim.", "source_ids": ["S1"], "locator": "P2"}],
      "sources": [{"id": "S1", "title": "A source", "url": "https://example.com/source", "origin": "Public", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "listed"}', null, 'rp-discuss-one');
reset role;


-- 1. The kind exists, human-only and held by every person.
do $$
begin
    assert (select human_only and every_person from rbac.permission_kinds
             where resource = 'engagement' and action = 'discuss'), 'engagement:discuss is human-only for every person';
end $$;


-- 2. A reader starts a thread on a claim with a stance; the owner replies; the
--    reader answers the reply. Each reply inherits the target and the claim.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c02"}';
set local role authenticated;
do $$
declare rev uuid := (research.get_package('rp-discuss-one')->'receipt'->>'revision_id')::uuid; root uuid;
begin
    root := engagement.discuss('I doubt the first claim.', p_revision => rev, p_claim_key => 'C1', p_stance => 'challenges');
    perform set_config('discuss.root', root::text, true);
    assert (select stance = 'challenges' and claim_key = 'C1' and parent_id is null
              from engagement.comments where id = root), 'a root keeps its claim and stance';
    begin
        perform engagement.discuss('Not a stance.', p_revision => rev, p_stance => 'agrees');
        raise exception 'an unknown stance was accepted';
    exception when check_violation then null;
    end;
    begin
        perform engagement.discuss('No such claim.', p_revision => rev, p_claim_key => 'C9');
        raise exception 'a claim outside the revision was accepted';
    exception when foreign_key_violation then null;
    end;
    begin
        perform engagement.discuss('About nothing.');
        raise exception 'a post with no target was accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform engagement.discuss('About two things.', p_revision => rev, p_resource => '00000000-0000-4000-8000-000000d15cd1');
        raise exception 'a post with two targets was accepted';
    exception when invalid_parameter_value then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c01"}';
set local role authenticated;
do $$
declare root uuid := current_setting('discuss.root')::uuid; reply uuid; rev uuid;
begin
    reply := engagement.discuss('The source says so on page one.', p_parent => root, p_stance => 'supports');
    perform set_config('discuss.reply', reply::text, true);
    select revision_id into rev from engagement.comments where id = root;
    assert (select revision_id = rev and claim_key = 'C1' and parent_id = root
              from engagement.comments where id = reply), 'a reply inherits its parent''s revision and claim';
    begin
        perform engagement.discuss('Moving to the other claim.', p_parent => root, p_claim_key => 'C2');
        raise exception 'a reply moved to another claim';
    exception when check_violation then null;
    end;
    begin
        perform engagement.discuss('Moving to a resource.', p_parent => root, p_resource => '00000000-0000-4000-8000-000000d15cd1');
        raise exception 'a reply moved to a resource';
    exception when check_violation then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c02"}';
set local role authenticated;
do $$
declare reply uuid := current_setting('discuss.reply')::uuid; deeper uuid;
begin
    deeper := engagement.discuss('Which edition?', p_parent => reply, p_stance => 'asks');
    assert (select parent_id = reply and claim_key = 'C1' from engagement.comments where id = deeper), 'a reply to a reply is threaded';
    -- Existing verbs hold for posts: edit keeps versions, likes work, withdrawal hides.
    assert engagement.edit_comment(deeper, 'Which edition of the source?', 1) = 2, 'a post is edited like a comment';
    assert engagement.set_like(reply, true), 'a reader likes the owner''s reply';
    assert (select count(*) from engagement.comments where parent_id = current_setting('discuss.root')::uuid) = 1,
        'the reader sees the thread';
end $$;
reset role;


-- 3. An agent is refused as human_only, even on a readable thread.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c02", "api_key_id": "00000000-0000-4000-8000-000000d15ca1"}';
set local role authenticated;
do $$
begin
    assert rbac.decide('engagement', 'discuss')->>'reason' = 'human_only', 'an agent may not discuss';
    begin
        perform engagement.discuss('An agent reply.', p_parent => current_setting('discuss.root')::uuid);
        raise exception 'an agent posted';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;


-- 4. Resources: a public one is discussed by anybody signed in; a private one
--    only by its owner, and its thread is invisible to everybody else.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c02"}';
set local role authenticated;
do $$
declare post uuid;
begin
    post := engagement.discuss('Is this the preprint or the paper?', p_resource => '00000000-0000-4000-8000-000000d15cd1', p_stance => 'asks');
    assert (select resource_id is not null and revision_id is null from engagement.comments where id = post), 'a post can be about a resource';
    begin
        perform engagement.discuss('Peeking.', p_resource => '00000000-0000-4000-8000-000000d15cd2');
        raise exception 'a stranger discussed a private resource';
    exception when no_data_found then null;
    end;
    begin
        perform engagement.discuss('A claim on a resource.', p_resource => '00000000-0000-4000-8000-000000d15cd1', p_claim_key => 'C1');
        raise exception 'a resource post carried a claim';
    exception when check_violation or foreign_key_violation then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c01"}';
set local role authenticated;
select engagement.discuss('A note to myself.', p_resource => '00000000-0000-4000-8000-000000d15cd2');
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000d15c03"}';
set local role authenticated;
do $$
begin
    assert not exists (select 1 from engagement.comments where resource_id = '00000000-0000-4000-8000-000000d15cd2'),
        'a thread on a private resource is invisible to others';
    assert exists (select 1 from engagement.comments where resource_id = '00000000-0000-4000-8000-000000d15cd1'),
        'a thread on a public resource is readable';
end $$;
reset role;

rollback;
