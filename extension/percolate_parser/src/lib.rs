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
//
//   [FUZZY] LOOKUP "<key>" [, "<key>" ...] [LIMIT n]
//   SEMANTIC "<text>" FROM <source> [USING <model>] [LIMIT n]
//   TEXT     "<text>" FROM <source> [LIMIT n]          -- lexical, ts_rank
//   SEARCH   "<text>" FROM <source> [USING <model>] [LIMIT n]  -- RRF fusion
//   GRAPH    "<key>"  [DEPTH n] [TYPE <relation>] [LIMIT n]
//   SCHEMA   ["<facet>"] [FROM <name>]              -- what this database IS
//   <any ordinary SQL statement>
//
// SCHEMA is the one mode whose argument is optional, and deliberately so:
// bare `SCHEMA` is the index -- the list of facets you may ask about -- which
// is the only query an agent can write before it knows anything. Every other
// mode requires you to already know what you are looking for.
//
// Four deliberate shapes, all of them about the dialect reading the way a
// person would write it:
//
// * SQL HAS NO KEYWORD. Ordinary SQL just works -- `select …` is recognised
//   as SQL because it starts like SQL, not because it was announced. A `SQL`
//   prefix was pure ceremony on the one mode that needed no help identifying
//   itself, and it made the escape hatch feel like a sixth mode rather than
//   the floor everything else sits on.
//
// * SEARCH, not HYBRID. `HYBRID` named the implementation (fusing two rankers)
//   rather than the intent. Somebody who wants to find things asks to SEARCH;
//   that it fuses lexical and semantic rank underneath is our business.
//
// * FUZZY IS A PREFIX. `FUZZY LOOKUP "acme"` reads as an adjective on the
//   verb, the way it is spoken. Trailing `LOOKUP "acme" FUZZY` parsed but
//   read backwards, and a modifier that changes what a query MEANS belongs
//   before the thing it modifies, not appended where it scans as an
//   afterthought.
//
// * LOOKUP TAKES A LIST. Resolving several names is the common case -- an
//   agent almost never has exactly one entity in hand -- and N round trips to
//   answer one question is a worse dialect, not a simpler one.
// ===========================================================================

#[derive(Debug, PartialEq)]
pub struct ParsedQuery {
    pub mode: String,
    /// Every argument, in order. Only LOOKUP may carry more than one.
    pub args: Vec<String>,
    pub fuzzy: bool,
    pub depth: i32,
    pub relation: Option<String>,
    pub source: Option<String>,
    pub model: Option<String>,
    pub limit: i32,
}

impl ParsedQuery {
    /// The first argument, which is the whole argument for every mode but
    /// LOOKUP. Kept so the single-valued modes are not made to index into a
    /// list they can never have more than one element of.
    pub fn arg(&self) -> &str {
        self.args.first().map(String::as_str).unwrap_or("")
    }
}

/// The SQL statements the passthrough will accept.
///
/// Since SQL no longer announces itself with a keyword, something has to
/// decide whether an unrecognised first word is SQL or a typo. Sniffing a
/// known set of read-only openers rather than treating *anything* unknown as
/// SQL keeps `LOKUP "acme"` an honest dialect error instead of handing a
/// misspelling to the SQL parser, which would report a syntax error at
/// position 1 about a language the caller wasn't writing.
///
/// The list is exactly the read-only openers, which loses nothing: the
/// passthrough is read-only-enforced downstream anyway (brief.md §3), so a
/// statement that could not start with one of these would have been refused a
/// step later regardless.
const SQL_OPENERS: [&str; 5] = ["SELECT", "WITH", "TABLE", "VALUES", "EXPLAIN"];

