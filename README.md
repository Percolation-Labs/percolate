# Percolate

Percolate is a multi-modal AI database built on PostgresSQL. It uniquely adds agentic AI into the data tier, obviating the need to use application tier agent orchestrators.

It is now possible to build sophisticated multi-agent, multi-modal and data-rich agentic systems in a way that minimizes effort in the application tier.  This can mean writing no-code applications on top of Percolate or building applications in any programming language on top of Percolate from Python to Zig. It also provides an excellent place to handle most of the hard things about integrating your data with AI.

With Percolate, you can register declarative agents, external functions and external large language models in the database and run agentic workflows entirely via database queries - this includes natural language, cypher and SQL queries. The reason to do this are two fold

1. Because agents can be expressed declaratively as data, this makes it easier to scale to large systems as agents can be managed and shared easily. 
2. Because everything happens in the data tier, complex multi-modal RAG concerns can be managed outside of the application tier, and in the database
3. Auditing conversations happens for free in way that makes it easier to trace, learn and optimize

## Easy to run - runs anywhere!

You can try the example agents and recipes out of the box or register your own function-calling agents declaratively as pure data. 

You can run Percolate anywhere - build it locally or run it from the Docker image. If you want to put it on your own cloud, we recommend using the Kubernetes installation. Or if you want to try it out without the setup hassle, get access to one of the managed cloud instances.

Everything you do in Percolate is naturally logged in the database for audit, analysis and optimization.


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