-- loads: research-platform/schema.sql
-- Exact-revision exposure (authoring-and-publication.md §4, REM-185): a listed
-- work shows anybody else only the revisions that were exposed. An owner's
-- private working successor, a draft from before listing, and everything
-- nested under them stay the owner's; a correction moves what others see and
-- keeps earlier public revisions resolvable; unlisting hides them all; and an
-- upgrade replay never exposes a private working revision.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000e0001', 'exposure-owner@example.test',    'active'),
    ('00000000-0000-4000-8000-0000000e0002', 'exposure-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('exposure-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('exposure-lister', 'research', 'list') on conflict do nothing;
set local request.jwt.claims = '';
select rbac.grant_with_basis('00000000-0000-4000-8000-0000000e0001', 'exposure-lister', 'invitation', 'exposure test');


-- 1. The owner lists a package, then loses the listing grant and keeps
--    writing privately: a working successor needs no listing authority.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0001"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "The public text", "summary": "What anybody may read.",
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "A public claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A public source", "url": "https://example.com/public", "origin": "Public", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "listed"}', null, 'rp-exposure-one');
reset role;

set local request.jwt.claims = '';
select rbac.revoke_grant((select id from rbac.grants where role = 'exposure-lister'
                           and user_id = '00000000-0000-4000-8000-0000000e0001' and revoked_at is null), 'exposure test');

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0001"}';
set local role authenticated;
do $$
declare r jsonb;
begin
    r := research.revise_working('rp-exposure-one',
        '{"schema_version": "0.1", "title": "The private working text", "summary": "Not ready for anybody else.",
          "claims": [{"id": "C9", "kind": "Inference", "text": "A private claim.", "source_ids": ["S9"], "locator": "P9"}],
          "sources": [{"id": "S9", "title": "A private source", "url": "https://example.com/private", "origin": "Private", "status": "Not opened", "locator": "P9"}],
          "edges": [], "visibility": "listed"}', 'draft-1');
    assert r->>'revision' = 'draft-2' and (r->>'created')::boolean, 'a working successor is draft-2';
    assert not (r->>'exposed')::boolean, 'a working successor is not exposed';
    assert research.get_package('rp-exposure-one')->>'revision' = 'draft-2', 'the owner reads the working head';
    assert (research.get_package('rp-exposure-one')->>'is_head')::boolean, 'to the owner it is the head';
    assert (select r2->>'title' from research.list_packages(true) r2 where r2->>'id' = 'rp-exposure-one') = 'The private working text',
        'the owner''s listing shows the working title';
    assert research.trust((research.get_package('rp-exposure-one', 'draft-1')->'receipt'->>'revision_id')::uuid)
               ->'corrections'->'superseded_by' = '["draft-2"]'::jsonb, 'the owner sees the private successor in history';
    assert research.revise_working('rp-exposure-one',
        '{"schema_version": "0.1", "title": "The private working text", "summary": "Not ready for anybody else.",
          "claims": [{"id": "C9", "kind": "Inference", "text": "A private claim.", "source_ids": ["S9"], "locator": "P9"}],
          "sources": [{"id": "S9", "title": "A private source", "url": "https://example.com/private", "origin": "Private", "status": "Not opened", "locator": "P9"}],
          "edges": [], "visibility": "listed"}', 'draft-2')->>'created' = 'false', 'an unchanged working revision is a no-op';
    begin
        perform research.revise_working('rp-exposure-one', '{"schema_version": "0.1", "title": "A stale tab"}', 'draft-1');
        raise exception 'a stale working revision was accepted';
    exception when sqlstate 'PT409' then null;
    end;
    begin
        perform research.revise_package('rp-exposure-one', '{"schema_version": "0.1", "title": "Relisted", "visibility": "listed"}', 'draft-2');
        raise exception 'listing a correction without a grant was accepted';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;


-- 2. Anybody else: the exposed revision only, with nothing of the successor --
--    no text, claims, sources, head, history label, trust read or receipt.
do $$
declare
    claims text[] := array['{}', '{"sub": "00000000-0000-4000-8000-0000000e0002"}'];
    c text;
    v_private uuid;
    v_public uuid;
