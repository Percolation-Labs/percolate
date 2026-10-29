-- Durability, on your own stack: a LIVE walk on the holiday question, so Jev judges every lead and the walk takes
-- minutes, long enough to stop its workers mid-wave. Not part of run.sh, because it needs a Jev key:
--   worker.env (beside docker-compose.yml):  JEV_API_KEY=<your key>
--   .env:  P8_CREDENTIAL_ORIGINS={"LLM_API_KEY":["https://api.openai.com"],"JEV_API_KEY":["https://api.typesafe.ai"]}
--   then:  docker compose up -d worker
-- The start is step 1's without replay and offline, on this release's defaults (walk.memory 0). About a cent of Jev.
--   psql "$P8_DSN" -f durability/start-live.sql
\set q 'How did my focus on different aspects of the holiday celebration evolve throughout our conversations in order? Mention ONLY and ONLY seven items.'
select workflow.start_workflow('walk', jsonb_build_object(
 'question', jsonb_build_object('node_id', n.id, 'text', r.title), 'channel', 'beam-1m35')) as run
 from content.resources r
 join content.channels c on c.id = r.channel_id and c.name = 'walk-questions'
 join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
 where r.title = :'q' \gset
\echo run :run
