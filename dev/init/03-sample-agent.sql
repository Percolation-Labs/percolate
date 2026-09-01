-- Sample: the Percolate agent and the two tool servers it binds.
--
-- GENERATED from specs/agentic/reference/percolate.yaml by binder.py. Do not edit.
--
-- Registration only. `cached_tools` stays empty here and is filled by the
-- discovery stage (`binder.py apply`, or the scheduled re-sync), because
-- discovery is an HTTP fetch and this file runs at initdb -- before the
-- servers it names are listening, and inside a database that deliberately
-- has no HTTP client (specs/README.md: the database never blocks on HTTP).
--
-- An agent bound to a server whose tools have not been discovered yet is not
-- broken, it is unsynced: the row says which server and which tool names, and
-- the descriptions arrive when something can reach the upstream.

set role app_owner;

do $$
begin
    -- The skew check, and why it warns instead of failing.
    --
    -- This file runs at initdb against whatever schema the DATABASE IMAGE
    -- carries, and the image is built from specs/ at publish time -- so a
    -- stack pulled before this sample landed has no `default_headers` column
    -- and no `may_author`, and every statement below would abort container
    -- startup. Bricking the stack is a worse answer than not having the
    -- sample: the other four subsystems are fine.
    --
    -- So it says so, loudly, and skips. `surface.sql` is what turns the
    -- absence back into a failure at the point where a failure is useful --
    -- the same division of labour the collection already uses for the
    -- compiled parser (`workflow.compiler_capabilities()`).
    if to_regprocedure('agentic.may_author(text,regclass)') is null
       or not exists (select 1 from pg_catalog.pg_attribute
                       where attrelid = 'agentic.tool_servers'::regclass
                         and attname = 'default_headers' and not attisdropped) then
        raise warning
            'skipping the sample agent: this database image predates it '
            '(agentic.may_author and tool_servers.default_headers are both '
            'missing). Everything else installed normally. To get the sample, '
            'rebuild the image from the current specs: dev/build-image.sh';
        return;
    end if;


    perform agentic.upsert_tool_server($p8${
    "name": "p8-query",
    "kind": "mcp",
    "url": "http://query-mcp:8090",
    "emits_citations": true
}$p8$::jsonb);

    perform agentic.upsert_tool_server($p8${
    "name": "p8-workflow",
    "kind": "openapi",
    "url": "http://postgrest:3000",
    "credential_ref": "env:P8_TOKEN",
    "default_headers": {
        "Accept-Profile": "workflow",
        "Content-Profile": "workflow"
    }
}$p8$::jsonb);

    perform agentic.upsert_agent($p8${
    "name": "percolate",
    "audience": "user",
    "category": "tool_user",
    "tags": [
        "query",
        "workflow",
        "operations"
    ],
    "model": "anthropic:claude-sonnet-5",
    "system_prompt": "You are Percolate, the agent for this database. You can read what it\nknows and you can run work against it.\n\nRetrieval goes through the `query` tool, in p8ql. Its description\ncarries the grammar and the sources this deployment actually has\nregistered -- read it rather than guessing at table names. The response\nincludes the parsed plan next to the rows: when a query returns nothing,\ncheck the plan before concluding the answer is nothing.\n\nWork is a workflow. Define one from YAML, start it, and report the run\nid; do not wait on it and do not poll in a loop -- starting a run\nreturns immediately by design, and the user can be told where to look.\nCheck status by that run id, and read the per-step tasks when a run has\nfailed and the question is which step.\n\nTwo habits, both of which matter more than they look:\n\nSay which tool told you something. An answer assembled from retrieval\nis worth exactly what its sources are worth, and the user cannot judge\nthat if you present it as your own knowledge.\n\nPrefer defining a workflow to doing the work yourself. Anything with\nmore than one step, anything that should be repeatable, and anything\nthat will need to be re-run belongs in a definition where it can be\nretried, scheduled and inspected -- not in a conversation that ends.\n",
    "tools": [
        {
            "server": "p8-query",
            "tools": [
                "query"
            ]
        },
        {
            "server": "p8-workflow",
            "tools": [
                "post_rpc_define_yaml",
                "post_rpc_start_workflow",
                "post_rpc_schedule_workflow",
                "get_runs_api",
                "get_tasks_api"
            ]
        }
    ]
}$p8$::jsonb);

end $$;

reset role;
