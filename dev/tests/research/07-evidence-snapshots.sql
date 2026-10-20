-- Cited evidence keeps the exact capture that was reviewed (REM-153): a snapshot keeps
-- its hash after the resource is refetched, only a readable capture can be pinned, an uncaptured source says so,
-- a later capture needs a new revision, resolution asks the resource, and removing pinned bytes is explicit and
-- leaves a tombstone.
--
-- One transaction, rolled back. Claims are set before each role switch. The snapshot id travels between blocks
-- in a transaction-local setting, set as the superuser and read back by every role.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000153a1', 'ev-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000153b2', 'ev-stranger@example.test', 'active');
-- Public, because a channel must be readable by somebody (channels_readable_by_somebody); the resources in it
-- are private to their owner, which is the scope this test is about.
insert into content.channels (id, name, kind, visibility) values ('00000000-0000-4000-8000-0000000153c1', 'ev-channel', 'manual', 'public');
insert into content.files (id, checksum, bucket, object_key, size_bytes, content_type) values
    ('00000000-0000-4000-8000-0000000153f1', 'ev-sum-one', 'bucket', 'ev/one', 10, 'text/html'),
    ('00000000-0000-4000-8000-0000000153f2', 'ev-sum-two', 'bucket', 'ev/two', 12, 'text/html');
insert into content.resources (id, channel_id, file_id, uri, title, status, owner_id, visibility) values
    ('00000000-0000-4000-8000-0000000153d1', '00000000-0000-4000-8000-0000000153c1', '00000000-0000-4000-8000-0000000153f1',
     'https://example.com/study', 'The study', 'stored', '00000000-0000-4000-8000-0000000153a1', 'private'),
    ('00000000-0000-4000-8000-0000000153d2', '00000000-0000-4000-8000-0000000153c1', null,
     'https://example.com/unfetched', 'Not fetched yet', 'pending', '00000000-0000-4000-8000-0000000153a1', 'private');


-- 1. The owner captures, pins a source and an artifact, and leaves another source uncaptured.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000153a1"}';
set local role authenticated;
do $$
declare snap uuid; r jsonb; rev uuid; t jsonb; doc jsonb;
begin
    begin
        perform content.capture_snapshot('00000000-0000-4000-8000-0000000153d2');
        raise exception 'a resource with no stored bytes was captured';
    exception when check_violation then null;
    end;
    snap := content.capture_snapshot('00000000-0000-4000-8000-0000000153d1');
    assert (select checksum from content.resource_snapshots where id = snap) = 'ev-sum-one', 'the snapshot keeps the hash it captured';
    assert (select captured_by = '00000000-0000-4000-8000-0000000153a1' and actor_kind = 'person'
              from content.resource_snapshots where id = snap), 'and who captured it';
    assert exists (select 1 from content.resolve_snapshot(snap) where object_key = 'ev/one'), 'the owner resolves the captured bytes';

    doc := jsonb_build_object('schema_version', '0.1', 'title', 'An evidence test', 'visibility', 'private', 'edges', '[]'::jsonb,
        'claims', jsonb_build_array(jsonb_build_object('id', 'C1', 'text', 'The study says so.', 'source_ids', jsonb_build_array('S1', 'S2'))),
        'sources', jsonb_build_array(
            jsonb_build_object('id', 'S1', 'title', 'The study', 'url', 'https://example.com/study', 'snapshot_id', snap),
            jsonb_build_object('id', 'S2', 'title', 'Not fetched yet', 'url', 'https://example.com/unfetched')),
        'artifacts', jsonb_build_array(
            jsonb_build_object('kind', 'note', 'title', 'A note', 'text', 'Paraphrased.', 'source_ids', jsonb_build_array('S1')),
            jsonb_build_object('kind', 'table', 'title', 'The table', 'snapshot_id', snap)));
    r := research.submit_package(doc, null, 'rp-evidence');
    rev := (r->>'revision_id')::uuid;
    assert (select snapshot_id from research.sources where revision_id = rev and source_key = 'S1') = snap, 'S1 pins its capture';
    assert (select snapshot_id from research.sources where revision_id = rev and source_key = 'S2') is null, 'S2 stays uncaptured';
    assert (select array_agg(artifact_key || ':' || purpose) from research.revision_files where revision_id = rev) = '{A2:table}',
        'the artifact with a capture is linked by its position';

    t := research.trust(rev);
    assert (select s->'capture'->>'status' from jsonb_array_elements(t->'sources') s where s->>'id' = 'S1') = 'captured', 'S1 reads as captured';
    assert (select s->'capture'->>'checksum' from jsonb_array_elements(t->'sources') s where s->>'id' = 'S1') = 'ev-sum-one', 'with its hash';
    assert (select s->'capture'->>'status' from jsonb_array_elements(t->'sources') s where s->>'id' = 'S2') = 'unverified', 'S2 says unverified';

    begin
        update research.sources set snapshot_id = null where revision_id = rev;
        raise exception 'a client rewrote a source''s pin';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- The snapshot id, carried to the later blocks. Set here, as the superuser: a person's role may not call
-- set_config (REM-44), and every role may read the setting back.
do $$ begin
    perform set_config('ev.snap', (select id::text from content.resource_snapshots
                                    where resource_id = '00000000-0000-4000-8000-0000000153d1' and checksum = 'ev-sum-one'), true);
