---
description: Understanding entities
---

# Entities

Entities and agents are synonymous in Percolate. When you create entities we create tables to store structured data for those agents and they are also registered as entities (in the graph). This allows looking up an entity by key/name. For example, suppose you have some entity called `Task` which is defined in Percolate (or any other object you register)

```python
from percolate.models.p8 import Task 
p8.repository(Task).register()
```

{% hint style="info" %}
In Percolate entities are just JSON Schema or Pydantic objects that are registered using an API or python client repository. These are stored as tables based on their schema and they are also indexed as graph nodes and vector embeddings (if their fields require vector embeddings).
{% endhint %}

If I then create a task

```python
repo = p8.repository(Task)
task = Task(name='T1234', 
    description="A task for creating a youtube video explaining how percolate works", 
    project_name='percolate')
repo.update_records(task)
```

Entities can have functions defined. For example the Task object is shon below

```python
class Task(Project):
    """Tasks are sub projects. A project can describe a larger objective and be broken down into tasks"""
    id: typing.Optional[uuid.UUID| str] = Field(None,description= 'id generated for the name and project - these must be unique or they are overwritten')
    project_name: typing.Optional[str] = Field(None, description="The related project name of relevant")
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({'name': values['name'], 'project_name': values['project_name']})
        return values
    
    @classmethod
    def get_model_functions(cls):
        """fetch task external functions"""
        return {'get_tasks_task_name_comments': 'get comments associated with this task, supplying the task name' }
```

This means when we look up entities by key in the database either using the database function or using a PostgresService in the python client, we get&#x20;

```json
{'get_entities': {'p8.Task': {'data': [{'id': '5e265e3a-536b-8d1d-1bed-435acc58bec8',
     'name': 'T1234',
     'userid': None,
     'created_at': '2025-02-04T20:27:03.391408',
     'deleted_at': '2025-02-04T20:27:03.391408',
     'updated_at': '2025-02-04T21:40:54.19967',
     'description': 'A task for creating a youtube video explaining how percolate works',
     'target_date': None,
     'project_name': 'percolate'}],
   'metadata': {'functions': {'get_tasks_task_name_comments': 'get comments associated with this task, supplying the task name'},
    'description': 'Tasks are sub projects. A project can describe a larger objective and be broken down into tasks'},
   'instruction': 'you can request to activate new functions by name to use them as tools'}}}
```

By doing this, we can ask any agent about the comments on task `T1234` and it will be able to not only retrieve the entity but call any functions it exposes.&#x20;

{% hint style="info" %}
In Percolate, every agent is given core functions which include a function to activate functions by name. This allows functions to be added dynamically to the function stack passed to the language model
{% endhint %}

```python
from percolate.models.p8 import PercolateAgent
agent = p8.Agent(PercolateAgent)
agent("What comments are associated with T1234")
#some of the logs
#(p8.PercolateAgent)function_call=FunctionCall(name='get_entities', arguments={'keys': 'T1234'}, id='call_wPVvPqIUL4j2v8PEr3AtREY1', scheme=None)
#(p8.PercolateAgent)function_call=FunctionCall(name='activate_functions_by_name', arguments={'function_names': ['get_tasks_task_name_comments']}, id='call_dAxa5llhvAFsl9GzEX8fgpVT', scheme=None)
#(p8.PercolateAgent)function_call=FunctionCall(name='get_tasks_task_name_comments', arguments={'task_name': 'T1234'}, id='call_6TWdv7KnInEMMNbovPFSb6AQ', scheme=None)
```

This is a useful general-purpose pattern to find out information in a few hops for any entity. By grouping functions onto entities, you can create small-world structures where entities act as hubs to expose functions.&#x20;

### Indexing

When we insert entities in the database a trigger activates a background process to index the entities. Indexing can mean multiple things but at a minimum, any fields on the entiiy that have embedding metadata such as a description field will have vector embeddings added. Named entities are also added to the graph as in this example.
