mkdir zep-tour && cd zep-tour
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/v0.2.38/compose/docker-compose.yml \
  -o docker-compose.yml
cat > .env <<ENV
COMPOSE_PROJECT_NAME=zep-tour
P8_PG_PORT=5434
P8_REST_PORT=3002
P8_AGENT_PORT=8280
P8_CONTENT_PORT=8281
P8_MINIO_PORT=9200
P8_MINIO_CONSOLE_PORT=9201
P8_QUERY_MCP_PORT=8290
OPENAI_API_KEY=$OPENAI_API_KEY
ENV
docker compose up -d --wait
python3 -m venv .venv && . .venv/bin/activate && pip install -q 'percolate-core==0.2.18'

set -a; . ./.env; set +a
export PAGER=cat P8_DSN=postgres://p8:p8@localhost:$P8_PG_PORT/percolate
export P8_JWT_SECRET=$(docker compose exec -T agent printenv P8_JWT_SECRET)
REST=http://localhost:$P8_REST_PORT AGENT=http://localhost:$P8_AGENT_PORT
psql "$P8_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')"
export TOKEN=$(percolate auth token --email me@example.com)
