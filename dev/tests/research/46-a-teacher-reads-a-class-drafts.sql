-- loads: research-platform/schema.sql
-- A TEACHER READS A CLASS'S PRIVATE DRAFTS; ANOTHER STUDENT DOES NOT, AND A STUDENT DOES NOT PUBLISH (REM-1166).
--
-- A class is an org, and its teacher holds research:supervise granted in it. Making a student's drafts org-visible
-- would show them to every classmate as well, so supervision is its own pair, asked by research.revision_readable.
--
--   1. the teacher reads every revision of a student's private work, the first draft too;
--   2. a classmate, and a teacher of another class, read none of it;
--   3. the student, holding no research:publish, is refused adding the work to a publication in the class.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000001166a1', 'rp46-teacher@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166b2', 'rp46-student@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166c3', 'rp46-classmate@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001166d4', 'rp46-other-teacher@example.test', 'active');
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


-- The student writes a private work in two revisions.
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
reset role;
set local request.jwt.claims = '';
-- Its revisions by id, read here because the work itself is not readable to the callers below.
select set_config('rp46.revisions', string_agg(r.id::text, ','), true)
  from research.revisions r join research.works w on w.id = r.work_id where w.public_id = 'rp46-draft';


-- 1. The teacher reads both revisions.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166a1"}';
set local role authenticated;
do $$
begin
    assert (select count(*) from unnest(string_to_array(current_setting('rp46.revisions'), ',')::uuid[]) r(id)
             where research.revision_readable(r.id)) = 2,
        'the class''s teacher reads both of a student''s private revisions';
end $$;
reset role;


-- 2. A classmate and another class's teacher read none.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166c3"}';
set local role authenticated;
do $$
begin
    assert (select count(*) from unnest(string_to_array(current_setting('rp46.revisions'), ',')::uuid[]) r(id)
             where research.revision_readable(r.id)) = 0,
        'a classmate reads none of it';
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001166d4"}';
set local role authenticated;
do $$
begin
    assert (select count(*) from unnest(string_to_array(current_setting('rp46.revisions'), ',')::uuid[]) r(id)
             where research.revision_readable(r.id)) = 0,
        'nor does a teacher of another class';
end $$;
reset role;


-- 3. The student is refused publishing in the class.
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
