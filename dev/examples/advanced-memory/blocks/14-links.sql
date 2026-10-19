select f.content as fact, q.phrasing as question, q.status, round(q.p::numeric, 2) as p
  from claims.fact_texts f, claims.questions_of_fact(f.id) q
 order by q.p desc;

select f.content as fact, f.status, round(f.p::numeric, 2) as p
  from claims.questions qs, claims.facts_on_question(qs.id) f
 where qs.phrasing = 'Should the harbour analytics move off Postgres?';
