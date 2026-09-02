//! The plan graph: a compiled workflow, expanded along the entities it names.
//!
//! `workflow.definitions.spec` is a DAG of steps and nothing else. What a step
//! *reaches* -- the agent it calls, that agent's tool servers and the tools it
//! is allowed on them, the corpus a query ranks against, the model that built
//! the space it ranks in, the function a `sql` step is allow-listed to run --
//! is spread across four schemas, and the only way to see it today is to open
//! four catalogs and hold the joins in your head. Every one of those reaches is
//! a place the plan can be wrong in a way that compiles, registers and starts.
//!
//! So this expands a stored spec into ONE graph over those entities, and
//! reports the reaches that do not resolve. Two things fall out of it that are
//! hard to get any other way: **how data moves through the schema** (a step
//! reads this source, which is embedded by that model, whose space is that
//! table) and **what an agent is actually able to do** (its prompt, its
//! servers, the tools it is narrowed to, and who it may delegate to) -- intent
//! and veracity in the ticket's words.
//!
//! ## Why the graph is built in Rust and the catalog is read in SQL
//!
//! The same split `aiq_parse` already draws, for the same reason. This function
//! is pure: spec in, catalog in, graph out. It makes no query, so it is
//! `immutable` and `parallel_safe`, it can be unit-tested with no database, and
//! -- the part that matters for an agent-facing surface -- a caller can see
//! exactly what its plan was understood to mean. SQL owns the catalog because
//! that is where RLS, the planner and the indexes already live: the views
//! feeding `catalog` are ordinary views, so what a caller may SEE in a plan
//! graph is the same decision as what it may see anywhere else, taken once, by
//! Postgres, rather than re-implemented here.
//!
//! ## The p8ql steps are parsed, not pattern-matched
//!
//! A `p8ql` step's source and model are read by running the step's query
//! through `parse_query` -- the same parser that will execute it. A regex over
//! the query string would be a second, worse implementation of the dialect, and
//! the failure mode is precisely the one this module exists to catch: a graph
//! that disagrees with the executor about what a step means is a graph that
//! reports health for a plan that does something else.

use serde_json::{json, Map, Value};

// ---------------------------------------------------------------------------
// The emitted vocabulary. Both lists are CLOSED, and that is the point: a
// viewer, an audit and a diff all need to know every kind that can appear, and
// an open vocabulary becomes a synonym pile within a month (the same argument
// agentic.agents.category settles the same way).
// ---------------------------------------------------------------------------

/// Node kinds. `lane` groups them for a layout that has not been written yet.
fn lane_of(kind: &str) -> &'static str {
    match kind {
        "workflow" => "workflow",
        "step" => "step",
        // Things the deployment configures, which a step reaches THROUGH.
        "agent" | "tool_server" | "tool" | "function" | "llm" => "capability",
        // Things data lives in or is measured against.
        "source" | "model" | "space" | "entity" => "data",
        // Things that decide whether a task ever runs.
        "queue" | "rate_key" | "signal" => "control",
        _ => "other",
    }
}

struct Graph {
    nodes: Map<String, Value>,
    edges: Vec<Value>,
    defects: Vec<Value>,
}

impl Graph {
    fn new() -> Self {
        Graph { nodes: Map::new(), edges: Vec::new(), defects: Vec::new() }
    }

    /// Add a node, or return the existing one. Ids are `kind:name`, so the same
    /// agent named by three steps is one node with three edges into it -- which
    /// is the whole reason this is a graph and not a tree.
    fn node(&mut self, kind: &str, name: &str, extra: Value) -> String {
        let id = format!("{kind}:{name}");
        if !self.nodes.contains_key(&id) {
            let mut n = json!({
                "id": id, "kind": kind, "name": name,
                "label": name, "lane": lane_of(kind),
            });
            if let Value::Object(m) = extra {
                for (k, v) in m {
                    n[k] = v;
                }
            }
            self.nodes.insert(id.clone(), n);
        }
        id
    }

    fn edge(&mut self, from: &str, to: &str, kind: &str) {
        let e = json!({"from": from, "to": to, "kind": kind});
        if !self.edges.contains(&e) {
            self.edges.push(e);
        }
    }

    /// A defect names the node it is about, what is wrong, and what happens if
    /// it is left alone. The third field is not decoration: "unknown queue" is
    /// a shrug, "nothing sizes a pool for this queue, so the task waits for a
    /// worker that autoscaling will never start" is a decision.
    fn defect(&mut self, severity: &str, code: &str, node: &str, message: &str, consequence: &str) {
        self.defects.push(json!({
            "severity": severity, "code": code, "node": node,
            "message": message, "consequence": consequence,
        }));
    }
}

// ---------------------------------------------------------------------------
// Catalog access. Every lookup is total -- a missing catalog section means the
// subsystem is not installed, and an absent subsystem must not turn every
// reference into a defect. `known()` is what separates "this deployment has no
// agentic schema" from "this deployment has one and your agent is not in it".
// ---------------------------------------------------------------------------

