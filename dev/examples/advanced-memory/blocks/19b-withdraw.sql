select claims.withdraw_answer(r.evidence, r.claim_key, r.question_id)
  from claims.answered r join claims.questions q on q.id = r.question_id
 where q.phrasing = 'Should the harbour analytics move off Postgres?' and r.stance = 'no';

select c.stance_then, c.stance_now, c.change
  from claims.questions q, claims.stance_changes(q.id, :'before_withdrawal', now()) c
 where q.phrasing = 'Should the harbour analytics move off Postgres?';

select 'before' as read_at, f.yes, f.no
  from claims.questions q
  join aiq."emb_bge_small_en_v1.5" e on e.chunk_id = q.id
  cross join claims.find_question(e.embedding, 0.1, 1, 'bge-small-en-v1.5', :'before_withdrawal') f
 where q.phrasing = 'Should the harbour analytics move off Postgres?'
union all
select 'now', f.yes, f.no
  from claims.questions q
  join aiq."emb_bge_small_en_v1.5" e on e.chunk_id = q.id
  cross join claims.find_question(e.embedding, 0.1, 1, 'bge-small-en-v1.5', now()) f
 where q.phrasing = 'Should the harbour analytics move off Postgres?';
