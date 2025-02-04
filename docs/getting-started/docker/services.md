---
description: In addition to the Postgres Instance, we add other services
---

# Services

```yaml
services:
  minio:
    image: quay.io/minio/minio
    container_name: minio
    ports:
      - "9000:9000"
      - "9090:9090" # MinIO Console
    environment:
      MINIO_ROOT_USER: percolate
      MINIO_ROOT_PASSWORD: percolate
    volumes:
      - minio_data:/data
    command: server /data --console-address ":9090"
  percolate-api:
    image: percolationlabs/percolate-api
    container_name: percolate-api
    ports:
      - "5008:5008"
    environment:
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      P8_PG_HOST: percolate #docker service that has postgres on it
      P8_PG_PORT: 5432 #this is what we do b default - we will change it on k8s
  postgres:
    image: percolationlabs/postgres-base:16
    container_name: percolate
    platform: linux/amd64
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: app
    ports:
      - "5438:5432"
    volumes:
      - percolate_data:/var/lib/postgresql/percolate
      - ./extension/sql:/docker-entrypoint-initdb.d
    restart: unless-stopped
volumes:
  percolate_data:
  minio_data:
#good to check the api logs so we can see if the api and percolate db are on speaking terms
#docker logs   percolate-api
```

Minio is added to allow for S3 like blob storage for uploading and indexing content.

We also add the Percolate admin API. For example you can use this to index content. This is a good reminder than while you can use localhost from within the container to hit this api, from a client you might do something like this - the key given here is just an example. The host.docker.internal host is used to route via your machine localhost.

```sql
SELECT *
FROM public.http(
	( 'POST', 
	'http://host.docker.internal:5008/' || 'admin/index/',
	ARRAY[http_header('Authorization', 'Bearer ' || 'c8de992a-fd92-9ce0-8cf8-0a8690be00a9')],
	'application/json',
	json_build_object('entity_full_name', 'p8.Agent')::jsonb
	)::http_request
);
```

