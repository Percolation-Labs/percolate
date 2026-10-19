select evidence ->> 'label' as name, status, decided_by, tier, reason
  from aiq.judgements order by status desc, name;

select relation, key from jsonb_to_recordset(aiq.query('GRAPH "Priya Raman" DEPTH 1') -> 'rows')
    as r(relation text, key text) order by relation, key;
