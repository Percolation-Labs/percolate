
<img src=".assets/images/proj_header.png"  />

# Percolate - Build your AI directly in multi-modal Postgres

**Note: This codebase is new and under active development. We will tag a stable release soon** 

Rather than build application-tier agentic frameworks that connect to language models, tools and databases, _Percolate_ brings language models, tools and agents into the database.

You can now orchestrate powerful agentic systems with multi-modal RAG using any language - that includes natural language. You can connect any LLM APIs and integrate your language models, tools and data directly inside the database. 


```sql
select * from percolate('Create task to deploy Percolate to cloud with instructions', 
  'claude-3-5-sonnet-20241022')
```

```sql
select * from percolate('How do I use Percolate studio to interact with my instance', 
  'deepseek-chat')
```

When you interact with language models in Percolate, conversations are naturally logged in your instance for audit, analysis and optimization.
We create new `Session` entries with user questions and then track each `AIResponse` which may include tool calls and evaluations. One of the things Percolate is useful for is _resuming_ and replaying sessions or getting a better understanding of the payloads that are sent to LLM Apis.

You can use tools implicitly or explicitly when you engage with Percolate.

```sql
select * from percolate_with_tools('What priority tasks did I created last week? How many did i create?', 
                                   ARRAY['query_conversations'] )
```
 
Reach out on the various channels at the bottom of the repo to tell us what you think. It would be great to hear from you!

## Easy set up

The easiest way to get started is simply to launch the docker instance and connect to postgres using your preferred client on port 5438 using `postgres:postgres` to login

```bash
docker compose up -d
```

---

You have the option of installing the client or using it from source (recommended). To install the python client locally 

```bash
pip install percolate-db
```

If you dont install the client but want to use the cli from the current build. For example you can you can do the following if your docker instance is up to sync API keys into the local database. (In future we will read them from the env automatically)

```
cd clients/python/percolate
python percolate/cli.py add env --sync
```

While the Python client is optional, its useful as a way to ingest data. It also provides a lightweight agentic workflow that relies on simple Pydantic objects. With this you can stream results or handle multi-step reasoning. See the docs to learn more about working with Percolate any Python or other languages.

You can use the Python client to add agents and APIs. Use the cli to add a test api. This assumes you have launched the docker instance or you have connected to another instance of Percolate.

```bash
p8 add api https://petstore.swagger.io/v2/swagger.json --verbs get
#OR if using the python client as mentioned above
#python percolate/cli.py add api https://petstore.swagger.io/v2/swagger.json --verbs get
```

Create a Python agent (and also register it in the database). 

```python

import percolate as p8
from pydantic import BaseModel,Field
import typing
from percolate.models import DefaultEmbeddingField

class MyFirstAgent(BaseModel):
    """You are an agent that provides the information you are asked and a second random fact"""
    #because it has no config it will save to the public database schema
    
    name: str = Field(description="Task name")
    #the default embedding field just settings json_schema_extra.embedding_provider so you can do that yourself
    description:str = DefaultEmbeddingField(description="Task description")
    
    @classmethod
    def get_model_functions(cls):
        """i return a list of functions by key stored in the database"""
        return {
            'get_pet_findByStatus': "a function i used to look up pets based on their status",
            'p8_About' : 'a "native" database function that gives me general information about percolate'
        }
#register creates tables to save data of this type and search for agents
#you do not not need to register the agent to use the Python examples.
p8.repository(MyFirstAgent).register()
```

Ask questions using whatever model(s) you have API keys for

```python
p8.Agent(MyFirstAgent).run("List some pets that are sold") #this is using the api we registered above
#p8.Agent(MyFirstAgent).run("List some pets that are sold", 'deepseek-chat')
#p8.Agent(MyFirstAgent).run("List some pets that are sold", 'claude-3-5-sonnet-20241022')
#p8.Agent(MyFirstAgent).run("List some pets that are sold", 'gemini-1.5-flash')
```

Also talk to your agent in the database

```sql
select * from percolate_with_agent('List some pets that are sold', 'MyAgent')
```

Try Percolate using the setup instructions below to see how it simplifies connecting AI to your data. You can run it locally, in the cloud or connect to a cloud instance. After setting up and trying a few examples, check out the recipes in the [Docs](https://percolation-labs.gitbook.io/percolation-labs) to go deeper.

### Configure

You can register you own APIs and tools and integrate LLM APIs such as those from OpenAI, Anthropic, Cerebras, Groq, XAI(Grok) DeepSeek, Google etc. All of these are registered in your Percolate instance along with your declarative agents. This section will show you the basics and you can check out the documentation links below for more details.

### Installing To K8s

To install Percolate to your K8s cluster simply apply the manifest below to your cluster. See the documentation for more details.

```yaml
#percolate-cluster.yaml
#kc apply -f percolate-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: percolate
spec:
  #the operator needs to use 16 as a postgres version
  imageName: percolationlabs/postgres-base:16
  instances: 1
  storage:
    size: 10Gi
```

To use this you need the [Cloud Native PG Operator](https://cloudnative-pg.io/) on your cluster

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.24.0.yaml

```

### Launching an instance (Coming soon)

To connect to a dedicated Percolate cloud instance, you will be able request a Percolate API KEY and use the percolate client to setup and connect to a new instance. 

## On the Roadmap

The main reason we created Percolate is to work on a new type of query plan that involves both agents and data. We wanted to push Agentic AI down into the data tier because we think it shows promises. Importantly data are multi-modal and rather than using multiple stores for key-value, relational, graph and vector, we want it all in the same place, first for convenience and then for optimization. Building this Optimizer is not trivial. 

We also have things to work out regarding database background workers to achieve a great user experience for agentic workflows that use the database during multi-hop reasoning. Another exciting avenue is an SQL coding environment that uses AI and the data and schema stored in Percolate. 
 

In the new database paradigm, it should be possible to interact with databases using natural language. We are building _Percolate Studio_ for query composition and data visualization powered with AI.

Any issues or suggestions you add will hopefully make their way into our prioritized roadmap so feel free to suggest anything related to putting ai in the dAta tIer.


## Developers

The Postgres Extension is being built in C and Zig. Instructions to install locally and develop the extension will be given below

Note on Jupyter

git attribute removes contents on commit
```bash
git config --global filter.strip-notebook-output.clean "jq --indent 1 '.cells[] |= if .outputs then .outputs = [] else . end | .metadata = {}' 2>/dev/null || cat"
```


## Connect and Learn

To learn more about or stay up to date on Percolate, check out the links below. Subscribe to the channels below and we look forward to hearing from you. 

**❤️  Please star this repo if you find it interesting ❤️**

---


- [Docs](https://percolation-labs.gitbook.io/percolation-labs)
- [Youtube](https://www.youtube.com/@PercolationLabs)
- [Substack](https://percolationlabs.substack.com/)
- [Medium](https://medium.com/percolation-labs)
- [PercolationLabs](https://percolationlabs.ai/)
- Discord
- Bluesky
