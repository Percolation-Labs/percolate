cat >> .env <<'ENV'
JEV_API_KEY=your-jev-key
P8_CREDENTIAL_ORIGINS={"LLM_API_KEY":["https://api.openai.com"],"JEV_API_KEY":["https://api.typesafe.ai"]}
ENV
cat > docker-compose.override.yml <<'YML'
services:
  worker:
    environment:
      JEV_API_KEY: ${JEV_API_KEY}
      P8_CREDENTIAL_ORIGINS: ${P8_CREDENTIAL_ORIGINS}
YML
docker compose up -d worker
