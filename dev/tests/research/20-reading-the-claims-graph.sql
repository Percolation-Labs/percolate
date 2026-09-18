-- Reading the claims graph (REM-475, specs/claims/graph.md §9 and §10): a claim with its occurrences and identity set,
-- what it rests on and what challenges it through that as paths, its history, and a claim-level diff between two
-- revisions; and §9's four consequences, each from a stranger's side: counts and paths are taken after the access
-- filter, an identity set never crosses a same_as the caller cannot read, a transaction shows its actor's kind and
-- nothing else, and a claim minted in a private draft is not observable.
--
-- One transaction, rolled back. Every row here shares one now(), so an as-of read is tested only against a time
-- before all of them.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000475a1', 'reads-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000475b2', 'reads-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-reads-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-reads-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000475a1', 'rp-reads-lister');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

-- 1. The owner writes a listed work in two drafts and a private one, and relates them.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000475a1"}';
set local role authenticated;
do $$
declare
    base jsonb := '{"schema_version": "0.1", "sources": [{"id": "S1", "title": "A note", "url": "https://example.com/n", "origin": "Note"}]}';
    l1 uuid; l2 uuid; p uuid;
begin
    l1 := (research.submit_package(base || '{"title": "Listed reads", "visibility": "listed",
        "claims": [{"id": "L1", "kind": "Inference", "text": "Hedges shelter birds.", "source_ids": ["S1"]},
                   {"id": "L2", "kind": "Inference", "text": "Birds nest where it is quiet.", "source_ids": ["S1"]},
                   {"id": "L3", "kind": "Inference", "text": "Hedges are noisy with traffic.", "source_ids": ["S1"]}],
        "edges": [{"source": "L2", "relation": "supports", "target": "L1"},
                  {"source": "L3", "relation": "challenges", "target": "L2"}]}', null, 'rp-reads-listed')->>'revision_id')::uuid;
    l2 := (research.revise_package('rp-reads-listed', base || '{"title": "Listed reads", "visibility": "listed",
        "claims": [{"id": "L1", "kind": "Inference", "text": "Hedges shelter birds.", "source_ids": ["S1"]},
                   {"id": "L2", "kind": "Inference", "text": "Birds nest where it is quiet and dark.", "source_ids": ["S1"]},
                   {"id": "L4", "kind": "Inference", "text": "Hedges hold insects birds eat.", "source_ids": ["S1"]}],
        "edges": [{"source": "L2", "relation": "supports", "target": "L1"},
                  {"source": "L4", "relation": "supports", "target": "L1"}]}', 'draft-1')->>'revision_id')::uuid;
    p := (research.submit_package(base || '{"title": "Private reads", "visibility": "private",
        "claims": [{"id": "P1", "kind": "Inference", "text": "Hedgerows are loud at dawn.", "source_ids": ["S1"]}],
        "edges": []}', null, 'rp-reads-private')->>'revision_id')::uuid;
    -- From the private work, a challenge aimed at the listed claim L2.
    perform claims.assert_relation('P1', 'challenges', 'L2', p, l2);
    insert into ids values ('l1', l1::text), ('l2', l2::text), ('p', p::text);
end $$;
reset role;

-- The claim ids, and a confirmed same_as between L1 and P1 evidenced by the private work, which REM-478's write
-- does not exist to make yet, so it is written here as the tables' owner.
do $$
declare t bigint;
begin
    insert into ids select 'c_' || lower(e.claim_key), e.claim_id::text from claims.expresses e
     where e.revision_id in ((select v::uuid from ids where k = 'l1'), (select v::uuid from ids where k = 'p'));
    insert into ids select 'c_l4', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'l2') and claim_key = 'L4';
    insert into claims.tx (actor_id, actor_kind, revision_id, reason)
    values ('00000000-0000-4000-8000-0000000475a1', 'person', (select v::uuid from ids where k = 'p'), 'a test same_as')
    returning id into t;
    insert into claims.relations (src, predicate, dst, status, evidence, evidence2, keys, tx)
    values ((select v::uuid from ids where k = 'c_p1'), 'same_as', (select v::uuid from ids where k = 'c_l1'), 'confirmed',
            (select v::uuid from ids where k = 'p'), (select v::uuid from ids where k = 'l2'), '{"src": "P1", "dst": "L1"}', t);
    -- And a PROPOSED same_as between L3 and L1, which extends no identity set (graph.md §6).
    insert into claims.relations (src, predicate, dst, status, evidence, evidence2, keys, tx)
    values ((select v::uuid from ids where k = 'c_l3'), 'same_as', (select v::uuid from ids where k = 'c_l1'), 'proposed',
            (select v::uuid from ids where k = 'p'), (select v::uuid from ids where k = 'l1'), '{"src": "L3", "dst": "L1"}', t);
end $$;

-- 2. The owner reads everything.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000475a1"}';
set local role authenticated;
do $$
declare
    c_l1 uuid := (select v::uuid from ids where k = 'c_l1');
    c_l2 uuid := (select v::uuid from ids where k = 'c_l2');
    c_l3 uuid := (select v::uuid from ids where k = 'c_l3');
    c_l4 uuid := (select v::uuid from ids where k = 'c_l4');
    c_p1 uuid := (select v::uuid from ids where k = 'c_p1');
    j jsonb;
begin
    j := claims.claim(c_l1);
    assert jsonb_array_length(j->'occurrences') = 2, 'L1 is expressed in both drafts: ' || j::text;
    assert j->'identity_set' @> to_jsonb(array[c_p1]), 'the owner''s identity set crosses the same_as they can read';
    assert not j->'identity_set' @> to_jsonb(array[c_l3]), 'a proposed same_as extends no identity set';
    assert (select array_agg(distinct claim order by claim) from claims.rests_on(c_l1))
         = (select array_agg(x order by x) from unnest(array[c_l2, c_l4]) x), 'L1 rests on L2 and L4';
    assert (select bool_and(path[1] = c_l1 and path[cardinality(path)] = claim and cardinality(relations) = depth)
              from claims.rests_on(c_l1)), 'each is returned with its path and the relations it walked';
    assert (select array_agg(distinct challenger order by challenger) from claims.challenged_through(c_l1))
         = (select array_agg(x order by x) from unnest(array[c_l3, c_p1]) x),
        'L1 is challenged through L2, by L3 in draft-1 and by the private P1';
    assert not exists (select 1 from claims.relations_at(c_l1) where predicate = 'challenges' and dst = c_l1),
        'and nothing records a challenge to L1 itself: the reading is derived, not asserted';
    assert exists (select 1 from claims.neighbourhood(c_l2, array['challenges'], 1) where src = c_p1),
        'the owner sees the private challenge in L2''s neighbourhood';
    assert claims.claim(c_l1, now() - interval '1 minute') is null, 'nothing is readable as of a time before it was written';
end $$;
reset role;

-- 3. A stranger reads the listed work, and the rules of graph.md §9 hold from their side.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000475b2"}';
set local role authenticated;
do $$
declare
    c_l1 uuid := (select v::uuid from ids where k = 'c_l1');
    c_l2 uuid := (select v::uuid from ids where k = 'c_l2');
    c_l3 uuid := (select v::uuid from ids where k = 'c_l3');
    c_l4 uuid := (select v::uuid from ids where k = 'c_l4');
    c_p1 uuid := (select v::uuid from ids where k = 'c_p1');
    d text[];
    t bigint;
begin
    -- A claim minted in a private draft is not observable.
    assert claims.claim(c_p1) is null, 'a private claim is not observable: ' || coalesce(claims.claim(c_p1)::text, '');
    assert not exists (select 1 from claims.history(c_p1)), 'nor its history';
    -- Counts and paths are taken after the access filter.
    assert (select array_agg(distinct challenger) from claims.challenged_through(c_l1)) = array[c_l3],
        'the stranger sees L3''s challenge and not the private one';
    assert not exists (select 1 from claims.neighbourhood(c_l2) where src = c_p1 or dst = c_p1),
        'no hop leads to the private claim';
    assert not exists (select 1 from claims.history(c_l2) where other = c_p1), 'nor does L2''s history';
    -- An identity set never crosses a same_as the caller cannot read.
    assert claims.claim(c_l1)->'identity_set' = to_jsonb(array[c_l1]), 'the stranger''s identity set is L1 alone';
    -- A transaction shows its actor's kind and nothing else.
    select r.tx into t from claims.relations r where r.dst = c_l1 and r.predicate = 'supports' limit 1;
    assert (select actor_kind from claims.tx where id = t) = 'platform', 'the stranger reads a readable row''s actor kind';
    begin
        perform reason from claims.tx where id = t;
        raise exception 'the stranger read a transaction''s reason';
    exception when insufficient_privilege then null;
    end;
    begin
        perform actor_id from claims.tx where id = t;
        raise exception 'the stranger read a transaction''s actor';
    exception when insufficient_privilege then null;
    end;
    begin
        perform revision_id from claims.tx where id = t;
        raise exception 'the stranger read which revision a transaction came from';
    exception when insufficient_privilege then null;
    end;
    -- The diff between the two listed drafts.
    select array_agg(x order by x) into d from (
      select change || ':' || coalesce(to_key, from_key, '') || ':' || coalesce(status, '')
        from claims.revision_diff((select v::uuid from ids where k = 'l1'), (select v::uuid from ids where k = 'l2'))
       where predicate is null) z(x);
    assert d = '{added:L4:confirmed,carried:L1:confirmed,dropped:L3:,reworded:L2:proposed}', 'the claim changes: ' || d::text;
    assert (select array_agg(change || ':' || predicate order by change) from claims.revision_diff(
                (select v::uuid from ids where k = 'l1'), (select v::uuid from ids where k = 'l2')) where predicate is not null)
         = '{"relation gained:supports","relation lost:challenges"}', 'and the relation changes';
    assert exists (select 1 from claims.revision_diff((select v::uuid from ids where k = 'l1'), (select v::uuid from ids where k = 'l2'))
                    where change = 'relation gained' and claim = c_l4 and other = c_l1), 'L4 supports L1 is the gain';
end $$;

rollback;
