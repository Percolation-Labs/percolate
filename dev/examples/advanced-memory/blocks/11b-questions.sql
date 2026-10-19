select claims.pose_question('Should the harbour analytics move off Postgres?');
select claims.pose_question('Should an agent''s memory record when each fact became true?');
select claims.pose_question('Is a method validated at one clinic valid at another hospital?');

select claims.propose_answer(pg_temp.note('Berth log benchmark, March',
         'DuckDB scanned a year of berth logs in 4 seconds where Postgres took 41.'), 'C1', (select id from claims.questions where phrasing = 'Should the harbour analytics move off Postgres?'), 'yes');
select claims.propose_answer(pg_temp.note('Ops review, April',
         'Postgres already holds the berth logs and every permission on them; a second store doubles both.'), 'C1', (select id from claims.questions where phrasing = 'Should the harbour analytics move off Postgres?'), 'no');
select claims.propose_answer(pg_temp.note('Agent memory notes',
         'An assistant that dates a fact by when it was stored answers questions about the past wrongly.'), 'C1', (select id from claims.questions where phrasing = 'Should an agent''s memory record when each fact became true?'), 'yes');
select claims.propose_answer(pg_temp.note('Clinical transfer study',
         'A triage method validated in one hospital lost a third of its accuracy in two others.'), 'C1', (select id from claims.questions where phrasing = 'Is a method validated at one clinic valid at another hospital?'), 'no');
