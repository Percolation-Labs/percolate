insert into team.people (name) values ('Priya Raman') on conflict do nothing;
select jsonb_pretty(aiq.dream() - 'since' - 'until') as receipt;

select relation, key from jsonb_to_recordset(aiq.query('GRAPH "Priya Raman" DEPTH 1') -> 'rows')
    as r(relation text, key text) order by relation, key;
