-- A HEADING STATES NOTHING, AND A NUMBER IS NOT A NAME.
--
-- aiq.use_edges keeps a candidate only where one sentence names both ends. A QASPER paragraph opens with its paper
-- title and section heading, then a blank line, with no full stop between: split only at . ! ? the heading was glued
-- onto the first sentence, so a pair named once in the heading and once in the body read as stated (2,103 of the
-- 3,906 edges on three QASPER misses). A sentence now also ends at a blank line, and a heading block (one line, no
-- closing punctuation, more text after it) is not a sentence.
--   ue/3 names Mediator only in its heading and Savings Account in its body: no edge.
--   ue/4 has a heading too, and its body names both in one sentence: an edge, carrying the body's sentence alone.
--   ue/5 is one line with no closing stop and no blank line: it is its own last block, not a heading, so an edge.
-- And a term with no letter is not a name: ue/1 says "27", which once made '27' an end, so ue/6 ("In 27 runs the
-- Savings Account expert failed.") was proposed. Now it is not. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table fu(n int, said text, terms text[]);
insert into fu values
 (1, E'Results | Evaluation\n\nIn 27 trials the Mediator answered every question.', '{mediator,27}'),
 (2, 'Savings Account options are listed.', '{savings account}'),
 (3, E'A Hybrid Architecture for Multi-Party Conversational Systems | Mediator\n\nThe Savings Account expert answers simulation questions.',
     '{mediator,savings account}'),
 (4, E'A Hybrid Architecture for Multi-Party Conversational Systems | Results\n\nThe Mediator calls the Savings Account expert. It answers.',
     '{mediator,savings account}'),
 (5, 'The Mediator and the Savings Account expert', '{mediator,savings account}'),
 (6, 'In 27 runs the Savings Account expert failed.', '{27,savings account}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'use_doc', gen_random_uuid(), org, 'public', said from fu;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select n.id, 'use_doc', 'ue/' || fu.n, 'canonical', org
      from fu join aiq.nodes n on n.entity_type = 'use_doc' and n.summary = fu.said;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'use_tag', gen_random_uuid(), org, 'public', t from fu, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('use_doc', 'walk_tagged', 'use_tag', 'query/65 fixture'),
        ('use_doc', 'walk_next', 'use_doc', 'query/65 fixture'),
        ('use_doc', 'walk_nearest', 'use_doc', 'query/65 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select d.id, tg.id, 'walk_tagged', org, '{}'
      from fu join aiq.nodes d on d.entity_type = 'use_doc' and d.summary = fu.said
      cross join unnest(fu.terms) t
      join aiq.nodes tg on tg.entity_type = 'use_tag' and tg.summary = t;
end $$;

do $$
declare
    inp jsonb := jsonb_build_object('nodes', 'use_doc', 'prefix', 'ue/');
    got text;
begin
    select string_agg(target || '|' || a || '|' || b || '|' || sentence, ' ;; ' order by rank) into got
      from aiq.use_edges(inp, 'Which expert does the system call?', array['ue/1', 'ue/2'], 'ue/1', 10);
    if got is distinct from 'ue/4|savings account|mediator|The Mediator calls the Savings Account expert.'
                            || ' ;; ue/5|savings account|mediator|The Mediator and the Savings Account expert' then
        raise exception 'use_edges proposed %', got;
    end if;
    raise notice 'query/65: a heading states nothing, and a number is not a name';
end $$;

rollback;
