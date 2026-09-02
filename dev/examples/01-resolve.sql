-- 1. Resolve a name somebody half-remembered.
--
-- The question an agent asks first and almost never asks with the right
-- spelling. LOOKUP searches KEYS, so it answers from the node registry rather
-- than from any of the four typed tables the keys came from.
set local role authenticated;
set local request.jwt.claims = '{"orgs":["d0000000-0000-0000-0000-00000000000a"]}';

\echo '-- exact, and it misses:'
select coalesce(jsonb_array_length(aiq.query('LOOKUP "meridien dawn"')->'rows'),0) as rows_returned;

\echo '-- FUZZY, and the misspelling resolves -- with the operator behind it:'
select r->>'key' as key, r->>'entity_type' as entity_type,
       round((r->>'score')::numeric,3) as score, r->>'match_kind' as match_kind
from jsonb_array_elements(aiq.query('FUZZY LOOKUP "meridien dawn" LIMIT 3')->'rows') r;

\echo '-- a short key registered by hand resolves exactly, no fuzz needed:'
select r->>'key' as key, r->>'entity_type' as entity_type, r->>'match_kind' as match_kind
from jsonb_array_elements(aiq.query('LOOKUP "dawn"')->'rows') r;
