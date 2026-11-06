select evidence ->> 'label' as name, status, verdict ->> 'decision' as verdict, tier,
       decided_by = 'agent:' || (select id from rbac.users where email = 'me@example.com') as by_my_agent
  from aiq.judgements order by status desc, name;

select relation, key from jsonb_to_recordset(aiq.query('GRAPH "Priya Raman" DEPTH 1') -> 'rows')
    as r(relation text, key text) order by relation, key;

select reason from aiq.judgements where evidence ->> 'label' = 'P. Raman';
