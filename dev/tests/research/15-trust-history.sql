-- loads: research-platform/schema.sql
-- Trust history cannot be rewritten, and can be read as of a date (REM-464, specs/tables/schema.md §3).
--
--   1. A work is written, listed, endorsed, published, withdrawn and unlisted, one step per transaction.
--   2. research.trust_state answers each moment between two steps, and 'unknown' before the record starts.
--   3. A reader sees only what they may read now, and nothing once the work is private again.
--   4. The owner of the tables -- which is what every definer runs as -- cannot rewrite any of it.
--   5. research.erase_work is the one way it leaves, and leaves a record that it did.
--
-- NOT ONE TRANSACTION, unlike its neighbours: now() is fixed for a transaction, so every step inside one would
-- share a timestamp and there would be no "between" to ask about. Each step commits, the moments between them
-- are kept in a temporary table, and the fixture is erased at the start and the end.

\set ON_ERROR_STOP on

-- 0. The fixture, and whatever a failed earlier run left of it.
select research.erase_work(public_id, 'rem464 test fixture, left by an earlier run')
  from research.works where public_id = 'rp-rem464';
insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000464a01', 'rem464-owner@example.test',  'active'),
    ('00000000-0000-4000-8000-000000464a02', 'rem464-reader@example.test', 'active')
on conflict do nothing;
insert into rbac.orgs (id, slug, name) values ('00000000-0000-4000-8000-000000464f01', 'rem464-pub', 'A publication')
on conflict do nothing;
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-000000464f01', '00000000-0000-4000-8000-000000464a01')
on conflict do nothing;
insert into rbac.roles (name, description) values
    ('rem464-publisher', 'adds research to a publication (test)'), ('rem464-lister', 'lists research (test)')
on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rem464-publisher', 'research', 'publish'), ('rem464-lister', 'research', 'list')
on conflict do nothing;
insert into rbac.grants (user_id, role, application, org_id, basis)
select '00000000-0000-4000-8000-000000464a01', 'rem464-publisher', 'percolate', '00000000-0000-4000-8000-000000464f01', 'operator'
 where not exists (select 1 from rbac.grants where user_id = '00000000-0000-4000-8000-000000464a01' and role = 'rem464-publisher');
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-4000-8000-000000464a01', 'rem464-publisher'), ('00000000-0000-4000-8000-000000464a01', 'rem464-lister')
on conflict do nothing;

create temporary table marks (name text primary key, at timestamptz not null);
grant select on marks to authenticated;
insert into marks values ('before', clock_timestamp());


-- 1. Six steps, each its own transaction, with a moment recorded after each.
set request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000464a01"}';
set role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "Trust history", "visibility": "private", "sources": [], "edges": [],
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "The first claim."}]}', null, 'rp-rem464');
reset role;
insert into marks values ('written', clock_timestamp());

set role authenticated;
select research.revise_package('rp-rem464',
    '{"schema_version": "0.1", "title": "Trust history, listed", "visibility": "listed", "sources": [], "edges": [],
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "The first claim, sharpened."}]}',
    'draft-1', 'sharpened C1 and listed it');
reset role;
insert into marks values ('listed', clock_timestamp());

set request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000464a02"}';
set role authenticated;
select research.endorse((select id from research.revisions where label = 'draft-2'
                          and work_id = (select id from research.works where public_id = 'rp-rem464')),
                        'the whole package', 'read C1 against its source');
reset role;
insert into marks values ('endorsed', clock_timestamp());

set request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000464a01"}';
set role authenticated;
select research.expose_for_publication('rp-rem464', 'draft-1', 'rem464-pub', '00000000-0000-4000-8000-000000464f01');
reset role;
insert into marks values ('published', clock_timestamp());

-- The reader, while the work is listed, is shown draft-2 and never the head.
set request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000464a02"}';
set role authenticated;
do $$
declare s jsonb := research.trust_state('rp-rem464');
begin
    assert s->>'shown' = 'draft-2', 'a reader is shown the listed revision: ' || s::text;
    assert s->'head' = 'null', 'and not the owner''s head';
    assert jsonb_array_length(s->'endorsements') = 1, 'and sees the endorsement of it';
    perform research.withdraw_endorsement((s->'endorsements'->0->>'id')::uuid, 'found a problem in C1');
end $$;
reset role;
set request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000464a01"}';
set role authenticated;
select research.withdraw_publication_exposure('rp-rem464', 'draft-1', 'rem464-pub');
reset role;
insert into marks values ('withdrawn', clock_timestamp());

set role authenticated;
select research.revise_package('rp-rem464',
    '{"schema_version": "0.1", "title": "Trust history, private again", "visibility": "private", "sources": [], "edges": [],
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "The first claim, withdrawn."}]}', 'draft-2');
reset role;
insert into marks values ('unlisted', clock_timestamp());


-- 2. The owner asks what stood at each moment.
set role authenticated;
do $$
declare
    s jsonb;
    m timestamptz;
