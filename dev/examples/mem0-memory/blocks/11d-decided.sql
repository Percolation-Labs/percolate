select evidence ->> 'claimed_kind' as kind, status, verdict ->> 'decision' as verdict, tier,
       decided_by = 'agent:' || (select id from rbac.users where email = 'maya@example.com') as by_her_agent, reason
  from aiq.judgements
 where evidence ->> 'key' = 'harbour health'
 order by decided_at nulls last;
