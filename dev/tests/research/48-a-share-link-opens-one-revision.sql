-- loads: research-platform/schema.sql
-- Share links (REM-1332): the owner of a private work makes a secret link to one
-- exact revision. Whoever presents its token, signed in or not, reads that
-- revision and what hangs off it, and nothing else of the work; it is never
-- listed. Sharing again moves the same link; revoking ends it, and a later share
-- makes a new token. A wrong token, another work's token, a stranger and the
-- stranger's agent are refused, and only the owner reads the token back.
--
-- One transaction, rolled back. Claims are set as the superuser between blocks.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000133201', 'rem1332-owner@example.test',    'active'),
    ('00000000-0000-4000-8000-000000133202', 'rem1332-stranger@example.test', 'active');


-- 1. The owner writes a private work with a private working successor, and shares draft-1.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000133201"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "The shared text", "summary": "What the reader sees.",
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "A shared claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A shared source", "url": "https://example.com/shared", "origin": "Shared", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp-rem1332-one');
select research.revise_working('rp-rem1332-one',
    '{"schema_version": "0.1", "title": "The working text", "summary": "Not ready.",
      "claims": [{"id": "C9", "kind": "Inference", "text": "A private claim.", "source_ids": ["S9"], "locator": "P9"}],
      "sources": [{"id": "S9", "title": "A private source", "url": "https://example.com/private", "origin": "Private", "status": "Not opened", "locator": "P9"}],
      "edges": [], "visibility": "private"}', 'draft-1');
