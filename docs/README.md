---
description: Percolate is a data-native agentic orchestrator in a multimodal database
---

# Percolate - AI in the data tier

<figure><img src=".gitbook/assets/image (1) (1).png" alt=""><figcaption></figcaption></figure>

**Percolate** brings language models, tools and agents into the database. You can orchestrate powerful agentic systems with multi-modal RAG in any language, including natural language.

***

## Try it now

To run it locally, clone the [repo](https://github.com/Percolation-Labs/percolate) and from inside the repo,

```bash
git clone https://github.com/Percolation-Labs/percolate.git
```

Launch the docker container so you can connect with your preferred database client

```bash
docker compose up -d #The connection details are in the docker-compose file
```

The easiest way to get started is to run the `init` - this will add some test data and also sync API tokens for using language models from your environment into your local database instance. This requires [Poetry](https://python-poetry.org/docs/) to be installed.

```bash
#cd clients/python/percolate to use poetry to run the cli
poetry run p8 init
```

You can ask a question to make sure things are working. Using your preferred Postgres client log in to the database on port `5438` using `password:password` and ask a question.

```sql
Select * from percolate('How does Percolate make it easy to add AI to applications?')
```

## Learn more

We are building out examples in the docs but you might start with [percolating-python-first.md](recipes/percolating-python-first.md "mention")

## Connect and Learn

To learn more follow us sing the links below

* [Github](https://github.com/Percolation-Labs/percolate)
* [Medium](https://medium.com/percolation-labs)
* [Substack](https://percolationlabs.substack.com/)
* [Bluesky](https://bsky.app/)
* [Youtube](https://www.youtube.com/@PercolationLabs)
