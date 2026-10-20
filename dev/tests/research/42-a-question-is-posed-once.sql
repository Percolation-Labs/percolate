-- A question is posed once (REM-1099, specs/claims/schema.sql §10a and §10a2). Production's search listed questions
-- in pairs, ids a millisecond apart and one wording. They were not posed twice: every key was distinct. Each pair
-- was a frame's question and the refined question minted with it, and a refined question's search text left its
-- refining slots out, so the two read alike and embedded alike. Here a pose of an existing wording returns the
-- existing question, a frame mints its broader question once, and a refined question reads as its own.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000109901', 'posed-once@example.test', 'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-000000109902', '00000000-0000-4000-8000-000000109901', 'coalescer', 'posed-once-k1',
     '{research:select,research:insert}');

-- 1. A second pose of the same words, however spaced or cased, returns the first question and mints nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000109901", "api_key_id": "00000000-0000-4000-8000-000000109902"}';
set local role authenticated;
do $$
declare
    q  uuid := claims.pose_question('Does an AGENTS.md file shorten a coding agent''s run?');
    q2 uuid := claims.pose_question('  does an agents.md   file shorten a coding agent''s RUN? ');
begin
    assert q2 = q, 'a pose of an existing wording returns the existing question';
end $$;
reset role;
do $$
begin
    assert (select count(*) from claims.questions
             where key = 'q:' || claims.normalised('Does an AGENTS.md file shorten a coding agent''s run?')) = 1,
        'one row for the wording';
end $$;

-- 2. A frame with refining slots mints its broader question once, and the refined one reads differently from it.
do $$
declare
    t     bigint;
    r     uuid;
    r2    uuid;
    other uuid;
    base  claims.questions;
    ref   claims.questions;
begin
    insert into claims.tx (actor_kind, reason) values ('platform', 'test: posed once') returning id into t;
    r := claims.question_for('AGENTS.md presence', 'wall-clock time and output tokens',
                             claims.refinements('{"comparator": "same task without AGENTS.md", "population": "124 pull requests"}'), t);
    r2 := claims.question_for(' agents.md presence', 'Wall-clock time and output tokens ',
                              claims.refinements('{"population": "124 pull requests", "comparator": "Same task without AGENTS.md"}'), t);
    assert r2 = r, 'the same frame, spaced and cased differently, is the same refined question';
    other := claims.question_for('AGENTS.md presence', 'wall-clock time and output tokens',
                                 claims.refinements('{"population": "10 repositories"}'), t);
    select * into ref from claims.questions where id = r;
    select * into base from claims.questions where id = ref.refines;
    assert (select count(*) from claims.questions where refines = base.id) = 2, 'two refinements under one broader question';
    assert (select count(*) from claims.questions where id in (base.id, r, other)) = 3, 'three questions, no twin';
    assert base.search_text = 'AGENTS.md presence: wall-clock time and output tokens', 'the broader one reads as its frame: ' || base.search_text;
    assert ref.search_text = 'AGENTS.md presence: wall-clock time and output tokens'
                             || ' (comparator: same task without agents.md, population: 124 pull requests)',
        'a refined question reads with its refining slots: ' || ref.search_text;
    assert (select count(distinct search_text) from claims.questions where id in (base.id, r, other)) = 3,
        'no two of the three are found by the same words';
end $$;

rollback;