fn section<'a>(catalog: &'a Value, name: &str) -> Option<&'a Map<String, Value>> {
    catalog.get(name).and_then(Value::as_object)
}

fn list<'a>(catalog: &'a Value, name: &str) -> Vec<&'a str> {
    catalog
        .get(name)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

// ---------------------------------------------------------------------------
// Step classification.
//
// A compiled step's KIND is not enough to know what it reaches: the compiler
// turns an `agent:` step into an ordinary `http_call` at the Agent Runtime, and
// an `embed:` step into an `http_call` at a model endpoint. Both keep the thing
// they were: an agent step carries `body.model` (the agent's NAME -- the
// runtime's OpenAI-shaped wire format calls it model) and an expanded embed
// step keeps its `embed` block with the model resolved into it. Reading those
// back is what makes the graph show an agent rather than a POST.
// ---------------------------------------------------------------------------

fn agent_of(input: &Value) -> Option<String> {
    // The marker is the agent-runtime url the compiler wrote -- `P8_AGENT_URL`
    // and nothing else.
    //
    // FOUND BY RUNNING IT. This also matched any url ending
    // `/v1/chat/completions`, on the reasoning that the runtime is
    // OpenAI-shaped. The dev stack's own `ask_uploads` is a `rest:` step
    // straight at `https://api.openai.com/v1/chat/completions` whose
    // `body.model` is `gpt-4o-mini` -- a MODEL name, not an agent -- and the
    // graph reported `unknown_agent: gpt-4o-mini` against a step that is
    // completely correct. A checker that invents defects is worse than no
    // checker, because the first false positive is what teaches a reader to
    // skip the report.
    //
    // The cost of the narrow test is a spec written as JSON that names the
    // runtime url literally: it draws as an ordinary external server rather
    // than as an agent. That is the right way to be wrong -- it understates
    // what it knows instead of asserting something false.
    let url = input.get("url").and_then(Value::as_str).unwrap_or("");
    if url.contains("P8_AGENT_URL") {
        return input.pointer("/body/model").and_then(Value::as_str).map(str::to_string);
    }
    None
}

fn embed_model_of(input: &Value) -> Option<String> {
    input.pointer("/embed/model").and_then(Value::as_str).map(str::to_string)
}

/// The host part of a url, for a `rest:` step that reaches something this
/// collection knows nothing about. Deliberately not the full url: the graph
/// groups every call to one host onto one node, and a url carrying a
/// `{{template}}` is not a url yet.
fn endpoint_of(url: &str) -> String {
    let after_scheme = url.split("://").nth(1).unwrap_or(url);
    after_scheme.split('/').next().unwrap_or(after_scheme).to_string()
}

// ---------------------------------------------------------------------------
// The builder.
// ---------------------------------------------------------------------------

