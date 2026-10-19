select aiq.promote_soft_node(
         (select id from aiq.soft_nodes where key = 'p. raman'),
         (select node_id from aiq.lookup('Priya Raman')),
         'harbour-lead', 'human',
         '{"why": "P. Raman is Priya: same team list, same project, same week"}') ->> 'moved' as moved;
select aiq.promote_soft_node(
         (select id from aiq.soft_nodes where key = 'harbour health' and claimed_kind = 'organization'),
         (select n.id from aiq.nodes n join aiq.soft_nodes s on n.entity_type = 'soft' and n.entity_id = s.id
           where s.key = 'harbour health' and s.claimed_kind = 'company'),
         'harbour-lead', 'human', '{"why": "one company, typed two ways by two extractors"}') ->> 'merged' as merged;
select aiq.retract_derived('knit-bad') ->> 'retracted' as retracted;
