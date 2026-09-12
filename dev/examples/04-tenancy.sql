-- 4. Two tenants, one table.
--
-- Nothing here filters by org. Every query is the same query; only the claim
-- changes, and the answers differ because row-level security is doing the
-- work. That is the property worth checking by behaviour rather than by
-- reading the policy: a key that resolves for one tenant and returns nothing
-- for another is indistinguishable from "no such key".
set local role authenticated;

set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000001","orgs":["d0000000-0000-0000-0000-00000000000a"]}';
\echo '-- Meridian sees its own fleet, and the shared charterer:'
select entity_type, summary from aiq.nodes
where entity_type in ('vessel','operator') order by entity_type, summary;

set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000002","orgs":["d0000000-0000-0000-0000-00000000000b"]}';
\echo '-- Kestrel, same query, different answer:'
select entity_type, summary from aiq.nodes
where entity_type in ('vessel','operator') order by entity_type, summary;

\echo '-- and Kestrel cannot resolve a Meridian vessel by name at all:'
select count(*) as rows_returned from aiq.lookup('Meridian Dawn');

\echo '-- shared reference data is visible to both. Rotterdam is not a loophole:'
select count(*) as ports_visible from aiq.nodes where entity_type = 'port';

set local request.jwt.claims = '{"orgs":[]}';
\echo '-- a caller with no org claim sees only the shared tier:'
select entity_type, count(*) from aiq.nodes
where entity_type in ('vessel','operator','port') group by 1 order by 1;