pub fn plan_graph(spec: &Value, catalog: &Value) -> Value {
    let mut g = Graph::new();

    let steps = match spec.get("steps").and_then(Value::as_array) {
        Some(s) if !s.is_empty() => s.clone(),
        _ => {
            return json!({
                "ok": false,
                "error": "spec has no steps -- pass workflow.definitions.spec, \
                          which is {\"steps\": [...]}",
            })
        }
    };

    let wf_name = str_of(spec, "name").unwrap_or_else(|| "(unnamed)".into());
    let wf_version = spec.get("version").and_then(Value::as_i64).unwrap_or(1);
    let wf_id = g.node(
        "workflow",
        &wf_name,
        json!({"version": wf_version, "label": format!("{wf_name} v{wf_version}")}),
    );

    // Pass 1: the steps themselves, so a `needs` edge can point at a node that
    // already exists and a dangling one is visible as a dangling one.
    let mut keys: Vec<String> = Vec::new();
    for s in &steps {
        if let Some(k) = str_of(s, "key") {
            keys.push(k);
        }
    }

    for s in &steps {
        let key = match str_of(s, "key") {
            Some(k) => k,
            None => continue,
        };
        let kind = str_of(s, "kind").unwrap_or_else(|| "unknown".into());
        let queue = str_of(s, "queue").unwrap_or_else(|| "none".into());
        let empty = json!({});
        let input = s.get("input").unwrap_or(&empty);

        let step_id = g.node(
            "step",
            &key,
            json!({
                "step_kind": kind,
                "queue": queue,
                // The join a viewer needs to colour this node with live state:
                // workflow.tasks is keyed (run_id, step_key), so an overlay is
                // a join rather than a second graph. See plan-graph.md §6.
                "step_key": key,
                "saga_group": s.get("saga_group").cloned().unwrap_or(Value::Null),
            }),
        );
        g.edge(&wf_id, &step_id, "contains");

        // ---- the DAG proper ------------------------------------------------
        for d in s.get("depends_on").and_then(Value::as_array).into_iter().flatten() {
            if let Some(d) = d.as_str() {
                if keys.iter().any(|k| k == d) {
                    g.edge(&format!("step:{d}"), &step_id, "needs");
                } else {
                    g.defect(
                        "error", "dangling_dependency", &step_id,
                        &format!("step '{key}' depends on '{d}', which is not a step in this spec"),
                        "the step is never ready, and the run stalls with no failure to report",
                    );
                }
            }
        }
        if let Some(c) = str_of(s, "compensation_task_key") {
            if keys.iter().any(|k| *k == c) {
                g.edge(&step_id, &format!("step:{c}"), "compensated_by");
            }
        }

        // ---- what the step reaches ----------------------------------------
        match kind.as_str() {
            "sql" => classify_sql(&mut g, &step_id, &key, input, catalog),
            "http_call" => classify_http(&mut g, &step_id, input, catalog),
            "agent" => {
                // The engine's own kind, for a spec written as JSON rather than
                // compiled from YAML. Same handling; the name is in the open.
                if let Some(a) = str_of(input, "agent") {
                    let aid = expand_agent(&mut g, &a, catalog, 0);
                    g.edge(&step_id, &aid, "calls");
                }
            }
            "matrix" => classify_matrix(&mut g, &step_id, &key, input, catalog),
            "signal" => {
                let name = str_of(input, "signal").unwrap_or_else(|| key.clone());
                let sid = g.node("signal", &name, json!({
                    "label": format!("{name} (a person)"),
                }));
                g.edge(&step_id, &sid, "waits_for");
            }
            "sub_workflow" => {
                let target = str_of(input, "workflow")
                    .or_else(|| str_of(input, "name"));
                if let Some(t) = target {
                    let tid = g.node("workflow", &t, json!({"external": true}));
                    g.edge(&step_id, &tid, "invokes");
                    if !list(catalog, "workflows").contains(&t.as_str()) {
                        g.defect(
                            "error", "unknown_sub_workflow", &tid,
                            &format!("step '{key}' runs workflow '{t}', which is not defined here"),
                            "start_workflow raises at dispatch, so the parent fails at the \
                             point of the call rather than at registration",
                        );
                    }
                }
            }
            // `timer` and `work` reach nothing outside the engine. A timer's
            // wait is a property of the step and a `work` step is, by
            // definition, code this collection did not write -- the queue edge
            // below is the only thing either has to say.
            _ => {}
        }

        // ---- what decides whether it is ever claimed -----------------------
        if queue != "none" {
            let qid = g.node("queue", &queue, json!({}));
            g.edge(&step_id, &qid, "claimed_from");
            if !list(catalog, "queues").contains(&queue.as_str()) {
                g.defect(
                    "warning", "unconfigured_queue", &qid,
                    &format!("step '{key}' is claimed from queue '{queue}', which has no \
                              workflow.queue_config row"),
                    "the reaper falls back to a default lease and no autoscaler is sizing \
                     this pool, so a stalled worker holds the task for the default timeout",
                );
            }
        }
        if let Some(rk) = str_of(s, "rate_key") {
            let rid = g.node("rate_key", &rk, json!({}));
            g.edge(&step_id, &rid, "throttled_by");
            if !list(catalog, "rate_keys").contains(&rk.as_str()) {
                g.defect(
                    "error", "unknown_rate_key", &rid,
                    &format!("step '{key}' consumes rate key '{rk}', which has no \
                              workflow.rate_limits row"),
                    "try_consume_rate_limit updates no row and returns false, so claim_task \
                     skips this task FOREVER -- an unthrottled step would have run; an \
                     unknown throttle never runs at all",
                );
            }
        }
    }

    rank_steps(&mut g, &steps);

    let (errors, warnings) = g.defects.iter().fold((0, 0), |(e, w), d| {
        match d.get("severity").and_then(Value::as_str) {
            Some("error") => (e + 1, w),
            _ => (e, w + 1),
        }
    });

    json!({
        "ok": true,
        "workflow": {"name": wf_name, "version": wf_version},
        "nodes": g.nodes.values().cloned().collect::<Vec<_>>(),
        "edges": g.edges,
        "defects": g.defects,
        "stats": {
            "nodes": g.nodes.len(),
            "edges": g.edges.len(),
            "steps": steps.len(),
            "errors": errors,
            "warnings": warnings,
        },
    })
}

// ---------------------------------------------------------------------------
// `sql` steps -- the ones that run inside Postgres, and the only kind whose
// data flow is visible without leaving the database.
// ---------------------------------------------------------------------------

fn classify_sql(g: &mut Graph, step_id: &str, key: &str, input: &Value, catalog: &Value) {
    let func = match str_of(input, "function") {
        Some(f) => f,
        None => return,
    };
    let fid = g.node("function", &func, json!({}));
    g.edge(step_id, &fid, "calls");

    match section(catalog, "functions") {
        Some(fns) if !fns.contains_key(&func) => g.defect(
            "error", "unknown_function", &fid,
            &format!("step '{key}' calls '{func}', which is not in workflow.step_functions"),
            "execute_sql_step raises 'step function not registered' on dispatch -- the \
             allow-list is the point, so this is a plan that cannot run, not a plan that \
             runs unsafely",
        ),
        Some(fns) => {
            if let Some(f) = fns.get(&func) {
                if let (Some(target), Some(n)) =
                    (f.get("fn").and_then(Value::as_str), g.nodes.get_mut(&fid))
                {
                    n["target"] = json!(target);
                }
            }
        }
        None => {}
    }

    // A p8ql step is the one kind that says, in the document, which data it
    // reads. Parsed rather than matched -- see the module header.
    if func == "p8ql" || func == "p8ql_vec" {
        if let Some(q) = input.pointer("/args/0").and_then(Value::as_str) {
            query_reaches(g, step_id, key, q, catalog);
        }
    }
}

