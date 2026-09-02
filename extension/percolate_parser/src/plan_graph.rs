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
        "source" | "model" | "space" | "entity" | "relation" => "data",
        // Things that decide whether a task ever runs.
        "queue" | "rate_key" | "signal" => "control",
        _ => "other",
    }
}

struct Graph {
    nodes: Map<String, Value>,
    edges: Vec<Value>,
    defects: Vec<Value>,
    /// The step being expanded, so a defect about a SHARED node can say whose
    /// use of it is at fault. Two steps on one queue produce two
    /// `unconfigured_queue` defects against one node, and without this the
    /// document hung both on whichever step reached the queue first.
    step: Option<String>,
}

impl Graph {
    fn new() -> Self {
        Graph { nodes: Map::new(), edges: Vec::new(), defects: Vec::new(), step: None }
    }

    /// Add a node, or return the existing one. Ids are `kind:name`, so the same
    /// agent named by three steps is one node with three edges into it -- which
    /// is the whole reason this is a graph and not a tree.
    ///
    /// `extra` carries the node's own fields; `detail` is the catalog entry it
    /// stands for, whole. The split is what makes the graph readable at two
    /// depths: the fields are what a layout needs (id, kind, lane, label,
    /// rank), and `detail` is what a READER needs -- the agent's actual
    /// prompt, the corpus's actual columns, the tool's actual description.
    /// Naming a thing and expanding it are different jobs and this does both
    /// rather than choosing.
    fn node_with(&mut self, kind: &str, name: &str, extra: Value, detail: Value) -> String {
        let id = self.node(kind, name, extra);
        if !detail.is_null() {
            if let Some(n) = self.nodes.get_mut(&id) {
                if n.get("detail").map(Value::is_null).unwrap_or(true) {
                    n["detail"] = detail;
                }
            }
        }
        id
    }

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
        let mut d = json!({
            "severity": severity, "code": code, "node": node,
            "message": message, "consequence": consequence,
        });
        if let Some(k) = &self.step {
            d["step"] = json!(k);
        }
        self.defects.push(d);
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
// What a step DOES, curated.
//
// A compiled step's `input` carries everything the engine needs and a fair
// amount a reader does not: an agent step's whole OpenAI-shaped envelope, an
// embed step's request template, a matrix's template object. This keeps the
// half that describes the PIPELINE -- the query, the prompt, the url, the
// fan-out width -- and drops the transport. The rule for what stays: if two
// steps of the same kind would differ in it, it describes the pipeline.
// ---------------------------------------------------------------------------

/// Every `{{env.NAME}}` a step's input mentions.
///
/// THE PLAN CAN SAY WHAT A STEP NEEDS AND NOT WHETHER IT IS THERE. The env
/// belongs to the WORKER -- deliberately, since it is where credentials live
/// and the database is not allowed to hold them -- so a plan built inside
/// Postgres can list the names and cannot resolve one. That is worth listing
/// anyway: the most common failure of a working plan is an agent step against
/// a deployment with no Agent Runtime configured, and the run's error for it
/// (`template {{env.P8_AGENT_URL}} resolved to nothing`) arrives after the
/// fetch it depended on has already spent somebody's rate limit.
fn requires_env(input: &Value) -> Vec<String> {
    let text = input.to_string();
    let mut out: Vec<String> = Vec::new();
    let mut rest = text.as_str();
    while let Some(i) = rest.find("{{env.") {
        rest = &rest[i + 6..];
        let end = rest.find("}}").unwrap_or(rest.len());
        let name: String = rest[..end].trim().to_string();
        if !name.is_empty() && !out.contains(&name) {
            out.push(name);
        }
        rest = &rest[end.min(rest.len())..];
    }
    out.sort();
    out
}

fn step_detail(kind: &str, input: &Value) -> Value {
    let mut d = Map::new();
    match kind {
        "sql" => {
            if let Some(st) = input.get("statement") {
                d.insert("statement".into(), st.clone());
                if input.get("write").and_then(Value::as_bool).unwrap_or(false) {
                    d.insert("write".into(), json!(true));
                }
                if let Some(t) = input.get("timeout_ms") {
                    d.insert("timeout_ms".into(), t.clone());
                }
            } else {
                if let Some(f) = input.get("function") {
                    d.insert("function".into(), f.clone());
                }
                if let Some(a) = input.get("args") {
                    d.insert("args".into(), a.clone());
                }
            }
        }
        "http_call" => {
            if let Some(agent) = agent_of(input) {
                d.insert("agent".into(), json!(agent));
                // The prompt this step sends, which is the step's half of the
                // intent -- the agent's own system prompt is the other half
                // and lives on the agent node.
                if let Some(m) = input.pointer("/body/messages").and_then(Value::as_array) {
                    let user: Vec<&Value> = m.iter()
                        .filter(|x| x.get("role").and_then(Value::as_str) == Some("user"))
                        .filter_map(|x| x.get("content"))
                        .collect();
                    if let Some(c) = user.first() {
                        d.insert("input".into(), (*c).clone());
                    }
                }
                // The session rides INSIDE the body, beside the model and the
                // messages, because that is where the runtime reads it --
                // `session_group` and `output_schema` are the task's own
                // business and sit at the top. Two homes, so two lookups.
                if let Some(v) = input.pointer("/body/session") {
                    d.insert("session".into(), v.clone());
                }
                for k in ["session_group", "output_schema"] {
                    if let Some(v) = input.get(k) {
                        d.insert(k.into(), v.clone());
                    }
                }
            } else if let Some(text) = input.pointer("/embed/text") {
                d.insert("embeds".into(), text.clone());
                if let Some(m) = input.pointer("/embed/model") {
                    d.insert("model".into(), m.clone());
                }
            } else {
                for k in ["url", "method", "jsonpath", "credential_ref", "timeout_ms"] {
                    if let Some(v) = input.get(k) {
                        d.insert(k.into(), v.clone());
                    }
                }
                // HEADERS ARE PART OF THE PLAN, and finding that out cost a
                // run: data.sec.gov returns 403 to a request with no
                // User-Agent, so the header is the difference between a
                // pipeline that works and one that fails at its first step. A
                // plan that hides it hides the reason.
                //
                // Values are shown because a header that says nothing is worth
                // nothing -- except for the four names a secret is ever
                // spelled with. `credential_ref` is where a secret belongs and
                // this schema cannot stop somebody putting one here anyway, so
                // the redaction is by NAME, applied before the value is ever
                // copied.
                if let Some(Value::Object(h)) = input.get("headers") {
                    let mut safe = Map::new();
                    for (k, v) in h {
                        let lower = k.to_lowercase();
                        if matches!(lower.as_str(), "authorization" | "proxy-authorization"
                                                  | "cookie" | "x-api-key") {
                            safe.insert(k.clone(), json!("<redacted>"));
                        } else {
                            safe.insert(k.clone(), v.clone());
                        }
                    }
                    d.insert("headers".into(), Value::Object(safe));
                }
                // A body is the request, not the plan -- except the model
                // name, which is the one thing in it that says what the call
                // is FOR.
                if let Some(m) = input.pointer("/body/model") {
                    d.insert("model".into(), m.clone());
                }
            }
        }
        "matrix" => {
            for k in ["max_fanout", "batch_size", "partition_by",
                      "continue_on", "min_success"] {
                if let Some(v) = input.get(k) {
                    d.insert(k.into(), v.clone());
                }
            }
            if let Some(f) = input.pointer("/rows/function") {
                d.insert("rows_from".into(), f.clone());
            } else if let Some(items) = input.get("items").and_then(Value::as_array) {
                d.insert("rows_from".into(), json!(format!("{} literal item(s)", items.len())));
            }
        }
        "signal" => {
            if let Some(v) = input.get("signal") {
                d.insert("signal".into(), v.clone());
            }
        }
        "timer" => {
            // `delay_seconds` is the key the compiler writes and the engine
            // reads (schedule_timer, workflow-engine/schema.sql) -- reading
            // anything else here means the document reports a wait no timer
            // ever has. `seconds` stays as a fallback for a spec stored as raw
            // JSON rather than compiled from YAML.
            if let Some(v) = input.get("delay_seconds").or_else(|| input.get("seconds")) {
                d.insert("seconds".into(), v.clone());
            }
        }
        "sub_workflow" => {
            if let Some(v) = input.get("workflow").or_else(|| input.get("name")) {
                d.insert("workflow".into(), v.clone());
            }
        }
        // `work` is code this collection did not write, so its input IS the
        // description -- there is nothing to curate down to.
        _ => {
            if let Value::Object(m) = input {
                for (k, v) in m {
                    d.insert(k.clone(), v.clone());
                }
            }
        }
    }
    let env = requires_env(input);
    if !env.is_empty() {
        d.insert("requires_env".into(), json!(env));
    }
    if d.is_empty() { Value::Null } else { Value::Object(d) }
}

// ---------------------------------------------------------------------------
// What a step DOES to the world, as a closed set.
//
// A reader wants to know three things before running a plan they did not write:
// what costs money, what changes data, and what merely asks a question. None of
// that was answerable from the document -- `sql` covered a query and a delete,
// `http_call` covered a free GET and a paid completion.
//
// `mutates` for a registered function is not a guess: it comes off
// pg_proc.provolatile, and a STABLE or IMMUTABLE function cannot write because
// Postgres refuses to let it. That is what makes `unconsumed_read` below safe
// to report -- without it, every step that lands rows through a function would
// look like a read nobody consumes.
// ---------------------------------------------------------------------------

fn effects_of(kind: &str, detail: &Value, catalog: &Value) -> Vec<&'static str> {
    match kind {
        "sql" => {
            if detail.get("statement").is_some() {
                if detail.get("write").and_then(Value::as_bool).unwrap_or(false) {
                    vec!["reads", "writes"]
                } else {
                    vec!["reads"]
                }
            } else {
                let mutates = detail
                    .get("function").and_then(Value::as_str)
                    .and_then(|f| section(catalog, "functions").and_then(|m| m.get(f)))
                    .and_then(|f| f.get("mutates")).and_then(Value::as_bool);
                match mutates {
                    Some(true) => vec!["reads", "writes"],
                    Some(false) => vec!["reads"],
                    // Registered against a function this deployment does not
                    // have. `unknown` rather than an assumption in either
                    // direction -- guessing "reads" here would let the orphan
                    // check fire on a step that lands data.
                    None => vec!["unknown"],
                }
            }
        }
        "http_call" => {
            if detail.get("agent").is_some() || detail.get("embeds").is_some() {
                vec!["network", "model"]
            } else {
                vec!["network"]
            }
        }
        "matrix" => vec!["reads", "fans_out"],
        "signal" | "timer" => vec!["waits"],
        "sub_workflow" => vec!["invokes"],
        // `work` is code this collection did not write. Anything it does is
        // outside what a plan can see, and saying "reads" would be a claim.
        _ => vec!["unknown"],
    }
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
        g.step = Some(key.clone());
        let kind = str_of(s, "kind").unwrap_or_else(|| "unknown".into());
        let queue = str_of(s, "queue").unwrap_or_else(|| "none".into());
        let empty = json!({});
        let input = s.get("input").unwrap_or(&empty);

