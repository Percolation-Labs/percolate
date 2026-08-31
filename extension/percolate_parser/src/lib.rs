use pgrx::prelude::*;

::pgrx::pg_module_magic!(name, version);

// The SCHEMA is deliberately not here. An extension cannot contain both C
// functions and RLS-protected tables, and the reason is structural:
//
//   superuser = false  -> the script runs as the caller, so tables are owned
//                         by app_owner and RLS works -- but a non-superuser
//                         cannot create C-language functions.
//   trusted = true     -> a non-superuser may install, but the script runs as
//                         the BOOTSTRAP SUPERUSER, so every table would be
//                         superuser-owned and every policy inert.
//
// Verified both ways against PG19: the first fails with "permission denied for
// language c", the second is caught by user-rbac's own superuser guard.
//
// So this extension is the C half (installed by a superuser, no tables, no
// policies), and `percolate` is the pure-SQL half (installed by app_owner,
// trusted, requires this one). The split is not a workaround -- a compiled
// parser and a schema genuinely have different install requirements.

// ===========================================================================
// The query dialect parser.
//
// This is the first genuine pgrx use case in the collection, and it meets the
// bar ai-query-layer/brief.md §3 sets (reserved for what SQL has no good
// equivalent for): tokenizing a small grammar with quoted strings and
// optional modifiers is miserable in PL/pgSQL and natural here, and it is
// pure computation over a string -- no I/O, no state, trivially unit-testable
// off-database.
//
// The payoff is the "query directly on the API" property: PostgREST exposes
// aiq_query(text) as ONE RPC, so an agent posts
//     {"q": "GRAPH \"acme\" DEPTH 2 TYPE competes_with"}
// to a single endpoint instead of choosing between five. The parser turns
// that into a structured plan; SQL executes it (§9 of schema.sql).
//
// Grammar (REM's five modes, brief.md §2, plus the two lexical modes added
// after running the "R7" case -- schema.sql §11):
//   LOOKUP   "<key>"  [FUZZY] [LIMIT n]
//   SEMANTIC "<text>" FROM <source> [USING <model>] [LIMIT n]
//   TEXT     "<text>" FROM <source> [LIMIT n]          -- lexical, ts_rank
//   HYBRID   "<text>" FROM <source> [USING <model>] [LIMIT n]  -- RRF fusion
//   GRAPH    "<key>"  [DEPTH n] [TYPE <relation>] [LIMIT n]
//   SQL <passthrough...>
// ===========================================================================

#[derive(Debug, PartialEq)]
pub struct ParsedQuery {
    pub mode: String,
    pub arg: String,
    pub fuzzy: bool,
    pub depth: i32,
    pub relation: Option<String>,
    pub source: Option<String>,
    pub model: Option<String>,
    pub limit: i32,
}

#[derive(Debug, PartialEq)]
pub enum ParseError {
    Empty,
    UnknownMode(String),
    MissingArgument(&'static str),
    UnterminatedQuote,
    BadNumber(String),
    UnexpectedToken(String),
}

impl ParseError {
    fn message(&self) -> String {
        match self {
            ParseError::Empty => "empty query".into(),
            ParseError::UnknownMode(m) => format!(
                "unknown mode '{m}' -- expected one of LOOKUP, SEMANTIC, TEXT, HYBRID, GRAPH, SQL"
            ),
            ParseError::MissingArgument(m) => format!("{m}"),
            ParseError::UnterminatedQuote => "unterminated quoted string".into(),
            ParseError::BadNumber(t) => format!("expected a number, got '{t}'"),
            ParseError::UnexpectedToken(t) => format!("unexpected token '{t}'"),
        }
    }
}

/// Split into tokens, treating a double-quoted run as ONE token so keys may
/// contain spaces ("acme robotics") and slashes ("places/ukraine/bakhmut").
fn tokenize(input: &str) -> Result<Vec<String>, ParseError> {
    let mut out = Vec::new();
    let mut chars = input.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else if c == '"' {
            chars.next();
            let mut buf = String::new();
            let mut closed = false;
            while let Some(c2) = chars.next() {
                if c2 == '"' {
                    closed = true;
                    break;
                }
                buf.push(c2);
            }
            if !closed {
                return Err(ParseError::UnterminatedQuote);
            }
            out.push(buf);
        } else {
            let mut buf = String::new();
            while let Some(&c2) = chars.peek() {
                if c2.is_whitespace() {
                    break;
                }
                buf.push(c2);
                chars.next();
            }
            out.push(buf);
        }
    }
    Ok(out)
}