end $$;


-- 2. A refetch moves the resource to new bytes. The snapshot keeps the old hash; a pinned resource cannot be
--    deleted, and pinned bytes are not an orphan.
do $$
declare snap uuid := current_setting('ev.snap')::uuid;
begin
    update content.resources set file_id = '00000000-0000-4000-8000-0000000153f2' where id = '00000000-0000-4000-8000-0000000153d1';
    assert (select checksum from content.resource_snapshots where id = snap) = 'ev-sum-one', 'a refetch leaves the capture''s hash alone';
    assert not exists (select 1 from content.check_drift() where kind = 'orphan_file' and id = '00000000-0000-4000-8000-0000000153f1'),
        'bytes a snapshot pins are not reported as an orphan';
    begin
        delete from content.resources where id = '00000000-0000-4000-8000-0000000153d1';
        raise exception 'a resource a snapshot pins was deleted';
    exception when foreign_key_violation then null;
    end;
end $$;


-- 3. A stranger can neither see, resolve, capture nor pin the owner's private evidence.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000153b2"}';
set local role authenticated;
do $$
declare snap uuid := current_setting('ev.snap')::uuid;
begin
    assert not exists (select 1 from content.resource_snapshots where id = snap), 'a stranger cannot read the capture';
    assert not exists (select 1 from content.resolve_snapshot(snap)), 'nor resolve its bytes';
    begin
        perform content.capture_snapshot('00000000-0000-4000-8000-0000000153d1');
        raise exception 'a stranger captured a private resource';
    exception when no_data_found then null;
    end;
    begin
        perform research.submit_package(jsonb_build_object('schema_version', '0.1', 'title', 'Borrowed evidence', 'visibility', 'private',
            'claims', '[]'::jsonb, 'edges', '[]'::jsonb,
            'sources', jsonb_build_array(jsonb_build_object('id', 'S1', 'title', 'Not mine', 'snapshot_id', snap))), null, 'rp-borrowed');
        raise exception 'a stranger pinned somebody else''s private capture';
    exception when foreign_key_violation then null;
    end;
    assert not has_function_privilege('authenticated', 'content.remove_snapshot_bytes(uuid, text)', 'execute'),
        'and no caller may remove pinned bytes';
end $$;
reset role;


-- 4. The owner captures the new bytes: that is a new revision, and the old one still pins the old capture.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000153a1"}';
set local role authenticated;
do $$
declare
    snap  uuid := current_setting('ev.snap')::uuid;
    snap2 uuid;
    -- The stored document of draft-1, read as its owner (get_package returns the document's fields at its top level).
    doc   jsonb := (select v.document from research.revisions v join research.works w on w.id = v.work_id
                     where w.public_id = 'rp-evidence' and v.label = 'draft-1');
begin
    snap2 := content.capture_snapshot('00000000-0000-4000-8000-0000000153d1');
    assert (select checksum from content.resource_snapshots where id = snap2) = 'ev-sum-two', 'a later capture takes the new bytes';
    perform research.revise_package('rp-evidence',
        jsonb_set(doc, '{sources,0,snapshot_id}', to_jsonb(snap2::text)), 'draft-1');
    assert (select s.snapshot_id from research.sources s join research.revisions v on v.id = s.revision_id
              join research.works w on w.id = v.work_id
             where w.public_id = 'rp-evidence' and v.label = 'draft-2' and s.source_key = 'S1') = snap2, 'draft-2 pins the new capture';
    assert (select s.snapshot_id from research.sources s join research.revisions v on v.id = s.revision_id
              join research.works w on w.id = v.work_id
             where w.public_id = 'rp-evidence' and v.label = 'draft-1' and s.source_key = 'S1') = snap, 'draft-1 still pins the one it had';
end $$;
reset role;


-- 5. The operator removes the old capture's bytes: a tombstone with its hash, nothing to resolve, and an old
--    revision that says "removed" rather than pointing at nothing.
do $$
declare snap uuid := current_setting('ev.snap')::uuid;
begin
    begin
        perform content.remove_snapshot_bytes(snap, '  ');
        raise exception 'pinned bytes were removed without a reason';
    exception when check_violation then null;
    end;
    perform content.remove_snapshot_bytes(snap, 'retention test');
    assert (select file_id is null and checksum = 'ev-sum-one' and removed_reason = 'retention test'
              from content.resource_snapshots where id = snap), 'the tombstone keeps the hash and the reason';
    assert exists (select 1 from content.check_drift() where kind = 'orphan_file' and id = '00000000-0000-4000-8000-0000000153f1'),
        'unpinned, the old bytes are now free to prune';
end $$;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000153a1"}';
set local role authenticated;
do $$
declare
    snap uuid := current_setting('ev.snap')::uuid;
    rev1 uuid := (select v.id from research.revisions v join research.works w on w.id = v.work_id
                   where w.public_id = 'rp-evidence' and v.label = 'draft-1');
begin
    assert not exists (select 1 from content.resolve_snapshot(snap)), 'removed bytes resolve to nothing';
    assert (select s->'capture'->>'status' from jsonb_array_elements(research.trust(rev1)->'sources') s where s->>'id' = 'S1') = 'removed',
        'the old revision says its evidence was removed';
end $$;
reset role;

rollback;
