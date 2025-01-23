# Docker

The main dockerfile built for the postgres stack that includes the Percolate extension is stored below. You can launch this locally with the command below (assuming you have Docker e.g. Docker Desktop installed)

```bash
docker compose up -d
```

Take note of the environment variables in the config file and other settings. For example we use the port `5438` as the Postgres port and we provided the default user and password that can be used for login. By default this is just `postgres:postgres`. It is also possible to read (or not read) environment variables e.g. for standard hubs and APIs that are used within Percolate. You do not have to do this but you would need to pass tokens in SQL queries if you do not configure them here. For example we will load `OPENAI_API_KEY` to support using default models but you can configure other tokens such as for Anthropic or Google.

## The API for Percolate Server

Docker compose will also load an instance of the Percolate admin API. This is a python FastAPI-based REST service that we use to support Percolate. The Dockerfile for this is in `api/Dockerfile`. 


## Developers

for instructions of building the Docker image to work on the Percolate extension see here.
