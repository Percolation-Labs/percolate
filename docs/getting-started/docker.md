---
description: Docker is the easiest way to try out Percolate on your local machine
---

# Docker

To run Percolate via docker, first clone the [repo](https://github.com/Percolation-Labs/percolate) and from the root of the repo -

```bash
docker compose up -d
```

The credentials to connect to Postgres using your preferred client are in the `docker-compose.yaml`

````yaml
dockercompose
services:
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
```
````

You will notice that the port is `5438`and you can connect with `postgres:postgres`

One useful way to check that the installation scripts ran is to check the watermark with -

```sql
select * from p8."Session"
```

Of course, you will truly know Percolate is ready if you can ask it questions -

{% hint style="info" %}
You need to have api keys set in the database. In some cases we can load these from the environment. In other cases you may want to add them to the `p8.LanguageModelApi` table. The tokens can be added to make it easier to run queries that require tokens.
{% endhint %}

```sql
select * from percolate('How do i add my own agents and entities to Percolate?')
```

***

The installation scripts in the docker compose are used to add extensions and Percolate schema elements to the database. If you wish you can remove some or all of the files in the local `/extension/sql.` Among other things, the install adds a number of extension for vector and graph data and also http requests.

The volume `percolate_data` is used to mount data.&#x20;

Here is a reminder of some useful commands when working with Docker containers

<table><thead><tr><th width="366">Command</th><th>What it does</th></tr></thead><tbody><tr><td><code>docker volume ls</code></td><td>list volumes in use by postgres/percolate</td></tr><tr><td><code>docker stop &#x3C;container__id></code></td><td>stop the running container e.g. to free a port</td></tr><tr><td><code>docker rm &#x3C;container__id></code></td><td>remove a container e.g. to clean up</td></tr></tbody></table>



```yaml
docker compose down --volumes
```

