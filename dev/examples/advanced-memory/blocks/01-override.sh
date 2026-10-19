cat >> .env <<'ENV'
JEV_API_KEY=your-jev-key
P8_CREDENTIAL_ORIGINS={"LLM_API_KEY":["https://api.openai.com"],"JEV_API_KEY":["https://api.typesafe.ai"]}
P8_QUERY_MCP_PORT=8090
ENV
cat > docker-compose.override.yml <<'YML'
services:
  query-mcp:
    ports: ["${P8_QUERY_MCP_PORT}:8090"]
  worker:
    environment:
      JEV_API_KEY: ${JEV_API_KEY}
      P8_CREDENTIAL_ORIGINS: ${P8_CREDENTIAL_ORIGINS}
YML
docker compose up -d query-mcp worker
