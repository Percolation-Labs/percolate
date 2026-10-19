select relation, key from jsonb_to_recordset(aiq.query($q$GRAPH "Priya Raman" AS OF '2026-02-01'$q$) -> 'rows')
    as r(relation text, key text) order by relation, key;
select relation, key from jsonb_to_recordset(aiq.query($q$GRAPH "Priya Raman" AS OF '2026-05-01'$q$) -> 'rows')
    as r(relation text, key text) order by relation, key;
