---
description: >-
  Most of the agentic frameworks in use today are Python-based. Many of them
  rely heavily on Pydantic. In this section we take a look at how Percolate and
  Python work together.
---

# Percolating Python-first

Percolate takes a different approach to AI agents by starting with the database first rather than the other way around. Before you write a single line of code, you can register tools, agents and langauge models in the database. If you want, you can orchestrate agents entirely through SQL queries and the Percolate streaming REST service. To learn more about that, see the next section.

But... maybe you just _need_ to write some Python code. Well, lets use Percolate python client as an agentic framework by installing the client

```bash
pip install percolate-db
```

The percolate client relies on `percolate`as a tools and agents registry. It also uses Percolate to audit conversations. And of course, it uses it just as a database. This allows you to keep your application tier as thin as possible but you can still write Agents in Python and you can still interact with all the same Language Model APIs via Python. To get started, create your first agent as a Pydantic object

```python
import percolate as p8
from pydantic import BaseModel,Field
import typing
from percolate.models import DefaultEmbeddingField

class MyFirstAgent(BaseModel):
    """You are an agent that provides the information you are asked and a second random fact"""
    #because it has no config it will save to the public database schema
    
    name: str = Field(description="Task name")
    #the default embedding field just settgs json_schema_extra.embedding_provider so you can do that yourself
    description:str = DefaultEmbeddingField(description="Task description")
    
    @classmethod
    def get_model_functions(cls):
        """i return a list of functions by key stored in the database"""
        return {
            'get_pet_findByStatus': "a function i used to look up petes based on their status",
            'p8_About' : 'a "native" database function that gives me general information about percolate'
        }

```

This is the structure of the agent. You can run this agent as follows

```python
p8.Agent(MyFirstAgent).run("what is your purpose and what functions do you have - list them by name")

```

If you "register" your agent you can run it via the database too, either in SQL or in Python via reloading

```python
p8.repository(MyFirstAgent).register()
#i can also use the repository to read and write any data for my agent/entity
```

To emphasize that agents are declarative - this agent and any other agent that is stored in the database can be used from the Percolate Python client - you don't need the Pydantic objects.

```python
percolate.run("ask a complicated question", agent="MyAgent")
```

***

This so far is maybe not very interesting since it just seems like a glorified prompt registry. To see the value just in terms of the Python framework, we need to be able to move structured data around and call external tools. We will also need to orchestrate more complex swarms of agents.&#x20;

### Registering tools and adding them to your agent

Lets start with registering tools that we can add to the list of functions on our agent. We will also be able to discover other tools in the database. In the section [add-tools-via-apis.md](../configure/add-tools-via-apis.md "mention") you learned how to register rest APIs in the database. This adds entries to the `p8.Functions`table. This table also contains some "native" sql tools that you can use such as interacting with agents/entities. We will add an external tool as an example. Then when you register this, you can add the name of the tool within your agent's `get_functions` body as we showed above.

```python
from percolate.utils.ingestion import add 
add.add_api('swagger_test', 
            'https://petstore.swagger.io/v2/swagger.json', verbs='get')
```

This registered the functions in the database which you can see for example if you run any of these commands

```python
from percolate.models.p8 import Function
#select all the functions
functions = [Function(**f) for f in p8.repository(Function).select()]
#find one by names
p8.repository(Function).get_by_name(['get_pet_findByStatus'], as_model=True)
```

{% hint style="info" %}
Behind the scenes, Percolate uses Function Manager to load and plan over functions. These are made available to the execution context and passed to the LanguageMode
{% endhint %}

Because the swagger example api has a get pets by status function, we can try to use that

```python
agent = p8.Agent(MyFirstAgent)
agent.run("can you find available pets",limit=2) 
```

### Using the structured response types

The agent is defined with its structured response. In Percolate Agents, Entities (structures) and tables are fairly synonymous. In this case we can automatically fetch data as structured response which can be saved in the database. To illustrate,

### Orchestration

Finally in this section we illustrate the swarm or multi-agent approach in Percolate. Building a single agent is useful but limited. We need to be able to wire together other agents and tools easily. Lets see how this works in Percolate.

### Final thoughts

Having interacted with our agent in different ways, we can now review our sessions in Percolate.&#x20;

To find out more about Percolate in Python checkout the YouTube channel and subscribe to our Medium and Substack. For a video walkthough of Python in Percolate, checkout the link below





