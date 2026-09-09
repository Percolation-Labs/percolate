/* Every read a screen makes, as data, because two things need to agree on it.
 *
 * A screen used to carry its own projection and Surface used to carry its own
 * probe -- `limit=1`, no columns, no ordering. So Surface answered a question
 * nobody asked ("does this view exist") while reporting it as the question
 * that matters ("can this screen read it"), and the two were only ever equal
 * by hand. They stopped being equal: Agents asked for `structured_output`,
 * tool servers for `transport`, Keys for `name`, sessions for `created_at` and
 * the auth stream for `event` -- five columns no view has ever had -- while
 * Surface reported 31 of 31 objects reachable. A projection that nothing
 * executes is a projection that nothing checks.
 *
 * So the projection, the ordering and any static filter live HERE, the screen
 * reads through `read()`, and the audit executes the same string. An invalid
 * column now fails the thing that exists to find invalid columns, and it fails
 * for every caller at once rather than on the one screen somebody opened.
 *
 * WHAT IS DELIBERATELY NOT HERE: the per-row filter (`id=eq.<uuid>`) and the
 * bound a screen chooses (`limit=50`). Those are arguments rather than
 * contracts -- an audit has no id to substitute, and running a screen's read
 * unbounded is not an audit of it. They stay at the call site, as `extra`.
 *
 * THIS FILE IMPORTS NOTHING, deliberately. `read()` lives in api.js with the
 * transport it uses, so this module is data a plain `node --input-type=module`
 * can import and print -- which is what `dev/ui_reads.py` does to execute the
 * screens' reads against a deployment with no browser in the loop. A contract
 * table that only a browser can read is a contract table CI cannot check.
 */

/* `screen` is the name Surface prints, so it is the screen a failure breaks --
   not the module the call happens to live in. */
