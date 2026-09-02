-- 3. Three ways to find the same page, and why there are three.
--
-- The corpus is built so they disagree. h1 carries the rare code verbatim;
-- h2 says the same thing in different words and carries none of them.
set local role authenticated;
set local request.jwt.claims = '{"orgs":["d0000000-0000-0000-0000-00000000000a"]}';

\echo '-- TEXT: an exact rare token. No embedding anywhere.'
select round((r->>'score')::numeric,4) as score, left(r->>'content',56) as content
from jsonb_array_elements(aiq.query('TEXT "PSC-441" FROM chunks LIMIT 3')->'rows') r;

\echo '-- SEMANTIC: returns refs, so join to read them. The top hit shares'
\echo '-- no word with the question.'
select round((r->>'distance')::numeric,3) as distance, left(c.content,56) as content
from jsonb_array_elements(aiq.query('SEMANTIC "a boiler fault" FROM chunks LIMIT 3','[0,0,0.707,0.707]')->'rows') r
join content.resource_chunks c on c.id = (r->>'chunk_id')::uuid
order by 1;

\echo '-- SEARCH: both ranks fused, so a page found by only one still places.'
\echo '-- The winner is first on lexical rank and third on semantic.'
select r->>'lexical_rank' as lex, r->>'semantic_rank' as sem,
       round((r->>'rrf_score')::numeric,5) as rrf, left(r->>'content',52) as content
from jsonb_array_elements(aiq.query('SEARCH "PSC-441 boiler" FROM chunks LIMIT 3','[0,0,0.707,0.707]')->'rows') r;

\echo '-- the same SEARCH as Kestrel. The Meridian exposure note is gone.'
set local request.jwt.claims = '{"orgs":["d0000000-0000-0000-0000-00000000000b"]}';
select r->>'lexical_rank' as lex, r->>'semantic_rank' as sem, left(r->>'content',52) as content
from jsonb_array_elements(aiq.query('SEARCH "PSC-441 boiler" FROM chunks LIMIT 2','[0,0,0.707,0.707]')->'rows') r;
