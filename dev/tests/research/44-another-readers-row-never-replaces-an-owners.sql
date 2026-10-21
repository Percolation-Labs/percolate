-- ANOTHER READER'S ROW NEVER REPLACES AN OWNER'S IN A READING (REM-1115).
--
-- graph.md §4 refuses "latest wins": two people asserting different things about one claim is the information.
-- The readings took the latest row per tuple whoever wrote it, so a reader of both revisions, or an agent, wrote a
-- later row and the work owner's confirmed label or stance disappeared from relations_at, claims.reading,
-- question_web and answers_of; withdraw_answer then let that reader erase the stance altogether. Both were
-- reproduced on 0.2.29 by the REM-1088 audit. claims.authoritative now ranks an owner's (or the platform's) rows
-- first in every reading. Asserted here, in two transactions, each rolled back:
--   1. X confirms "A1 contradicts B1"; reader R re-asserts it disputed, and another person's agent proposed:
--      X's reading still shows X's confirmation, through relations_at and claims.reading.
--   2. W confirms A1 answers yes; reader R proposes no, then withdraws: W's yes/confirmed shows throughout, in
--      question_web and answers_of, and R's withdrawal takes back only R's own row.

\set ON_ERROR_STOP on
begin;

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;
insert into ids select k, gen_random_uuid()::text from unnest(array['x', 'b', 'r', 's', 'key']) k;
insert into ids values ('sfx', substr(md5(random()::text), 1, 8));

insert into rbac.users (id, email, status)
select v::uuid, k || '-' || (select v from ids where k = 'sfx') || '@rem1115.test', 'active' from ids where k in ('x', 'b', 'r', 's');
insert into rbac.roles (name, description) values ('rp-rem1115-lister', 'may list research (REM-1115)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-rem1115-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) select v::uuid, 'rp-rem1115-lister' from ids where k in ('x', 'b');
-- An agent key belonging to S, a fourth person who owns neither work.
insert into rbac.api_keys (id, user_id, label, key_hash, scopes)
values ((select v::uuid from ids where k = 'key'), (select v::uuid from ids where k = 's'), 'rem1115-agent',
        'rem1115-' || (select v from ids where k = 'sfx'), '{research:select,research:insert}');

-- X writes work A (listed); B writes work B (listed).
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'x'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into ids values ('wa', research.submit_package('{"schema_version": "0.1", "title": "REM-1088 A", "visibility": "listed", "edges": [],
    "claims": [{"id": "A1", "kind": "Inference", "text": "Access raised build success.", "source_ids": ["S1"]}],
    "sources": [{"id": "S1", "title": "Trial", "origin": "https://doi.org/10.5555/rem1115.2024", "url": ""}]}', null,
    'rem1115-a-' || (select v from ids where k = 'sfx'))->>'revision_id');
reset role;
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'b'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into ids values ('wb', research.submit_package('{"schema_version": "0.1", "title": "REM-1088 B", "visibility": "listed", "edges": [],
    "claims": [{"id": "B1", "kind": "Inference", "text": "Access lowered build success.", "source_ids": ["S1"]}],
    "sources": [{"id": "S1", "title": "Trial again", "origin": "10.5555/rem1115.2024", "url": ""}]}', null,
    'rem1115-b-' || (select v from ids where k = 'sfx'))->>'revision_id');
reset role;

create temporary table seen (step int, who text, predicate text, status text, actor_kind text, rel_id bigint) on commit drop;
grant all on seen to authenticated;

-- Step 1. X, a person and the owner of A, confirms "A1 contradicts B1".
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'x'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into ids values ('rel_x', claims.assert_relation('A1', 'contradicts', 'B1',
    (select v::uuid from ids where k = 'wa'), (select v::uuid from ids where k = 'wb'), null,
    '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same", "period": "same",
                      "setting": "same", "comparator": "same"},
      "src": "Access raised build success", "dst": "Access lowered build success"}')::text);
