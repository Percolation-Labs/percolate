curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/v0.2.38/compose/docker-compose.yml -o docker-compose.yml
printf 'COMPOSE_PROJECT_NAME=zep-bench\nP8_PG_PORT=47969\nP8_REST_PORT=47970\nP8_AGENT_PORT=47971\nP8_CONTENT_PORT=47972\nP8_MINIO_PORT=47973\nP8_MINIO_CONSOLE_PORT=47974\nP8_QUERY_MCP_PORT=47975\nOPENAI_API_KEY=%s\n' "$OPENAI_API_KEY" > .env
for arm in told dream; do
  docker compose up -d --wait > /dev/null 2>&1
  [ $arm = dream ] && export DREAM=1
  EXTRACT=gpt-4o-mini DSN=postgresql://p8:p8@localhost:47969/percolate env/bin/python -I percolate_run.py fixture.json \
    > percolate-$arm.jsonl 2> percolate-$arm.log
  docker compose down -v > /dev/null 2>&1; unset DREAM
done
docker run -d --name zep-bench-neo4j -e NEO4J_AUTH=neo4j/zep-bench-pass -p 57697:7687 neo4j:5.26 > /dev/null
LLM_MODEL=gpt-4o-mini TOLD=1 NEO4J_URI=bolt://localhost:57697 NEO4J_USER=neo4j NEO4J_PASSWORD=zep-bench-pass \
  env/bin/python -I graphiti_run.py fixture.json > graphiti.jsonl 2> graphiti.log
docker rm -f zep-bench-neo4j > /dev/null
grep -h '^percolate:\|^dream:' percolate-told.jsonl percolate-told.log percolate-dream.jsonl percolate-dream.log
grep -h '^graphiti:' graphiti.jsonl
python3 -I score.py fixture.json graphiti.jsonl percolate-told.jsonl percolate-dream.jsonl \
  | grep -E '^system|graphiti-valid|percolate-valid'