/// The data half: a query names a source, and in a vector mode a model. Both
/// become nodes, and the pair is where the highest-value defect in this module
/// lives -- see `space_model_split`.
fn query_reaches(g: &mut Graph, step_id: &str, key: &str, query: &str, catalog: &Value) {
    let parsed = match crate::parse_query(query) {
        Ok(p) => p,
        Err(_) => {
            // A stored spec whose query does not parse is a real defect, but it
            // is the p8ql lint's to report with a proper message; saying it
            // twice in two vocabularies helps nobody.
            return;
        }
    };
    if let Some(n) = g.nodes.get_mut(step_id) {
        n["query_mode"] = json!(parsed.mode);
    }

    let source = match &parsed.source {
        Some(s) => s.clone(),
        None => return,
    };
    let sources = section(catalog, "sources");
    let known = sources.and_then(|m| m.get(&source));
    let sid = g.node("source", &source, json!({
        "table": known.and_then(|k| str_of(k, "table")),
    }));
    g.edge(step_id, &sid, "reads");

    if sources.is_some() && known.is_none() {
        g.defect(
            "error", "unknown_source", &sid,
            &format!("step '{key}' queries '{source}', which is registered as neither a \
                      semantic nor a lexical source"),
            "the query returns zero rows rather than raising, which is indistinguishable \
             from a corpus that has nothing to say",
        );
        return;
    }

    // Vector modes only: a lexical TEXT query ranks in no space and needs no
    // model, and reporting a missing model for it would be noise.
    let vector_mode = matches!(parsed.mode.as_str(), "SEMANTIC" | "SEARCH");
    if !vector_mode {
        return;
    }

    let model = parsed.model.clone().or_else(|| {
        section(catalog, "models").and_then(|ms| {
            ms.iter()
                .find(|(_, v)| v.get("is_default").and_then(Value::as_bool).unwrap_or(false))
                .map(|(k, _)| k.clone())
        })
    });
    let model = match model {
        Some(m) => m,
        None => return,
    };
    let mid = g.node("model", &model, json!({}));
    g.edge(&sid, &mid, "ranked_in");
    g.edge(step_id, &mid, "embeds_with");

    let models = section(catalog, "models");
    if models.is_some() && models.unwrap().get(&model).is_none() {
        g.defect(
            "error", "unknown_model", &mid,
            &format!("step '{key}' ranks against model '{model}', which is not in \
                      aiq.embedding_models"),
            "there is no space table to rank in, so the query raises at dispatch",
        );
        return;
    }

    // THE ONE THIS MODULE IS FOR.
    //
    // A corpus is embedded per model, one space table each. A query that ranks
    // a source in a space that source has no rows in is not an error anywhere:
    // cosine distance between a vector and an empty table is no rows, and
    // between two spaces is a number -- just a meaningless one. The compiler
    // closes the sugar path by pinning one model into both halves; it cannot
    // close the hand-written path, where the embed step and the query are two
    // steps an author wrote separately. This is that path, seen before it runs.
    if let Some(k) = known {
        let spaces: Vec<&str> = k
            .get("spaces")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        if spaces.is_empty() {
            // Registered, and holding no vectors in any space. Ranking it is
            // not WRONG, it is early -- a corpus that has not been embedded
            // yet answers nothing, and a deployment mid-backfill is the
            // ordinary way to be in this state. Reported so that "the search
            // returns nothing" has an answer, at the severity that says so.
            g.defect(
                "warning", "corpus_not_embedded", &sid,
                &format!("step '{key}' ranks '{source}', which has no vectors in any \
                          registered space"),
                "the query returns zero rows until something embeds this corpus -- which \
                 is indistinguishable, from the caller's side, from a corpus with nothing \
                 to say",
            );
        } else if !spaces.contains(&model.as_str()) {
            g.defect(
                "error", "space_model_split", &sid,
                &format!("step '{key}' ranks '{source}' against '{model}', but that corpus \
                          is embedded in: {}", spaces.join(", ")),
                "the query returns rows ranked in a space this corpus was never embedded \
                 into -- a number rather than an error, and the failure the compiler's \
                 pinned-model rule exists to prevent on the sugar path",
            );
        }
    }
}

// ---------------------------------------------------------------------------
// `http_call` steps -- an agent, an embedding, or something outside.
// ---------------------------------------------------------------------------