#[derive(Debug, PartialEq)]
pub enum ParseError {
    Empty,
    UnknownMode(String),
    MissingArgument(&'static str),
    UnterminatedQuote,
    BadNumber(String),
    UnexpectedToken(String),
    /// A spelling the dialect used to accept. Printed verbatim, because the
    /// whole value of these is the sentence telling the caller what to write
    /// instead -- wrapped inside "unknown mode '...'" it reads as noise.
    Retired(&'static str),
}

impl ParseError {
    pub fn message(&self) -> String {
        match self {
            ParseError::Empty => "empty query".into(),
            // SCHEMA is named last and with a nudge, because it is the one
            // mode that answers "what may I ask for" -- a caller who got here
            // by guessing a mode name is exactly the caller who should be
            // told there is a query that lists them.
            ParseError::UnknownMode(m) => format!(
                "unknown mode '{m}' -- expected one of LOOKUP, SEMANTIC, TEXT, SEARCH, GRAPH, \
                 SCHEMA, or an ordinary SQL statement. Write SCHEMA to see what this \
                 database can answer."
            ),
            ParseError::MissingArgument(m) => format!("{m}"),
            ParseError::UnterminatedQuote => "unterminated quoted string".into(),
            ParseError::BadNumber(t) => format!("expected a number, got '{t}'"),
            ParseError::UnexpectedToken(t) => format!("unexpected token '{t}'"),
            ParseError::Retired(m) => (*m).into(),
        }
    }
}

/// Split into tokens, treating a quoted run as ONE token so keys may contain
/// spaces ("acme robotics") and slashes ("places/ukraine/bakhmut").
///
/// Both quote characters are accepted, and that is not laxity. P8QL is always
/// written *inside* a host language, and the two hosts it has both claim the
/// double quote first: SQL (`aiq.query('LOOKUP ...')`) and YAML
/// (`args: ["LOOKUP ..."]`). An author embedding a query in either reaches for
/// the single quote because it is the one still available. Accepting only the
/// double quote made `LOOKUP 'R7 Notice'` fail with `unexpected token
/// 'Notice''` — and, far worse, made `LOOKUP 'R7'` *succeed* with the quotes
/// left inside the key, looking up a key literally named `'R7'`, matching
/// nothing, and reporting no error at all.
///
/// Returns each token with a flag saying whether it arrived quoted. The flag
/// is what lets an argument list end at the right place: `LOOKUP "a" "b"` is
/// two keys, but `LOOKUP "a" LIMIT 5` must stop at LIMIT -- and the only
/// difference between a bare LIMIT and a key that happens to be spelled
/// "limit" is the quoting.
///
/// A comma is a separator, not a token: `LOOKUP "a", "b"` and `LOOKUP "a" "b"`
/// are the same query. Commas read naturally in a list and cost nothing to
/// ignore.
fn tokenize(input: &str) -> Result<(Vec<String>, Vec<bool>), ParseError> {
    let mut out = Vec::new();
    let mut quoted = Vec::new();
    let mut chars = input.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() || c == ',' {
            chars.next();
        } else if c == '"' || c == '\'' {
            let quote = c;
            chars.next();
            let mut buf = String::new();
            let mut closed = false;
            while let Some(c2) = chars.next() {
                if c2 == quote {
                    closed = true;
                    break;
                }
                buf.push(c2);
            }
            if !closed {
                return Err(ParseError::UnterminatedQuote);
            }
            out.push(buf);
            quoted.push(true);
        } else {
            let mut buf = String::new();
            while let Some(&c2) = chars.peek() {
                if c2.is_whitespace() || c2 == ',' {
                    break;
                }
                buf.push(c2);
                chars.next();
            }
            out.push(buf);
            quoted.push(false);
        }
    }
    Ok((out, quoted))
}

pub fn parse_query(input: &str) -> Result<ParsedQuery, ParseError> {
    let (toks, quoted) = tokenize(input)?;
    if toks.is_empty() {
        return Err(ParseError::Empty);
    }

    let mut q = ParsedQuery {
        mode: String::new(),
        args: Vec::new(),
        fuzzy: false,
        depth: 1,
        relation: None,
        source: None,
        model: None,
        limit: 20,
    };

    // Ordinary SQL, recognised by how it starts rather than by an announcement.
    // Everything is the payload, untouched: it runs SECURITY INVOKER and
    // read-only-enforced on the SQL side (brief.md §3), and the parser
    // deliberately does not try to validate it -- a half-parser that thinks it
    // understands SQL is exactly how an injection filter gets bypassed.
    let first = toks[0].to_uppercase();
    if SQL_OPENERS.contains(&first.as_str()) {
        q.mode = "SQL".into();
        q.args = vec![input.trim().to_string()];
        return Ok(q);
    }

    // FUZZY is a prefix adjective: `FUZZY LOOKUP "acme"`.
    let mut i = 0;
    if first == "FUZZY" {
        q.fuzzy = true;
        i = 1;
        if toks.len() < 2 {
            return Err(ParseError::MissingArgument(
                "FUZZY modifies a mode -- write FUZZY LOOKUP \"acme\"",
            ));
        }
    }

    let mode = toks[i].to_uppercase();
    q.mode = mode.clone();
    i += 1;

    // HYBRID was renamed to SEARCH. Refused with the new spelling rather than
    // aliased: an alias lets every document and stored definition keep the old
    // word indefinitely, and the whole point of the rename was that HYBRID
    // named the implementation instead of the intent.
    if mode == "HYBRID" {
        return Err(ParseError::Retired(
            "HYBRID is now SEARCH -- it names the intent rather than the rank \
             fusion behind it",
        ));
    }
    if mode == "SQL" {
        return Err(ParseError::Retired(
            "drop the SQL keyword and write the statement -- `select ...` is \
             recognised as SQL on its own",
        ));
    }

    if !matches!(
        mode.as_str(),
        "LOOKUP" | "SEMANTIC" | "GRAPH" | "TEXT" | "SEARCH" | "SCHEMA"
    ) {
        return Err(ParseError::UnknownMode(mode));
    }

    // FUZZY is trigram matching over node_keys, which only LOOKUP does.
    // Rejected rather than ignored on the others: silently dropping a modifier
    // the caller wrote is how a query quietly means something else.
    if q.fuzzy && mode != "LOOKUP" {
        return Err(ParseError::MissingArgument(
            "FUZZY applies only to LOOKUP -- SEMANTIC and SEARCH are already \
             approximate by construction",
        ));
    }

    // The argument list. Commas are optional separators, so both
    // `LOOKUP "a", "b"` and `LOOKUP "a" "b"` parse -- but an unquoted bare
    // word still ends the list, so `LOOKUP acme LIMIT 5` cannot swallow LIMIT.
    while i < toks.len() {
        let upper = toks[i].to_uppercase();
        let is_keyword = !quoted[i]
            && matches!(
                upper.as_str(),
                "DEPTH" | "TYPE" | "FROM" | "USING" | "LIMIT" | "FUZZY"
            );
        if is_keyword {
            break;
        }
        q.args.push(toks[i].clone());
        i += 1;
    }

    // Bare `SCHEMA` is legal and means the index. Every other mode needs to be
    // told what it is looking for; the whole point of this one is that it is
    // answerable before you know anything, so requiring an argument would put
    // the only bootstrapping query behind knowledge you do not yet have.
    if q.args.is_empty() && mode != "SCHEMA" {
        return Err(ParseError::MissingArgument(
            "expected a quoted argument, e.g. LOOKUP \"acme\"",
        ));
    }
    if q.args.len() > 1 && mode != "LOOKUP" {
        return Err(ParseError::UnexpectedToken(format!(
            "{} takes one argument, got {} -- only LOOKUP resolves a list",
            mode,
            q.args.len()
        )));
    }

    // Written-ness, not value: `limit` and `depth` carry defaults, so "was it
    // asked for" cannot be read off the struct afterwards. That distinction is
    // what lets a modifier be REFUSED where it means nothing rather than
    // silently ignored -- the rule this dialect already applies to USING and
    // FUZZY, extended to the two that had escaped it.
    let mut wrote_limit = false;
    let mut wrote_graph_modifier: Option<&'static str> = None;

    while i < toks.len() {
        match toks[i].to_uppercase().as_str() {
            // Trailing FUZZY was the old spelling. Refused with the new one:
            // accepting both would leave the dialect with two ways to say the
            // same thing and no reason to prefer either.
            "FUZZY" => {
                return Err(ParseError::Retired(
                    "FUZZY is now a prefix -- write FUZZY LOOKUP \"acme\"",
                ))
            }
            "DEPTH" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "DEPTH requires a number",
                ))?;
                q.depth = v
                    .parse::<i32>()
                    .map_err(|_| ParseError::BadNumber(v.clone()))?;
                wrote_graph_modifier = Some("DEPTH");
                i += 2;
            }
            "TYPE" => {
                let v = toks.get(i + 1).ok_or(ParseError::MissingArgument(
                    "TYPE requires a relation name",
                ))?;
                q.relation = Some(v.clone());
                wrote_graph_modifier = Some("TYPE");
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
                wrote_limit = true;
                i += 2;
            }
            _ => return Err(ParseError::UnexpectedToken(toks[i].clone())),
        }
    }

    // Every content-searching mode needs a source: there is no meaningful
    // default corpus, and silently picking one would make a typo look like an
    // empty result.
    if matches!(q.mode.as_str(), "SEMANTIC" | "TEXT" | "SEARCH") && q.source.is_none() {
        return Err(ParseError::MissingArgument(
            "SEMANTIC, TEXT and SEARCH each require FROM <source>",
        ));
    }
    // USING selects an embedding space, so it is meaningless where no vector
    // is involved. Rejected rather than ignored -- silently dropping a
    // modifier the caller wrote is how a query quietly means something else.
    if q.model.is_some() && !matches!(q.mode.as_str(), "SEMANTIC" | "SEARCH") {
        return Err(ParseError::MissingArgument(
            "USING <model> applies only to SEMANTIC and SEARCH",
        ));
    }
    // The same rule, applied to the two modifiers that had escaped it. DEPTH
    // and TYPE describe a traversal, so `LOOKUP "acme" DEPTH 3` parsed and
    // silently did a depth-1 lookup -- a query that quietly meant something
    // other than what it said, which is the exact failure the two rules above
    // exist to prevent. Found while adding SCHEMA, not by SCHEMA.
    if let Some(m) = wrote_graph_modifier {
        if q.mode != "GRAPH" {
            return Err(ParseError::MissingArgument(match m {
                "DEPTH" => "DEPTH applies only to GRAPH -- it describes a traversal",
                _ => "TYPE applies only to GRAPH -- it filters a relation on an edge",
            }));
        }
    }
    // A schema document is not a result set, so LIMIT has nothing to limit.
    if wrote_limit && q.mode == "SCHEMA" {
        return Err(ParseError::MissingArgument(
            "LIMIT does not apply to SCHEMA -- a schema document is not a result set. \
             Narrow it with SCHEMA \"sql\" FROM <relation> instead",
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
            // `arg` is the first argument and `args` is all of them. Both are
            // emitted rather than making every single-valued mode reach into
            // a one-element list, and rather than making LOOKUP's list-ness
            // invisible to a caller reading the plan.
            "arg": q.arg(),
            "args": q.args,
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

/// The dialect, described by the thing that parses it.
///
/// This exists so `SCHEMA "p8ql"` can hand an agent the grammar without a
/// second copy of it living in SQL or in markdown. A grammar written down
/// anywhere other than beside the parser is a grammar that will eventually
/// describe a dialect this crate no longer implements -- and an agent has no
/// way to notice, because a wrong grammar produces a parse error that reads
/// like the agent's mistake.
///
/// The `example` on each row is not decoration: the SQL side feeds every one
/// of them back through `aiq_parse` and reports whether it still parses, so a
/// row that stops being true announces itself instead of teaching a syntax
/// that no longer works.
#[pg_extern(immutable, parallel_safe)]
fn p8_query_grammar() -> pgrx::JsonB {
    pgrx::JsonB(serde_json::json!({
        "dialect": "p8ql",
        "one_endpoint": "aiq.query(text, vector) -- POST /rpc/query",
        "notes": [
            "Quotes are interchangeable ('...' and \"...\"), commas in a LOOKUP list are optional, and mode keywords are case-insensitive.",
            "A modifier that means nothing for a mode is REFUSED, never ignored: a query must not quietly mean something other than what it says.",
            "The response always carries the parsed plan alongside the rows, because a misparse is otherwise indistinguishable from an empty result."
        ],
        "modes": [
            {"mode": "LOOKUP",
             "syntax": "[FUZZY] LOOKUP \"<key>\" [, \"<key>\" ...] [LIMIT n]",
             "purpose": "Resolve one or more names to nodes. Takes a list because an agent almost never holds exactly one entity.",
             "example": "FUZZY LOOKUP \"acme\", \"globex\" LIMIT 5"},
            {"mode": "GRAPH",
             "syntax": "GRAPH \"<key>\" [DEPTH n] [TYPE <relation>] [LIMIT n]",
             "purpose": "Walk relationships out from a named node. DEPTH and TYPE apply only here.",
             "example": "GRAPH \"acme\" DEPTH 2 TYPE competes_with"},
            {"mode": "TEXT",
             "syntax": "TEXT \"<text>\" FROM <source> [LIMIT n]",
             "purpose": "Lexical search. Needs no embedding, which is why it answers the rare-exact-token case SEMANTIC misses.",
             "example": "TEXT \"R7 recall notice\" FROM chunks LIMIT 10"},
            {"mode": "SEMANTIC",
             "syntax": "SEMANTIC \"<text>\" FROM <source> [USING <model>] [LIMIT n]",
             "purpose": "Meaning-based search. The caller supplies the embedding; the database makes no model calls.",
             "example": "SEMANTIC \"battery safety\" FROM chunks USING nomic-embed-text"},
            {"mode": "SEARCH",
             "syntax": "SEARCH \"<text>\" FROM <source> [USING <model>] [LIMIT n]",
             "purpose": "Lexical and semantic rank fused. Named for the intent, not the fusion.",
             "example": "SEARCH \"safety recall\" FROM chunks LIMIT 5"},
            {"mode": "SCHEMA",
             "syntax": "SCHEMA [\"<facet>\"] [FROM <name>]",
             "purpose": "What this database IS. Bare SCHEMA is the index of facets; the argument names one. The only mode answerable before you know anything.",
             "example": "SCHEMA \"workflow\""},
            {"mode": "SQL",
             "syntax": "<any read-only SQL statement>",
             "purpose": "The floor everything else sits on. Recognised by how it starts, not by an announcement; executed read-only through the SECURITY INVOKER passthrough.",
             "example": "select count(*) from aiq.nodes"}
        ],
        "retired": [
            {"was": "HYBRID \"...\"", "now": "SEARCH \"...\"",
             "why": "HYBRID named the implementation; SEARCH names the intent."},
            {"was": "LOOKUP \"...\" FUZZY", "now": "FUZZY LOOKUP \"...\"",
             "why": "A modifier that changes what a query means belongs before the thing it modifies."},
            {"was": "SQL select ...", "now": "select ...",
             "why": "Ceremony on the one mode that needed no help identifying itself."}
        ]
    }))
}

/// The workflow YAML vocabulary, described by the compiler that reads it.
///
/// Same argument as p8_query_grammar, and the same mechanism: the SQL side
/// feeds the examples back through `p8_compile_workflow` and reports what
/// each one compiled to. An agent therefore gets the step vocabulary AND
/// proof that the spelling it is about to use still compiles on this
/// deployment -- which is the difference between documentation and a
/// capability report.
#[pg_extern(immutable, parallel_safe)]
fn p8_workflow_grammar() -> pgrx::JsonB {
    pgrx::JsonB(serde_json::json!({
        "document": {
            "name": "required -- the workflow's name",
            "version": "optional int, default 1",
            "steps": "required, non-empty. Each step: id, optional needs[], optional queue, and EXACTLY ONE action (or a matrix)."
        },
        "step_keys": {
            "id": "required, unique within the document; becomes the task's step_key",
            "needs": "list of step ids this one waits for -- an AND-join",
            "queue": "which worker pool claims it; in-database kinds ignore it",
            "compensate_with": "step id to run in reverse order if a saga member fails",
            "saga_group": "groups tasks compensated together"
        },
        "actions": [
            {"key": "p8ql", "compiles_to": "kind: sql", "runs_on": "nobody -- inside Postgres",
             "purpose": "A dialect query as a step. No process, no queue wait. In SEMANTIC or SEARCH mode it compiles to TWO tasks -- see `desugaring` below -- because those rank against a vector and the database makes no model calls."},
            {"key": "sql", "compiles_to": "kind: sql", "runs_on": "nobody -- inside Postgres",
             "purpose": "Call an allow-listed function by name. Steps may not supply arbitrary SQL; see workflow.step_functions for what is callable."},
            {"key": "rest", "compiles_to": "kind: http_call", "runs_on": "the worker's built-in handler",
             "purpose": "A durable outbound HTTP call. Retries, backoff and the reaper apply unchanged."},
            {"key": "embed", "compiles_to": "kind: http_call", "runs_on": "the worker's built-in handler",
             "purpose": "Turn text into a vector. Spelled `embed: \"<text>\"` or `embed: {text: ..., model: ...}`. You never write a url: the endpoint, request body and response path come from aiq.embedding_models and aiq.embedding_providers, and define_yaml fills them in. The result is the vector, so a search step reads it as {{steps.<id>.result}}."},
            {"key": "agent", "compiles_to": "kind: http_call", "runs_on": "the Agent Runtime",
             "purpose": "Names a row in agentic.agents. The agent's prompt and tools are data, so changing them never touches the workflow."},
            {"key": "work", "compiles_to": "kind: work", "runs_on": "your own code",
             "purpose": "The only case that needs a worker you wrote."},
            {"key": "matrix", "compiles_to": "kind: matrix", "runs_on": "nobody -- expansion is a transaction",
             "purpose": "Fan out over a row set: one child task per row, inserted by the statement that completes the parent. Requires max_fanout and exactly one of rows (a registered function) or items (a literal list). The template is an ordinary action, spelled the same way."}
        ],
        "templates": {
            "run": "{{run.x}} -- what start_workflow was called with",
            "steps": "{{steps.<id>.result}} -- a completed step's output",
            "item": "{{item.x}} -- one matrix row; bound only on fan-out children",
            "env": "{{env.X}} -- resolved by the WORKER only. sql steps have no env: the database has no business reading the deployment's environment.",
            "when": "All of these resolve at DISPATCH, never at definition time."
        },
        "desugaring": {
            "p8ql SEMANTIC/SEARCH": {
                "you_write": "- id: retrieve\n  p8ql: 'SEARCH \"outage causes\" FROM chunks LIMIT 5'",
                "compiles_to": "an http_call step keyed <id>__embed, plus the sql step keyed <id> calling p8ql_vec with {{steps.<id>__embed.result}} and depending on it",
                "your_id_stays_on_the_search": "successors still say needs: [<id>] and read {{steps.<id>.result}} -- the embed is a hidden PREDECESSOR, so nothing is rewired",
                "the_model_is_pinned_at_definition_time": "USING <model> is written into the query if it was not there, and refused if it disagrees with the embed step's model. A vector from one space ranked against another is not an error at runtime, only a meaningless number.",
                "queue": "queue: on the step routes the EMBED half; the search half runs in-database and is claimed by nobody",
                "escape_hatch": "write the two steps by hand -- `embed:` then `sql: {function: p8ql_vec, ...}` -- and you get the same rows"
            }
        },
        "limits": {
            "payload": "task input/output are capped (workflow.max_payload_bytes); anything larger must be a $ref to object storage",
            "max_fanout": "mandatory on a matrix step -- a cross join with a forgotten WHERE would otherwise insert the cartesian product as task rows"
        }
    }))
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use crate::*;

    #[pg_test]
    fn parses_plain_lookup() {
        let q = parse_query("LOOKUP \"acme\"").unwrap();
        assert_eq!(q.mode, "LOOKUP");
        assert_eq!(q.arg(), "acme");
        assert!(!q.fuzzy);
    }

    #[pg_test]
    fn parses_quoted_key_with_spaces_and_slashes() {
        let q = parse_query("LOOKUP \"places/ukraine/bakhmut city\"").unwrap();
        assert_eq!(q.arg(), "places/ukraine/bakhmut city");
    }

    /// Single quotes are the only ones left once SQL or YAML has taken the
    /// double quote, so they must produce the identical parse. The second
    /// assertion is the one that matters: before single quotes were a quoting
    /// character, this parsed *successfully* with `arg` as `'R7'`, which
    /// matches no key and raises no error.
    #[pg_test]
    fn single_quotes_quote_exactly_as_double_quotes_do() {
        assert_eq!(parse_query("LOOKUP 'R7 Notice'").unwrap().arg(), "R7 Notice");
        assert_eq!(parse_query("LOOKUP 'R7'").unwrap().arg(), "R7");
    }

    #[pg_test]
    fn unterminated_single_quote_is_an_error_not_a_key() {
        assert!(parse_query("LOOKUP 'R7 Notice").is_err());
    }

    #[pg_test]
    fn parses_fuzzy_and_limit() {
        let q = parse_query("FUZZY LOOKUP \"acme robotcs\" LIMIT 5").unwrap();
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
    fn parses_text_and_search_modes() {
        assert_eq!(parse_query("TEXT \"R7 arm\" FROM chunks").unwrap().mode, "TEXT");
        let h = parse_query("SEARCH \"R7 arm\" FROM chunks USING nomic-embed-text LIMIT 5").unwrap();
        assert_eq!(h.mode, "SEARCH");
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
        for m in ["SEMANTIC", "TEXT", "SEARCH"] {
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
    /// SQL needs no keyword: it is recognised by how it starts.
    fn sql_passthrough_is_untouched() {
        let q = parse_query("select 1 from t where x = 'y'").unwrap();
        assert_eq!(q.mode, "SQL");
        assert_eq!(q.arg(), "select 1 from t where x = 'y'");
        assert_eq!(parse_query("WITH x as (select 1) select * from x").unwrap().mode, "SQL");
    }

    /// LOOKUP resolves a list; commas are optional and every other mode
    /// refuses one, so a second argument is never quietly ignored.
    #[pg_test]
    fn lookup_takes_a_list() {
        let q = parse_query("LOOKUP \"acme\", \"nadler dynamics\", \"R7\"").unwrap();
        assert_eq!(q.args, vec!["acme", "nadler dynamics", "R7"]);
        assert_eq!(q.arg(), "acme");

        assert_eq!(parse_query("LOOKUP \"a\" \"b\"").unwrap().args, vec!["a", "b"]);

        // a bare keyword ends the list rather than joining it
        let q = parse_query("LOOKUP \"a\", \"b\" LIMIT 5").unwrap();
        assert_eq!(q.args, vec!["a", "b"]);
        assert_eq!(q.limit, 5);

        assert!(parse_query("SEARCH \"a\", \"b\" FROM chunks").is_err());
    }

    /// The three retired spellings each name their replacement. Asserted
    /// because a rename whose error says only "unknown mode" is a worse
    /// dialect than the one it replaced.
    #[pg_test]
    fn retired_spellings_say_what_to_write_instead() {
        for (q, want) in [
            ("HYBRID \"x\" FROM chunks", "SEARCH"),
            ("LOOKUP \"acme\" FUZZY", "prefix"),
            ("SQL select 1", "drop the SQL keyword"),
        ] {
            let e = parse_query(q).unwrap_err().message();
            assert!(e.contains(want), "{q} -> {e}");
        }
    }

    /// FUZZY is trigram matching over node_keys, which only LOOKUP does.
    #[pg_test]
    fn fuzzy_outside_lookup_is_refused_not_ignored() {
        assert!(parse_query("FUZZY SEARCH \"x\" FROM chunks").is_err());
        assert!(parse_query("FUZZY GRAPH \"acme\"").is_err());
    }

    /// A misspelled mode stays a dialect error. If anything unrecognised were
    /// treated as SQL, this would reach the SQL parser and come back as a
    /// syntax error about a language the caller was not writing.
    #[pg_test]
    fn a_typo_is_not_mistaken_for_sql() {
        let e = parse_query("LOKUP \"acme\"").unwrap_err().message();
        assert!(e.contains("unknown mode"), "{e}");
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

// deny_unknown_fields, on every struct an author writes into.
//
// A key this compiler does not know is either a typo or a feature it predates,
// and serde's default -- drop it -- makes both silent. That is how an
// `output_schema` declared on a step compiled clean and simply was not there at
// runtime: the author wrote a contract, got a green run, and reasonably
// concluded it was enforced.
//
// This is the durable half of that fix. The engine-side check in define_yaml is
// the half that works on a deployment whose .so is already old, which is
// exactly the situation that produced the bug.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WfDoc {
    name: String,
    #[serde(default)]
    version: Option<i32>,
    steps: Vec<WfStep>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
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
    // `embed:` is a REST call whose url, body shape and response path the
    // author never writes -- they are rows in aiq.embedding_models and
    // aiq.embedding_providers, filled in by define_yaml. See EmbedStep.
    #[serde(default)]
    embed: Option<serde_yaml::Value>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    work: Option<bool>,
    // ...or a matrix, which is not an action but a fan-out OVER one.
    #[serde(default)]
    matrix: Option<WfMatrix>,
    // The three kinds the engine has always supported and the compiler could
    // not express -- found by trying to author a human-in-the-loop workflow
    // and being refused. `SCHEMA "workflow"` reported all eight legal kinds
    // while this file accepted five, so the capability document contradicted
    // the tool it described.
    #[serde(default)]
    signal: Option<serde_yaml::Value>,      // true -> named after the step id
    #[serde(default)]
    timer: Option<f64>,                     // seconds, measured from readiness
    #[serde(default)]
    workflow: Option<String>,               // a sub_workflow, by name

    // agent steps
    #[serde(default)]
    input: Option<serde_yaml::Value>,
    #[serde(default)]
    session: Option<String>,
    // FEATURE 1a. A workflow could not ORIGINATE a session: `session:` resolved
    // only if the CALLER put an id in the run input -- the same circularity as
    // BUG 1, since the natural key derives from the run and the run could not
    // see itself. `session_group` asks the engine to mint one, stable for the
    // life of the run, so several agent steps share a conversation by naming
    // the same group and stay stateless by declaring none. Two groups in one
    // run are two independent threads.
    #[serde(default)]
    session_group: Option<String>,
    // FEATURE 1b. jsonpath was hard-coded to the assistant text, so anything
    // else the runtime returned -- a session id it issued, token counts, tool
    // traces -- was discarded before reaching runs.context, and
    // {{steps.<id>.session}} could never resolve. The default is unchanged.
    #[serde(default)]
    jsonpath: Option<String>,
    // Declaring the shape an agent must return is what makes N agent results
    // combinable: a fan-in over them can read a column instead of inspecting
    // each answer. Checked by the engine on completion, and a violation is
    // RETRYABLE -- asking a model again is a real remedy.
    #[serde(default)]
    output_schema: Option<serde_yaml::Value>,

    // saga
    #[serde(default)]
    compensate_with: Option<String>,
    #[serde(default)]
    saga_group: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SqlStep {
    function: String,
    #[serde(default)]
    args: Vec<serde_yaml::Value>,
}

// `embed:` -- the one action whose ENDPOINT is deployment data.
//
// Every other action is fully described by what the author wrote: a `rest:`
// step carries its url, a `sql:` step names its function. An embedding call
// cannot be, and the reason is in ai-query-layer/schema.sql §10: a vector is
// only comparable inside the space of the MODEL that produced it, and which
// models exist, where they are served and what their request and response
// shapes look like are rows in aiq.embedding_models and
// aiq.embedding_providers. Spelling a url in the YAML would put a deployment
// fact in a document that is meant to survive deployments -- and, worse, would
// let a workflow embed with one model and search a space built by another,
// which is not an error anywhere: cosine distance between two spaces is a
// number, just a meaningless one.
//
// So the compiler emits a MARKER -- {"embed": {text, model}} and no url -- and
// define_yaml fills it in from the registry, pinning the model into both
// halves at once. The marker is deliberately unrunnable: an http_call with no
// url is refused by the lint, so a spec that reached workflow.definitions
// without passing the expander cannot quietly become a task nobody can
// explain.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EmbedStep {
    text: String,
    // Optional because a deployment has a default model. Naming one pins it,
    // which is what a workflow searching a space built by a specific model
    // wants; leaving it out asks define_yaml for the default AT DEFINITION
    // TIME, so the answer is recorded in the spec rather than re-decided per
    // run by whichever row happens to carry is_default that day.
    #[serde(default)]
    model: Option<String>,
}

// `embed: "some text"` and `embed: {text: ..., model: ...}` are the same step.
// Hand-parsed rather than an untagged enum: serde's untagged error for a typo
// is "data did not match any variant", which tells an author nothing about
// which of the two spellings they were closer to.
fn parse_embed(what: &str, v: &serde_yaml::Value) -> Result<(String, Option<String>), String> {
    match v {
        serde_yaml::Value::String(t) => Ok((t.clone(), None)),
        serde_yaml::Value::Mapping(_) => {
            let e: EmbedStep = serde_yaml::from_value(v.clone()).map_err(|err| {
                format!(
                    "{}: {}. An embed step is `embed: \"<text>\"` or \
                     `embed: {{text: <text>, model: <a registered model>}}` -- the url is \
                     not yours to write, it comes from aiq.embedding_models.",
                    what, err)
            })?;
            Ok((e.text, e.model))
        }
        _ => Err(format!(
            "{} has an `embed:` that is neither text nor a mapping. Write \
             `embed: \"<text>\"` or `embed: {{text: <text>, model: <a registered model>}}`.",
            what)),
    }
}

// SEMANTIC and SEARCH rank against a vector, and the database cannot make one:
// embedding is a model call and no HTTP client is installed. That has always
// been true, and the consequence used to be the author's problem -- two steps,
// hand-wired, with the model named twice or not at all.
//
// It is a COMPILER's problem, because the compiler is the one thing here that
// already knows which modes need a vector: parse_query lives in this crate.
// Returns the text to embed and the model named by USING, or None for the
// modes that need neither.
//
// A query that does not parse returns None rather than an error, deliberately:
// the compiler has never been the thing that reports a bad query -- the lint
// (workflow.lint_spec) is, with the step key and the parser's own message --
// and turning a parse failure into a compile failure here would move that
// diagnosis to a worse place. A query that is itself a template
// (`p8ql: '{{run.query}}'`) lands here too, and correctly compiles to the
// one-argument form: nothing can know at authoring time what mode it will be.
fn vector_mode_of(query: &str) -> Option<(String, Option<String>)> {
    let p = parse_query(query).ok()?;
    match p.mode.as_str() {
        "SEMANTIC" | "SEARCH" => Some((p.arg().to_string(), p.model.clone())),
        _ => None,
    }
}

// A matrix step: a row set, a ceiling, and ONE ordinary step spelled once and
// run per row. The template is deliberately the same vocabulary as a top-level
// step (rest/sql/p8ql/embed/agent/work) rather than a second syntax -- YAML.md's
// rule that every high-level step must remain expressible in raw steps applies
// to the thing being fanned out as much as to the fan-out.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WfMatrix {
    // exactly one of rows / items
    #[serde(default)]
    rows: Option<SqlStep>,
    #[serde(default)]
    items: Option<Vec<serde_yaml::Value>>,
    // NOT optional in practice -- see the check in compile_workflow. Declared
    // Option only so a missing one is a named error rather than a serde
    // "missing field" message that does not say why it matters.
    #[serde(default)]
    max_fanout: Option<i64>,
    // A fan-out over real sources meets an absent record, a rate limit or an
    // oversized response on essentially every run. `continue_on: failed` makes
    // a failed child satisfy its dependents instead of cancelling them;
    // `min_success` is the floor that keeps that from silently averaging over
    // survivors -- a fraction (<= 1) or an absolute count (> 1).
    #[serde(default)]
    continue_on: Option<String>,
    #[serde(default)]
    min_success: Option<f64>,
    template: WfTemplate,
}

// The same action fields a step has, minus the graph and saga ones: a child
// has no `needs` (it depends on nothing but the expansion) and no `id` (it is
// keyed <step>[<i>] by the engine).
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WfTemplate {
    #[serde(default)]
    queue: Option<String>,
    #[serde(default)]
    p8ql: Option<String>,
    #[serde(default)]
    sql: Option<SqlStep>,
    #[serde(default)]
    rest: Option<serde_yaml::Value>,
    #[serde(default)]
    embed: Option<serde_yaml::Value>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    work: Option<bool>,
    #[serde(default)]
    input: Option<serde_yaml::Value>,
    #[serde(default)]
    session: Option<String>,
    #[serde(default)]
    session_group: Option<String>,
    #[serde(default)]
    jsonpath: Option<String>,
    #[serde(default)]
    rate_key: Option<String>,
    // Rejected, not ignored. serde drops unknown keys, so without this field a
    // nested matrix compiles to "template has no action" -- a true statement
    // that tells the author nothing about what they actually wrote.
    #[serde(default)]
    matrix: Option<serde_yaml::Value>,
}

fn y2j(v: &serde_yaml::Value) -> serde_json::Value {
    serde_json::to_value(v).unwrap_or(serde_json::Value::Null)
}

// The action half of a step, borrowed rather than owned so a top-level step
// and a matrix template can be resolved by the same code. They must be: a
// matrix child is an ordinary step, and a second copy of this match is a
// second place for the vocabularies to drift apart.
struct Action<'a> {
    p8ql: &'a Option<String>,
    sql: &'a Option<SqlStep>,
    rest: &'a Option<serde_yaml::Value>,
    embed: &'a Option<serde_yaml::Value>,
    agent: &'a Option<String>,
    work: Option<bool>,
    queue: &'a Option<String>,
    input: &'a Option<serde_yaml::Value>,
    session: &'a Option<String>,
    session_group: &'a Option<String>,
    jsonpath: &'a Option<String>,
}

fn resolve_action(what: &str, a: &Action) -> Result<(&'static str, String, serde_json::Value), String> {
    let chosen: Vec<&str> = [
        a.p8ql.is_some().then_some("p8ql"),
        a.sql.is_some().then_some("sql"),
        a.rest.is_some().then_some("rest"),
        a.embed.is_some().then_some("embed"),
        a.agent.is_some().then_some("agent"),
        a.work.unwrap_or(false).then_some("work"),
    ].into_iter().flatten().collect();
    if chosen.len() != 1 {
        return Err(format!(
            "{} must have exactly one of p8ql/sql/rest/embed/agent/work, found {}",
            what,
            if chosen.is_empty() { "none".to_string() } else { chosen.join(" + ") }
        ));
    }

    Ok(match chosen[0] {
        // P8QL runs in-database as an allow-listed sql step. No queue, no
        // process: 'none' is a label, nothing polls it.
        "p8ql" => ("sql", "none".to_string(), serde_json::json!({
            "function": "p8ql",
            "args": [a.p8ql.clone().unwrap()]
        })),
        "sql" => {
            let sq = a.sql.as_ref().unwrap();
            ("sql", "none".to_string(), serde_json::json!({
                "function": sq.function,
                "args": sq.args.iter().map(y2j).collect::<Vec<_>>()
            }))
        }
        "rest" => ("http_call",
            a.queue.clone().unwrap_or_else(|| "http".into()),
            y2j(a.rest.as_ref().unwrap())),
        // A MARKER, not a call: url, method, body and jsonpath are added by
        // define_yaml from the model registry (see EmbedStep). The queue is
        // the ordinary http one by default, because after expansion this is an
        // ordinary http_call and the shipped worker already polls it --
        // `queue: embed` routes it to a pool of its own where one exists.
        "embed" => {
            let (text, model) = parse_embed(what, a.embed.as_ref().unwrap())?;
            ("http_call", a.queue.clone().unwrap_or_else(|| "http".into()),
             serde_json::json!({"embed": {"text": text, "model": model}}))
        }
        // An agent step is a REST call to the Agent Runtime with the agent
        // NAMED, not defined -- the agent itself is a row in agentic.agents,
        // so changing its prompt or tools never touches this workflow.
        "agent" => {
            // An explicit `session:` still wins -- a caller threading an id it
            // already holds is the case that always worked. Otherwise a
            // declared session_group asks the ENGINE for one; declaring
            // neither stays stateless, which is the right default.
            let session = match (a.session, a.session_group) {
                (Some(s), _) => Some(s.clone()),
                (None, Some(_)) => Some("{{run.$session}}".to_string()),
                _ => None,
            };
            let mut input = serde_json::json!({
                "url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                "method": "POST",
                "credential_ref": "P8_API_KEY",
                "timeout_ms": 120000,
                "body": {
                    "model": a.agent.clone().unwrap(),
                    "session": session,
                    "messages": [{"role": "user",
                                  "content": a.input.as_ref().map(y2j)
                                      .unwrap_or(serde_json::Value::Null)}]
                },
                // The assistant text is what almost every step wants, so it
                // stays the default. Override to capture the whole envelope --
                // a session id the runtime issued, token counts, tool traces.
                "jsonpath": a.jsonpath.clone()
                    .unwrap_or_else(|| "choices.0.message.content".into())
            });
            // Carried on the task so get_task_context can bind {{run.$session}}
            // to THIS step's thread rather than the run's default one.
            if let Some(g) = a.session_group {
                input["session_group"] = serde_json::json!(g);
            }
            ("http_call", a.queue.clone().unwrap_or_else(|| "http".into()), input)
        }
        _ => ("work", a.queue.clone().unwrap_or_else(|| "default".into()),
              a.input.as_ref().map(y2j).unwrap_or(serde_json::json!({}))),
    })
}

// The three control kinds: wait for a person, wait for a clock, run another
// workflow. None of them ACTS, which is why they sit outside resolve_action's
// exactly-one-of rule rather than inside it.
fn compile_control(id: &str, s: &WfStep) -> Result<(&'static str, String, serde_json::Value), String> {
    let chosen: Vec<&str> = [
        s.signal.is_some().then_some("signal"),
        s.timer.is_some().then_some("timer"),
        s.workflow.is_some().then_some("workflow"),
    ].into_iter().flatten().collect();
    if chosen.len() != 1 {
        return Err(format!(
            "step '{}' has {} -- signal, timer and workflow are alternatives, not a set",
            id, chosen.join(" + ")));
    }
    let acted: Vec<&str> = [
        s.p8ql.is_some().then_some("p8ql"), s.sql.is_some().then_some("sql"),
        s.rest.is_some().then_some("rest"), s.embed.is_some().then_some("embed"),
        s.agent.is_some().then_some("agent"),
        s.work.unwrap_or(false).then_some("work"),
    ].into_iter().flatten().collect();
    if !acted.is_empty() {
        return Err(format!(
            "step '{}' is a {} step and also declares `{}`. A control step waits; it does \
             not act.", id, chosen[0], acted.join(" + ")));
    }

    // Every one of these runs in-database or waits, so none is claimed from a
    // queue: 'none' is the same label p8ql and sql steps carry.
    match chosen[0] {
        "signal" => {
            // `signal: true` is named after the step; `signal: approved_by_ops`
            // names it explicitly, for when one run waits on two different
            // things and the step ids are not the vocabulary the signaller uses.
            let name = match s.signal.as_ref().unwrap() {
                serde_yaml::Value::Bool(true) => id.to_string(),
                serde_yaml::Value::String(n) => n.clone(),
                other => return Err(format!(
                    "step '{}' has signal: {:?} -- write `signal: true` to wait on the \
                     step's own name, or `signal: <name>`", id, other)),
            };
            Ok(("signal", "none".to_string(), serde_json::json!({"signal": name})))
        }
        "timer" => {
            let secs = s.timer.unwrap();
            if secs <= 0.0 {
                return Err(format!("step '{}' has timer: {}, which waits for nothing", id, secs));
            }
            Ok(("timer", "none".to_string(), serde_json::json!({"delay_seconds": secs})))
        }
        _ => {
            let name = s.workflow.clone().unwrap();
            Ok(("sub_workflow", "none".to_string(), serde_json::json!({
                "workflow": name,
                "input": s.input.as_ref().map(y2j).unwrap_or(serde_json::json!({}))
            })))
        }
    }
}

// A matrix compiles to ONE task row of kind 'matrix'. The engine
// (workflow.expand_matrix, schema.sql §20) turns it into N children inside the
// transaction that completes it, rewires the successors onto them, and records
// each row on the child it produced.
//
// The checks below duplicate the engine's on purpose, and the duplication is
// the point rather than an oversight -- YAML.md §"What the compiler checks":
// the compiler catches it at AUTHORING time with the step id in the message,
// the engine catches it at REGISTRATION time because a spec can also arrive as
// JSON without passing through here. `max_fanout` is the one that matters
// most: a cross join with a forgotten WHERE is the obvious way to hurt
// yourself with this feature, and the ceiling should be a thing you had to
// write down.
fn compile_matrix(id: &str, m: &WfMatrix, s: &WfStep)
    -> Result<(&'static str, String, serde_json::Value), String>
{
    let acted: Vec<&str> = [
        s.p8ql.is_some().then_some("p8ql"),
        s.sql.is_some().then_some("sql"),
        s.rest.is_some().then_some("rest"),
        s.agent.is_some().then_some("agent"),
        s.work.unwrap_or(false).then_some("work"),
    ].into_iter().flatten().collect();
    if !acted.is_empty() {
        return Err(format!(
            "step '{}' has both `matrix` and `{}`. A matrix does not act; it fans out \
             over the action in its `template`.", id, acted.join(" + ")));
    }

    if m.rows.is_some() == m.items.is_some() {
        return Err(format!(
            "matrix step '{}' must declare exactly one of `rows` (a registered function) \
             or `items` (a literal list)", id));
    }
    let max_fanout = m.max_fanout.ok_or_else(|| format!(
        "matrix step '{}' declares no `max_fanout`. A matrix needs a ceiling: a cross join \
         with a forgotten WHERE expands to the cartesian product, and that should fail this \
         step rather than the database.", id))?;
    if max_fanout < 1 {
        return Err(format!("matrix step '{}' has max_fanout {}, which expands to nothing",
                           id, max_fanout));
    }

    // A child has no static successors to rewire, so a matrix inside a matrix
    // would produce grandchildren that nothing waits on -- a run that reports
    // completion before they finish. The engine refuses it too
    // (workflow.validate_matrix_steps); this is the copy that names the step.
    if m.template.matrix.is_some() {
        return Err(format!(
            "matrix step '{}' templates another matrix. Nested fan-out is not supported: \
             the grandchildren would never be joined to this step's successors, so the run \
             would complete before they finished.", id));
    }

    // A template is ONE step, and a vector-mode query is two. Refused by name
    // rather than compiled into a search with no vector, which is a runtime
    // failure on every child at once.
    if let Some(q) = &m.template.p8ql {
        if vector_mode_of(q).is_some() {
            return Err(format!(
                "matrix step '{}' templates a SEMANTIC/SEARCH query, which needs an embedding \
                 and therefore two steps -- a template is one. Fan out over `embed:` and search \
                 in a fan-in step, or embed once before the matrix and pass \
                 {{{{steps.<id>.result}}}} to a `sql:` template calling p8ql_vec.", id));
        }
    }

    let (tkind, tqueue, tinput) = resolve_action(
        &format!("the matrix template of step '{}'", id),
        &Action {
            p8ql: &m.template.p8ql, sql: &m.template.sql, rest: &m.template.rest,
            embed: &m.template.embed,
            agent: &m.template.agent, work: m.template.work,
            queue: &m.template.queue, input: &m.template.input,
            session: &m.template.session,
            session_group: &m.template.session_group, jsonpath: &m.template.jsonpath,
        })?;

    if let Some(c) = &m.continue_on {
        if c != "failed" {
            return Err(format!(
                "matrix step '{}' has continue_on: '{}'. The only value is `failed` -- \
                 there is nothing else a child can do that a parent might tolerate.",
                id, c));
        }
    }
    if let Some(ms) = m.min_success {
        if ms <= 0.0 {
            return Err(format!(
                "matrix step '{}' has min_success {}, which requires nothing", id, ms));
        }
        if m.continue_on.is_none() {
            return Err(format!(
                "matrix step '{}' sets min_success without continue_on: failed. Without \
                 continue_on the first failed child cancels the successors, so a threshold \
                 could never be reached -- and reading this spec would suggest otherwise.",
                id));
        }
    }

    let mut input = serde_json::json!({
        "max_fanout": max_fanout,
        "template": {"queue": tqueue, "kind": tkind, "input": tinput},
    });
    if let Some(c) = &m.continue_on {
        input["continue_on"] = serde_json::json!(c);
    }
    if let Some(ms) = m.min_success {
        input["min_success"] = serde_json::json!(ms);
    }
    if let Some(rk) = &m.template.rate_key {
        input["template"]["rate_key"] = serde_json::json!(rk);
    }
    if let Some(r) = &m.rows {
        input["rows"] = serde_json::json!({
            "function": r.function,
            "args": r.args.iter().map(y2j).collect::<Vec<_>>()
        });
    } else {
        input["items"] = serde_json::json!(
            m.items.as_ref().unwrap().iter().map(y2j).collect::<Vec<_>>());
    }

    // Expansion happens in-database, so the matrix task itself is claimed by
    // nobody -- 'none' is the same label p8ql and sql steps carry.
    Ok(("matrix", s.queue.clone().unwrap_or_else(|| "none".into()), input))
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

        let kind_is_agent = s.agent.is_some();
        let (kind, queue, mut input) = if let Some(m) = &s.matrix {
            compile_matrix(&s.id, m, s)?
        } else if s.signal.is_some() || s.timer.is_some() || s.workflow.is_some() {
            compile_control(&s.id, s)?
        } else {
            resolve_action(&format!("step '{}'", s.id), &Action {
                p8ql: &s.p8ql, sql: &s.sql, rest: &s.rest, embed: &s.embed,
                agent: &s.agent,
                work: s.work, queue: &s.queue, input: &s.input, session: &s.session,
                session_group: &s.session_group, jsonpath: &s.jsonpath,
            })?
        };

        // Agent-only keys, refused elsewhere rather than ignored. deny_unknown_fields
        // stops a TYPO being dropped; this stops a REAL key being dropped because
        // it means nothing for the kind it was written on -- the same silent
        // class, one level up. It is also the rule the query dialect already
        // applies to USING, DEPTH and TYPE: a modifier that means nothing where
        // it is written is an error, because silently discarding it is how a
        // document quietly means something other than what it says.
        for (key, present) in [("session", s.session.is_some()),
                               ("session_group", s.session_group.is_some()),
                               ("jsonpath", s.jsonpath.is_some())] {
            if present && kind_is_agent == false {
                return Err(format!(
                    "step '{}' declares `{}`, which applies only to an `agent:` step. \
                     For a `rest:` step, jsonpath belongs inside the rest block.",
                    s.id, key));
            }
        }

        // ---- the vector-mode desugar --------------------------------------
        //
        // `p8ql: 'SEARCH "..." FROM chunks'` compiles to TWO rows: an embed
        // step and the search that consumes it. What makes this sugar rather
        // than a new step kind is that both rows are ones an author can write
        // by hand today -- YAML.md's promotion rule -- and the test is a diff:
        // this must emit exactly what the hand-written pair emits.
        //
        // It PREPENDS a hidden predecessor rather than inserting children, and
        // that is the difference from `matrix:` that makes it cheap. The
        // author's step id stays on the SEARCH, which is the step that
        // produces the result, so every successor's `needs:` and every
        // {{steps.<id>.result}} still mean what they meant. Nothing is
        // rewired, because nothing moved.
        let mut extra_dep: Option<String> = None;
        if let Some(q) = &s.p8ql {
            if let Some((text, model)) = vector_mode_of(q) {
                let ekey = format!("{}__embed", s.id);
                if ids.contains(&ekey.as_str()) {
                    return Err(format!(
                        "step '{}' is a SEMANTIC/SEARCH query, which compiles to an embed step \
                         named '{}' -- and this workflow already has a step by that name. \
                         Rename one of them.", s.id, ekey));
                }
                steps.push(serde_json::json!({
                    "key": ekey, "kind": "http_call",
                    "queue": s.queue.clone().unwrap_or_else(|| "http".into()),
                    "input": {"embed": {"text": text, "model": model}}
                }));
                // The two-argument registration. Same function underneath
                // (workflow.p8ql); the second name is how the allow-list
                // distinguishes the arity that takes a vector.
                input["function"] = serde_json::json!("p8ql_vec");
                input["args"] = serde_json::json!([
                    q.clone(), format!("{{{{steps.{}.result}}}}", ekey)]);
                extra_dep = Some(ekey);
            }
        }

        let mut step = serde_json::json!({
            "key": s.id, "kind": kind, "queue": queue, "input": input
        });
        if let Some(sc) = &s.output_schema {
            if kind == "sql" || kind == "matrix" {
                return Err(format!(
                    "step '{}' declares output_schema on a {} step. The shape check is for \
                     output this engine did not produce -- a model's answer or a remote \
                     response; a registered function's return type is already known.",
                    s.id, kind));
            }
            step["input"]["output_schema"] = y2j(sc);
        }
        if !s.needs.is_empty() || extra_dep.is_some() {
            let mut deps = s.needs.clone();
            if let Some(d) = extra_dep { deps.push(d); }
            step["depends_on"] = serde_json::json!(deps);
        }
        // saga_group is emitted INDEPENDENTLY of compensate_with, and tying
        // the two together was a real bug found by running a saga: the step
        // that FAILS is usually the one with nothing to undo, so it declares
        // saga_group and no compensate_with -- and it was losing its group
        // membership in compilation. fail_task keys the rollback off exactly
        // that field, so the member whose failure starts the saga was the one
        // member the engine could not see.
        if let Some(c) = &s.compensate_with {
            if !ids.contains(&c.as_str()) {
                return Err(format!(
                    "step '{}' compensates with '{}', which is not a step in this workflow",
                    s.id, c));
            }
            step["compensation_task_key"] = serde_json::json!(c);
        }
        if s.saga_group.is_some() || s.compensate_with.is_some() {
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
