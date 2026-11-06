-- A WITHDRAWN FACT ENDS ON THE RECORD CLOCK (REM-1314).
--
-- aiq.retract_derived withdraws what one agent alone said. A withdrawal is not a fact ending: the store stops
-- believing the fact ever held. So as the store knew things before the withdrawal the fact reads as held, and as it
-- knows them from the withdrawal on it never held, at any valid time. An ended fact (aiq.close_edge) is the
-- control: it held until it ended, and a read of a date inside its interval still shows it.
--
-- On 0.2.38 the withdrawal set valid_to to now() and nothing else, so a read of May, known after the withdrawal,
-- still showed the fact (the Zep tutorial's road preference, withdrawn on 6 November, read as held from March).
-- WHAT WOULD MAKE IT FAIL: drop the `withdrawn` record retract_derived writes, or read aiq.edge_periods_recorded
-- where aiq.edge_periods is read, and the "known now" assertions raise.

\set ON_ERROR_STOP on

begin;

do $$
declare
    org   uuid := (select id from rbac.orgs order by id limit 1);
    k0    timestamptz := now() - interval '2 hours';   -- when the facts were recorded
    kb    timestamptz := now() - interval '1 hour';    -- a time after recording, before the withdrawal
    may   timestamptz := '2026-05-01T00:00:00Z';
    ana uuid; road uuid; rail uuid; sea uuid;
    e_road uuid; e_rail uuid; e_sea uuid;
    r jsonb; got text[];
begin
    insert into aiq.relation_types (src_type, relation, dst_type, description)
    values ('q70_fact', 'q70_prefers', 'q70_fact', 'query/70 fixture') on conflict do nothing;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q70_fact', gen_random_uuid(), org, 'public', 'Ana') returning id into ana;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q70_fact', gen_random_uuid(), org, 'public', 'road') returning id into road;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q70_fact', gen_random_uuid(), org, 'public', 'rail') returning id into rail;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    values ('q70_fact', gen_random_uuid(), org, 'public', 'sea') returning id into sea;

    -- road: a misreading, said by q70-reader alone, held from March.
    insert into aiq.edges (src_id, dst_id, relation, org_id, valid_from, created_at, provenance)
    values (ana, road, 'q70_prefers', org, '2026-03-09T16:00:00Z', k0,
            '{"sources": [{"agent": "q70-reader", "run_id": "r1"}]}') returning id into e_road;
    -- sea: said by another reader, held from January, and ENDED in June (the control).
    insert into aiq.edges (src_id, dst_id, relation, org_id, valid_from, created_at, provenance)
    values (ana, sea, 'q70_prefers', org, '2026-01-14T09:30:00Z', k0,
            '{"sources": [{"agent": "q70-other", "run_id": "r1"}]}') returning id into e_sea;
    perform aiq.close_edge(jsonb_build_object('edge_id', e_sea), '2026-06-01T00:00:00Z');
    update aiq.edges set provenance = jsonb_set(provenance, '{closed,at}', to_jsonb(k0)) where id = e_sea;
    -- rail: said by a derivation that withdraws and re-derives at one instant, so it held throughout.
    insert into aiq.edges (src_id, dst_id, relation, org_id, valid_from, created_at, provenance)
    values (ana, rail, 'q70_prefers', org, '2026-03-09T16:00:00Z', k0,
            '{"agent": "q70-rederive"}') returning id into e_rail;

    r := aiq.retract_derived('q70-reader');
    if (r->>'retracted')::int <> 1 then raise exception 'retract_derived(q70-reader) retracted %, not 1', r; end if;
    perform aiq.retract_derived('q70-rederive');
    update aiq.edges set valid_to = null where id = e_rail;   -- the derivation's own insert revives it, same now()

    -- 1. As of May, as known before the withdrawal: road was believed then.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of(may, kb) e join aiq.nodes n on n.id = e.dst_id where e.src_id = ana;
    if got is distinct from array['rail', 'road', 'sea'] then
        raise exception 'as of May, known before the withdrawal: % (want rail, road, sea)', got;
    end if;
    -- 2. As of May, as known now: road never held. sea did, until June.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of(may, now()) e join aiq.nodes n on n.id = e.dst_id where e.src_id = ana;
    if got is distinct from array['rail', 'sea'] then
        raise exception 'as of May, known now: % (want rail, sea) -- the withdrawn fact still reads as held '
            'from when it was said (REM-1314)', got;
    end if;
    -- 3. Now, as known before the withdrawal: road was current then; sea had ended.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of(now(), kb) e join aiq.nodes n on n.id = e.dst_id where e.src_id = ana;
    if got is distinct from array['rail', 'road'] then
        raise exception 'now, known before the withdrawal: % (want rail, road)', got;
    end if;
    -- 4. Now, as known now: only rail.
    select array_agg(n.summary order by n.summary) into got
      from aiq.edges_as_of(now(), now()) e join aiq.nodes n on n.id = e.dst_id where e.src_id = ana;
    if got is distinct from array['rail'] then
        raise exception 'now, known now: % (want rail)', got;
    end if;

    -- 5. GRAPH ... AS OF reads the periods as known now, through graph_neighbors.
    select array_agg(g.summary order by g.summary) into got
      from aiq.graph_neighbors(ana, 'q70_prefers', 100, may) g where g.direction = 'out';
    if got is distinct from array['rail', 'sea'] then
        raise exception 'graph_neighbors as of May: % (want rail, sea)', got;
    end if;

    -- 6. The withdrawal is on record: who, when, and the end it replaced.
    if not exists (select 1 from aiq.edges e
                    where e.id = e_road and e.provenance->'withdrawn'->>'agent' = 'q70-reader'
                      and (e.provenance->'withdrawn'->>'at')::timestamptz = now() and e.valid_to = now()
                      and not e.provenance->'withdrawn' ? 'valid_to') then
        raise exception 'the withdrawal is not recorded on the road edge: %',
            (select provenance->'withdrawn' from aiq.edges where id = e_road);
    end if;
    if (select count(*) from aiq.edge_periods_recorded where edge_id = e_road and withdrawn_at = now()) <> 1
       or exists (select 1 from aiq.edge_periods where edge_id = e_road) then
        raise exception 'edge_periods_recorded should hold the withdrawn period and edge_periods should not';
    end if;
    raise notice 'query/70: a withdrawn fact reads as held only as known before the withdrawal';
end $$;

rollback;
