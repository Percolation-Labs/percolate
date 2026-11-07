# Core canvas conversation rehearsal
Simulated user prompts; actual caller-authenticated MCP/SQL results from the local core workspace. No example rows are inserted.

**User (simulated):** What tables are in this Percolate database? Group them by schema.

**Assistant:** Queried the live database and displayed plot using saved result `01a1b647-fe22-7b17-9d1e-5d255ab342fe`.

```sql
select n.nspname as schema, count(*)::int as tables
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')
  and n.nspname not like 'pg_toast%'
group by n.nspname order by tables desc, schema limit 30
```

Returned 14 rows:
```json
[
  {
    "schema": "aiq",
    "tables": 25
  },
  {
    "schema": "research",
    "tables": 24
  },
  {
    "schema": "claims",
    "tables": 22
  },
  {
    "schema": "rbac",
    "tables": 21
  },
  {
    "schema": "workflow",
    "tables": 13
  },
  {
    "schema": "calder",
    "tables": 9
  },
  {
    "schema": "content",
    "tables": 9
  },
  {
    "schema": "agentic",
    "tables": 8
  },
  {
    "schema": "engagement",
    "tables": 7
  },
  {
    "schema": "demo",
    "tables": 4
  },
  {
    "schema": "harbour",
    "tables": 4
  },
  {
    "schema": "percolate",
    "tables": 3
  },
  {
    "schema": "public",
    "tables": 3
  },
  {
    "schema": "cron",
    "tables": 2
  }
]
```

**User (simulated):** Now graph the relationships between the workflow tables.

**Assistant:** Queried the live database and displayed graph using saved result `01a1b647-fe34-729a-842b-b0ef07cf6f15`.

```sql
select ns.nspname||'.'||src.relname as source,
       nt.nspname||'.'||dst.relname as target, c.conname as relation
from pg_catalog.pg_constraint c
join pg_catalog.pg_class src on src.oid=c.conrelid
join pg_catalog.pg_namespace ns on ns.oid=src.relnamespace
join pg_catalog.pg_class dst on dst.oid=c.confrelid
join pg_catalog.pg_namespace nt on nt.oid=dst.relnamespace
where c.contype='f' and ns.nspname='workflow' and nt.nspname='workflow'
order by source,target,relation limit 100
```

Returned 12 rows:
```json
[
  {
    "source": "workflow.run_estimates",
    "target": "workflow.runs",
    "relation": "run_estimates_run_id_fkey"
  },
  {
    "source": "workflow.runs",
    "target": "workflow.definitions",
    "relation": "runs_workflow_def_id_fkey"
  },
  {
    "source": "workflow.runs",
    "target": "workflow.lifecycle_states",
    "relation": "runs_status_fk"
  },
  {
    "source": "workflow.runs",
    "target": "workflow.runs",
    "relation": "runs_dry_run_of_fkey"
  },
  {
    "source": "workflow.schedules",
    "target": "workflow.runs",
    "relation": "schedules_last_run_id_fkey"
  },
  {
    "source": "workflow.task_dependencies",
    "target": "workflow.tasks",
    "relation": "task_dependencies_depends_on_task_id_fkey"
  },
  {
    "source": "workflow.task_dependencies",
    "target": "workflow.tasks",
    "relation": "task_dependencies_task_id_fkey"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.lifecycle_states",
    "relation": "tasks_status_fk"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.runs",
    "relation": "tasks_child_run_id_fkey"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.runs",
    "relation": "tasks_run_id_fkey"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.tasks",
    "relation": "tasks_compensates_task_id_fkey"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.tasks",
    "relation": "tasks_matrix_parent_id_fkey"
  }
]
```

**User (simulated):** How much actual canvas work have we recorded? Plot its task types.

**Assistant:** Queried the live database and displayed plot using saved result `01a1b647-fe40-7681-be00-3a0efdd0b8a1`.

```sql
select step_key as step, count(*)::int as tasks
from workflow.tasks_api where queue='workspace-canvas'
group by step_key order by tasks desc,step_key limit 20
```

Returned 3 rows:
```json
[
  {
    "step": "intent",
    "tasks": 67
  },
  {
    "step": "view",
    "tasks": 67
  },
  {
    "step": "query",
    "tasks": 14
  }
]
```

**User (simulated, after clicking a node):** Show only relationships involving the table I selected.

**Assistant:** Your canvas selection was `workflow.runs`. The live follow-up query returned 7 relationships, now displayed as a graph.

```sql
select * from (select ns.nspname||'.'||src.relname as source,
       nt.nspname||'.'||dst.relname as target, c.conname as relation
from pg_catalog.pg_constraint c
join pg_catalog.pg_class src on src.oid=c.conrelid
join pg_catalog.pg_namespace ns on ns.oid=src.relnamespace
join pg_catalog.pg_class dst on dst.oid=c.confrelid
join pg_catalog.pg_namespace nt on nt.oid=dst.relnamespace
where c.contype='f' and ns.nspname='workflow' and nt.nspname='workflow'
order by source,target,relation limit 100) edges where source='workflow.runs' or target='workflow.runs'
```

```json
[
  {
    "source": "workflow.run_estimates",
    "target": "workflow.runs",
    "relation": "run_estimates_run_id_fkey"
  },
  {
    "source": "workflow.runs",
    "target": "workflow.definitions",
    "relation": "runs_workflow_def_id_fkey"
  },
  {
    "source": "workflow.runs",
    "target": "workflow.lifecycle_states",
    "relation": "runs_status_fk"
  },
  {
    "source": "workflow.runs",
    "target": "workflow.runs",
    "relation": "runs_dry_run_of_fkey"
  },
  {
    "source": "workflow.schedules",
    "target": "workflow.runs",
    "relation": "schedules_last_run_id_fkey"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.runs",
    "relation": "tasks_child_run_id_fkey"
  },
  {
    "source": "workflow.tasks",
    "target": "workflow.runs",
    "relation": "tasks_run_id_fkey"
  }
]
```
