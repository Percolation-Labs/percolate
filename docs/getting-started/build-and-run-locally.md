---
description: Get up and run in a 1 minute
---

# Quick start

To start trying Percolate, clone the [repo](https://github.com/Percolation-Labs/percolate) and from the root

```bash
docker compose up -d
```

You now have a postgres instance on port `5438` hat you can log into with `postgres:postgres`

{% hint style="info" %}
We manage environment variables that are needed for interacting with LLMs/APIs in different ways but using the percolate cli can be a generally useful way to bootstrap your environment.&#x20;
{% endhint %}

You can install percolate-db with pip but lets use the codebase for now...

```bash
cd clients/python/percolate
#if you have API keys like OPEN_AI_KEY these are synced into your local instance
python percolate/cli.py add env --sync
```

Another thing you can do is index Percolate files so you can ask questions about Percolate. This will use your Open AI key to generate embeddings.&#x20;

```bash
python percolate/cli.py index 
```

Now you can ask questions from the cli

```bash
python percolate/cli.py ask 'are there SQL functions in Percolate for interacting with models like Claude?'
```

***

Percolate is a database - it wraps Postgres and adds extensions for vector and graph data. It also pushes agentic AI down into the data tier. Using your favourite Postgres client,

```sql
select * from percolate('What is the capital of ireland?')
--try different models
--select * from percolate('how can percolate help me with creating agentic systems',
--  'deepseek-chat')
--see what Models are in Percolate by default
--select * from p8."LangaugeModelApi"
```

This trivial example tests that we are connected to a langauge model(s) without using tools or data

If we want to use an Agent we can try the built in ones as an example&#x20;

{% hint style="info" %}
To understand creating agents see [add-agents.md](../configure/add-agents.md "mention") or [percolating-python-first.md](../recipes/percolating-python-first.md "mention")
{% endhint %}

```bash
 select * from percolate_with_agent('give a brief summary of percolate', 
                                    'p8.PercolateAgent')
```

If you have created an agent using the example with the sample pets store tools

```sql
select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent',
```

&#x20;

