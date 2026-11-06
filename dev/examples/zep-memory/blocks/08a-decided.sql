select evidence ->> 'label' as label, evidence ->> 'claimed_kind' as kind, status, verdict ->> 'decision' as verdict,
       tier, decided_by = 'agent:' || (select id from rbac.users where email = 'ana@example.com') as by_her_agent, reason
  from aiq.judgements
 order by decided_at nulls last, evidence ->> 'label';