pub fn parse_query(input: &str) -> Result<ParsedQuery, ParseError> {
    let toks = tokenize(input)?;
    if toks.is_empty() {
        return Err(ParseError::Empty);
    }

    let mode = toks[0].to_uppercase();
    let mut q = ParsedQuery {
        mode: mode.clone(),
        arg: String::new(),
        fuzzy: false,
        depth: 1,
        relation: None,
        source: None,
        model: None,
        limit: 20,
    };

    // SQL is a raw passthrough: everything after the keyword is the payload,
    // untouched. It is executed SECURITY INVOKER and read-only-enforced on the
    // SQL side (brief.md §3) -- the parser deliberately does not try to
    // validate it, because a half-parser that thinks it understands SQL is
    // exactly how an injection filter gets bypassed.
    if mode == "SQL" {
        let idx = input.to_uppercase().find("SQL").unwrap_or(0);
        q.arg = input[idx + 3..].trim().to_string();
        if q.arg.is_empty() {
            return Err(ParseError::MissingArgument("SQL requires a statement"));
        }
        return Ok(q);
    }

    if !matches!(
        mode.as_str(),
        "LOOKUP" | "SEMANTIC" | "GRAPH" | "TEXT" | "HYBRID"
    ) {
        return Err(ParseError::UnknownMode(mode));
    }

    if toks.len() < 2 {
        return Err(ParseError::MissingArgument(
            "expected a quoted argument, e.g. LOOKUP \"acme\"",
        ));
    }
    q.arg = toks[1].clone();

    let mut i = 2;
    while i < toks.len() {
        match toks[i].to_uppercase().as_str() {
            "FUZZY" => {
                q.fuzzy = true;
                i += 1;
            }
            "DEPTH" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "DEPTH requires a number",
                ))?;
                q.depth = v
                    .parse::<i32>()
                    .map_err(|_| ParseError::BadNumber(v.clone()))?;
                i += 2;
            }
            "TYPE" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "TYPE requires a relation name",
                ))?;
                q.relation = Some(v.clone());
                i += 2;
            }
            "FROM" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "FROM requires a source name",
                ))?;
                q.source = Some(v.clone());
                i += 2;
            }
            // USING names the EMBEDDING MODEL, not the source. Two different
            // 768-dim models are not interchangeable (schema.sql §10), so the
            // model has to be nameable in the dialect rather than left to a
            // server-side default the caller cannot see.
            "USING" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "USING requires an embedding model name",
                ))?;
                q.model = Some(v.clone());
                i += 2;
            }
            "LIMIT" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "LIMIT requires a number",
                ))?;
                q.limit = v
                    .parse::<i32>()
                    .map_err(|_| ParseError::BadNumber(v.clone()))?;
                i += 2;
            }
            _ => return Err(ParseError::UnexpectedToken(toks[i].clone())),
        }
    }

    // Every content-searching mode needs a source: there is no meaningful
    // default corpus, and silently picking one would make a typo look like an
    // empty result.
    if matches!(q.mode.as_str(), "SEMANTIC" | "TEXT" | "HYBRID") && q.source.is_none() {
        return Err(ParseError::MissingArgument(
            "SEMANTIC, TEXT and HYBRID each require FROM <source>",
        ));
    }
    // USING selects an embedding space, so it is meaningless where no vector
    // is involved. Rejected rather than ignored -- silently dropping a
    // modifier the caller wrote is how a query quietly means something else.
    if q.model.is_some() && !matches!(q.mode.as_str(), "SEMANTIC" | "HYBRID") {
        return Err(ParseError::MissingArgument(
            "USING <model> applies only to SEMANTIC and HYBRID",
        ));
    }
    Ok(q)
}

