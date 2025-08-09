#!/bin/bash
# Simple script to launch Jupyter Notebook with database connection

# Export environment variables
export P8_PG_HOST=localhost P8_PG_PORT=25432 P8_PG_DATABASE=app P8_PG_USER=postgres P8_PG_PASSWORD="${P8_TEST_BEARER_TOKEN:-postgres}"

# Start port forwarding in background (silent)
kubectl port-forward -n p8 service/percolate-rw 25432:5432 >/dev/null 2>&1 &
PF_PID=$!

# Give it a moment
sleep 2

# Launch Jupyter Notebook
poetry run jupyter notebook

# Kill port-forward when done
kill $PF_PID 2>/dev/null