fn classify_http(g: &mut Graph, step_id: &str, input: &Value, catalog: &Value) {
    if let Some(agent) = agent_of(input) {
        let aid = expand_agent(g, &agent, catalog, 0);
        g.edge(step_id, &aid, "calls");
        if input.get("output_schema").is_some() {
            if let Some(n) = g.nodes.get_mut(step_id) {
                n["declares_output_schema"] = json!(true);
            }
        }
        return;
    }
    if let Some(model) = embed_model_of(input) {
        let mid = g.node("model", &model, json!({}));
        g.edge(step_id, &mid, "embeds_with");
        let models = section(catalog, "models");
        if let Some(ms) = models {
            match ms.get(&model) {
                None => g.defect(
                    "error", "unknown_model", &mid,
                    &format!("an embed step resolves model '{model}', which is not in \
                              aiq.embedding_models"),
                    "the worker has no endpoint to call and the task fails on every attempt",
                ),
                Some(m) if !m.get("space_exists").and_then(Value::as_bool).unwrap_or(true) => g
                    .defect(
                        "warning", "no_space", &mid,
                        &format!("model '{model}' is registered and has no space table"),
                        "embedding succeeds and nothing can be ranked in it until \
                         aiq.register_embedding_space('{model}') has been run",
                    ),
                _ => {}
            }
        }
        return;
    }
    if let Some(url) = input.get("url").and_then(Value::as_str) {
        let host = endpoint_of(url);
        let eid = g.node("tool_server", &host, json!({"external": true, "url": url}));
        g.edge(step_id, &eid, "calls");
        if input.get("credential_ref").is_none() {
            if let Some(n) = g.nodes.get_mut(&eid) {
                n["anonymous"] = json!(true);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// `matrix` steps -- a fan-out is one authored step and N runtime tasks, so the
// graph shows the TEMPLATE as its own node. Drawing N children would be a lie
// about a number nobody knows until the rows are counted.
// ---------------------------------------------------------------------------

fn classify_matrix(g: &mut Graph, step_id: &str, key: &str, input: &Value, catalog: &Value) {
    if let Some(rows) = input.pointer("/rows/function").and_then(Value::as_str) {
        let fid = g.node("function", rows, json!({}));
        g.edge(step_id, &fid, "expands_over");
        if let Some(fns) = section(catalog, "functions") {
            if !fns.contains_key(rows) {
                g.defect(
                    "error", "unknown_function", &fid,
                    &format!("matrix step '{key}' expands over '{rows}', which is not in \
                              workflow.step_functions"),
                    "expand_matrix raises when the parent completes, so the fan-out fails \
                     at the moment the work it was waiting for succeeded",
                );
            }
        }
    }
    let empty = json!({});
    let tinput = input.pointer("/template/input").unwrap_or(&empty);
    let tkind = input.pointer("/template/kind").and_then(Value::as_str).unwrap_or("");
    let tid = g.node(
        "step",
        &format!("{key}\u{2009}template"),
        json!({"step_kind": tkind, "template_of": key, "label": format!("{key} · each row")}),
    );
    g.edge(step_id, &tid, "expands_to");
    match tkind {
        "sql" => classify_sql(g, &tid, key, tinput, catalog),
        "http_call" => classify_http(g, &tid, tinput, catalog),
        _ => {}
    }
    if let Some(q) = input.pointer("/template/queue").and_then(Value::as_str) {
        if q != "none" {
            let qid = g.node("queue", q, json!({}));
            g.edge(&tid, &qid, "claimed_from");
        }
    }
}

// ---------------------------------------------------------------------------
// Agents -- the expansion the ticket is mostly about.
//
// An agent is a row, its tools are bindings to registered servers, and an
// allow-list narrows which tools on each. Delegation is the same shape one
// level up: the agent gateway is an ordinary tool server whose TOOLS ARE
// AGENTS, so following it is how "who may this agent hand work to" becomes an
// edge rather than a convention.
// ---------------------------------------------------------------------------

const MAX_DELEGATION_DEPTH: usize = 4;

fn expand_agent(g: &mut Graph, name: &str, catalog: &Value, depth: usize) -> String {
    let agents = section(catalog, "agents");
    let row = agents.and_then(|m| m.get(name));

    let aid = g.node(
        "agent",
        name,
        json!({
            "category": row.and_then(|r| str_of(r, "category")),
            "audience": row.and_then(|r| str_of(r, "audience")),
            "model": row.and_then(|r| str_of(r, "model")),
            // The prompt is what an agent's intent actually IS, and a graph
            // that omits it makes every agent look alike. Truncated by the
            // view, not here -- see plan-graph.md §4.
            "intent": row.and_then(|r| str_of(r, "intent")),
            "structured_output": row
                .and_then(|r| r.get("has_output_schema"))
                .cloned()
                .unwrap_or(Value::Null),
        }),
    );

    // Already expanded (the same agent called by two steps, or a delegation
    // cycle). Expanding again would duplicate every edge and, in the cycle
    // case, not terminate.
    if g.nodes.get(&aid).and_then(|n| n.get("expanded")).is_some() {
        return aid;
    }

    if agents.is_some() && row.is_none() {
        g.defect(
            "error", "unknown_agent", &aid,
            &format!("agent '{name}' has no row in agentic.agents"),
            "the Agent Runtime returns 404 for every call, so the step exhausts its retries \
             and the run fails on a name that was never going to resolve",
        );
        return aid;
    }
    let row = match row {
        Some(r) => r.clone(),
        None => return aid,
    };
    if let Some(n) = g.nodes.get_mut(&aid) {
        n["expanded"] = json!(true);
    }

    if let Some(m) = str_of(&row, "model") {
        let mid = g.node("llm", &m, json!({}));
        g.edge(&aid, &mid, "runs_on");
    }
    if let Some(s) = str_of(&row, "summarizer") {
        let sid = expand_agent(g, &s, catalog, depth + 1);
        g.edge(&aid, &sid, "summarised_by");
    }

    let servers = section(catalog, "servers");
    for binding in row.get("tools").and_then(Value::as_array).into_iter().flatten() {
        let server = match str_of(binding, "server") {
            Some(s) => s,
            None => continue,
        };
        let srow = servers.and_then(|m| m.get(&server));
        let sid = g.node(
            "tool_server",
            &server,
            json!({
                "server_kind": srow.and_then(|r| str_of(r, "kind")),
                "url": srow.and_then(|r| str_of(r, "url")),
                "emits_citations": srow
                    .and_then(|r| r.get("emits_citations")).cloned().unwrap_or(Value::Null),
                "serves_agents": srow
                    .and_then(|r| r.get("serves_agents")).cloned().unwrap_or(Value::Null),
            }),
        );
        g.edge(&aid, &sid, "binds");

        if servers.is_some() && srow.is_none() {
            g.defect(
                "error", "unregistered_server", &sid,
                &format!("agent '{name}' binds tool server '{server}', which has no row in \
                          agentic.tool_servers"),
                "the runtime resolves no tools from it, so the agent runs with a strictly \
                 smaller toolset than its definition claims and answers anyway",
            );
            continue;
        }
        let srow = srow.unwrap();
        let serves_agents = srow
            .get("serves_agents").and_then(Value::as_bool).unwrap_or(false);
        let available: Vec<&str> = srow
            .get("tools").and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let synced = srow.get("synced_at").map(|v| !v.is_null()).unwrap_or(false);

        // A null allow-list means every tool the server exposes, which is the
        // registration's default and NOT the same as an empty list.
        let allowed: Option<Vec<String>> = binding
            .get("tools")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect());

        let names: Vec<String> = match &allowed {
            Some(list) => list.clone(),
            None => available.iter().map(|s| s.to_string()).collect(),
        };

        for t in names {
            if serves_agents {
                // The tools of the agent gateway ARE agents, so this edge is a
                // delegation and the target is expanded like any other agent.
                if depth >= MAX_DELEGATION_DEPTH {
                    g.defect(
                        "warning", "delegation_depth", &aid,
                        &format!("delegation from '{name}' was not followed past depth {depth}"),
                        "the graph is truncated here; a cycle is legal at runtime and this \
                         is not evidence of one",
                    );
                    continue;
                }
                let tid = expand_agent(g, &t, catalog, depth + 1);
                g.edge(&aid, &tid, "delegates_to");
                continue;
            }
            let tid = g.node("tool", &format!("{server}/{t}"), json!({
                "label": t, "server": server,
            }));
            g.edge(&sid, &tid, "exposes");
            g.edge(&aid, &tid, "may_call");

            if allowed.is_some() && !available.is_empty() && !available.contains(&t.as_str()) {
                g.defect(
                    "warning", "unbound_tool", &tid,
                    &format!("agent '{name}' is allowed tool '{t}' on '{server}', which that \
                              server's synced tool list does not contain"),
                    "the runtime hands the model a tool the server will not answer, and a \
                     stale cached_tools is the other explanation -- re-sync before \
                     believing this one",
                );
            }
        }

        if !synced {
            g.defect(
                "warning", "unsynced_server", &sid,
                &format!("tool server '{server}' has never been synced"),
                "cached_tools is empty, so every tool this agent may call is unverifiable \
                 and an allow-list cannot be checked against anything",
            );
        }
    }
    aid
}

// ---------------------------------------------------------------------------
// Layout. `rank` is the longest path from a root, which is the only ordering a
// DAG viewer needs and the one a reader already has in their head: rank 0 is
// what starts, rank n is what waits for everything before it.
// ---------------------------------------------------------------------------

fn rank_steps(g: &mut Graph, steps: &[Value]) {
    let mut rank: Map<String, Value> = Map::new();
    // Longest-path ranking by relaxation. Bounded by step count because the
    // spec is acyclic -- validate_spec refuses a cycle at registration -- and
    // capped anyway so a spec that reached the table another way cannot spin.
    for s in steps {
        if let Some(k) = s.get("key").and_then(Value::as_str) {
            rank.insert(k.to_string(), json!(0));
        }
    }
    for _ in 0..steps.len() {
        let mut changed = false;
        for s in steps {
            let key = match s.get("key").and_then(Value::as_str) {
                Some(k) => k,
                None => continue,
            };
            let mut want = 0i64;
            for d in s.get("depends_on").and_then(Value::as_array).into_iter().flatten() {
                if let Some(d) = d.as_str() {
                    if let Some(r) = rank.get(d).and_then(Value::as_i64) {
                        want = want.max(r + 1);
                    }
                }
            }
            if rank.get(key).and_then(Value::as_i64).unwrap_or(0) < want {
                rank.insert(key.to_string(), json!(want));
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    for (k, r) in rank {
        if let Some(n) = g.nodes.get_mut(&format!("step:{k}")) {
            n["rank"] = r;
        }
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Value {
        json!({
            "agents": {
                "triage_bot": {"category": "classifier", "audience": "user",
                               "model": "claude-sonnet-5", "intent": "Classify an outage report.",
                               "has_output_schema": true,
                               "tools": [{"server": "p8-query", "tools": ["semantic_search"]}]},
                "researcher": {"category": "general", "audience": "user",
                               "tools": [{"server": "p8-agents", "tools": ["triage_bot"]}]}
            },
            "servers": {
                "p8-query": {"kind": "mcp", "url": "http://mcp:8000", "emits_citations": true,
                             "serves_agents": false, "synced_at": "2026-09-01T00:00:00Z",
                             "tools": ["semantic_search", "graph_walk"]},
                "p8-agents": {"kind": "mcp", "url": "http://runtime:8080", "serves_agents": true,
                              "synced_at": "2026-09-01T00:00:00Z", "tools": ["triage_bot"]}
            },
            "functions": {"p8ql": {"fn": "workflow.p8ql"},
                          "p8ql_vec": {"fn": "workflow.p8ql"},
                          "unextracted": {"fn": "content.unextracted"}},
            "sources": {"chunks": {"table": "content.resource_chunks",
                                   "spaces": ["nomic-embed-text"]}},
            "models": {"nomic-embed-text": {"dim": 768, "is_default": true, "space_exists": true},
                       "text-embedding-3-small": {"dim": 1536, "space_exists": false}},
            "queues": ["http", "default"],
            "rate_keys": ["openai"],
            "workflows": ["reindex"]
        })
    }

    fn spec_of(steps: Value) -> Value {
        json!({"name": "triage", "version": 2, "steps": steps})
    }

    fn find<'a>(g: &'a Value, id: &str) -> Option<&'a Value> {
        g["nodes"].as_array().unwrap().iter().find(|n| n["id"] == id)
    }

    fn codes(g: &Value) -> Vec<String> {
        g["defects"].as_array().unwrap().iter()
            .map(|d| d["code"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn empty_spec_is_refused_rather_than_returning_an_empty_graph() {
        let g = plan_graph(&json!({"steps": []}), &catalog());
        assert_eq!(g["ok"], json!(false));
    }

    #[test]
    fn a_step_reaches_its_agent_its_servers_and_the_tools_it_is_narrowed_to() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "classify", "kind": "http_call", "queue": "http",
                "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                          "body": {"model": "triage_bot"}}
            }])),
            &catalog(),
        );
        assert!(find(&g, "agent:triage_bot").is_some(), "the agent is a node");
        assert!(find(&g, "tool_server:p8-query").is_some(), "its server is a node");
        assert!(find(&g, "tool:p8-query/semantic_search").is_some(), "its allowed tool is a node");
        // The tool it is NOT allowed is on the server and not on the agent.
        assert!(find(&g, "tool:p8-query/graph_walk").is_none(),
                "an allow-list that admits every tool would make the narrowing invisible");
        assert_eq!(g["stats"]["errors"], json!(0));
    }

    #[test]
    fn delegation_is_followed_through_the_agent_gateway() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "research", "kind": "http_call", "queue": "http",
                "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                          "body": {"model": "researcher"}}
            }])),
            &catalog(),
        );
        let e = g["edges"].as_array().unwrap();
        assert!(e.contains(&json!({"from": "agent:researcher", "to": "agent:triage_bot",
                                   "kind": "delegates_to"})),
                "a gateway server's tools are agents, so the edge is a delegation");
        assert!(find(&g, "tool:p8-agents/triage_bot").is_none(),
                "and NOT also a tool, which would double-count the same reach");
    }

    #[test]
    fn a_rest_step_at_someone_elses_completions_api_is_not_an_agent() {
        // The dev stack's own ask_uploads, which reported unknown_agent until
        // agent_of stopped matching on the url SHAPE. body.model here is a
        // model name and there is no row anywhere that should have it.
        let g = plan_graph(
            &spec_of(json!([{
                "key": "answer", "kind": "http_call", "queue": "http",
                "input": {"url": "https://api.openai.com/v1/chat/completions",
                          "credential_ref": "LLM_API_KEY",
                          "body": {"model": "gpt-4o-mini"}}
            }])),
            &catalog(),
        );
        assert!(find(&g, "agent:gpt-4o-mini").is_none(), "a model name is not an agent");
        assert!(find(&g, "tool_server:api.openai.com").is_some(),
                "it is an external endpoint, drawn as one");
        assert_eq!(g["stats"]["errors"], json!(0));
    }

    #[test]
    fn a_query_step_reaches_the_corpus_and_the_space_it_ranks_in() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "retrieve", "kind": "sql", "queue": "none",
                "input": {"function": "p8ql_vec",
                          "args": ["SEARCH \"outage\" FROM chunks USING nomic-embed-text"]}
            }])),
            &catalog(),
        );
        assert_eq!(find(&g, "step:retrieve").unwrap()["query_mode"], json!("SEARCH"));
        assert!(find(&g, "source:chunks").is_some());
        let e = g["edges"].as_array().unwrap();
        assert!(e.contains(&json!({"from": "source:chunks", "to": "model:nomic-embed-text",
                                   "kind": "ranked_in"})));
        assert_eq!(g["stats"]["errors"], json!(0));
    }

    #[test]
    fn ranking_a_corpus_in_a_space_it_was_never_embedded_into_is_an_error() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "retrieve", "kind": "sql", "queue": "none",
                "input": {"function": "p8ql_vec",
                          "args": ["SEARCH \"outage\" FROM chunks USING text-embedding-3-small"]}
            }])),
            &catalog(),
        );
        assert!(codes(&g).contains(&"space_model_split".to_string()),
                "the hand-written pair is the path the compiler cannot close");
    }

    #[test]
    fn a_rate_key_with_no_row_is_an_error_because_the_task_never_gets_claimed() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "call", "kind": "http_call", "queue": "http",
                "rate_key": "anthropic",
                "input": {"url": "https://api.example.com/v1/x"}
            }])),
            &catalog(),
        );
        assert!(codes(&g).contains(&"unknown_rate_key".to_string()));
        assert_eq!(g["stats"]["errors"], json!(1));
    }

    #[test]
    fn an_unknown_agent_is_an_error_and_an_unconfigured_queue_is_a_warning() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "classify", "kind": "http_call", "queue": "gpu",
                "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                          "body": {"model": "nobody"}}
            }])),
            &catalog(),
        );
        assert!(codes(&g).contains(&"unknown_agent".to_string()));
        assert!(codes(&g).contains(&"unconfigured_queue".to_string()));
        assert_eq!(g["stats"]["errors"], json!(1));
        assert_eq!(g["stats"]["warnings"], json!(1));
    }

    #[test]
    fn a_matrix_shows_its_template_once_rather_than_n_children() {
        let g = plan_graph(
            &spec_of(json!([{
                "key": "extract", "kind": "matrix", "queue": "none",
                "input": {"max_fanout": 500,
                          "rows": {"function": "unextracted", "args": []},
                          "template": {"kind": "sql", "queue": "none",
                                       "input": {"function": "p8ql",
                                                 "args": ["LOOKUP \"{{item.name}}\""]}}}
            }])),
            &catalog(),
        );
        assert!(find(&g, "step:extract\u{2009}template").is_some());
        let e = g["edges"].as_array().unwrap();
        assert!(e.contains(&json!({"from": "step:extract", "to": "function:unextracted",
                                   "kind": "expands_over"})));
    }

    #[test]
    fn rank_is_the_longest_path_so_a_join_sits_after_both_of_its_inputs() {
        let g = plan_graph(
            &spec_of(json!([
                {"key": "a", "kind": "sql", "queue": "none", "input": {"function": "p8ql",
                    "args": ["LOOKUP \"x\""]}},
                {"key": "b", "kind": "sql", "queue": "none", "depends_on": ["a"],
                 "input": {"function": "p8ql", "args": ["LOOKUP \"y\""]}},
                {"key": "c", "kind": "sql", "queue": "none", "depends_on": ["a", "b"],
                 "input": {"function": "p8ql", "args": ["LOOKUP \"z\""]}}
            ])),
            &catalog(),
        );
        assert_eq!(find(&g, "step:a").unwrap()["rank"], json!(0));
        assert_eq!(find(&g, "step:b").unwrap()["rank"], json!(1));
        assert_eq!(find(&g, "step:c").unwrap()["rank"], json!(2));
    }

    #[test]
    fn a_signal_step_is_a_node_because_a_person_is_part_of_the_plan() {
        let g = plan_graph(
            &spec_of(json!([{"key": "approve", "kind": "signal", "queue": "none",
                             "input": {"signal": "approve"}}])),
            &catalog(),
        );
        assert!(find(&g, "signal:approve").is_some());
    }

    #[test]
    fn an_absent_subsystem_is_not_a_defect() {
        // No `agents` section at all: agentic is not installed. Every agent
        // reference must still draw, and none of them may be reported missing.
        let g = plan_graph(
            &spec_of(json!([{
                "key": "classify", "kind": "http_call", "queue": "http",
                "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                          "body": {"model": "triage_bot"}}
            }])),
            &json!({"queues": ["http"], "rate_keys": [], "workflows": []}),
        );
        assert!(find(&g, "agent:triage_bot").is_some());
        assert_eq!(g["stats"]["errors"], json!(0));
    }
}
