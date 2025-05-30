---
description: Getting started with the managed cloud instance
---

# Managed Cloud

{% hint style="info" %}
Percolate cloud is by invitation only at this time. Reach out for an experimental managed instance
{% endhint %}

You need a `project-name`  and `api-key` to carry out the steps below. You will also be given a database `port` when you use the connect command below.&#x20;

Your `domain` will be `project-name.percolationlabs.ai`&#x20;

If you want to use the OpenWebUI client to connect to your instance, you should set the env variables as follows, replacing your project name and api key,

```bash
export P8_API_KEY="[api-key]"
export P8_API_URL="https://[project-name].percolationlabs.ai"
```

There is a script in the repo you can run but it is shown in full below.

### Using Open Web UI to connect

```bash
#!/bin/bash

# Load base URL and API key from environment - by default the dev api at 5009 could be used if you want to test this in development
# chmod +x run-open-webui.sh
# for example you can see your parameters in your profile
# export P8_API_KEY="YOUR-KEY"
# export P8_API_URL="your-project.percolationlabs.ai"
#source ~/.bash_profile

export OPENAI_API_BASE_URL=${P8_API_URL:-http://host.docker.internal:5009}
export OPENWEBUI_OPENAI_API_KEY=${P8_API_KEY}

docker run -d \
  -p 3000:8080 \
  -v open-webui:/app/backend/data \
  -e WEBUI_AUTH=false \
  -e OLLAMA_ENABLED=false \
  -e OPENAI_API_BASE_URL="$OPENAI_API_BASE_URL" \
  -e OPENAI_API_KEY="$OPENWEBUI_OPENAI_API_KEY" \
  -e DEFAULT_MODEL=gpt-40-mini \
  -e ENABLE_MODEL_SELECTOR=true \
  --name open-webui \
  ghcr.io/open-webui/open-webui:main
  
#commands to stop or purge or check logs for docker
#docker rm -f open-webui
#docker volume rm open-webui
#docker logs -f open-webui
```

The first time it will take some time but you can browse OpenWebUI at `localhost:3000` and select from models that are configured in your instance and then chat.

{% hint style="info" %}
We load default models in your instance such as gpt, gemini and claude models. If the API token is set, they will shown in the list. You can add your own models and keys with your database access.
{% endhint %}

### Using the Percolate client to connect

If you have cloned the repo as per the getting started guide you can use the poetry setup to run the `cli` command below.

{% hint style="info" %}
You can also pip install percolate-db but for developers its better to just use the codebase
{% endhint %}

To connect to your instance you can use your api-key

```bash
#from the clients/python/percolate directory where the poetry project lives
poetry run p8 connect project-name --token [api-key]
```

This will fetch the connection details you need to connect to your instance. These connection details include your database `port`.

You can interact with the Percolate cli, which will use your cloud instance database. When "connected" anything you do in Percolate will use this connection profile.

{% hint style="info" %}
When developing if you want to connect to the test docker database instead of the cloud instance you will need to either delete the downloaded account token from \~/.percolate/auth/token or set the P8\_DEV\_MODE="true" flag.&#x20;
{% endhint %}

{% hint style="info" %}
The first time you connect you may need to initialize your database unless you have done it via another route. You can do this as described in the getting started guide i.e. using `poetry run p8 init`&#x20;

If you have been invited to try Percolate this will already have been done by the sys admin.
{% endhint %}

To test that you are connected you can ask a question which will use configured language models

```bash
#from the same cli directory
poetry run p8 ask "what is the capital of ireland?"
```

If this works you are connected and using language models.&#x20;

You are now ready to add more Language models, tools and agents as described in further sections of the docs.