export const READS = {
  /* -- workflow ------------------------------------------------------- */
  definitions: { screen: "Workflows", schema: "workflow", view: "definitions_api",
    q: "select=id,name,version,step_count,step_kinds,queues,created_at&order=name" },
  runsByStatus: { screen: "Overview", schema: "workflow", view: "runs_by_status_api",
    q: "select=status,n" },
  tasksByStatus: { screen: "Queues", schema: "workflow", view: "tasks_by_status_api",
    q: "select=queue,status,n&order=queue" },
  recentRuns: { screen: "Overview", schema: "workflow", view: "runs_api",
    q: "select=id,status,external_id,created_at,workflow_def_id&order=created_at.desc" },
  runs: { screen: "Runs", schema: "workflow", view: "runs_api",
    q: "select=id,status,compensation_state,external_id,created_at,completed_at,workflow_def_id"
       + "&order=created_at.desc" },
  /* No projection, and that is the contract: the Run panel prints the whole
     row as JSON, so pinning columns here would hide the ones added later --
     the failure this file exists to prevent, running the other way. */
  run: { screen: "Run detail", schema: "workflow", view: "runs_api", q: "",
    note: "the whole row, because the screen prints it" },
  tasks: { screen: "Run detail", schema: "workflow", view: "tasks_api",
    q: "select=id,step_key,kind,status,queue,attempts,max_attempts,error,output,created_at,completed_at"
       + "&order=created_at" },
  taskDeps: { screen: "Run detail", schema: "workflow", view: "task_dependencies_api",
    q: "select=task_id,depends_on_task_id" },
  taskEvents: { screen: "Overview · Run detail", schema: "workflow", view: "task_events_api",
    q: "select=step_key,from_status,to_status,queue,detail,at&order=at.desc" },
  eventStream: { screen: "Events", schema: "workflow", view: "task_events_api",
    q: "select=id,run_id,step_key,kind,queue,from_status,to_status,detail,at&order=at.desc" },
  schedules: { screen: "Schedules", schema: "workflow", view: "schedules_api",
    q: "select=name,workflow_name,cron_expr,timezone,enabled,overlap_policy,last_fired_at,"
       + "fire_count,skip_count,last_error&order=name" },
  queueDepth: { screen: "Overview · Queues", schema: "workflow", view: "queues_api",
    q: "select=queue,depth" },
  pools: { screen: "Queues", schema: "workflow", view: "v_pools",
    q: "select=name,image,enabled,queues,min_replicas,max_replicas,node_class,generation,"
       + "observed_generation,reconcile_pending,phase&order=name" },
  poolQueues: { screen: "Queues", schema: "workflow", view: "pool_queues",
    q: "select=queue,pool&order=queue" },
  unservedQueues: { screen: "Queues", schema: "workflow", view: "v_unserved_queues",
    q: "select=queue,ready_tasks,running_tasks,oldest_task&order=queue" },
  rateLimits: { screen: "Queues", schema: "workflow", view: "rate_limits_api",
    q: "select=key,capacity,tokens&order=key" },
  imagePolicy: { screen: "Queues", schema: "workflow", view: "pool_image_policy",
    q: "select=pattern,note&order=pattern" },

  /* -- rbac ----------------------------------------------------------- */
  users: { screen: "Users", schema: "rbac", view: "users_api",
    q: "select=id,email,status,created_at&order=email" },
  userRoles: { screen: "Users", schema: "rbac", view: "user_roles", q: "select=user_id,role" },
  roleNames: { screen: "Users", schema: "rbac", view: "roles", q: "select=name&order=name" },
  roles: { screen: "Roles", schema: "rbac", view: "roles",
    q: "select=name,grants_all,description&order=name" },
  permissionKinds: { screen: "Roles", schema: "rbac", view: "permission_kinds",
    q: "select=resource,action,checked_by&order=resource,action" },
  rolePermissions: { screen: "Roles", schema: "rbac", view: "role_permissions",
    q: "select=role,resource,action" },
  orgMembers: { screen: "Users · Settings", schema: "rbac", view: "org_members",
    q: "select=org_id,user_id,role" },
  /* `label`, not `name`: rbac.api_keys_api has always published `label`. */
  apiKeys: { screen: "Keys", schema: "rbac", view: "api_keys_api",
    q: "select=id,label,scopes,created_at,last_used_at,revoked_at&order=created_at.desc" },
  /* `issued_at`, not `created_at`, and the ordering was wrong with it -- which
     is why the ordering belongs in the contract the audit executes. */
  refreshSessions: { screen: "Keys", schema: "rbac", view: "refresh_tokens_api",
    q: "select=id,device_label,issued_at,expires_at,revoked_at&order=issued_at.desc" },
  orgs: { screen: "Settings", schema: "rbac", view: "orgs", q: "select=id,slug,name&order=slug" },
  visibilities: { screen: "Settings", schema: "rbac", view: "visibilities",
    q: "select=scope,rank,requires_org,description&order=rank" },
  /* `event_type` and `at`: the columns rbac.auth_events actually has. */
  authEvents: { screen: "Events", schema: "rbac", view: "auth_events",
    q: "select=id,user_id,event_type,detail,at&order=at.desc" },

  /* -- agentic -------------------------------------------------------- */
  agents: { screen: "Agents", schema: "agentic", view: "agents_api",
    q: "select=name,model,tools,skills,structured_output_schema,system_prompt&order=name" },
  agentNames: { screen: "Chat", schema: "agentic", view: "agents_api", q: "select=name&order=name" },
  skills: { screen: "Agents", schema: "agentic", view: "skills_api",
    q: "select=name,description&order=name" },
  toolServers: { screen: "Agents", schema: "agentic", view: "tool_servers_api",
    q: "select=name,kind,cached_tools,synced_at&order=name" },
  plugins: { screen: "Agents", schema: "agentic", view: "plugins_api", q: "select=name&order=name" },
  chatSessions: { screen: "Chat", schema: "agentic", view: "sessions_api",
    q: "select=id,title,created_at&order=created_at.desc" },
  messages: { screen: "Chat", schema: "agentic", view: "messages_api",
    q: "select=role,content,tool_calls,is_error,seq,created_at&order=seq" },
  messageSeqs: { screen: "Chat", schema: "agentic", view: "messages_api", q: "select=seq" },
  sessionRuns: { screen: "Chat", schema: "agentic", view: "runs_api",
    q: "select=id,agent_id,status,state,trigger_kind,depth,created_at&order=created_at.desc" },
};

/* Objects no screen READS, kept in the audit as what they are.
 *
 * Existence is the whole claim here, and separating them is the point: a table
 * that is merely reachable cannot count towards "the screens work", which is
 * exactly the arithmetic that let five broken projections pass. */
export const PROBES = [
  { schema: "workflow", view: "pools", why: "written by the pool toggle (PATCH); never read as a list" },
  { schema: "content", view: "resources", why: "no screen reads it yet" },
];
