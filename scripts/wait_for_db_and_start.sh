#!/bin/bash
# Wait for database to be ready and have the API key before starting the API

echo "Waiting for PostgreSQL to be ready..."
until PGPASSWORD=$P8_PG_PASSWORD psql -h $P8_PG_HOST -p $P8_PG_PORT -U $P8_PG_USER -d $P8_PG_DATABASE -c '\q' 2>/dev/null; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 2
done

echo "PostgreSQL is up - checking for P8_API_KEY in Settings..."
while true; do
  API_KEY=$(PGPASSWORD=$P8_PG_PASSWORD psql -h $P8_PG_HOST -p $P8_PG_PORT -U $P8_PG_USER -d $P8_PG_DATABASE -t -c "SELECT value FROM p8.\"Settings\" WHERE key = 'P8_API_KEY' LIMIT 1" 2>/dev/null | tr -d ' \n')
  
  if [ ! -z "$API_KEY" ]; then
    echo "Found API key: ${API_KEY:0:8}..."
    break
  fi
  
  echo "API key not found yet - sleeping"
  sleep 2
done

echo "Database is ready with API key - starting uvicorn..."
exec uvicorn percolate.api.main:app --host 0.0.0.0 --port 5008