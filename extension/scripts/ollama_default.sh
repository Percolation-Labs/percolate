#!/bin/sh
set -e

# Pull the BGE model
ollama pull bge-m3

# Execute the original entrypoint
exec "$@"