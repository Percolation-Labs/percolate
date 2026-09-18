-- A revision's claims, sources, citations and argument edges (REM-152, specs/tables/schema.md §3): they
-- project atomically, a duplicate or dangling reference rolls the whole write back, all six 0.1 relations and
-- an uncited source survive, a rebuild restores what is missing without rewriting the revision, and search
-- over them returns only what the caller may read, with no client write on aiq.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000152a1', 'proj-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000152b2', 'proj-stranger@example.test', 'active');


-- 1. The owner: every malformed package or revision is refused whole, and a good one round-trips.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000152a1"}';
set local role authenticated;
do $$
declare
    good jsonb := '{"schema_version": "0.1", "title": "A zephyrine projection test", "visibility": "private",
        "claims": [{"id": "C1", "kind": "Source assertion", "text": "The zephyrine assertion is made in the source.", "source_ids": ["S1"]},
                   {"id": "C2", "kind": "Inference", "text": "A second claim follows.", "source_ids": ["S2"]},
                   {"id": "C3", "kind": "Inference", "text": "A third claim compares them.", "source_ids": ["S2"]}],
        "sources": [{"id": "S1", "title": "A marmalade report", "url": "https://example.com/1", "origin": "Report"},
                    {"id": "S2", "title": "A second source", "url": "https://example.com/2", "origin": "Report"},
                    {"id": "S3", "title": "Read but never cited", "url": "", "origin": "Notes"}],
        "edges": [{"source": "C1", "relation": "supports", "target": "C2"},
                  {"source": "C1", "relation": "challenges", "target": "C3"},
                  {"source": "C2", "relation": "motivates", "target": "C3"},
                  {"source": "C3", "relation": "qualifies", "target": "C1"},
                  {"source": "C2", "relation": "limits", "target": "C1"},
                  {"source": "C1", "relation": "compares with", "target": "C3"}]}';
    bad record;
    r   jsonb;
    rev uuid;
    t   jsonb;
begin
    for bad in select * from (values
        ('duplicate claim id',     good || '{"claims": [{"id": "C1", "text": "one"}, {"id": "C1", "text": "two"}], "edges": []}', '23505'),
        ('duplicate source id',    good || '{"sources": [{"id": "S1", "title": "a"}, {"id": "S1", "title": "b"}, {"id": "S2", "title": "c"}], "edges": []}', '23505'),
        ('citation to no source',  good || '{"claims": [{"id": "C1", "text": "one", "source_ids": ["S9"]}], "edges": []}', '23503'),
        ('edge to no claim',       good || '{"edges": [{"source": "C1", "relation": "supports", "target": "C9"}]}', '23503'),
        ('an unknown relation',    good || '{"edges": [{"source": "C1", "relation": "depends on", "target": "C2"}]}', '23514'),
        ('a claim with no id',     good || '{"claims": [{"text": "no id"}], "edges": []}', '23514'),
        ('a duplicate edge',       good || '{"edges": [{"source": "C1", "relation": "supports", "target": "C2"}, {"source": "C1", "relation": "supports", "target": "C2"}]}', '23505'),
        ('a source cited twice',   good || '{"claims": [{"id": "C1", "text": "one", "source_ids": ["S1", "S1"]}], "edges": []}', '23505')
    ) v(what, doc, code) loop
        begin
            perform research.submit_package(bad.doc, null, 'rp-proj-bad');
            raise exception 'a package with % was accepted', bad.what;
        exception when others then
            if sqlstate <> bad.code then
                raise exception 'a package with % raised % (%), not %', bad.what, sqlstate, sqlerrm, bad.code;
            end if;
        end;
        assert not exists (select 1 from research.works where public_id = 'rp-proj-bad'),
            'nothing of a refused package survives: ' || bad.what;
    end loop;

    r := research.submit_package(good, null, 'rp-proj-good');
    rev := (r->>'revision_id')::uuid;
    begin
        perform research.revise_package('rp-proj-good', good || '{"edges": [{"source": "C1", "relation": "supports", "target": "C9"}]}', 'draft-1');
        raise exception 'a revision with a dangling edge was accepted';
    exception when foreign_key_violation then null;
    end;
    assert research.get_package('rp-proj-good')->>'revision' = 'draft-1', 'a refused revision leaves the head where it was';
    assert (select count(*) from research.revisions v join research.works w on w.id = v.work_id where w.public_id = 'rp-proj-good') = 1,
        'and adds no revision row';

    assert (select array_agg(claim_key order by claim_key) from research.claims where revision_id = rev) = '{C1,C2,C3}', 'every claim';
    assert (select array_agg(source_key order by source_key) from research.sources where revision_id = rev) = '{S1,S2,S3}',
        'every source, the uncited one included';
    assert (select array_agg(claim_key || '->' || source_key order by claim_key, source_key) from research.citations where revision_id = rev)
         = '{C1->S1,C2->S2,C3->S2}', 'every citation, as written';
    assert (select array_agg(relation order by relation) from research.argument_edges where revision_id = rev)
         = '{challenges,"compares with",limits,motivates,qualifies,supports}', 'all six relations, as written';
    assert (select count(*) from research.argument_edges where revision_id = rev and source_claim_key = 'C3' and target_claim_key = 'C1') = 1,
        'direction is kept as supplied';
    t := research.trust(rev);
    assert (select (s->>'cited_by')::int from jsonb_array_elements(t->'sources') s where s->>'id' = 'S3') = 0,
        'the trust read shows the uncited source';
    assert position('search_tsv' in t::text) = 0, 'the search column never reaches a read';

    -- Search, as the owner.
    assert exists (select 1 from aiq.lexical('research_claims', 'zephyrine', 10)), 'the owner finds their own private claim';
    assert exists (select 1 from aiq.lexical('research_sources', 'marmalade', 10)), 'and their own private source';
    assert not has_table_privilege('authenticated', 'aiq.nodes', 'insert')
       and not has_table_privilege('authenticated', 'aiq.node_keys', 'insert'), 'with no write on aiq';
    assert not has_function_privilege('authenticated', 'research.rebuild_projection(uuid)', 'execute'),
        'a caller cannot rebuild a projection';
