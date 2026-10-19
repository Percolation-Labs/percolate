select claims.withdraw_answer(r.evidence, r.claim_key, r.question_id)
  from claims.answered r join claims.questions q on q.id = r.question_id
 where q.phrasing = 'Should the harbour analytics move off Postgres?' and r.stance = 'no';

select c.stance_then, c.stance_now, c.change
  from claims.questions q, claims.stance_changes(q.id, :'before_withdrawal', now()) c
 where q.phrasing = 'Should the harbour analytics move off Postgres?';