insert into seen select 1, 'X reads after own confirm', r.predicate, r.status, r.actor_kind, r.id
  from claims.relations_at((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa') and claim_key = 'A1')) r
 where r.predicate = 'contradicts';
reset role;

-- Step 2. R, a person who owns neither work and only reads both, re-asserts the same tuple as 'proposed'.
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'r'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into ids values ('rel_r', claims.assert_relation('A1', 'contradicts', 'B1',
    (select v::uuid from ids where k = 'wa'), (select v::uuid from ids where k = 'wb'), 'disputed',
    '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same", "period": "same",
                      "setting": "same", "comparator": "same"},
      "src": "Access raised build success", "dst": "Access lowered build success"}')::text);
reset role;
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'x'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into seen select 2, 'X reads after reader R re-asserts disputed', r.predicate, r.status, r.actor_kind, r.id
  from claims.relations_at((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa') and claim_key = 'A1')) r
 where r.predicate = 'contradicts';
reset role;

-- Step 3. X confirms again; then S's agent (which may never confirm) re-asserts the tuple: it lands 'proposed'.
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'x'), 'role', 'authenticated')::text, true);
set local role authenticated;
select claims.assert_relation('A1', 'contradicts', 'B1',
    (select v::uuid from ids where k = 'wa'), (select v::uuid from ids where k = 'wb'), null,
    '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same", "period": "same",
                      "setting": "same", "comparator": "same"},
      "src": "Access raised build success", "dst": "Access lowered build success"}') is not null as x_reconfirmed;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 's'), 'role', 'authenticated',
                                                          'api_key_id', (select v from ids where k = 'key'))::text, true);
