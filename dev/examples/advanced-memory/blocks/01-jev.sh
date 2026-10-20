cat >> .env <<'ENV'
P8_CREDENTIAL_ORIGINS={"LLM_API_KEY":["https://api.openai.com"],"JEV_API_KEY":["https://api.typesafe.ai"]}
ENV
echo 'JEV_API_KEY=your-jev-key' >> worker.env
docker compose up -d worker
P8_QUERY_MCP_PORT=$(sed -n 's/^P8_QUERY_MCP_PORT=//p' .env); export P8_QUERY_MCP_PORT
