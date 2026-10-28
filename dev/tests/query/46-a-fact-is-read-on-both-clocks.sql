-- A FACT IS READ ON BOTH CLOCKS (REM-1234).
--
-- aiq.edges_as_of(valid_at, known_at) is the edges that, as the store knew things at known_at, held at valid_at:
-- recorded by then (created_at), begun by valid_at, and not ended by valid_at unless that end had been recorded by
-- known_at (aiq.close_edge's closed.at). It replaces the record-time SQL the walkthrough's two-clocks step built by
-- hand from created_at and the close's provenance.
--
-- A budget that changed: two answers of $150 said at 00:11:11 and 00:11:15 and recorded at the first landing (k1),
-- the raise to $160 said at 00:11:28 and recorded at the second landing (k2), when the two $150 answers are closed at
-- 00:11:28. Read at both clocks, the store answers $150 for 00:11:20 whatever it knew, $160 for now once it knew of
-- the raise, $150 for now as it knew things after the first landing, and nothing before anything was recorded.
-- On main the function does not exist.

\set ON_ERROR_STOP on

begin;

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    k1  timestamptz := now() - interval '2 hours';
    k2  timestamptz := now() - interval '1 hour';
    q   uuid; a uuid; b uuid; c uuid;
    ea  uuid; eb uuid;
    got text[];
begin
    insert into aiq.relation_types (src_type, relation, dst_type, description)
    values ('q46_fact', 'q46_answered_in', 'q46_fact', 'query/46 fixture') on conflict do nothing;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q46_fact', gen_random_uuid(), org, 'public', 'budget?') returning id into q;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q46_fact', gen_random_uuid(), org, 'public', '$150 (00:11:11)') returning id into a;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q46_fact', gen_random_uuid(), org, 'public', '$150 (00:11:15)') returning id into b;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q46_fact', gen_random_uuid(), org, 'public', '$160 (00:11:28)') returning id into c;

    -- The first landing records the two $150 answers; the second records the raise.
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance, valid_from, created_at)
    values (q, a, 'q46_answered_in', org, '{}', '2024-08-12 00:11:11+00', k1) returning id into ea;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance, valid_from, created_at)
    values (q, b, 'q46_answered_in', org, '{}', '2024-08-12 00:11:15+00', k1) returning id into eb;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance, valid_from, created_at)
    values (q, c, 'q46_answered_in', org, '{}', '2024-08-12 00:11:28+00', k2);
    -- The raise ends the two $150 answers at 00:11:28, and the store learns that at the second landing.
    perform aiq.close_edge(jsonb_build_object('edge_id', ea), '2024-08-12 00:11:28+00');
    perform aiq.close_edge(jsonb_build_object('edge_id', eb), '2024-08-12 00:11:28+00');
    update aiq.edges set provenance = jsonb_set(provenance, '{closed,at}', to_jsonb(k2)) where id in (ea, eb);

    -- valid 00:11:20, known now: the two $150 answers.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of('2024-08-12 00:11:20+00', now()) e join aiq.nodes n on n.id = e.dst_id where e.src_id = q;
    if got is distinct from array['$150 (00:11:11)', '$150 (00:11:15)'] then
        raise exception 'at 00:11:20, known now: %', got;
    end if;
    -- valid now, known now: the raise.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of(now(), now()) e join aiq.nodes n on n.id = e.dst_id where e.src_id = q;
    if got is distinct from array['$160 (00:11:28)'] then
        raise exception 'now, known now: %', got;
    end if;
    -- valid now, as known after the first landing: still $150, because the raise and the close were not yet recorded.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of(now(), k1 + interval '1 minute') e join aiq.nodes n on n.id = e.dst_id where e.src_id = q;
    if got is distinct from array['$150 (00:11:11)', '$150 (00:11:15)'] then
        raise exception 'now, known after the first landing: %', got;
    end if;
    -- before anything was recorded: nothing.
    if exists (select 1 from aiq.edges_as_of(now(), k1 - interval '1 minute') e where e.src_id = q) then
        raise exception 'an edge was read before it was recorded';
    end if;
    raise notice 'query/46: a fact is read on both clocks';
end $$;

rollback;
