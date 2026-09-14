-- What a research revision row may say about itself, whoever writes it (REM-151, specs/tables/schema.md §3):
-- the hash and schema versions it was made with, a predecessor from its own work, a base revision from its
-- parent work, and an actor, credential and caller that agree. Concurrency is dev/research-concurrent-writes.sh,
-- because one rolled-back session cannot overlap itself.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000151a1', 'rc-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000151b2', 'rc-other@example.test', 'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000151c1', '00000000-0000-4000-8000-0000000151a1', 'owner agent', 'rc-hash-owner', '{packages:create-private}'),
    ('00000000-0000-4000-8000-0000000151c2', '00000000-0000-4000-8000-0000000151b2', 'other agent', 'rc-hash-other', '{packages:create-private}');


-- 1. The owner, through the RPCs: the receipt names its versions, and the ledger takes no direct write.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000151a1"}';
set local role authenticated;
do $$
declare
    d jsonb := '{"schema_version": "0.1", "title": "A revision contract test", "sources": [], "claims": [], "edges": [], "visibility": "private"}';
    r jsonb;
begin
    r := research.submit_package(d, null, 'rp-rc-one');
    assert r->>'schema_version' = '0.1' and r->>'hash_algorithm' = 'sha256'
       and r->>'hash_format_version' = 'pg-jsonb-text-1', 'the receipt names what its hash was computed over: ' || r;
    perform research.submit_package(d || '{"title": "A second work"}', null, 'rp-rc-two');
    r := research.revise_package('rp-rc-one', d || '{"title": "A revised contract test"}', 'draft-1');
    assert (select hash_format_version from research.revisions where id = (r->>'revision_id')::uuid) = 'pg-jsonb-text-1',
        'the version is on the row, not only in the receipt';
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, actor_id, actor_kind)
        select id, 9, 'draft-9', '0.1', '{}', 'x', '00000000-0000-4000-8000-0000000151a1', 'person'
          from research.works where public_id = 'rp-rc-one';
        raise exception 'a client wrote a revision row directly';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;


-- 2. As the table owner, the way a definer writes: every wrong row is refused by the row itself.
do $$
declare
    a  uuid := '00000000-0000-4000-8000-0000000151a1';
    b  uuid := '00000000-0000-4000-8000-0000000151b2';
    w1 uuid := (select id from research.works where public_id = 'rp-rc-one');
    w2 uuid := (select id from research.works where public_id = 'rp-rc-two');
    h1 uuid := (select revision_id from research.heads where work_id = (select id from research.works where public_id = 'rp-rc-one'));
    h2 uuid := (select revision_id from research.heads where work_id = (select id from research.works where public_id = 'rp-rc-two'));
begin
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, actor_id, actor_kind)
        values (w1, 50, 'draft-50', '0.1', '{}', 'x', h2, a, 'person');
        raise exception 'a predecessor from another work was accepted';
    exception when foreign_key_violation then null;
    end;
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind)
        values (w1, 51, 'draft-51', '0.1', '{}', 'x', h1, h2, a, 'person');
        raise exception 'a base revision on a work with no parent was accepted';
    exception when foreign_key_violation then null;
    end;

    update research.works set parent_work_id = w2 where id = w1;
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind)
        values (w1, 52, 'draft-52', '0.1', '{}', 'x', h1, h1, a, 'person');
        raise exception 'a base from outside the parent work was accepted';
    exception when foreign_key_violation then null;
    end;
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, actor_id, actor_kind)
        values (w1, 53, 'draft-53', '0.1', '{}', 'x', h1, a, 'person');
        raise exception 'a derivative revision without a base was accepted';
    exception when foreign_key_violation then null;
    end;
    insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind)
    values (w1, 3, 'draft-3', '0.1', '{}', 'x', h1, h2, a, 'person');

    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind)
        values (w1, 60, 'draft-60', '0.1', '{}', 'x', h1, h2, a, 'agent');
        raise exception 'an agent revision without its credential was accepted';
    exception when check_violation then null;
    end;
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind, credential_id)
        values (w1, 61, 'draft-61', '0.1', '{}', 'x', h1, h2, a, 'person', '00000000-0000-4000-8000-0000000151c1');
        raise exception 'a person''s revision carrying a credential was accepted';
    exception when check_violation then null;
    end;
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind, credential_id)
        values (w1, 62, 'draft-62', '0.1', '{}', 'x', h1, h2, a, 'agent', '00000000-0000-4000-8000-0000000151c2');
        raise exception 'an agent revision with somebody else''s credential was accepted';
    exception when check_violation then null;
    end;
    -- The claims still name the owner: a row recorded as anybody else is a forgery.
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, predecessor_id, base_revision_id, actor_id, actor_kind)
        values (w1, 63, 'draft-63', '0.1', '{}', 'x', h1, h2, b, 'person');
        raise exception 'a revision recorded as somebody other than the caller was accepted';
    exception when check_violation then null;
    end;
end $$;


-- 3. Somebody else, and the owner's narrowed key: neither reads nor revises the private work.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000151b2"}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-rc-one') is null, 'a stranger cannot read a private work';
    assert not exists (select 1 from research.revisions r join research.works w on w.id = r.work_id where w.public_id = 'rp-rc-one'),
        'nor its revision rows';
    begin
        perform research.revise_package('rp-rc-one', '{"schema_version": "0.1", "title": "A stranger''s edit", "sources": [], "claims": [], "edges": [], "visibility": "private"}', 'draft-2');
        raise exception 'a stranger revised a private work';
    exception when no_data_found then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000151a1", "api_key_id": "00000000-0000-4000-8000-0000000151c1", "orgs": []}';
set local role authenticated;
do $$
begin
    assert rbac.current_actor() = 'agent', 'the owner''s key is an agent';
    assert rbac.decide('research', 'list')->>'reason' = 'scope_missing', 'a create-private key cannot list';
    begin
        perform research.revise_package('rp-rc-one', '{"schema_version": "0.1", "title": "Listed by a key", "sources": [], "claims": [], "edges": [], "visibility": "listed"}', 'draft-2');
        raise exception 'a create-private key listed the owner''s work';
    exception when insufficient_privilege or raise_exception then
        if sqlerrm = 'a create-private key listed the owner''s work' then raise; end if;
    end;
end $$;
reset role;

rollback;
