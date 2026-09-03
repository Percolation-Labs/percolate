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
       or to_regclass('agentic.skills') is null
       or not exists (select 1 from pg_catalog.pg_attribute
                       where attrelid = 'agentic.tool_servers'::regclass
                         and attname = 'default_headers' and not attisdropped) then
        raise warning
            'skipping the sample agent: this database image predates it '
            '(agentic.may_author, agentic.skills or tool_servers.default_headers '
            'is missing). Everything else installed normally. To get the sample, '
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

    perform agentic.upsert_skill($p8${
    "name": "p8ql-schema-first",
    "category": "procedure",
    "tags": [
        "query",
        "p8ql"
    ],
    "requires_tools": [
        "p8-query"
    ],
    "description": "Start with SCHEMA before writing any other p8ql; nothing you have not read in a SCHEMA response exists.",
    "when_to_use": "Before the first query of a conversation, or whenever you are about to name a table, relation or entity type you have not seen in a SCHEMA response.",
    "content": "ALWAYS START WITH `SCHEMA`. It is the one mode answerable before you know\nanything, and it returns the index of what you may ask about; then\n`SCHEMA \"graph\"` for the entity types and the relation catalogue. This is\nnot a formality. Given a question about currencies, a model that skips it\nwrites `select * from forex_weekly_bands` -- a table that does not exist,\nin a store that is not tables -- gets an empty result, and reports back\nthat there is no data. Observed, on the first real question ever put to\nthis agent.\n\nWhat is behind the tool is a property graph: entities joined by named\nrelations, plus text and vector indexes over content. Nothing you have\nnot read in a SCHEMA response exists. Use LOOKUP to resolve a name to a\nnode, GRAPH to walk relations from it, TEXT/SEMANTIC/SEARCH for content.\nReach for plain SQL last, and only over relations SCHEMA \"sql\" listed.\n"
}$p8$::jsonb);

    perform agentic.upsert_skill($p8${
    "name": "house-style-attribution",
    "category": "style",
    "tags": [
        "style",
        "citations"
    ],
    "description": "Say which tool told you something; an answer assembled from retrieval is worth what its sources are worth.",
    "when_to_use": "Always, whenever any part of an answer came from a tool rather than from your own knowledge.",
    "content": "Say which tool told you something. An answer assembled from retrieval is\nworth exactly what its sources are worth, and the user cannot judge that\nif you present it as your own knowledge.\n"
}$p8$::jsonb);

    perform agentic.upsert_skill($p8${
    "name": "workflow-define-then-start",
    "category": "procedure",
    "tags": [
        "workflow",
        "operations"
    ],
    "requires_tools": [
        "p8-workflow"
    ],
    "description": "Define work as a YAML workflow and start a run rather than doing multi-step work in the conversation; never poll a run.",
    "when_to_use": "The task has more than one step, should be repeatable, or will need to be re-run -- or you have just started a run and are wondering whether to wait on it.",
    "content": "Work is a workflow. Define one from YAML, start it, and report the run\nid; do not wait on it and do not poll in a loop -- starting a run returns\nimmediately by design, and the user can be told where to look. Check\nstatus by that run id, and read the per-step tasks when a run has failed\nand the question is which step.\n\nPrefer defining a workflow to doing the work yourself. Anything with more\nthan one step, anything that should be repeatable, and anything that will\nneed to be re-run belongs in a definition where it can be retried,\nscheduled and inspected -- not in a conversation that ends.\n"
}$p8$::jsonb);

    perform agentic.upsert_skill($p8${
    "name": "p8ql-fuzzy-lookup",
    "category": "procedure",
    "tags": [
        "query",
        "p8ql"
    ],
    "requires_tools": [
        "p8-query"
    ],
    "description": "When a LOOKUP returns nothing, use FUZZY LOOKUP instead of guessing another spelling.",
    "when_to_use": "A LOOKUP came back empty, or you are about to try a second spelling of a name, ticker, code or identifier.",
    "content": "WHEN A LOOKUP FINDS NOTHING, USE `FUZZY LOOKUP` -- do not guess another\nspelling. The names in this store follow conventions you cannot deduce:\nasked about sterling, a model tried `sterling`, `gbp`, `gbp/usd`,\n`GBPUSD` and `fx_pair` in five separate calls and gave up, while\n`FUZZY LOOKUP \"gbp\"` returns `usd/gbp` on the first try. The schema's\nsample_keys show you the shape of a key; FUZZY closes the rest of the\ndistance. Guessing spellings is the one thing this tool is built to make\nunnecessary.\n\nA LOOKUP response separates `rows` from `unresolved`. A name in\n`unresolved` was not found -- say so, rather than answering as though the\nquestion had no data behind it.\n"
}$p8$::jsonb);

    perform agentic.upsert_skill($p8${
    "name": "p8ql-read-the-plan",
    "category": "procedure",
    "tags": [
        "query",
        "p8ql",
        "debugging"
    ],
    "requires_tools": [
        "p8-query"
    ],
    "description": "An empty result and a misparsed query look identical; read the returned plan before concluding there is no data.",
    "when_to_use": "A query returned no rows and you are about to report that the data does not exist.",
    "content": "The response includes the parsed plan next to the rows: when a query\nreturns nothing, read the plan before concluding the answer is nothing --\nan empty result and a misparsed query look identical otherwise.\n"
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
    "system_prompt": "You are Percolate, the agent for this database. You can read what it\nknows and you can run work against it.\n\nRetrieval goes through the `query` tool, in p8ql.\n",
    "skills": [
        "p8ql-schema-first",
        "house-style-attribution",
        "workflow-define-then-start"
    ],
    "context_policy": {
        "skills": {
            "match": true,
            "top_k": 2,
            "min_score": 0.28,
            "max_chars": 6000,
            "index": "bound",
            "sticky": true
        }
    },
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
