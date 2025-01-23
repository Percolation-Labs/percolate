# Percolate: Build AI agents directly in Postgres

<figure><img src=".gitbook/assets/image (1).png" alt=""><figcaption></figcaption></figure>

Rather than build application-tier agentic frameworks that connect to language models, tools and databases, Percolate brings language models, tools and agents into the database.



You can now orchestrate powerful agentic systems with multi-modal RAG using any language, and that includes natural language. You can easily connect any langauge model APIs (Open AI/GPT models will be the default).

```sql
select * from percolate('Create task to deploy Percolate to cloud with instructions', 
  'claude-3-5-sonnet-20241022')
```

```sql
select * from percolate('How do I use Percolate studio to interact with my instance', 
  'deepseek-chat')
```

When you interact with language models in Percolate, conversations are naturally logged in your instance for audit, analysis and optimization.

You can use tools implicitly or explicitly when you engage with Percolate.

```sql
select * from percolate_with_tools('What priority tasks did I created last week? How many did i create?', 
ARRAY['query_conversations']
)
```

Try Percolate using the setup instructions below to see how it simplifies connecting AI to your data.

## Easy to run - runs anywhere!

You can build it locally, run it on Docker or Kind or deploy it to the cloud. To run the cloud you can either use the Kubernetes recipe or connect to a managed instance.

## Getting set up

### Adding APIs and Agents

You can register you own APIs and tools and integrate LLM APIs such as those from OpenAI, Anthropic, Cerebras, Grow, DeepSeek, Google etc. All of these are registered in your Percolate instance along with your declarative agents. This section will show you the basks and you can check out the documentation links for more details

### Installing To K8s

To install Percolate on your cluster simply run the command below in your cluster. See the documentation for more details.

### Launching an instance

To connect to your own instance, request a KEY and use the percolate client to connect.

## On the Roadmap

1. Query optimizers: we built Percolate to allow for multi-modal RAG queries to be intelligently optimized in the data tier. Having put the framework in place, our primary objective is to focus on the query planners
2. In the new database paradigm, it should be possible to interact with databases using natural language. We are building percolate studio for query composition and data visualization powered with AI.
3. Any issues or suggestions you add will hopefully make their way into our prioritized roadmap so feel free to suggesting anything!

## Developers

The Postgres Extension is built in C and Zig. Instructions to install locally and develop the extension are given below.

## Connect and Learn

To learn more, checkout the links below.

* Docs
* Youtube
* Substack Publication
* Medium Publication
* PercolationLabs home
* Discord
* Bluesky
