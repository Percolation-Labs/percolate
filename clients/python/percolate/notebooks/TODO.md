# Misc

- add save function to system functions in percoalte agents in python and database 
## Functions
- make it easier to enable default functions or add them from external refs. 
- add discovery and reachability tests for referenced functions
- create a discovery test space e.g. hundreds of functions and hypothetical calling sequences - this should replace the idea of static graphs

## Infra
- add Docker registry on the server so that custom APIs can be added - this would be mapped to custom-api:5000 for example and any functions here would be discoverable by default

## DB

### Embeddings

- allow column embeddings to be toggled on and off / add to config in site - for example sessions could be embedded but disabled by default
- 
- 
- 
- 
# Issues / missing faetures

If user does not add ID field we need to warn or add + docs should mention convention

## Migrations

We dont really have a good database migration approach - this requires more thought - we can auto migrate on updates that failed for the right reasons in this world of auto-crud but migratinos should be back compat but being additive and we dont allow field type changes by default

## conventions based on names

- for the graph interface today we assume an entity has both a name column and an id which is not always reasonable. The rationale is that we need a human friendly label for graph nodes, we can spoof this by adding a uuid has of some other field as a name

## managing embeddings

- when a schema is upserted and embedding fields we dont add the notify trigger that is only added when tables are created with embedding fields. We can attach this trigger in the alter.
- We dont refresh embeddings today when fields are updated - we need to invalidate embeddings when there are row updates - there is an argument in some cases the fuzzyness is ok for some tables so we might make this optional
- WE have yet to implement multiple embeddings types e.g. ollama or multiple embeddings for searching. 