-- loads: research-platform/schema.sql
-- A TEACHER READS THE DRAFTS A STUDENT PLACED IN THE CLASS, AND NOTHING ELSE OF ANYBODY'S (REM-1166).
--
-- A class is an org, and its teacher holds research:supervise granted in it. Making a student's drafts org-visible
-- would show them to every classmate as well, so supervision is its own pair, asked by research.revision_readable,
-- and it reaches only a work its owner placed in the class (research.place_work) while still a member. Membership is
-- given by an org's admin without the member's say, so membership alone must open nothing.
--
--   1. the teacher reads every revision of a work the student placed in the class, the first draft too;
--   2. not the student's other work, which they did not place, nor an outsider's private work once the outsider is
--      joined to the class: joining somebody reads none of their work;
--   3. a classmate, and a teacher of another class, read none of it;
--   4. a student places a work only in an org they belong to;
--   5. once the student leaves the class the teacher reads none of it;
--   6. the student, holding no research:publish, is refused adding the work to a publication in the class.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000001166a1', 'rp46-teacher@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166b2', 'rp46-student@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166c3', 'rp46-classmate@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166d4', 'rp46-other-teacher@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166e5', 'rp46-outsider@example.test', 'active');
insert into rbac.orgs (id, slug, name) values
    ('00000000-0000-4000-8000-0000001166f1', 'rp46-class-one', 'Class one'),
    ('00000000-0000-4000-8000-0000001166f2', 'rp46-class-two', 'Class two');
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-0000001166f1', '00000000-0000-4000-8000-0000001166a1'),
    ('00000000-0000-4000-8000-0000001166f1', '00000000-0000-4000-8000-0000001166b2'),
    ('00000000-0000-4000-8000-0000001166f1', '00000000-0000-4000-8000-0000001166c3'),
    ('00000000-0000-4000-8000-0000001166f2', '00000000-0000-4000-8000-0000001166d4');
set local request.jwt.claims = '';
select rbac.define_role('rp46-teacher', array['research:supervise', 'research:publish'], 'teaches a class');
select rbac.define_role('rp46-student', array['research:list'], 'writes in a class');
select rbac.grant_with_basis('00000000-0000-4000-8000-0000001166a1', 'rp46-teacher', 'operator',
                             p_org => '00000000-0000-4000-8000-0000001166f1');
select rbac.grant_with_basis('00000000-0000-4000-8000-0000001166d4', 'rp46-teacher', 'operator',
                             p_org => '00000000-0000-4000-8000-0000001166f2');
select rbac.grant_with_basis('00000000-0000-4000-8000-0000001166b2', 'rp46-student', 'operator',
                             p_org => '00000000-0000-4000-8000-0000001166f1');
select rbac.grant_with_basis('00000000-0000-4000-8000-0000001166c3', 'rp46-student', 'operator',
                             p_org => '00000000-0000-4000-8000-0000001166f1');


-- The student writes a class work in two revisions and places it in the class, and keeps a work of their own.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166b2"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "A first draft", "summary": "Not ready.",
      "claims": [{"id": "C1", "kind": "Inference", "text": "A first claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A source", "url": "https://example.com/rp46", "origin": "Private", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp46-draft');
select research.revise_working('rp46-draft',
    '{"schema_version": "0.1", "title": "A second draft", "summary": "Closer.",
      "claims": [{"id": "C1", "kind": "Inference", "text": "A better claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A source", "url": "https://example.com/rp46", "origin": "Private", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', 'draft-1');
select research.place_work('rp46-draft', '00000000-0000-4000-8000-0000001166f1');
select research.submit_package(
    '{"schema_version": "0.1", "title": "My own notes", "summary": "Not for the class.",
      "claims": [{"id": "C1", "kind": "Inference", "text": "A private claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A source", "url": "https://example.com/rp46-own", "origin": "Private", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp46-own');
reset role;

-- The outsider has a private work, then is joined to the class by somebody else.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166e5"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "An outsider''s draft", "summary": "Nobody else''s.",
      "claims": [{"id": "C1", "kind": "Inference", "text": "An outsider''s claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A source", "url": "https://example.com/rp46-out", "origin": "Private", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "private"}', null, 'rp46-outsider');
reset role;
set local request.jwt.claims = '';
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-0000001166f1', '00000000-0000-4000-8000-0000001166e5');

-- Each work's revisions by id, read here because the works themselves are not readable to the callers below.
select set_config('rp46.' || replace(w.public_id, '-', '_'), string_agg(r.id::text, ','), true)
  from research.revisions r join research.works w on w.id = r.work_id
 where w.public_id in ('rp46-draft', 'rp46-own', 'rp46-outsider') group by w.public_id;
create function pg_temp.rp46_readable(p_work text) returns int language sql as $$
    select count(*)::int from unnest(string_to_array(current_setting('rp46.' || p_work), ',')::uuid[]) r(id)
     where research.revision_readable(r.id);
$$;


-- 1 and 2. The teacher reads both revisions of the placed work, and nothing of the other two.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166a1"}';
do $$
begin
    assert pg_temp.rp46_readable('rp46_draft') = 2, 'the teacher reads both revisions the student placed in the class';
    assert pg_temp.rp46_readable('rp46_own') = 0, 'not a work the student did not place';
    assert pg_temp.rp46_readable('rp46_outsider') = 0, 'nor anything of an outsider joined to the class';
end $$;


-- 3. A classmate and another class's teacher read none.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166c3"}';
do $$
begin
    assert pg_temp.rp46_readable('rp46_draft') = 0, 'a classmate reads none of it';
end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166d4"}';
do $$
begin
    assert pg_temp.rp46_readable('rp46_draft') = 0, 'nor does a teacher of another class';
end $$;


-- 4. The student places a work only in an org they belong to.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166b2"}';
set local role authenticated;
do $$
declare v_hint text;
begin
    perform research.place_work('rp46-own', '00000000-0000-4000-8000-0000001166f2');
    assert false, 'a student placed a work in a class they are not in';
exception when insufficient_privilege then
    get stacked diagnostics v_hint = pg_exception_hint;
    assert v_hint = 'not_a_member', format('refused as not a member, not %s', v_hint);
end $$;
reset role;


-- 5. Once the student leaves the class, the teacher reads none of it.
set local request.jwt.claims = '';
delete from rbac.org_members
 where org_id = '00000000-0000-4000-8000-0000001166f1' and user_id = '00000000-0000-4000-8000-0000001166b2';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166a1"}';
do $$
begin
    assert pg_temp.rp46_readable('rp46_draft') = 0, 'a student who left the class takes their drafts with them';
end $$;
set local request.jwt.claims = '';
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-0000001166f1', '00000000-0000-4000-8000-0000001166b2');


-- 6. The student is refused publishing in the class.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166b2"}';
set local role authenticated;
do $$
declare v_hint text;
begin
    perform research.expose_for_publication('rp46-draft', 'draft-2', 'rp46-class-journal',
                                            '00000000-0000-4000-8000-0000001166f1');
    assert false, 'a student with no research:publish added work to a publication';
exception when insufficient_privilege then
    get stacked diagnostics v_hint = pg_exception_hint;
    assert v_hint = 'no_grant', format('refused for want of the grant, not %s', v_hint);
end $$;
reset role;
set local request.jwt.claims = '';

rollback;
