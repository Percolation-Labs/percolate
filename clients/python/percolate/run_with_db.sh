#!/bin/bash

# Kill any existing port-forward on port 25432
lsof -ti:25432 | xargs kill -9 2>/dev/null || true

# Start port forwarding in the background
kubectl port-forward -n p8 service/percolate-rw 25432:5432 &
PORT_FORWARD_PID=$!

# Give it a moment to establish connection
sleep 3

# Export PostgreSQL environment variables
export P8_PG_HOST="localhost"
export P8_PG_PORT="25432"
export P8_PG_DATABASE="app"
export P8_PG_USER="postgres"
export P8_PG_PASSWORD="$P8_TEST_BEARER_TOKEN"

echo "Port forwarding established (PID: $PORT_FORWARD_PID)"

# Run the command passed as argument
poetry run python "$@"

# Kill the port forward
kill $PORT_FORWARD_PID 2>/dev/null || true

echo "Done."