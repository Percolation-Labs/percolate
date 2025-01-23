# Percolate: Build AI agents directly in Postgres

Rather than build application-tier agentic frameworks that connect to language models, tools and databases, Percolate brings language models, tools and agents into the database.

You can now orchestrate powerful agentic systems with multi-modal RAG using any language, and that includes natural language. 


```sql
select * from percolate('Create task to deploy Percolate to the cloud with some high-level instructions', 
  'claude-3-5-sonnet-20241022')
```

```sql
select * from percolate('How do I use Percolate studio to interact with my instance', 
  'deepseek-chat')
```


When you interact with language models in Percolate, conversations are naturally logged in your instance for audit, analysis and optimization.


```sql
select * from percolate_with_tools('What priority tasks did I created last week? How many did i create in total?', 
ARRAY['query_conversations']
)
```

Try Percolate using the setup instructions below to see how it simplifies connecting AI to your data.

## Easy to run - runs anywhere!

You can build it locally, run it on Docker or Kind or deploy it to the cloud. To run the cloud you can either using the Kubernetes recipe or connect to a managed instance.


## Getting set up

### Adding your own entities i.e. "Agents"

### Installing To K8s

### Launching an instance 



## On the Roadmap

1. Query optimizers: we built Percolate to allow for multi-modal RAG queries to be intelligently optimized in the data tier. Having put the framework in place, our primary objective is to focus on the query planners
2. In the new database paradigm, it should be possible to interact with databases using natural language. We are building percolate studio for query composition and data visualization powered with AI.
3. Any issues or suggestions you add will hopefully make their way into our prioritized roadmap so feel free to suggesting anything!


## Developers

### Connect and Learn

- Docs
- Youtube
- Substack
- Discord
- Bluesky
- Medium
- PercolationLabs home