set local role authenticated;
select claims.assert_relation('A1', 'contradicts', 'B1',
    (select v::uuid from ids where k = 'wa'), (select v::uuid from ids where k = 'wb'), null,
    '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same", "period": "same",
                      "setting": "same", "comparator": "same"},
      "src": "Access raised build success", "dst": "Access lowered build success"}') is not null as agent_asserted;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'x'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into seen select 3, 'X reads after S''s agent re-asserts', r.predicate, r.status, r.actor_kind, r.id
  from claims.relations_at((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa') and claim_key = 'A1')) r
 where r.predicate = 'contradicts';
-- And claims.reading, which builds its 'relations' from relations_at.
insert into seen select 4, 'X claims.reading relations', e->>'predicate', e->>'status', e->>'actor_kind', (e->>'id')::bigint
  from jsonb_array_elements(claims.reading((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa') and claim_key = 'A1'),
                                            'current', null, null)->'relations') e
 where e->>'predicate' = 'contradicts';
reset role;


do $$ begin
    if exists (select 1 from seen where step in (2, 3, 4) and (status is distinct from 'confirmed' or actor_kind is distinct from 'person'))
       or (select count(*) from seen where step in (2, 3, 4)) <> 3 then
        raise exception 'a reader''s or an agent''s later row replaced X''s confirmed contradicts in X''s reading: %',
            (select string_agg(step || ' ' || who || ': ' || status || '/' || actor_kind, '; ' order by step) from seen);
    end if;
end $$;
rollback;

begin;

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;
insert into ids select k, gen_random_uuid()::text from unnest(array['w', 'b', 'r']) k;
insert into ids values ('sfx', substr(md5(random()::text), 1, 8));

insert into rbac.users (id, email, status)
select v::uuid, k || '-' || (select v from ids where k = 'sfx') || '@rem1115.test', 'active' from ids where k in ('w', 'b', 'r');
insert into rbac.roles (name, description) values ('rp-rem1115-lister', 'may list research (REM-1115)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-rem1115-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) select v::uuid, 'rp-rem1115-lister' from ids where k in ('w', 'b');

create temporary table seen (step int, who text, claim_key text, stance text, status text) on commit drop;
grant all on seen to authenticated;

-- W writes work A and poses the question; W confirms A1 answers it 'yes' (a person, own work: confirmed).
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'w'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into ids values ('wa', research.submit_package('{"schema_version": "0.1", "title": "REM-1088 stance A", "visibility": "listed", "edges": [],
    "claims": [{"id": "A1", "kind": "Inference", "text": "Replacing the draft changes which ideas a writer reaches.", "source_ids": ["S1"]}],
    "sources": [{"id": "S1", "title": "A study", "url": "https://example.com/s", "origin": "Study"}]}', null,
    'rem1115-sa-' || (select v from ids where k = 'sfx'))->>'revision_id');
insert into ids values ('q', claims.pose_question('Does handing work to AI weaken the thinking of person '
    || (select v from ids where k = 'sfx') || '?')::text);
select claims.propose_answer((select v::uuid from ids where k = 'wa'), 'A1', (select v::uuid from ids where k = 'q'), 'yes') is not null as w_answered;
reset role;

-- B writes work B and confirms B1 'yes', so the question is answered from two works and appears in question_web.
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'b'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into ids values ('wb', research.submit_package('{"schema_version": "0.1", "title": "REM-1088 stance B", "visibility": "listed", "edges": [],
    "claims": [{"id": "B1", "kind": "Judgement", "text": "Long practice leaves a judgement no answer key supplies.", "source_ids": ["S1"]}],
    "sources": [{"id": "S1", "title": "A craft", "url": "https://example.com/c", "origin": "Craft"}]}', null,
    'rem1115-sb-' || (select v from ids where k = 'sfx'))->>'revision_id');
select claims.propose_answer((select v::uuid from ids where k = 'wb'), 'B1', (select v::uuid from ids where k = 'q'), 'yes') is not null as b_answered;
reset role;

-- Step 1. W's view: A1 yes/confirmed.
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'w'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into seen select 1, 'W question_web, before', e->>'claim_key', e->>'stance', e->>'status'
  from claims.question_web() x, jsonb_array_elements(x.answers) e where x.question = (select v::uuid from ids where k = 'q');
reset role;

-- Step 2. R, a person who owns neither work, first tries to withdraw W's stance directly: refused, as test 36 intends.
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'r'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$ begin
    perform claims.withdraw_answer((select v::uuid from ids where k = 'wa'), 'A1', (select v::uuid from ids where k = 'q'));
    raise exception 'unexpected: R withdrew W''s stance directly';
exception when insufficient_privilege then
    insert into seen values (2, 'R withdraw_answer directly: refused (insufficient_privilege)', 'A1', null, null);
end $$;
-- Step 3. R proposes 'no' on W's A1. It lands proposed, as the spec says a reader's does.
select claims.propose_answer((select v::uuid from ids where k = 'wa'), 'A1', (select v::uuid from ids where k = 'q'), 'no') is not null as r_proposed;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'w'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into seen select 3, 'W question_web, after R proposes no', e->>'claim_key', e->>'stance', e->>'status'
  from claims.question_web() x, jsonb_array_elements(x.answers) e where x.question = (select v::uuid from ids where k = 'q');
insert into seen select 3, 'W answers_of(A1), after R proposes no', 'A1', a.stance, a.status
  from claims.answers_of((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa') and claim_key = 'A1')) a
 where a.question_id = (select v::uuid from ids where k = 'q');
reset role;

-- Step 4. R now withdraws: allowed, because R made the latest row. W's confirmed 'yes' is gone from every read.
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'r'), 'role', 'authenticated')::text, true);
set local role authenticated;
select claims.withdraw_answer((select v::uuid from ids where k = 'wa'), 'A1', (select v::uuid from ids where k = 'q')) is not null as r_withdrew;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where k = 'w'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into seen select 4, 'W question_web(min_works 1), after R withdraws', e->>'claim_key', e->>'stance', e->>'status'
  from claims.question_web(now(), 1) x, jsonb_array_elements(x.answers) e where x.question = (select v::uuid from ids where k = 'q');
insert into seen select 4, 'W answers_of(A1), after R withdraws: rows = ' || count(*), 'A1', null, null
  from claims.answers_of((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa') and claim_key = 'A1')) a
 where a.question_id = (select v::uuid from ids where k = 'q');
reset role;


do $$ begin
    if not exists (select 1 from seen where step = 3 and who like 'W question_web%' and claim_key = 'A1' and stance = 'yes' and status = 'confirmed')
       or not exists (select 1 from seen where step = 3 and who like 'W answers_of%' and stance = 'yes' and status = 'confirmed') then
        raise exception 'reader R''s proposed no replaced W''s confirmed yes: %',
            (select string_agg(step || ' ' || who || ': ' || coalesce(stance, '-') || '/' || coalesce(status, '-'), '; ' order by step) from seen);
    end if;
    if not exists (select 1 from seen where step = 4 and who like 'W question_web%' and claim_key = 'A1' and stance = 'yes' and status = 'confirmed')
       or not exists (select 1 from seen where step = 4 and who like '%rows = 1') then
        raise exception 'R''s withdrawal of R''s own proposal erased W''s confirmed stance: %',
            (select string_agg(step || ' ' || who || ': ' || coalesce(stance, '-') || '/' || coalesce(status, '-'), '; ' order by step) from seen);
    end if;
end $$;
rollback;

\echo research/44: a row by another reader or an agent never replaces the owner row in a reading, and a withdrawal takes back only the caller row