        let step_id = g.node_with(
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
                "effects": json!(effects_of(&kind, &step_detail(&kind, input), catalog)),
            }),
            step_detail(&kind, input),
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

    g.step = None;
    rank_steps(&mut g, &steps);

    // A READ NOTHING CONSUMES.
    //
    // `resolve` in a real pipeline ran a LOOKUP, depended on the landing step,
    // and nothing depended on IT -- so its result went into runs.context and no
    // step ever read it. That is either the workflow's output for whoever polls
    // the run, or a wiring mistake, and the two are indistinguishable from
    // here: this says which step it is and lets the reader decide.
    //
    // Only for steps whose effects are reads alone. A step that writes, calls a
    // model, waits on a person or runs somebody's code has a point beyond its
    // return value, and reporting those would make the check noise -- the last
    // step of most pipelines is exactly one of them.
    //
    // AND ONLY WHEN SOMETHING ELSE FINISHES THE WORKFLOW. A pipeline whose only
    // leaf is a query is a pipeline whose answer IS that query, and warning on
    // it would fire on the most ordinary thing anyone writes -- the version
    // that did exactly that lasted one test run. The signal is a read left
    // hanging BESIDE a leaf that does something: then the read is either the
    // caller's second output or a step somebody meant to wire in, and it is
    // worth a sentence.
    let leaves: Vec<String> = steps.iter().filter_map(|s| str_of(s, "key"))
        .filter(|k| !steps.iter().any(|o| o.get("depends_on").and_then(Value::as_array)
            .map(|d| d.iter().any(|x| x.as_str() == Some(k.as_str()))).unwrap_or(false)))
        .collect();
    let effects_of_key = |k: &str| -> Vec<String> {
        g.nodes.get(&format!("step:{k}")).and_then(|n| n.get("effects"))
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    };
    let has_acting_leaf = leaves.iter().any(|k| effects_of_key(k) != vec!["reads".to_string()]);
    if !has_acting_leaf {
        return finish(g, &steps, wf_name, wf_version);
    }

    for s in &steps {
        let key = match str_of(s, "key") { Some(k) => k, None => continue };
        let id = format!("step:{key}");
        let effects: Vec<&str> = g.nodes.get(&id)
            .and_then(|n| n.get("effects"))
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        if effects != ["reads"] {
            continue;
        }
        let consumed = steps.iter().any(|other| {
            other.get("depends_on").and_then(Value::as_array)
                .map(|d| d.iter().any(|x| x.as_str() == Some(key.as_str())))
                .unwrap_or(false)
        });
        if !consumed {
            g.step = Some(key.clone());
            g.defect(
                "warning", "unconsumed_read", &id,
                &format!("nothing in this workflow depends on '{key}', and it only reads"),
                "its result reaches runs.context and nowhere else, so this is the run's \
                 output for whoever polls it -- or a step somebody meant to wire up",
            );
            g.step = None;
        }
    }

    finish(g, &steps, wf_name, wf_version)
}