begin
    s := research.trust_state('rp-rem464', (select at from marks where name = 'before') - interval '1 day');
    assert s->>'visibility' = 'unknown' and s->'head' = 'null', 'before the record starts, nothing is claimed: ' || s::text;
    assert (s->>'recorded_since')::timestamptz between (select at from marks where name = 'before')
                                                   and (select at from marks where name = 'written'),
        'and recorded_since says when it starts';

    s := research.trust_state('rp-rem464', (select at from marks where name = 'written'));
    assert s->>'visibility' = 'private' and s->>'head' = 'draft-1' and s->'shown' = 'null', 'written: ' || s::text;

    s := research.trust_state('rp-rem464', (select at from marks where name = 'listed'));
    assert s->>'visibility' = 'listed' and s->>'head' = 'draft-2' and s->>'shown' = 'draft-2', 'listed: ' || s::text;
    assert s->'endorsements' = '[]', 'nobody had endorsed it yet';

    s := research.trust_state('rp-rem464', (select at from marks where name = 'endorsed'));
    assert s->'endorsements'->0->>'revision' = 'draft-2' and not (s->'endorsements'->0->>'self')::boolean,
        'the reader''s endorsement of draft-2 stood: ' || s::text;
    assert s->'publications' = '[]', 'nothing was in a publication yet';

    s := research.trust_state('rp-rem464', (select at from marks where name = 'published'));
    assert jsonb_array_length(s->'publications') = 1 and s->'publications'->0->>'publication' = 'rem464-pub'
           and s->'publications'->0->>'revision' = 'draft-1', 'draft-1 was in the publication: ' || s::text;

    s := research.trust_state('rp-rem464', (select at from marks where name = 'withdrawn'));
    assert s->'publications' = '[]' and s->'endorsements' = '[]', 'both withdrawals are in the past state: ' || s::text;
    assert s->>'visibility' = 'listed', 'and the work was still listed';

    s := research.trust_state('rp-rem464', (select at from marks where name = 'unlisted'));
    assert s->>'visibility' = 'private' and s->>'head' = 'draft-3' and s->'shown' = 'null', 'unlisted: ' || s::text;

    -- The same question asked again gets the same answer: nothing it reads was rewritten by the steps after it.
    m := (select at from marks where name = 'endorsed');
    assert research.trust_state('rp-rem464', m) = research.trust_state('rp-rem464', m), 'an as-of read is stable';

    assert (select reason from research.revisions where label = 'draft-2'
             and work_id = (select id from research.works where public_id = 'rp-rem464')) = 'sharpened C1 and listed it',
        'a revision carries why it was made';
    assert (select count(*) from research.publication_withdrawals pw join research.works w on w.id = pw.work_id
             where w.public_id = 'rp-rem464') = 1, 'the withdrawn exposure is on the record';
end $$;
reset role;


-- 3. The reader, now that the work is private and out of the publication, gets nothing: a past state is not a
--    way into a revision they cannot open today.
set request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000464a02"}';
set role authenticated;
do $$
begin
    assert research.trust_state('rp-rem464', (select at from marks where name = 'endorsed')) is null,
        'a reader who cannot read the work now learns nothing about it then';
end $$;
reset role;
reset request.jwt.claims;


-- 4. As the tables' owner, which every definer runs as: no rewrite, no delete, no truncate.
do $$
declare
    w  uuid := (select id from research.works where public_id = 'rp-rem464');
    r2 uuid := (select id from research.revisions where label = 'draft-2'
                  and work_id = (select id from research.works where public_id = 'rp-rem464'));
    statement text;
begin
    foreach statement in array array[
        format('update research.revisions set document = document || ''{"title": "rewritten"}'' where id = %L', r2),
        format('update research.revisions set reason = ''a different reason'' where id = %L', r2),
        format('delete from research.revisions where id = %L', r2),
        format('update research.claims set text = ''rewritten'' where revision_id = %L', r2),
        format('update research.endorsements set scope = ''a narrower scope'' where revision_id = %L', r2),
        format('update research.endorsements set withdrawn_at = null, withdraw_reason = null where revision_id = %L', r2),
        format('update research.endorsements set withdrawn_at = now() where revision_id = %L', r2),
        format('delete from research.endorsement_withdrawals where endorsement_id in '
               '(select id from research.endorsements where revision_id = %L)', r2),
        format('delete from research.publication_withdrawals where work_id = %L', w),
        format('delete from research.visibility_changes where work_id = %L', w),
        format('delete from research.exposures where work_id = %L', w),
        format('delete from research.works where id = %L', w),
        'truncate research.claims cascade'] loop
        begin
            execute statement;
            raise exception 'history was rewritten by the owner: %', statement;
        exception when restrict_violation then null;
        end;
    end loop;
    -- The one update a revision takes: its workflow run pruned, which the foreign key does as set null.
    update research.revisions set run_id = null where id = r2;
end $$;


-- 5. Erasure is the one way out, it needs a reason, and it leaves a record.
do $$
declare w uuid := (select id from research.works where public_id = 'rp-rem464'); e jsonb;
begin
    begin
        perform research.erase_work('rp-rem464', ' ');
        raise exception 'an erasure without a reason was accepted';
    exception when check_violation then null;
    end;
    assert not has_function_privilege('authenticated', 'research.erase_work(text, text)', 'execute'),
        'nobody a person can become may erase';
    e := research.erase_work('rp-rem464', 'rem464 test fixture');
    assert (e->>'revisions')::int = 3, 'the work went with its three revisions: ' || e::text;
    assert not exists (select 1 from research.revisions where work_id = w), 'and none is left';
    assert not exists (select 1 from research.visibility_changes where work_id = w), 'nor its history';
    assert (select reason from research.erasures where work_id = w order by id desc limit 1) = 'rem464 test fixture',
        'and the erasure says why';
    raise notice 'research/15: trust history reads as of each step, refuses the owner, and leaves only by erasure';
end $$;