/// Parse a dialect string into a structured plan as JSONB.
///
/// Returns the PLAN, not the result. Keeping parse and execute separate is
/// deliberate: it makes the parser testable without a database, lets SQL own
/// execution (where the planner, RLS and the indexes already live), and means
/// a caller can inspect what its string was understood to mean -- which for
/// an agent-facing dialect is a feature, since a misparse is otherwise
/// indistinguishable from an empty result.
#[pg_extern(immutable, parallel_safe)]
fn aiq_parse(query: &str) -> pgrx::JsonB {
    match parse_query(query) {
        Ok(q) => pgrx::JsonB(serde_json::json!({
            "ok": true,
            "mode": q.mode,
            "arg": q.arg,
            "fuzzy": q.fuzzy,
            "depth": q.depth,
            "relation": q.relation,
            "source": q.source,
            "model": q.model,
            "limit": q.limit,
        })),
        Err(e) => pgrx::JsonB(serde_json::json!({
            "ok": false,
            "error": e.message(),
        })),
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use crate::*;

    #[pg_test]
    fn parses_plain_lookup() {
        let q = parse_query("LOOKUP \"acme\"").unwrap();
        assert_eq!(q.mode, "LOOKUP");
        assert_eq!(q.arg, "acme");
        assert!(!q.fuzzy);
    }

    #[pg_test]
    fn parses_quoted_key_with_spaces_and_slashes() {
        let q = parse_query("LOOKUP \"places/ukraine/bakhmut city\"").unwrap();
        assert_eq!(q.arg, "places/ukraine/bakhmut city");
    }

    #[pg_test]
    fn parses_fuzzy_and_limit() {
        let q = parse_query("LOOKUP \"acme robotcs\" FUZZY LIMIT 5").unwrap();
        assert!(q.fuzzy);
        assert_eq!(q.limit, 5);
    }

    #[pg_test]
    fn parses_graph_with_depth_and_type() {
        let q = parse_query("GRAPH \"acme\" DEPTH 3 TYPE competes_with").unwrap();
        assert_eq!(q.mode, "GRAPH");
        assert_eq!(q.depth, 3);
        assert_eq!(q.relation.as_deref(), Some("competes_with"));
    }

    #[pg_test]
    fn parses_text_and_hybrid_modes() {
        assert_eq!(parse_query("TEXT \"R7 arm\" FROM chunks").unwrap().mode, "TEXT");
        let h = parse_query("HYBRID \"R7 arm\" FROM chunks USING nomic-embed-text LIMIT 5").unwrap();
        assert_eq!(h.mode, "HYBRID");
        assert_eq!(h.model.as_deref(), Some("nomic-embed-text"));
        assert_eq!(h.limit, 5);
    }

    #[pg_test]
    fn using_is_rejected_where_no_vector_is_involved() {
        assert!(parse_query("TEXT \"x\" FROM chunks USING m").is_err());
        assert!(parse_query("LOOKUP \"x\" USING m").is_err());
    }

    #[pg_test]
    fn all_content_modes_require_from() {
        for m in ["SEMANTIC", "TEXT", "HYBRID"] {
            assert!(parse_query(&format!("{m} \"x\"")).is_err(), "{m} should require FROM");
        }
    }

    #[pg_test]
    fn semantic_requires_from() {
        assert!(parse_query("SEMANTIC \"revenue\"").is_err());
        let q = parse_query("SEMANTIC \"revenue\" FROM chunks").unwrap();
        assert_eq!(q.source.as_deref(), Some("chunks"));
    }

    #[pg_test]
    fn sql_passthrough_is_untouched() {
        let q = parse_query("SQL select 1 from t where x = \"y\"").unwrap();
        assert_eq!(q.mode, "SQL");
        assert_eq!(q.arg, "select 1 from t where x = \"y\"");
    }

    #[pg_test]
    fn mode_is_case_insensitive() {
        assert_eq!(parse_query("lookup \"acme\"").unwrap().mode, "LOOKUP");
    }

    #[pg_test]
    fn rejects_unknown_mode_and_unterminated_quote() {
        assert!(matches!(
            parse_query("TRAVERSE \"acme\""),
            Err(ParseError::UnknownMode(_))
        ));
        assert!(matches!(
            parse_query("LOOKUP \"acme"),
            Err(ParseError::UnterminatedQuote)
        ));
    }

    #[pg_test]
    fn rejects_bad_number() {
        assert!(matches!(
            parse_query("GRAPH \"a\" DEPTH deep"),
            Err(ParseError::BadNumber(_))
        ));
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}

// ===========================================================================
// The workflow compiler: YAML -> workflow.definitions spec.
//
// The point of this is not ergonomics. It is that a workflow composed only of
// P8QL and REST steps needs NO USER CODE ANYWHERE -- the worker stops being
// something you write and becomes something purely generic that we ship. A
// step is one of:
//
//   p8ql:  <query>     -> kind 'sql'       -> runs INSIDE Postgres, no process
//   sql:   <function>  -> kind 'sql'       -> ditto, allow-listed function
//   rest:  {...}       -> kind 'http_call' -> the generic HTTP handler
//   agent: <name>      -> kind 'http_call' -> the Agent Runtime, agent loaded
//                                             from agentic.agents by name
//   work:  <queue>     -> kind 'work'      -> the ONLY case needing your code
//
// So "bring your own worker" becomes the exception rather than the shape of
// the system, and an entire LLM pipeline -- retrieve, classify, delegate,
// index -- is a YAML document that compiles to ordinary task rows and
// inherits retry, backoff, saga, cancellation and tracing unchanged.
//
// Compiled in Rust rather than PL/pgSQL because YAML parsing in plpgsql is not
// a reasonable thing to attempt, and because it keeps authoring SQL-native:
// `select workflow.define_yaml($$...$$)` needs no service running.
// ===========================================================================

use serde::Deserialize;

#[derive(Deserialize)]
struct WfDoc {
    name: String,
    #[serde(default)]
    version: Option<i32>,
    steps: Vec<WfStep>,
}

#[derive(Deserialize)]
struct WfStep {
    id: String,
    #[serde(default)]
    needs: Vec<String>,
    #[serde(default)]
    queue: Option<String>,

    // exactly one of these
    #[serde(default)]
    p8ql: Option<String>,
    #[serde(default)]
    sql: Option<SqlStep>,
    #[serde(default)]
    rest: Option<serde_yaml::Value>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    work: Option<bool>,

    // agent steps
    #[serde(default)]
    input: Option<serde_yaml::Value>,
    #[serde(default)]
    session: Option<String>,

    // saga
    #[serde(default)]
    compensate_with: Option<String>,
    #[serde(default)]
    saga_group: Option<String>,
}

#[derive(Deserialize)]
struct SqlStep {
    function: String,
    #[serde(default)]
    args: Vec<serde_yaml::Value>,
}

fn y2j(v: &serde_yaml::Value) -> serde_json::Value {
    serde_json::to_value(v).unwrap_or(serde_json::Value::Null)
}

pub fn compile_workflow(yaml: &str) -> Result<serde_json::Value, String> {
    let doc: WfDoc = serde_yaml::from_str(yaml).map_err(|e| format!("invalid YAML: {e}"))?;
    if doc.steps.is_empty() {
        return Err("workflow has no steps".into());
    }

    let ids: Vec<&str> = doc.steps.iter().map(|s| s.id.as_str()).collect();
    let mut steps = Vec::new();

    for s in &doc.steps {
        // Validate the dependency graph HERE rather than letting a broken
        // reference become a task that waits forever. The engine's own
        // validate_spec() also checks reachability; this catches the typo with
        // the step name in the message.
        for n in &s.needs {
            if !ids.contains(&n.as_str()) {
                return Err(format!("step '{}' needs '{}', which is not a step in this workflow", s.id, n));
            }
        }

        let chosen: Vec<&str> = [
            s.p8ql.is_some().then_some("p8ql"),
            s.sql.is_some().then_some("sql"),
            s.rest.is_some().then_some("rest"),
            s.agent.is_some().then_some("agent"),
            s.work.unwrap_or(false).then_some("work"),
        ].into_iter().flatten().collect();
        if chosen.len() != 1 {
            return Err(format!(
                "step '{}' must have exactly one of p8ql/sql/rest/agent/work, found {}",
                s.id,
                if chosen.is_empty() { "none".to_string() } else { chosen.join(" + ") }
            ));
        }

        let (kind, queue, input) = match chosen[0] {
            // P8QL runs in-database as an allow-listed sql step. No queue, no
            // process: 'none' is a label, nothing polls it.
            "p8ql" => ("sql", "none".to_string(), serde_json::json!({
                "function": "p8ql",
                "args": [s.p8ql.clone().unwrap()]
            })),
            "sql" => {
                let sq = s.sql.as_ref().unwrap();
                ("sql", "none".to_string(), serde_json::json!({
                    "function": sq.function,
                    "args": sq.args.iter().map(y2j).collect::<Vec<_>>()
                }))
            }
            "rest" => ("http_call",
                s.queue.clone().unwrap_or_else(|| "http".into()),
                y2j(s.rest.as_ref().unwrap())),
            // An agent step is a REST call to the Agent Runtime with the agent
            // NAMED, not defined -- the agent itself is a row in
            // agentic.agents, so changing its prompt or tools never touches
            // this workflow.
            "agent" => ("http_call",
                s.queue.clone().unwrap_or_else(|| "http".into()),
                serde_json::json!({
                    "url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                    "method": "POST",
                    "credential_ref": "P8_API_KEY",
                    "timeout_ms": 120000,
                    "body": {
                        "model": s.agent.clone().unwrap(),
                        "session": s.session.clone(),
                        "messages": [{"role": "user",
                                      "content": s.input.as_ref().map(y2j)
                                          .unwrap_or(serde_json::Value::Null)}]
                    },
                    "jsonpath": "choices.0.message.content"
                })),
            _ => ("work", s.queue.clone().unwrap_or_else(|| "default".into()),
                  s.input.as_ref().map(y2j).unwrap_or(serde_json::json!({}))),
        };

        let mut step = serde_json::json!({
            "key": s.id, "kind": kind, "queue": queue, "input": input
        });
        if !s.needs.is_empty() {
            step["depends_on"] = serde_json::json!(s.needs);
        }
        if let Some(c) = &s.compensate_with {
            step["compensation_task_key"] = serde_json::json!(c);
            step["saga_group"] = serde_json::json!(
                s.saga_group.clone().unwrap_or_else(|| "default".into()));
        }
        steps.push(step);
    }

    Ok(serde_json::json!({
        "name": doc.name,
        "version": doc.version.unwrap_or(1),
        "spec": {"steps": steps}
    }))
}

/// Compile a YAML workflow into the spec shape workflow.definitions stores.
/// Returns {ok:false, error:...} rather than raising, so a caller can show the
/// author a message instead of a stack trace.
#[pg_extern(immutable, parallel_safe)]
fn p8_compile_workflow(yaml: &str) -> pgrx::JsonB {
    match compile_workflow(yaml) {
        Ok(v) => pgrx::JsonB(serde_json::json!({"ok": true, "workflow": v})),
        Err(e) => pgrx::JsonB(serde_json::json!({"ok": false, "error": e})),
    }
}
