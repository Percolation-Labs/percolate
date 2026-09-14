-- loads: research-platform/schema.sql
-- Publication exposure (authoring-and-publication.md §5, REM-252): an owner adds
-- an exact revision of their own private work to a publication, in an org where
-- they hold research:publish, and anybody may read that revision without the
-- work being listed. Its head, its other revisions and everything nested under
-- them stay the owner's; listing and unlisting leave it alone; withdrawing the
-- exposure hides the revision again. An agent, a stranger, a member without the
-- grant and a grant held only in the shared org are refused.
--
-- One transaction, rolled back. Claims are set as the superuser between blocks.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000252a01', 'rem252-owner@example.test',    'active'),
    ('00000000-0000-4000-8000-000000252a02', 'rem252-stranger@example.test', 'active'),
    ('00000000-0000-4000-8000-000000252a03', 'rem252-member@example.test',   'active'),
    ('00000000-0000-4000-8000-000000252a04', 'rem252-shared@example.test',   'active');
insert into rbac.orgs (id, slug, name) values
    ('00000000-0000-4000-8000-000000252f01', 'rem252-blog', 'A publication');
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-000000252f01', '00000000-0000-4000-8000-000000252a01'),
    ('00000000-0000-4000-8000-000000252f01', '00000000-0000-4000-8000-000000252a02'),
    ('00000000-0000-4000-8000-000000252f01', '00000000-0000-4000-8000-000000252a03'),
    ('00000000-0000-4000-8000-000000252f01', '00000000-0000-4000-8000-000000252a04');
insert into rbac.roles (name, description) values
    ('rem252-publisher', 'adds research to a publication (test)'),
    ('rem252-lister', 'lists research (test)')
on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rem252-publisher', 'research', 'publish'),
    ('rem252-lister', 'research', 'list')
on conflict do nothing;
-- The owner and the stranger publish in the org; the shared holder's only grant is in the shared org.
insert into rbac.grants (user_id, role, application, org_id, basis) values
    ('00000000-0000-4000-8000-000000252a01', 'rem252-publisher', 'percolate', '00000000-0000-4000-8000-000000252f01', 'operator'),
    ('00000000-0000-4000-8000-000000252a02', 'rem252-publisher', 'percolate', '00000000-0000-4000-8000-000000252f01', 'operator');
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-4000-8000-000000252a01', 'rem252-publisher'),
    ('00000000-0000-4000-8000-000000252a02', 'rem252-publisher'),
    ('00000000-0000-4000-8000-000000252a04', 'rem252-publisher'),
    ('00000000-0000-4000-8000-000000252a01', 'rem252-lister');

do $$
begin
    assert (select org_id = rbac.shared_org_id() from rbac.grants
             where user_id = '00000000-0000-4000-8000-000000252a04' and role = 'rem252-publisher'),
        'the fixture holds the shared holder''s grant in the shared org';
end $$;


-- 1. The owner writes a private package with a private working successor, then
--    adds draft-1 to the publication. Doing it again changes nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "The published text", "summary": "What the publication shows.",
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "A published claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A published source", "url": "https://example.com/published", "origin": "Published", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp-rem252-one');
select research.revise_working('rp-rem252-one',
    '{"schema_version": "0.1", "title": "The private working text", "summary": "Not ready.",
      "claims": [{"id": "C9", "kind": "Inference", "text": "A private claim.", "source_ids": ["S9"], "locator": "P9"}],
      "sources": [{"id": "S9", "title": "A private source", "url": "https://example.com/private", "origin": "Private", "status": "Not opened", "locator": "P9"}],
      "edges": [], "visibility": "private"}', 'draft-1');
do $$
declare r jsonb; again jsonb;
begin
    r := research.expose_for_publication('rp-rem252-one', 'draft-1', 'blog', '00000000-0000-4000-8000-000000252f01');
    assert r->>'publication' = 'blog' and r->>'revision' = 'draft-1', 'the owner adds draft-1 to the publication';
    again := research.expose_for_publication('rp-rem252-one', 'draft-1', 'blog', '00000000-0000-4000-8000-000000252f01');
    assert again->>'exposed_at' = r->>'exposed_at', 'adding it again changes nothing';
    assert (select count(*) from research.publication_exposures) = 1, 'one exposure';
    assert research.get_package('rp-rem252-one')->>'visibility' = 'private', 'the work is still private';
    assert research.get_package('rp-rem252-one')->>'revision' = 'draft-2', 'the owner still reads the working head';
