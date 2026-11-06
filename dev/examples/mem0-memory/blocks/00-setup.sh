mkdir mem0-tour && cd mem0-tour
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml \
  -o docker-compose.yml
cat > .env <<ENV
COMPOSE_PROJECT_NAME=mem0-tour
P8_PG_PORT=5433
P8_REST_PORT=3001
P8_AGENT_PORT=8180
P8_CONTENT_PORT=8181
P8_MINIO_PORT=9100
P8_MINIO_CONSOLE_PORT=9101
P8_QUERY_MCP_PORT=8190
OPENAI_API_KEY=$OPENAI_API_KEY
ENV
docker compose up -d --wait
python3 -m venv .venv && . .venv/bin/activate && pip install -q 'percolate-core==0.2.17'

set -a; . ./.env; set +a
export PAGER=cat P8_DSN=postgres://p8:p8@localhost:$P8_PG_PORT/percolate
export P8_JWT_SECRET=change-me-a-long-random-string-at-least-32-chars
REST=http://localhost:$P8_REST_PORT AGENT=http://localhost:$P8_AGENT_PORT
psql "$P8_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')"
export TOKEN=$(percolate auth token --email me@example.com)