select research.submit_package(
    '{"schema_version": "0.1", "title": "Another work", "summary": "Never shared.",
      "claims": [{"id": "C1", "kind": "Inference", "text": "Another claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "Another source", "url": "https://example.com/other", "origin": "Other", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp-rem1332-two');
do $$
declare r jsonb; again jsonb;
begin
    r := research.share_revision('rp-rem1332-one', 'draft-1');
    assert r->>'revision' = 'draft-1' and length(r->>'token') >= 32, 'the owner shares draft-1 and gets a token';
    again := research.share_revision('rp-rem1332-one', 'draft-1');
    assert again->>'token' = r->>'token', 'sharing the same revision again returns the same link';
    assert (select count(*) from research.share_links) = 1, 'one link';
    assert research.get_package('rp-rem1332-one')->>'visibility' = 'private', 'the work is still private';
    assert research.get_package('rp-rem1332-one')->>'revision' = 'draft-2', 'the owner still reads the working head';
end $$;
reset role;
select set_config('rem1332.token', (select token from research.share_links), true) is not null as stashed;


-- 2. Holding the token, a stranger or nobody reads exactly draft-1 and nothing else of the work.
do $$
declare
    claims text[] := array['{}', '{"sub": "00000000-0000-4000-8000-000000133202"}'];
    c text;
    v_shared uuid;
    v_private uuid;
begin
    select r.id into v_shared from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-rem1332-one' and r.label = 'draft-1';
    select r.id into v_private from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-rem1332-one' and r.label = 'draft-2';
    foreach c in array claims loop
        perform set_config('request.jwt.claims', c, true);
        perform set_config('request.share_token', current_setting('rem1332.token'), true);
        execute 'set local role authenticated';
        assert research.shared_revision('rp-rem1332-one') = 'draft-1', 'the token names the shared revision: ' || c;
        assert research.get_package('rp-rem1332-one', 'draft-1')->>'title' = 'The shared text',
            'the shared revision reads by its label: ' || c;
        assert research.get_package('rp-rem1332-one', 'draft-2') is null, 'the working revision is hidden: ' || c;
        assert research.get_package('rp-rem1332-one') is null, 'the work has no head to find: ' || c;
        assert not exists (select 1 from research.list_packages() r where r->>'id' = 'rp-rem1332-one'),
            'the work is not in the listing: ' || c;
        assert (select count(*) from research.claims where revision_id = v_shared) = 1, 'its claims are readable: ' || c;
        assert not exists (select 1 from research.claims where revision_id = v_private), 'the working claims are not: ' || c;
        assert exists (select 1 from research.works w join research.revisions r on r.work_id = w.id
                        where w.public_id = 'rp-rem1332-one' and r.label = 'draft-1'),
            'the shared revision joins to its work under row security: ' || c;
        assert research.shared_revision('rp-rem1332-two') is null, 'the token opens no other work: ' || c;
        assert research.get_package('rp-rem1332-two') is null, 'and the other work stays hidden: ' || c;
        assert (select count(*) from research.share_links) = 1, 'the holder sees only their own link row: ' || c;

        -- Without the token, or with a wrong one, nothing.
        execute 'reset role';
        perform set_config('request.share_token', '', true);
        execute 'set local role authenticated';
        assert research.get_package('rp-rem1332-one', 'draft-1') is null, 'no token reads nothing: ' || c;
        assert research.shared_revision('rp-rem1332-one') is null, 'no token names nothing: ' || c;
        assert not exists (select 1 from research.share_links), 'no token sees no link: ' || c;
        execute 'reset role';
        perform set_config('request.share_token', repeat('A', 32), true);
        execute 'set local role authenticated';
        assert research.get_package('rp-rem1332-one', 'draft-1') is null, 'a wrong token reads nothing: ' || c;
        assert not exists (select 1 from research.works where public_id = 'rp-rem1332-one'),
            'a wrong token shows no work row: ' || c;
        execute 'reset role';
    end loop;
    perform set_config('request.share_token', '', true);
end $$;


-- 3. A stranger can neither share, move nor revoke somebody else's link, and reads no token back.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000133202"}';
set local role authenticated;
do $$
begin
    begin
        perform research.share_revision('rp-rem1332-one', 'draft-2');
        raise exception 'a stranger shared somebody else''s working revision';
    exception when no_data_found then null;
    end;
    begin
        perform research.revoke_share('rp-rem1332-one');
        raise exception 'a stranger revoked somebody else''s link';
    exception when no_data_found then null;
    end;
    assert not exists (select 1 from research.share_links), 'a stranger reads no token';
end $$;
reset role;


-- 4. Sharing draft-2 moves the link: the same token now opens draft-2 and no longer draft-1.
--    Revoking ends it; sharing again makes a different token, and the old one opens nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000133201"}';
set local role authenticated;
do $$
declare r jsonb; fresh jsonb;
begin
    r := research.share_revision('rp-rem1332-one', 'draft-2');
    assert r->>'token' = current_setting('rem1332.token') and r->>'moved_at' is not null, 'the link moves, keeping its token';
    begin
        perform research.share_revision('rp-rem1332-one', 'draft-9');
        raise exception 'shared a revision that does not exist';
    exception when no_data_found then null;
    end;
end $$;
reset role;
do $$
begin
    perform set_config('request.jwt.claims', '{}', true);
    perform set_config('request.share_token', current_setting('rem1332.token'), true);
    execute 'set local role authenticated';
    assert research.get_package('rp-rem1332-one', 'draft-2')->>'title' = 'The working text', 'the moved link reads draft-2';
    assert research.get_package('rp-rem1332-one', 'draft-1') is null, 'and no longer draft-1';
    execute 'reset role';
    perform set_config('request.share_token', '', true);
end $$;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000133201"}';
set local role authenticated;
do $$
declare fresh jsonb;
begin
    assert research.revoke_share('rp-rem1332-one'), 'the owner revokes the link';
    assert not research.revoke_share('rp-rem1332-one'), 'revoking again finds nothing live';
    fresh := research.share_revision('rp-rem1332-one', 'draft-1');
    assert fresh->>'token' <> current_setting('rem1332.token'), 'a share after revoking is a new token';
    assert (select count(*) from research.share_links) = 2, 'the revoked link is kept on record';
end $$;
reset role;
do $$
begin
    perform set_config('request.jwt.claims', '{}', true);
    perform set_config('request.share_token', current_setting('rem1332.token'), true);
    execute 'set local role authenticated';
    assert research.get_package('rp-rem1332-one', 'draft-1') is null, 'the revoked token reads nothing';
    assert research.get_package('rp-rem1332-one', 'draft-2') is null, 'not even the revision it last opened';
    assert research.shared_revision('rp-rem1332-one') is null, 'and names nothing';
    execute 'reset role';
    perform set_config('request.share_token', '', true);
end $$;

rollback;
\echo 'research/48: a share link opens exactly one revision, until it is moved or revoked'
