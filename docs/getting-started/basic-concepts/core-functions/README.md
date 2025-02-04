# Core functions

For building agentic systems there are several core funcions that are available to all agents.

* `get_entities` provides a key-value lookup for any entity in the system. Entities are added by name as graph nodes when they are inserted as structured data in the relational data store. If entities have embedding metadata e.g an image or text these are also indexed in the vector data store. Get entities provides not just the entities but optionally the metadata about the entities.
* `help` a help function is the main planning agent that searches over agents and functions to recruit agents or functions&#x20;
* `search` is a generic multi-modal search on all entities - search is used in the context if a particular entity and is confined to the structured data or the graph or vector embeddings associated with that entity
* `activate function by name` allows any entity to request a function be added to its call stack and passed to the langauge model. These functions are loaded in the database or Python runners.

These are the core functions that allow agents to participate in the Percolate ecosystem. There are some other notification functions that agents can call. For example the language model can be given notification callbacks such as to announce when it is generating a large amout of content. We will explore these later. In the following sections we provide more details about the core functions