begin
    select r.id into v_private from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-exposure-one' and r.label = 'draft-2';
    select r.id into v_public from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-exposure-one' and r.label = 'draft-1';
    foreach c in array claims loop
        perform set_config('request.jwt.claims', c, true);
        execute 'set local role authenticated';
        assert research.get_package('rp-exposure-one')->>'revision' = 'draft-1', 'others read the exposed revision: ' || c;
        assert research.get_package('rp-exposure-one')->>'title' = 'The public text', 'with its own text: ' || c;
        assert (research.get_package('rp-exposure-one')->>'is_head')::boolean, 'is_head does not reveal a successor: ' || c;
        assert research.get_package('rp-exposure-one', 'draft-2') is null, 'the working revision is not readable by label: ' || c;
        assert (select r->>'revision' from research.list_packages() r where r->>'id' = 'rp-exposure-one') = 'draft-1',
            'the listing shows the exposed revision: ' || c;
        assert not exists (select 1 from research.revisions where id = v_private), 'row security hides the revision body: ' || c;
        assert exists (select 1 from research.revisions where id = v_public), 'and shows the exposed one: ' || c;
        assert not exists (select 1 from research.heads h join research.works w on w.id = h.work_id where w.public_id = 'rp-exposure-one'),
            'a head on a private revision is hidden: ' || c;
        assert not exists (select 1 from research.claims where revision_id = v_private), 'its claims are hidden: ' || c;
        assert not exists (select 1 from research.sources where revision_id = v_private), 'its sources are hidden: ' || c;
        assert not exists (select 1 from research.citations where revision_id = v_private), 'its citations are hidden: ' || c;
        assert (select count(*) from research.claims cl join research.revisions r on r.id = cl.revision_id
                  join research.works w on w.id = r.work_id where w.public_id = 'rp-exposure-one') = 1,
            'claim counts include only the exposed revision: ' || c;
        assert research.trust(v_private) is null, 'no trust read for the working revision: ' || c;
        assert research.trust(v_public)->'corrections'->'superseded_by' = '[]'::jsonb, 'history does not name the private successor: ' || c;
        assert research.receipt(v_private, false) is null, 'no receipt for the working revision: ' || c;
        assert engagement.revision_signals(v_private) is null
            or coalesce((engagement.revision_signals(v_private)->>'useful_votes')::int, 0) = 0,
            'no signals for the working revision: ' || c;
        execute 'reset role';
    end loop;
end $$;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0002"}';
set local role authenticated;
do $$
declare v_private uuid;
begin
    reset role;
    select r.id into v_private from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-exposure-one' and r.label = 'draft-2';
    set local role authenticated;
    begin
        perform engagement.add_comment(v_private, 'A comment on text that is not public.');
        raise exception 'a stranger commented on a private working revision';
    exception when no_data_found or insufficient_privilege then null;
    end;
    begin
        perform research.revise_working('rp-exposure-one', '{"schema_version": "0.1", "title": "Not mine"}', 'draft-2');
        raise exception 'a stranger wrote a working revision';
    exception when no_data_found then null;
    end;
end $$;
reset role;


-- 3. A draft from before listing stays private; a listed correction moves what
--    others read and keeps the earlier public revision resolvable.
set local request.jwt.claims = '';
select rbac.grant_with_basis('00000000-0000-4000-8000-0000000e0001', 'exposure-lister', 'invitation', 'renewed exposure test');
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0001"}';
set local role authenticated;
select research.submit_package('{"schema_version": "0.1", "title": "A private first draft", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
                               null, 'rp-exposure-two');
select research.revise_package('rp-exposure-two', '{"schema_version": "0.1", "title": "The listed second draft", "claims": [], "sources": [], "edges": [], "visibility": "listed"}',
                               'draft-1');
select research.revise_package('rp-exposure-one', '{"schema_version": "0.1", "title": "The public correction", "claims": [], "sources": [], "edges": [], "visibility": "listed"}',
                               'draft-2');
reset role;

set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-exposure-two')->>'revision' = 'draft-2', 'the listed revision is readable';
    assert research.get_package('rp-exposure-two', 'draft-1') is null, 'a draft from before listing is not';
    assert research.get_package('rp-exposure-one')->>'title' = 'The public correction', 'a listed correction is what others read now';
    assert research.get_package('rp-exposure-one', 'draft-1')->>'title' = 'The public text',
        'an earlier public revision still resolves, so a pinned link keeps working';
    assert research.get_package('rp-exposure-one', 'draft-2') is null, 'the working revision in between stays private';
    assert research.trust((research.get_package('rp-exposure-one', 'draft-1')->'receipt'->>'revision_id')::uuid)
               ->'corrections'->'superseded_by' = '["draft-3"]'::jsonb, 'history names only the public correction';
end $$;
reset role;


-- 3b. Listing the owner's private working revision exactly as saved exposes it
--     (REM-269): an unchanged head used to return before the listing, so the
--     correction stayed private. It makes no new revision, and a replay adds no
--     second exposure.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0001"}';
set local role authenticated;
do $$
declare
    v_saved constant jsonb := '{"schema_version": "0.1", "title": "A correction listed as saved", "claims": [], "sources": [], "edges": [], "visibility": "listed"}';
    r jsonb;