end $$;
reset role;


-- 2. Anybody else reads exactly draft-1, and finds nothing else of the work.
do $$
declare
    claims text[] := array['{}', '{"sub": "00000000-0000-4000-8000-000000252a03"}'];
    c text;
    v_private uuid;
    v_published uuid;
begin
    select r.id into v_private from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-rem252-one' and r.label = 'draft-2';
    select r.id into v_published from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-rem252-one' and r.label = 'draft-1';
    foreach c in array claims loop
        perform set_config('request.jwt.claims', c, true);
        execute 'set local role authenticated';
        assert research.get_package('rp-rem252-one', 'draft-1')->>'title' = 'The published text',
            'the published revision reads by its label: ' || c;
        assert research.get_package('rp-rem252-one') is null, 'the work has no head to find: ' || c;
        assert research.get_package('rp-rem252-one', 'draft-2') is null, 'the working revision is hidden: ' || c;
        assert not exists (select 1 from research.list_packages() r where r->>'id' = 'rp-rem252-one'),
            'the work is not in the listing: ' || c;
        assert exists (select 1 from research.revisions where id = v_published), 'row security shows the published revision: ' || c;
        assert not exists (select 1 from research.revisions where id = v_private), 'and hides the working one: ' || c;
        assert (select count(*) from research.claims where revision_id = v_published) = 1, 'its claims are readable: ' || c;
        assert not exists (select 1 from research.claims where revision_id = v_private), 'the working claims are not: ' || c;
        assert not exists (select 1 from research.heads h join research.works w on w.id = h.work_id
                            where w.public_id = 'rp-rem252-one'), 'the head is hidden: ' || c;
        assert research.trust(v_published)->'corrections'->'superseded_by' = '[]'::jsonb,
            'history does not name the private successor: ' || c;
        assert research.trust(v_private) is null, 'no trust read for the working revision: ' || c;
        assert (select count(*) from research.publication_exposures) = 1, 'the exposure itself is readable: ' || c;
        assert exists (select 1 from research.works w join research.revisions r on r.work_id = w.id
                        where w.public_id = 'rp-rem252-one' and r.label = 'draft-1'),
            'the published revision joins to its work under row security: ' || c;
        execute 'reset role';
    end loop;
end $$;


-- 3. Refusals: a stranger who publishes in the org, a member without the grant,
--    a grant held only in the shared org, the shared org itself, an agent, a
--    bad slug and another org for the same revision.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a02"}';
set local role authenticated;
do $$
begin
    begin
        perform research.expose_for_publication('rp-rem252-one', 'draft-2', 'blog', '00000000-0000-4000-8000-000000252f01');
        raise exception 'a stranger exposed somebody else''s working revision';
    exception when no_data_found then null;
    end;
    begin
        perform research.withdraw_publication_exposure('rp-rem252-one', 'draft-1', 'blog');
        raise exception 'a stranger withdrew somebody else''s exposure';
    exception when no_data_found then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a03"}';
set local role authenticated;
select research.submit_package('{"schema_version": "0.1", "title": "A member''s draft", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
                               null, 'rp-rem252-member');
do $$
begin
    begin
        perform research.expose_for_publication('rp-rem252-member', 'draft-1', 'blog', '00000000-0000-4000-8000-000000252f01');
        raise exception 'a member without research:publish exposed their work';
    exception when insufficient_privilege then
        null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a04"}';
set local role authenticated;
select research.submit_package('{"schema_version": "0.1", "title": "A shared holder''s draft", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
                               null, 'rp-rem252-shared');
do $$
begin
    begin
        perform research.expose_for_publication('rp-rem252-shared', 'draft-1', 'blog', '00000000-0000-4000-8000-000000252f01');
        raise exception 'a grant held in the shared org opened a publication';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01"}';
