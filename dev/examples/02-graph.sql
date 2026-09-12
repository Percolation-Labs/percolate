-- 2. Who ultimately runs this ship, and what else was in the same port?
--
-- One walk answers both. DEPTH 2 from a vessel crosses two different relations
-- and three entity types, and path_weight carries how well corroborated the
-- route is -- the subsidiary claim is 0.95, not 1.0, because it came from a
-- registry rather than a filing.
set local role authenticated;
set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000001","orgs":["d0000000-0000-0000-0000-00000000000a"]}';

select r->>'depth' as depth, r->>'entity_type' as type, r->>'summary' as summary,
       r->>'path_relations' as path, round((r->>'path_weight')::numeric,2) as weight
from jsonb_array_elements(aiq.query('GRAPH "Bulk Harmony" DEPTH 2')->'rows') r;

\echo '-- narrowed to one relation, the ownership chain alone:'
select r->>'depth' as depth, r->>'summary' as summary
from jsonb_array_elements(aiq.query('GRAPH "MERB" DEPTH 2 TYPE subsidiary_of')->'rows') r;
