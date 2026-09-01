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
//   <any ordinary SQL statement>
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
            ParseError::UnknownMode(m) => format!(
                "unknown mode '{m}' -- expected one of LOOKUP, SEMANTIC, TEXT, SEARCH, GRAPH, \
                 or an ordinary SQL statement"
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
        "LOOKUP" | "SEMANTIC" | "GRAPH" | "TEXT" | "SEARCH"
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

    if q.args.is_empty() {
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
    // ...or a matrix, which is not an action but a fan-out OVER one.
    #[serde(default)]
    matrix: Option<WfMatrix>,

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

// A matrix step: a row set, a ceiling, and ONE ordinary step spelled once and
// run per row. The template is deliberately the same vocabulary as a top-level
// step (rest/sql/p8ql/agent/work) rather than a second syntax -- YAML.md's
// rule that every high-level step must remain expressible in raw steps applies
// to the thing being fanned out as much as to the fan-out.
#[derive(Deserialize)]
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
    template: WfTemplate,
}

// The same action fields a step has, minus the graph and saga ones: a child
// has no `needs` (it depends on nothing but the expansion) and no `id` (it is
// keyed <step>[<i>] by the engine).
#[derive(Deserialize)]
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
    agent: Option<String>,
    #[serde(default)]
    work: Option<bool>,
    #[serde(default)]
    input: Option<serde_yaml::Value>,
    #[serde(default)]
    session: Option<String>,
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
    agent: &'a Option<String>,
    work: Option<bool>,
    queue: &'a Option<String>,
    input: &'a Option<serde_yaml::Value>,
    session: &'a Option<String>,
}

fn resolve_action(what: &str, a: &Action) -> Result<(&'static str, String, serde_json::Value), String> {
    let chosen: Vec<&str> = [
        a.p8ql.is_some().then_some("p8ql"),
        a.sql.is_some().then_some("sql"),
        a.rest.is_some().then_some("rest"),
        a.agent.is_some().then_some("agent"),
        a.work.unwrap_or(false).then_some("work"),
    ].into_iter().flatten().collect();
    if chosen.len() != 1 {
        return Err(format!(
            "{} must have exactly one of p8ql/sql/rest/agent/work, found {}",
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
        // An agent step is a REST call to the Agent Runtime with the agent
        // NAMED, not defined -- the agent itself is a row in agentic.agents,
        // so changing its prompt or tools never touches this workflow.
        "agent" => ("http_call",
            a.queue.clone().unwrap_or_else(|| "http".into()),
            serde_json::json!({
                "url": "{{env.P8_AGENT_URL}}/v1/chat/completions",
                "method": "POST",
                "credential_ref": "P8_API_KEY",
                "timeout_ms": 120000,
                "body": {
                    "model": a.agent.clone().unwrap(),
                    "session": a.session.clone(),
                    "messages": [{"role": "user",
                                  "content": a.input.as_ref().map(y2j)
                                      .unwrap_or(serde_json::Value::Null)}]
                },
                "jsonpath": "choices.0.message.content"
            })),
        _ => ("work", a.queue.clone().unwrap_or_else(|| "default".into()),
              a.input.as_ref().map(y2j).unwrap_or(serde_json::json!({}))),
    })
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

    let (tkind, tqueue, tinput) = resolve_action(
        &format!("the matrix template of step '{}'", id),
        &Action {
            p8ql: &m.template.p8ql, sql: &m.template.sql, rest: &m.template.rest,
            agent: &m.template.agent, work: m.template.work,
            queue: &m.template.queue, input: &m.template.input,
            session: &m.template.session,
        })?;

    let mut input = serde_json::json!({
        "max_fanout": max_fanout,
        "template": {"queue": tqueue, "kind": tkind, "input": tinput},
    });
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

        let (kind, queue, input) = if let Some(m) = &s.matrix {
            compile_matrix(&s.id, m, s)?
        } else {
            resolve_action(&format!("step '{}'", s.id), &Action {
                p8ql: &s.p8ql, sql: &s.sql, rest: &s.rest, agent: &s.agent,
                work: s.work, queue: &s.queue, input: &s.input, session: &s.session,
            })?
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