set local role authenticated;
do $$
begin
    begin
        perform research.expose_for_publication('rp-rem252-one', 'draft-2', 'blog', rbac.shared_org_id());
        raise exception 'the shared org was accepted as a publication''s org';
    exception when insufficient_privilege then null;
    end;
    begin
        perform research.expose_for_publication('rp-rem252-one', 'draft-2', 'Not A Slug', '00000000-0000-4000-8000-000000252f01');
        raise exception 'a publication name that is not a slug was accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform research.expose_for_publication('rp-rem252-one', 'draft-9', 'blog', '00000000-0000-4000-8000-000000252f01');
        raise exception 'a revision that does not exist was exposed';
    exception when no_data_found then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '';
insert into rbac.orgs (id, slug, name) values ('00000000-0000-4000-8000-000000252f02', 'rem252-other', 'Another publication');
insert into rbac.org_members (org_id, user_id) values ('00000000-0000-4000-8000-000000252f02', '00000000-0000-4000-8000-000000252a01');
insert into rbac.grants (user_id, role, application, org_id, basis) values
    ('00000000-0000-4000-8000-000000252a01', 'rem252-publisher', 'percolate', '00000000-0000-4000-8000-000000252f02', 'operator');
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01"}';
set local role authenticated;
do $$
begin
    begin
        perform research.expose_for_publication('rp-rem252-one', 'draft-1', 'blog', '00000000-0000-4000-8000-000000252f02');
        raise exception 'one revision joined one publication under two orgs';
    exception when unique_violation then null;
    end;
end $$;
reset role;

-- An agent: the same person, calling with a credential.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01", "api_key_id": "00000000-0000-4000-8000-000000252b01"}';
set local role authenticated;
do $$
begin
    begin
        perform research.expose_for_publication('rp-rem252-one', 'draft-2', 'blog', '00000000-0000-4000-8000-000000252f01');
        raise exception 'an agent added work to a publication';
    exception when insufficient_privilege then null;
    end;
    begin
        perform research.withdraw_publication_exposure('rp-rem252-one', 'draft-1', 'blog');
        raise exception 'an agent took work out of a publication';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;


-- 4. Listing is independent: listing a correction and unlisting the work leave
--    the publication's revision readable, and never expose it as a head.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01"}';
set local role authenticated;
select research.revise_package('rp-rem252-one', '{"schema_version": "0.1", "title": "The listed correction", "claims": [], "sources": [], "edges": [], "visibility": "listed"}',
                               'draft-2');
reset role;
set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-rem252-one')->>'title' = 'The listed correction', 'the listing shows the listed correction';
    assert research.get_package('rp-rem252-one', 'draft-1')->>'title' = 'The published text', 'the publication''s revision still reads';
    assert research.get_package('rp-rem252-one', 'draft-2') is null, 'the working revision stays private';
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01"}';
set local role authenticated;
select research.revise_package('rp-rem252-one', '{"schema_version": "0.1", "title": "Unlisted again", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
                               'draft-3');
reset role;
set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-rem252-one') is null, 'an unlisted work has no head for others';
    assert research.get_package('rp-rem252-one', 'draft-3') is null, 'nor its listed correction';
    assert research.get_package('rp-rem252-one', 'draft-1')->>'title' = 'The published text',
        'unlisting leaves the publication''s revision readable';
end $$;
reset role;


-- 5. Withdrawing the exposure hides the revision again; a second withdrawal removes nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000252a01"}';
set local role authenticated;
do $$
begin
    assert research.withdraw_publication_exposure('rp-rem252-one', 'draft-1', 'blog'), 'the owner withdraws the exposure';
    assert not research.withdraw_publication_exposure('rp-rem252-one', 'draft-1', 'blog'), 'a second withdrawal removes nothing';
end $$;
reset role;
set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-rem252-one', 'draft-1') is null, 'a withdrawn revision is private again';
    assert not exists (select 1 from research.publication_exposures), 'and no exposure is left to read';
    assert not exists (select 1 from research.works where public_id = 'rp-rem252-one'), 'nor its work, now unlisted';
    assert exists (select 1 from research.works w where w.public_id = 'rp-rem252-member' and w.visibility = 'private')
           is false, 'a private work with nothing in a publication stays hidden';
end $$;
reset role;

rollback;
