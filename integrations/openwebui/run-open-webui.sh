#!/bin/bash

# Load base URL and API key from environment - by default the dev api at 5009 could be used if you want to test this in development
# chmod +x run-open-webui.sh
# for example you can see your parameters in your profile
# export P8_API_KEY="YOUR-KEY"
# export P8_API_URL="your-project.percolationlabs.ai"
#source ~/.bash_profile

#commands to stop or purge or check logs for docker
#docker rm -f open-webui
#docker volume rm open-webui
#docker logs -f open-webui

export OPENAI_API_BASE_URL=${P8_API_URL:-http://host.docker.internal:5009}
export OPENAI_API_KEY=${P8_API_KEY}

docker run -d \
  -p 3000:8080 \
  -v open-webui:/app/backend/data \
  -e WEBUI_AUTH=false \
  -e OLLAMA_ENABLED=false \
  -e OPENAI_API_BASE_URL="$OPENAI_API_BASE_URL" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e DEFAULT_MODEL=gpt-40-mini \
  -e ENABLE_MODEL_SELECTOR=true \
  --name open-webui \
  ghcr.io/open-webui/open-webui:main


#open on localhost:3000 
# - > it make take a moment to startup the first time so dont worry if nothing appears at first and check the logs in case