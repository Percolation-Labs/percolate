-- An article image (REM-309): a writer with no upload permission stores a PNG as a
-- private resource on the evidence budget; only PNG, JPEG and WebP up to 2 MB are kept; once a listed revision pins
-- it as an image, a stranger and a signed-out reader resolve its bytes through that revision, while the resource
-- itself stays unreadable to them; and nothing else resolves this way -- a table's pinned evidence page, or a
-- picture only a private work shows. Its uploader reads an image no revision cites yet (REM-813: a picture shown
-- before it is cited, such as a reviewer's portrait); nobody else does.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000309a1', 'image-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000309b2', 'image-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('image-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('image-lister', 'research', 'list') on conflict do nothing;
set local request.jwt.claims = '';
select rbac.grant_with_basis('00000000-0000-4000-8000-0000000309a1', 'image-lister', 'invitation', 'image test');


-- 1. The writer stores an image without resources:create, and only an image of an allowed type and size.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000309a1"}';
set local role authenticated;
do $$
declare me uuid := '00000000-0000-4000-8000-0000000309a1'; img uuid; again uuid; page uuid; kept uuid;
        snap uuid; page_snap uuid; kept_snap uuid; loose uuid; loose_snap uuid;
begin
    assert not content.may_upload(null), 'the writer holds no resources:create';
    img := content.register_research_image('img-sum-1', 'bucket', 'objects/im/img-sum-1', 40000, 'image/png', 'Three cycles');
    assert (select status = 'stored' and visibility = 'private' and owner_id = me and uri is null
              from content.resources where id = img), 'the image is stored, private and the writer''s';
    again := content.register_research_image('img-sum-1', 'bucket', 'objects/im/img-sum-1', 40000, 'image/png', null);
    assert img = again, 'the same bytes uploaded again are the same resource';
    assert (rbac.limit_state(me, 'evidence_bytes')->>'used')::bigint = 40000, 'and are charged once';

    begin
        perform content.register_research_image('img-sum-2', 'bucket', 'k2', 100, 'image/svg+xml', null);
        raise exception 'an SVG was kept as an article image';
    exception when check_violation then null;
    end;
    begin
        perform content.register_research_image('img-sum-3', 'bucket', 'k3', 2097153, 'image/jpeg', null);
        raise exception 'an image over 2 MB was kept';
    exception when check_violation then null;
    end;
    begin
        perform content.register_research_image('img-sum-4', 'bucket', 'k4', 0, 'image/webp', null);
        raise exception 'an empty image was kept';
    exception when check_violation then null;
    end;

    snap := content.capture_snapshot(img);
    kept := content.register_research_image('img-sum-5', 'bucket', 'objects/im/img-sum-5', 50000, 'image/jpeg', null);
    kept_snap := content.capture_snapshot(kept);
    page := content.register_evidence('https://example.com/page', 'img-page-1', 'bucket', 'objects/pg/1', 900,
                                      'text/html', 'A page');
    page_snap := content.capture_snapshot(page);

    perform research.submit_package(jsonb_build_object('schema_version', '0.1', 'title', 'Pictures', 'visibility', 'listed',
        'claims', '[]'::jsonb, 'edges', '[]'::jsonb, 'sources', '[]'::jsonb,
        'artifacts', jsonb_build_array(
            jsonb_build_object('id', 'A1', 'kind', 'image', 'title', 'Three cycles', 'snapshot_id', snap),
            jsonb_build_object('id', 'A2', 'kind', 'table', 'title', 'Evidence', 'snapshot_id', page_snap))),
        null, 'rp-images-public');
    perform research.submit_package(jsonb_build_object('schema_version', '0.1', 'title', 'Private pictures',
        'visibility', 'private', 'claims', '[]'::jsonb, 'edges', '[]'::jsonb, 'sources', '[]'::jsonb,
        'artifacts', jsonb_build_array(jsonb_build_object('id', 'A1', 'kind', 'image', 'title', 'Kept', 'snapshot_id', kept_snap))),
        null, 'rp-images-private');

    assert exists (select 1 from research.resolve_image(snap) where object_key = 'objects/im/img-sum-1'),
        'the writer resolves the listed work''s image';
    assert exists (select 1 from research.resolve_image(kept_snap)), 'and their private work''s';

    loose := content.register_research_image('img-sum-6', 'bucket', 'objects/im/img-sum-6', 30000, 'image/webp', 'A portrait');
    loose_snap := content.capture_snapshot(loose);
    assert exists (select 1 from research.resolve_image(loose_snap) where object_key = 'objects/im/img-sum-6'),
        'the uploader reads an image no revision cites yet (REM-813)';
end $$;
reset role;

do $$ begin
    perform set_config('im.snap', (select s.id::text from content.resource_snapshots s join content.files f on f.id = s.file_id
                                    where f.checksum = 'img-sum-1'), true);
    perform set_config('im.kept', (select s.id::text from content.resource_snapshots s join content.files f on f.id = s.file_id
                                    where f.checksum = 'img-sum-5'), true);
    perform set_config('im.page', (select s.id::text from content.resource_snapshots s join content.files f on f.id = s.file_id
                                    where f.checksum = 'img-page-1'), true);
    perform set_config('im.loose', (select s.id::text from content.resource_snapshots s join content.files f on f.id = s.file_id
                                    where f.checksum = 'img-sum-6'), true);
end $$;


-- 2. A stranger and a signed-out reader: the listed work's picture, and nothing else.
do $$
declare
    claims text[] := array['{}', '{"sub": "00000000-0000-4000-8000-0000000309b2"}'];
    c text;
    snap uuid := current_setting('im.snap')::uuid;
    page uuid := current_setting('im.page')::uuid;
    kept uuid := current_setting('im.kept')::uuid;
    loose uuid := current_setting('im.loose')::uuid;
begin
    foreach c in array claims loop
        perform set_config('request.jwt.claims', c, true);
        execute 'set local role authenticated';
        assert (select content_type from research.resolve_image(snap)) = 'image/png',
            'a reader of the listed revision resolves its image: ' || c;
        assert not exists (select 1 from content.resolve_snapshot(snap)),
            'but never the uploader''s resource itself: ' || c;
        assert not exists (select 1 from content.resources r join content.resource_snapshots s on s.resource_id = r.id
                            where s.id = snap), 'which stays private: ' || c;
        assert not exists (select 1 from research.resolve_image(kept)),
            'a picture only a private work shows does not resolve: ' || c;
        assert not exists (select 1 from research.resolve_image(page)),
            'a table''s pinned evidence page is not served as an image: ' || c;
        assert not exists (select 1 from research.resolve_image(loose)),
            'an image nobody cites stays its uploader''s alone: ' || c;
        execute 'reset role';
    end loop;
end $$;

rollback;