/// The one exit, because there are two ways out of the builder now and a
/// second copy of this is how the two stop agreeing.
fn finish(g: Graph, steps: &[Value], wf_name: String, wf_version: i64) -> Value {
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

/// The relations a statement names, as a heuristic and labelled as one.
///
/// Only bare identifiers after FROM or JOIN are taken: `from (select ...) t`
/// and `from jsonb_array_elements(x) e` both start with something containing a
/// bracket and are skipped rather than guessed at, and names introduced by a
/// CTE in the same statement are removed. What is left is the set of relations
/// this step reads from something outside itself, which is the useful half.
///
/// This replaces a check the registry used to give for free: with `sql:
/// "select ..."` there is no registered function to look up, and a plan that
/// said nothing at all about a statement step would be a plan that got worse as
/// the engine got more expressive. Naming a table that does not exist is a
/// better check than naming a function that does not exist, because it is the
/// mistake people actually make.
fn statement_relations(sql: &str) -> Vec<String> {
    let lower = sql.to_lowercase();
    let bytes: Vec<char> = lower.chars().collect();
    let mut ctes: Vec<String> = Vec::new();
    let mut found: Vec<String> = Vec::new();

    // Tokenise crudely: identifiers, and everything else as separators.
    let mut toks: Vec<String> = Vec::new();
    let mut cur = String::new();
    for c in bytes {
        if c.is_alphanumeric() || c == '_' || c == '.' || c == '"' {
            cur.push(c);
        } else {
            if !cur.is_empty() { toks.push(std::mem::take(&mut cur)); }
            if c == '(' { toks.push("(".into()); }
            if c == ',' { toks.push(",".into()); }
        }
    }
    if !cur.is_empty() { toks.push(cur); }

    for i in 0..toks.len() {
        // `with x as (`, and `, y as (` for the second CTE onward.
        if toks[i] == "as" && i >= 1 && i + 1 < toks.len() && toks[i + 1] == "(" {
            ctes.push(toks[i - 1].clone());
        }
        if (toks[i] == "from" || toks[i] == "join") && i + 1 < toks.len() {
            let t = &toks[i + 1];
            if t == "(" || t == "," || t.is_empty() { continue; }
            let name = t.trim_matches('"').to_string();
            if name.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(true) { continue; }
            if !found.contains(&name) { found.push(name); }
        }
    }
    found.retain(|n| !ctes.contains(n) && !ctes.contains(&n.split('.').next().unwrap_or("").to_string()));
    found
}

fn classify_sql(g: &mut Graph, step_id: &str, key: &str, input: &Value, catalog: &Value) {
    // A step that carries its own SQL names no function. It still says what it
    // reads, which is the thing worth checking.
    if let Some(stmt) = input.get("statement").and_then(Value::as_str) {
        let known = list(catalog, "relations");
        for name in statement_relations(stmt) {
            let resolved = known.iter().find(|r| {
                **r == name || r.split('.').nth(1).map(|t| t == name).unwrap_or(false)
            });
            let rid = g.node_with("relation", resolved.unwrap_or(&name.as_str()), json!({}),
                                  Value::Null);
            g.edge(step_id, &rid, "reads");
            if !known.is_empty() && resolved.is_none() {
                g.defect(
                    "warning", "unknown_relation", &rid,
                    &format!("step '{key}' reads '{name}', which is not a relation this \
                              caller can see"),
                    "the statement fails at dispatch with `relation does not exist` -- \
                     unless the name is one this heuristic misread, which it will say \
                     nothing more about",
                );
            }
        }
        return;
    }

    let func = match str_of(input, "function") {
        Some(f) => f,
        None => return,
    };
    // The registry entry whole, comment included -- what a `sql:` step DOES is
    // then answerable from the plan rather than from the source.
    let fid = g.node_with("function", &func, json!({}),
        section(catalog, "functions").and_then(|m| m.get(&func)).cloned()
            .unwrap_or(Value::Null));
    g.edge(step_id, &fid, "calls");

    match section(catalog, "functions") {
        Some(fns) if !fns.contains_key(&func) => g.defect(
            "error", "unknown_function", &fid,
            &format!("step '{key}' calls '{func}', which is not in workflow.step_functions"),
            "execute_sql_step raises 'step function not registered' on dispatch -- the \
             allow-list is the point, so this is a plan that cannot run, not a plan that \
             runs unsafely",
        ),
        _ => {}
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
    let sid = g.node_with("source", &source, json!({
        "table": known.and_then(|k| str_of(k, "table")),
    }), known.cloned().unwrap_or(Value::Null));
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
    let mid = g.node_with("model", &model, json!({}),
        section(catalog, "models").and_then(|m| m.get(&model)).cloned()
            .unwrap_or(Value::Null));
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
        let mid = g.node_with("model", &model, json!({}),
            section(catalog, "models").and_then(|m| m.get(&model)).cloned()
                .unwrap_or(Value::Null));
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
    // A row source that is a statement reaches relations, exactly as a `sql:`
    // step does -- reusing classify_sql rather than repeating the extraction,
    // so a fan-out over a query is checked the same way a query is.
    if input.pointer("/rows/statement").is_some() {
        let empty = json!({});
        classify_sql(g, step_id, key, input.get("rows").unwrap_or(&empty), catalog);
    }
    if let Some(rows) = input.pointer("/rows/function").and_then(Value::as_str) {
        let fid = g.node_with("function", rows, json!({}),
            section(catalog, "functions").and_then(|m| m.get(rows)).cloned()
                .unwrap_or(Value::Null));
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
    let tid = g.node_with(
        "step",
        &format!("{key}\u{2009}template"),
        json!({"step_kind": tkind, "template_of": key, "label": format!("{key} · each row")}),
        step_detail(tkind, tinput),
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

    let aid = g.node_with(
        "agent",
        name,
        json!({"category": row.and_then(|r| str_of(r, "category"))}),
        // The row whole: the prompt IS the intent, and the shape it must
        // return is what says whether N of its answers will combine.
        row.cloned().unwrap_or(Value::Null),
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
        // The server whole, minus the per-tool detail -- that belongs on the
        // tool nodes, and carrying it twice makes a plan unreadable exactly
        // where a server exposes forty tools.
        let mut sdetail = srow.cloned().unwrap_or(Value::Null);
        if let Some(o) = sdetail.as_object_mut() {
            o.remove("tool_detail");
        }
        let sid = g.node_with(
            "tool_server",
            &server,
            json!({"server_kind": srow.and_then(|r| str_of(r, "kind"))}),
            sdetail,
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
            // What the tool SAYS IT DOES, which is the text the model reads
            // before deciding to call it -- the half of a binding that carries
            // intent, and the half a name alone cannot show.
            let tid = g.node_with("tool", &format!("{server}/{t}"), json!({
                "label": t, "server": server,
            }), srow.pointer(&format!("/tool_detail/{t}")).cloned().unwrap_or(Value::Null));
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

// ===========================================================================
// The document: the same resolution, projected into something you can read.
//
// The graph answers "what does this reach, and does it resolve". It is the
// right shape for a checker and the wrong shape for a person: a reader wants
// the PIPELINE -- step, then what that step actually says and does, with the
// agent's prompt, the corpus's columns and the tool's description sitting
// where they are used rather than in a node list to be joined by eye.
//
// So this is a projection, not a second resolver. Everything below reads the
// graph that was already built, which is what keeps the two views from ever
// disagreeing -- a document that resolved things its own way would be a second
// implementation of the only part that matters.
//
// WHAT IT LEAVES OUT is as deliberate as what it keeps. No ids, no lanes, no
// ranks, no edge list: those are for a layout engine. Curation is the point --
// an expansion that reproduces every column, constraint and schema of
// everything a workflow touches is a document nobody reads twice, which is
// the same failure as not expanding at all.
// ===========================================================================

/// A one-line statement of what the step does, built from the same detail the
/// entry carries -- so the summary can never say something the body does not.
fn about(kind: &str, detail: &Value, reaches: &Map<String, Value>) -> String {
    let d = |k: &str| detail.get(k).cloned().unwrap_or(Value::Null);
    let s = |k: &str| detail.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    match kind {
        "query" | "write" => {
            let q = detail.get("statement").and_then(Value::as_str)
                .or_else(|| detail.pointer("/args/0").and_then(Value::as_str))
                .unwrap_or("");
            format!("runs {}", trim(q, 90))
        }
        "function" => format!("calls {}()", s("function")),
        "agent" => {
            let name = s("agent");
            match reaches.get("calls").and_then(|c| c.get("model")).and_then(Value::as_str) {
                Some(m) => format!("asks agent {name} (on {m})"),
                None => format!("asks agent {name}"),
            }
        }
        "embed" => format!("embeds {} with {}", trim(&s("embeds"), 60), s("model")),
        "rest" => format!("{} {}",
            detail.get("method").and_then(Value::as_str).unwrap_or("calls"),
            endpoint_of(&s("url"))),
        "matrix" => format!("fans out over {} (max {})",
            s("rows_from"),
            d("max_fanout").as_i64().map(|n| n.to_string()).unwrap_or_else(|| "?".into())),
        "signal" => format!("waits for a person to signal '{}'", s("signal")),
        "timer" => format!("waits {} seconds", d("seconds")),
        "sub_workflow" => format!("runs the workflow '{}'", s("workflow")),
        _ => "runs code a worker supplies".to_string(),
    }
}

fn trim(s: &str, n: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= n { s } else {
        format!("{}...", s.chars().take(n).collect::<String>())
    }
}

/// The step kind a reader recognises, rather than the one the engine dispatches
/// on: `http_call` is three different things and the difference is the whole
/// point of reading the plan.
fn reader_kind(step_kind: &str, detail: &Value) -> &'static str {
    match step_kind {
        "sql" => {
            if detail.get("statement").is_some() {
                // A statement that changes the database is not a query, and the
                // document should not make a reader open it to find out.
                if detail.get("write").and_then(Value::as_bool).unwrap_or(false) {
                    "write"
                } else {
                    "query"
                }
            } else {
                match detail.get("function").and_then(Value::as_str) {
                    Some("p8ql") | Some("p8ql_vec") => "query",
                    _ => "function",
                }
            }
        }
        "http_call" => {
            if detail.get("agent").is_some() { "agent" }
            else if detail.get("embeds").is_some() { "embed" }
            else { "rest" }
        }
        "matrix" => "matrix",
        "signal" => "signal",
        "timer" => "timer",
        "sub_workflow" => "sub_workflow",
        _ => "work",
    }
}

/// The document form of one referenced entity: what it is, and the curated
/// expansion of it, with the graph's bookkeeping dropped.
fn inline(node: &Value) -> Value {
    let mut m = Map::new();
    let kind = node.get("kind").and_then(Value::as_str).unwrap_or("");
    m.insert(kind.to_string(), node.get("name").cloned().unwrap_or(Value::Null));
    if let Some(Value::Object(d)) = node.get("detail") {
        let dimensioned = d.contains_key("space_detail");
        for (k, v) in d {
            // `tools` on an agent is the raw binding; the document shows the
            // resolved tools instead, added by the caller.
            if k == "tools" && kind == "agent" { continue; }
            // The graph checks against the model NAMES and a reader wants the
            // dimensions beside them. Both belong in the catalog; only one
            // belongs in a document.
            if k == "spaces" && dimensioned { continue; }
            if k == "space_detail" {
                m.insert("embedded_in".into(), v.clone());
                continue;
            }
            m.insert(k.clone(), v.clone());
        }
    }
    Value::Object(m)
}

pub fn plan_document(spec: &Value, catalog: &Value) -> Value {
    let g = plan_graph(spec, catalog);
    if g.get("ok").and_then(Value::as_bool) != Some(true) {
        return g;
    }
    let empty: Vec<Value> = Vec::new();
    let nodes: Vec<&Value> = g["nodes"].as_array().unwrap_or(&empty).iter().collect();
    let edges: Vec<&Value> = g["edges"].as_array().unwrap_or(&empty).iter().collect();
    let by_id = |id: &str| nodes.iter().find(|n| n["id"] == id).copied();
    let out_of = |id: &str, kind: &str| -> Vec<&Value> {
        edges.iter()
            .filter(|e| e["from"] == id && e["kind"] == kind)
            .filter_map(|e| e["to"].as_str().and_then(by_id))
            .collect()
    };

    // Which defects belong to which step: a defect names a node, and a node is
    // THIS step's business if THIS step reaches it. `claimed` accumulates
    // across steps only so that the leftovers can be found at the end -- the
    // per-step set has to be local, or step three inherits the defects of
    // everything step one touched.
    let mut claimed: Vec<String> = Vec::new();

    let mut steps: Vec<Value> = Vec::new();
    let mut step_nodes: Vec<&Value> = nodes.iter()
        .filter(|n| n["kind"] == "step" && n.get("template_of").is_none())
        .copied()
        .collect();
    step_nodes.sort_by_key(|n| (n.get("rank").and_then(Value::as_i64).unwrap_or(0),
                                n["name"].as_str().unwrap_or("").to_string()));

    for sn in step_nodes {
        let id = sn["id"].as_str().unwrap_or("");
        let mut mine: Vec<String> = Vec::new();
        let detail = sn.get("detail").cloned().unwrap_or(json!({}));
        let step_kind = sn.get("step_kind").and_then(Value::as_str).unwrap_or("");
        let kind = reader_kind(step_kind, &detail);

        let mut reaches: Map<String, Value> = Map::new();
        for (edge_kind, key) in [("calls", "calls"), ("reads", "reads"),
                                 ("embeds_with", "embeds_with"),
                                 ("expands_over", "rows_from"),
                                 ("invokes", "invokes"), ("waits_for", "waits_for")] {
            for t in out_of(id, edge_kind) {
                mine.push(t["id"].as_str().unwrap_or("").to_string());
                let mut entry = inline(t);
                // An agent is the one entity worth following one hop further:
                // its tools and delegation targets are what it can DO, and a
                // plan that names the agent and hides those has expanded
                // nothing.
                if t["kind"] == "agent" {
                    let aid = t["id"].as_str().unwrap_or("");
                    let tools: Vec<Value> = out_of(aid, "may_call").into_iter().map(|tool| {
                        mine.push(tool["id"].as_str().unwrap_or("").to_string());
                        inline(tool)
                    }).collect();
                    if !tools.is_empty() {
                        entry["tools"] = json!(tools);
                    }
                    let servers: Vec<Value> = out_of(aid, "binds").into_iter().map(|srv| {
                        mine.push(srv["id"].as_str().unwrap_or("").to_string());
                        json!({"server": srv["name"], "url": srv.pointer("/detail/url"),
                               "kind": srv.pointer("/detail/kind"),
                               "synced_at": srv.pointer("/detail/synced_at")})
                    }).collect();
                    if !servers.is_empty() {
                        entry["servers"] = json!(servers);
                    }
                    let deleg: Vec<Value> = out_of(aid, "delegates_to").into_iter()
                        .map(|a| a["name"].clone()).collect();
                    if !deleg.is_empty() {
                        entry["delegates_to"] = json!(deleg);
                    }
                }
                reaches.insert(key.to_string(), entry);
            }
        }

        // A matrix's template is a step in every way but its key, so it is
        // shown as one -- nested, because that is what it is.
        if let Some(t) = out_of(id, "expands_to").into_iter().next() {
            let tdetail = t.get("detail").cloned().unwrap_or(json!({}));
            let tkind = reader_kind(t.get("step_kind").and_then(Value::as_str).unwrap_or(""),
                                    &tdetail);
            let tid = t["id"].as_str().unwrap_or("");
            let mut treaches: Map<String, Value> = Map::new();
            for (ek, key) in [("calls", "calls"), ("reads", "reads"),
                              ("embeds_with", "embeds_with")] {
                for tt in out_of(tid, ek) {
                    mine.push(tt["id"].as_str().unwrap_or("").to_string());
                    treaches.insert(key.to_string(), inline(tt));
                }
            }
            let mut child = json!({"kind": tkind,
                                   "about": about(tkind, &tdetail, &treaches)});
            if let Value::Object(d) = &tdetail {
                for (k, v) in d { child[k] = v.clone(); }
            }
            for (k, v) in treaches { child[k] = v; }
            reaches.insert("each_row".into(), child);
        }

        // The control edges are not expanded into the document -- a queue is a
        // name, not an entity worth a paragraph -- but a defect about one is
        // still THIS step's problem, so its node counts as reached.
        for k in ["claimed_from", "throttled_by"] {
            for t in out_of(id, k) {
                mine.push(t["id"].as_str().unwrap_or("").to_string());
            }
        }

        let needs: Vec<Value> = edges.iter()
            .filter(|e| e["to"] == id && e["kind"] == "needs")
            .filter_map(|e| e["from"].as_str())
            .map(|f| json!(f.trim_start_matches("step:")))
            .collect();

        let defects: Vec<Value> = g["defects"].as_array().unwrap_or(&empty).iter()
            .filter(|d| {
                // A defect that names a step belongs to that step and to no
                // other, however many steps reach the node it is about.
                match d.get("step").and_then(Value::as_str) {
                    Some(k) => format!("step:{k}") == id,
                    None => {
                        let n = d["node"].as_str().unwrap_or("");
                        n == id || mine.iter().any(|c| c == n)
                    }
                }
            })
            .map(|d| json!({"severity": d["severity"], "code": d["code"],
                            "message": d["message"]}))
            .collect();

        let mut entry = json!({
            "id": sn["name"],
            "kind": kind,
            "about": about(kind, &detail, &reaches),
        });
        if !needs.is_empty() { entry["needs"] = json!(needs); }
        let q = sn.get("queue").and_then(Value::as_str).unwrap_or("none");
        if q != "none" { entry["queue"] = json!(q); }
        if let Value::Object(d) = &detail {
            for (k, v) in d {
                if k == "agent" { continue; }   // shown under `calls`
                entry[k] = v.clone();
            }
        }
        for (k, v) in reaches { entry[k] = v; }
        if !defects.is_empty() { entry["defects"] = json!(defects); }
        claimed.append(&mut mine);
        steps.push(entry);
    }

    let unclaimed: Vec<Value> = g["defects"].as_array().unwrap_or(&empty).iter()
        .filter(|d| {
            let n = d["node"].as_str().unwrap_or("");
            !claimed.iter().any(|c| c == n)
                && !steps.iter().any(|s| format!("step:{}", s["id"].as_str().unwrap_or("")) == n)
        })
        .cloned()
        .collect();

    let mut out = json!({
        "ok": true,
        "workflow": g["workflow"],
        "stats": g["stats"],
        "steps": steps,
    });
    if !unclaimed.is_empty() {
        out["defects"] = json!(unclaimed);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Value {
        json!({
            "agents": {
                "triage_bot": {"category": "classifier", "audience": "user",
                               "model": "claude-sonnet-5",
                               "system_prompt": "Classify an outage report.",
                               "output_shape": {"required": ["verdict"],
                                                "properties": {"verdict": "string"}},
                               "has_output_schema": true,
                               "tools": [{"server": "p8-query", "tools": ["semantic_search"]}]},
                "researcher": {"category": "general", "audience": "user",
                               "tools": [{"server": "p8-agents", "tools": ["triage_bot"]}]}
            },
            "servers": {
                "p8-query": {"kind": "mcp", "url": "http://mcp:8000", "emits_citations": true,
                             "serves_agents": false, "synced_at": "2026-09-01T00:00:00Z",
                             "tools": ["semantic_search", "graph_walk"],
                             "tool_detail": {"semantic_search": {
                                 "description": "Rank chunks against a question vector",
                                 "params": ["limit", "query"]}}},
                "p8-agents": {"kind": "mcp", "url": "http://runtime:8080", "serves_agents": true,
                              "synced_at": "2026-09-01T00:00:00Z", "tools": ["triage_bot"]}
            },
            "functions": {"p8ql": {"fn": "workflow.p8ql"},
                          "p8ql_vec": {"fn": "workflow.p8ql"},
                          "unextracted": {"fn": "content.unextracted"}},
            "sources": {"chunks": {"table": "content.resource_chunks",
                                   "content_col": "content",
                                   "columns": [{"name": "id", "type": "uuid"},
                                               {"name": "content", "type": "text"}],
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
    fn the_document_puts_the_expansion_where_the_step_uses_it() {
        let g = plan_document(
            &spec_of(json!([
                {"key": "retrieve", "kind": "sql", "queue": "none",
                 "input": {"function": "p8ql_vec",
                           "args": ["SEARCH \"outage\" FROM chunks USING nomic-embed-text"]}},
                {"key": "classify", "kind": "http_call", "queue": "http",
                 "depends_on": ["retrieve"],
                 "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                           "body": {"model": "triage_bot",
                                    "messages": [{"role": "user", "content": "Classify: x"}]}}}
            ])),
            &catalog(),
        );
        let steps = g["steps"].as_array().unwrap();
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[0]["id"], json!("retrieve"), "steps come out in rank order");

        // The corpus is expanded WHERE IT IS READ, not in a node list.
        assert_eq!(steps[0]["reads"]["source"], json!("chunks"));
        assert_eq!(steps[0]["reads"]["table"], json!("content.resource_chunks"));
        assert!(steps[0]["about"].as_str().unwrap().starts_with("runs SEARCH"));

        // And the agent brings its prompt, its shape and its tools with it.
        let calls = &steps[1]["calls"];
        assert_eq!(calls["agent"], json!("triage_bot"));
        assert_eq!(calls["system_prompt"], json!("Classify an outage report."));
        assert_eq!(calls["tools"][0]["tool"], json!("p8-query/semantic_search"));
        assert_eq!(calls["tools"][0]["description"],
                   json!("Rank chunks against a question vector"));
        assert_eq!(steps[1]["needs"], json!(["retrieve"]));
    }

    /// The three keys a document reads from a COMPILED step, each of which
    /// lives somewhere a plausible guess would not have found it. A wrong key
    /// here does not fail: it renders a blank, which reads like a step that
    /// says nothing rather than a reader that looked in the wrong place.
    #[test]
    fn the_document_reads_the_keys_the_engine_writes_not_the_ones_it_might_have() {
        let g = plan_document(
            &spec_of(json!([
                // `delay_seconds` is what compile_control emits and what
                // schedule_timer reads -- not `seconds`, not `timer`.
                {"key": "settle", "kind": "timer", "queue": "none",
                 "input": {"delay_seconds": 90}},
                // The session sits INSIDE the body, beside the model; only
                // session_group is at the top.
                {"key": "classify", "kind": "http_call", "queue": "http",
                 "depends_on": ["settle"],
                 "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                           "session_group": "triage",
                           "body": {"model": "triage_bot",
                                    "session": "{{run.$session}}",
                                    "messages": [{"role": "user", "content": "Classify: x"}]}}},
                // A queue with no queue_config row: the defect names the QUEUE
                // node, and the step is the only place a reader will look for
                // it.
                {"key": "ship", "kind": "work", "queue": "nowhere",
                 "depends_on": ["classify"], "input": {}}
            ])),
            &catalog(),
        );
        let steps = g["steps"].as_array().unwrap();

        assert_eq!(steps[0]["seconds"], json!(90));
        assert_eq!(steps[0]["about"], json!("waits 90 seconds"));

        assert_eq!(steps[1]["session"], json!("{{run.$session}}"));
        assert_eq!(steps[1]["session_group"], json!("triage"));

        // A defect about a queue belongs to the step claimed from it, not to
        // the unattributed pile at the end.
        assert_eq!(steps[2]["defects"][0]["code"], json!("unconfigured_queue"));
        assert!(g.get("defects").is_none(),
                "every defect here has a step to belong to");
    }

    #[test]
    fn a_step_carrying_its_own_sql_reaches_the_relations_it_names() {
        let mut cat = catalog();
        cat["relations"] = json!(["content.resource_chunks", "demo_sec.facts"]);
        let g = plan_graph(
            &spec_of(json!([{
                "key": "quarters", "kind": "sql", "queue": "none",
                "input": {"statement":
                    "with recent as (select 1) select f.fy, f.val from demo_sec.facts f \
                     join recent on true where f.cik = '0000320193'"}
            }])),
            &cat,
        );
        assert!(find(&g, "relation:demo_sec.facts").is_some(),
                "the table it reads is a node");
        assert!(find(&g, "relation:recent").is_none(),
                "a CTE defined in the same statement is not a relation it reaches");
        assert!(find(&g, "function:p8ql").is_none(),
                "a statement step names no function, so none is invented");
        assert_eq!(g["stats"]["errors"], json!(0));
        assert_eq!(g["stats"]["warnings"], json!(0));
    }

    #[test]
    fn a_statement_naming_a_table_nobody_has_is_a_warning() {
        let mut cat = catalog();
        cat["relations"] = json!(["demo_sec.facts"]);
        let g = plan_graph(
            &spec_of(json!([{
                "key": "q", "kind": "sql", "queue": "none",
                "input": {"statement": "select * from demo_sec.factz"}
            }])),
            &cat,
        );
        assert!(codes(&g).contains(&"unknown_relation".to_string()));
        // A WARNING, not an error: the extraction is a heuristic over SQL this
        // crate does not parse, and a checker that refuses a working pipeline
        // on a guess is worse than one that says nothing.
        assert_eq!(g["stats"]["errors"], json!(0));
    }

    #[test]
    fn the_document_says_which_steps_change_the_database() {
        let mut cat = catalog();
        cat["relations"] = json!(["demo_sec.facts"]);
        let g = plan_document(
            &spec_of(json!([{
                "key": "purge", "kind": "sql", "queue": "none",
                "input": {"statement": "delete from demo_sec.facts where fy < 2020",
                          "write": true}
            }])),
            &cat,
        );
        assert_eq!(g["steps"][0]["kind"], json!("write"),
                   "a mutation must not read as a query");
        assert_eq!(g["steps"][0]["write"], json!(true));
    }

    #[test]
    fn a_read_left_hanging_beside_a_step_that_acts_is_reported() {
        let mut cat = catalog();
        cat["relations"] = json!(["demo_sec.facts"]);
        let g = plan_graph(
            &spec_of(json!([
                {"key": "land", "kind": "sql", "queue": "none",
                 "input": {"function": "record", "args": []}},
                // reads, and nothing depends on it
                {"key": "resolve", "kind": "sql", "queue": "none", "depends_on": ["land"],
                 "input": {"statement": "select 1 from demo_sec.facts"}},
                // the leaf that finishes the workflow
                {"key": "classify", "kind": "http_call", "queue": "http",
                 "depends_on": ["land"],
                 "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                           "body": {"model": "triage_bot"}}}
            ])),
            &cat,
        );
        let d: Vec<&Value> = g["defects"].as_array().unwrap().iter()
            .filter(|d| d["code"] == "unconsumed_read").collect();
        assert_eq!(d.len(), 1, "exactly the hanging read");
        assert_eq!(d[0]["step"], json!("resolve"));
    }

    #[test]
    fn a_workflow_whose_only_leaf_is_a_query_is_not_nagged() {
        // The answer IS the query. The version of this check that fired here
        // lasted one test run, and would have fired on the most ordinary
        // workflow anyone writes.
        let mut cat = catalog();
        cat["relations"] = json!(["demo_sec.facts"]);
        let g = plan_graph(
            &spec_of(json!([{"key": "q", "kind": "sql", "queue": "none",
                             "input": {"statement": "select 1 from demo_sec.facts"}}])),
            &cat,
        );
        assert!(!codes(&g).contains(&"unconsumed_read".to_string()));
    }

    #[test]
    fn a_step_says_what_it_does_to_the_world() {
        let mut cat = catalog();
        cat["functions"] = json!({
            "land_rows": {"fn": "demo.land", "mutates": true},
            "count_rows": {"fn": "demo.count", "mutates": false}});
        let g = plan_graph(
            &spec_of(json!([
                {"key": "w", "kind": "sql", "queue": "none",
                 "input": {"statement": "delete from t", "write": true}},
                {"key": "land", "kind": "sql", "queue": "none", "depends_on": ["w"],
                 "input": {"function": "land_rows", "args": []}},
                {"key": "count", "kind": "sql", "queue": "none", "depends_on": ["w"],
                 "input": {"function": "count_rows", "args": []}},
                {"key": "ask", "kind": "http_call", "queue": "http", "depends_on": ["w"],
                 "input": {"url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                           "body": {"model": "triage_bot"}}}
            ])),
            &cat,
        );
        let fx = |k: &str| find(&g, &format!("step:{k}")).unwrap()["effects"].clone();
        assert_eq!(fx("w"), json!(["reads", "writes"]));
        // provolatile, not a promise: a STABLE function cannot write, and
        // Postgres is what enforces that.
        assert_eq!(fx("land"), json!(["reads", "writes"]));
        assert_eq!(fx("count"), json!(["reads"]));
        assert_eq!(fx("ask"), json!(["network", "model"]));
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
