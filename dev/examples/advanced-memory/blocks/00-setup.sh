mkdir advanced-tour && cd advanced-tour
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/v0.2.38/compose/docker-compose.yml \
  -o docker-compose.yml
cat > .env <<ENV
COMPOSE_PROJECT_NAME=advanced-tour
P8_PG_PORT=5435
P8_REST_PORT=3003
P8_AGENT_PORT=8380
P8_CONTENT_PORT=8381
P8_MINIO_PORT=9300
P8_MINIO_CONSOLE_PORT=9301
P8_QUERY_MCP_PORT=8390
ENV
docker compose up -d --wait
python3 -m venv .venv && . .venv/bin/activate && pip install -q 'percolate-core==0.2.18'

set -a; . ./.env; set +a
export PAGER=cat P8_DSN=postgres://p8:p8@localhost:$P8_PG_PORT/percolate
export P8_JWT_SECRET=$(docker compose exec -T agent printenv P8_JWT_SECRET)
REST=http://localhost:$P8_REST_PORT
psql "$P8_DSN" -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')"
export TOKEN=$(percolate auth token --email me@example.com --ttl 28800)

start() {
  r=$(curl -s $REST/rpc/start_workflow -H 'Content-Profile: workflow' -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' -d "{\"p_name\": \"$1\", \"p_input\": $2}" | jq -r .)
  case $r in
    ????????-????-????-????-????????????) echo "$r" ;;
    *) echo "start $1 failed: $r" >&2; return 1 ;;
  esac
}
show() {
  for i in $(seq 150); do
    [ "$(psql "$P8_DSN" -Atc "select status from workflow.runs where id = '$1'")" != running ] && break
    sleep 2
  done
  psql "$P8_DSN" -c "select step_key, status, left(output->>'result', 60) as result
                       from workflow.tasks where run_id = '$1' and matrix_parent_id is null
                      order by completed_at nulls last, step_key"
}
settle() {
  for r in $(psql "$P8_DSN" -Atc "select r.id from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
                                  where d.name = '$1'"); do
    show $r > /dev/null
  done
}