begin
    perform research.submit_package('{"schema_version": "0.1", "title": "The first public text", "claims": [], "sources": [], "edges": [], "visibility": "listed"}',
                                    null, 'rp-exposure-identical');
    r := research.revise_working('rp-exposure-identical', v_saved, 'draft-1');
    assert r->>'revision' = 'draft-2' and not (r->>'exposed')::boolean, 'the correction starts as a private working revision';
    r := research.revise_package('rp-exposure-identical', v_saved, 'draft-2');
    assert r->>'revision' = 'draft-2', 'listing it unchanged names the same revision: ' || r::text;
    assert not (r->>'created')::boolean, 'and creates none';
    assert (r->>'exposed')::boolean and r->>'visibility' = 'listed', 'it is exposed and the work is listed: ' || r::text;
    r := research.revise_package('rp-exposure-identical', v_saved, 'draft-2');
    assert (r->>'exposed')::boolean and not (r->>'created')::boolean, 'a replay is the same exposed revision';
end $$;
reset role;

do $$
begin
    assert (select count(*) from research.exposures e join research.revisions r on r.id = e.revision_id
              join research.works w on w.id = r.work_id where w.public_id = 'rp-exposure-identical' and r.label = 'draft-2') = 1,
        'a replayed listing adds no second exposure';
end $$;

set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-exposure-identical')->>'revision' = 'draft-2', 'anybody now reads the listed correction';
    assert research.get_package('rp-exposure-identical', 'draft-1')->>'title' = 'The first public text',
        'and the earlier public revision still resolves';
    assert research.trust((research.get_package('rp-exposure-identical', 'draft-1')->'receipt'->>'revision_id')::uuid)
               ->'corrections'->'superseded_by' = '["draft-2"]'::jsonb,
        'history names the correction that was listed unchanged';
end $$;
reset role;


-- 4. Unlisting hides every exposed revision.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0001"}';
set local role authenticated;
select research.revise_package('rp-exposure-one', '{"schema_version": "0.1", "title": "Withdrawn", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
                               'draft-3');
reset role;
set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-exposure-one') is null, 'an unlisted work is gone for others';
    assert research.get_package('rp-exposure-one', 'draft-1') is null, 'including its earlier public revisions';
    assert not exists (select 1 from research.list_packages() r where r->>'id' = 'rp-exposure-one'), 'and from the listing';
end $$;
reset role;


-- 5. Upgrade: a public work from before exposures keeps every revision readable,
--    and replaying the schema never exposes a working revision written after.
set local request.jwt.claims = '';
insert into research.works (id, public_id, owner_id, visibility, listed_at) values
    ('00000000-0000-4000-8000-0000000e0100', 'rp-exposure-legacy', '00000000-0000-4000-8000-0000000e0001', 'public', now());
insert into research.revisions (id, work_id, number, label, schema_version, document, content_hash, actor_id, actor_kind) values
    ('00000000-0000-4000-8000-0000000e0101', '00000000-0000-4000-8000-0000000e0100', 1, 'draft-1', '0.1',
     '{"schema_version": "0.1", "title": "Legacy one"}', 'legacy-1', '00000000-0000-4000-8000-0000000e0001', 'person'),
    ('00000000-0000-4000-8000-0000000e0102', '00000000-0000-4000-8000-0000000e0100', 2, 'draft-2', '0.1',
     '{"schema_version": "0.1", "title": "Legacy two"}', 'legacy-2', '00000000-0000-4000-8000-0000000e0001', 'person');
insert into research.heads (work_id, revision_id) values ('00000000-0000-4000-8000-0000000e0100', '00000000-0000-4000-8000-0000000e0102');

\i /tmp/schema.sql

set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-exposure-legacy')->>'title' = 'Legacy two', 'a legacy public head stays readable after the upgrade';
    assert research.get_package('rp-exposure-legacy', 'draft-1')->>'title' = 'Legacy one', 'and so does its earlier revision';
    assert research.get_package('rp-exposure-two', 'draft-1') is null, 'the replay did not expose a draft from before listing';
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000e0001"}';
set local role authenticated;
select research.revise_working('rp-exposure-legacy', '{"schema_version": "0.1", "title": "Legacy private work"}', 'draft-2');
reset role;

\i /tmp/schema.sql

set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-exposure-legacy', 'draft-3') is null, 'a second replay did not expose the working revision';
    assert research.get_package('rp-exposure-legacy')->>'title' = 'Legacy two', 'others still read the last exposed revision';
end $$;
reset role;

rollback;