end $$;
reset role;


-- 2. Somebody else: search returns nothing of the owner's private work.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000152b2"}';
set local role authenticated;
do $$
begin
    assert not exists (select 1 from aiq.lexical('research_claims', 'zephyrine', 10)), 'a stranger''s search finds no private claim';
    assert not exists (select 1 from aiq.lexical('research_sources', 'marmalade', 10)), 'nor a private source';
end $$;
reset role;


-- 3. As the operator: a rebuild restores what is missing with the same ids, never rewrites the revision, and
--    refuses a projection holding a row its document does not say.
do $$
declare
    rev       uuid := (select h.revision_id from research.heads h join research.works w on w.id = h.work_id where w.public_id = 'rp-proj-good');
    ids       uuid[];
    doc_hash  text;
    counts    jsonb;
begin
    select array_agg(id order by claim_key) into ids from research.claims where revision_id = rev;
    select content_hash || md5(document::text) into doc_hash from research.revisions where id = rev;

    -- Losing projected rows takes an operator switching the history guard off (REM-464): nothing else can.
    alter table research.citations disable trigger trg_refuse_rewrite;
    alter table research.argument_edges disable trigger trg_refuse_rewrite;
    alter table research.claims disable trigger trg_refuse_rewrite;
    alter table claims.expresses disable trigger trg_refuse_rewrite;   -- a claim's link goes with its occurrence (REM-473)
    delete from research.citations where revision_id = rev and claim_key = 'C3';
    delete from research.argument_edges where revision_id = rev and relation = 'limits';
    delete from research.claims where revision_id = rev and claim_key = 'C2';   -- takes its citations and edges with it
    alter table research.citations enable trigger trg_refuse_rewrite;
    alter table research.argument_edges enable trigger trg_refuse_rewrite;
    alter table research.claims enable trigger trg_refuse_rewrite;
    alter table claims.expresses enable trigger trg_refuse_rewrite;

    counts := research.rebuild_projection(rev);
    assert counts = '{"claims": 3, "sources": 3, "citations": 3, "edges": 6}', 'the rebuild restores everything: ' || counts;
    assert (select array_agg(id order by claim_key) from research.claims where revision_id = rev) = ids, 'with the ids it had';
    assert (select content_hash || md5(document::text) from research.revisions where id = rev) = doc_hash, 'and the revision untouched';
    assert research.rebuild_projection(rev) = counts, 'a second rebuild changes nothing';

    begin
        insert into research.claims (id, revision_id, claim_key, kind, text) values (gen_random_uuid(), rev, 'C99', 'Inference', 'Not in the document');
        perform research.rebuild_projection(rev);
        raise exception 'a projection with a row its document does not say was rebuilt silently';
    exception when data_corrupted then null;
    end;
end $$;

rollback;
