/* The whole data layer.
 *
 * There is no server of ours between the browser and Postgres. Every read is a
 * PostgREST URL against an RLS-filtered view; every write is `POST /rpc/<fn>`
 * against a SECURITY DEFINER function that checks permission itself. That is
 * the point: this file cannot grant anyone anything, because it has no
 * privileges of its own -- it carries the caller's JWT and nothing else.
 *
 * Two PostgREST facts this file exists to encapsulate:
 *   1. Multi-schema. PGRST_DB_SCHEMAS lists six; the FIRST one (content) is the
 *      default, and every other schema needs `Accept-Profile` on reads and
 *      `Content-Profile` on writes. Without them you get a 404 naming
 *      `content.rbac.users_api`, which is a confusing way to say "wrong header".
 *   2. Counts come from the `Content-Range` header with `Prefer: count=exact`,
 *      NOT from an aggregate -- aggregates are disabled on this deployment
 *      (PGRST123), deliberately, so a dashboard tile is a HEAD request rather
 *      than a group-by somebody could point at a million rows.
 */

/* Where this page points, in precedence order:
 *
 *   1. an explicit override this browser stored (the Settings screen)
 *   2. `config.json` from this page's own origin, when percolate-core is
 *      serving it -- the deployment says where PostgREST is, because a client
 *      guessing that gets it right in exactly one deployment
 *   3. the dev stack's ports, so the page still works opened as a file
 *
 * `dev_token` is the server's answer to whether the sign-in page may mint a
 * JWT in the browser. Off unless a deployment turns it on: right for a
 * workbench whose secret is printed in a compose file, a hole anywhere else. */
const CONFIG = {
  rest: localStorage.getItem("p8-rest") || "http://localhost:5611",
  core: localStorage.getItem("p8-core") || "http://localhost:5613",
  content: localStorage.getItem("p8-content") || "",
  devToken: true,          // until the server says otherwise; see loadConfig
  devSecret: "",           // never a default: the deployment supplies it or nobody does
  devUser: "",             // the development sign-in's user, when the deployment names one
  served: false,
};

export function config() { return { ...CONFIG }; }
export function setEndpoint(k, v) { localStorage.setItem("p8-" + k, v); CONFIG[k] = v; }

export async function loadConfig() {
  try {
    const res = await fetch("config.json", { cache: "no-store" });
    if (!res.ok) return CONFIG;                    // opened as a file, or served flat
    const c = await res.json();
    CONFIG.served = true;
    CONFIG.devToken = !!c.dev_token;
    CONFIG.devSecret = c.dev_secret || "";
    CONFIG.devUser = c.dev_user || "";
    // A stored override is a decision somebody made in this browser and wins.
    /* Served, the server's answer is authoritative EVEN WHEN EMPTY. An earlier
       version only took `c.core` when it was truthy, so a deployment saying
       "there is no agent runtime" (core: "") left the localhost fallback in
       place -- and the chat composer posted turns at the Content Server, which
       has no /chat. The page then reported the runtime as missing, which was
       true, and pointed at the wrong port while saying it. */
    if (!localStorage.getItem("p8-rest")) CONFIG.rest = c.rest || CONFIG.rest;
    if (!localStorage.getItem("p8-core")) CONFIG.core = c.core || "";
    if (!localStorage.getItem("p8-content")) CONFIG.content = c.content || "";
    CONFIG.version = c.version;
    CONFIG.workflowQueue = c.workflow_queue || "http";
    CONFIG.ingestQueue = c.ingest_queue || "ingest";
  } catch (e) {
    /* No config.json is not an error: it is the file:// and static-host case,
       and the defaults above are for exactly that. */
  }
  return CONFIG;
}

export function token() { return sessionStorage.getItem("p8-token") || ""; }
let sessionGeneration = 0;
export function setToken(t) {
  sessionGeneration++;
  if (t) sessionStorage.removeItem("p8-signed-out");
  t ? sessionStorage.setItem("p8-token", t) : sessionStorage.removeItem("p8-token");
  window.dispatchEvent(new CustomEvent("p8-session-changed"));
}

export function claims() {
  const t = token();
  if (!t) return null;
  try { return JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); }
  catch (e) { return null; }
}


// All protected HTTP surfaces use this transport, so an expired session has
// one recovery path in Files, Query, Chat and tool discovery alike.
export function sessionState() {
  const c = claims();
  if (!token()) return "signed-out";
  if (!c?.sub || !Number.isFinite(c.exp)) return "invalid";
  return c.exp <= Date.now() / 1000 ? "expired" : "active";
}
export function canRenewSession() { return !!(CONFIG.devToken && CONFIG.devSecret); }

export async function devToken(sub, secret = CONFIG.devSecret) {
  const enc = new TextEncoder();
  const b64 = value => btoa(unescape(encodeURIComponent(JSON.stringify(value))))
    .replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
  const head = b64({alg:"HS256",typ:"JWT"});
  const body = b64({role:"authenticated",sub,exp:Math.floor(Date.now()/1000)+3600});
  const key = await crypto.subtle.importKey("raw",enc.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const sig = await crypto.subtle.sign("HMAC",key,enc.encode(head+"."+body));
  return head+"."+body+"."+btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
}
let renewal = null;
export async function renewSession(sub = claims()?.sub) {
  if (!canRenewSession() || !sub) throw new Error("Sign in to continue to your workspace.");
  if (renewal?.sub === sub && renewal.generation === sessionGeneration) return renewal.promise;
  const job = {sub, generation:sessionGeneration};
  renewal = job;
  job.promise = (async () => {
    const signed = await devToken(sub);
    if (renewal !== job || sessionGeneration !== job.generation) throw new Error("The account changed while renewing. Sign in again.");
    setToken(signed);
    return signed;
  })().finally(() => { if (renewal === job) renewal = null; });
  return job.promise;
}
export class SessionError extends Error {
  constructor() {
    super("Your session has expired. Sign in to continue; your drafts are saved.");
    this.status = 401; this.code = "SESSION_EXPIRED";
  }
}
function requireSignIn() {
  window.dispatchEvent(new CustomEvent("p8-auth-required"));
  return new SessionError();
}
export async function ensureSession() {
  if (!token()) return;
  const c = claims();
  if (!c?.sub || !Number.isFinite(c.exp)) throw requireSignIn();
  if (c.exp <= Date.now()/1000 + 30) {
    if (canRenewSession()) await renewSession(c.sub);
    else if (c.exp <= Date.now()/1000) throw requireSignIn();
  }
}
export async function authFetch(url, options = {}) {
  await ensureSession();
  const send = () => {
    const headers = new Headers(options.headers);
    if (token()) headers.set("Authorization","Bearer "+token());
    else headers.delete("Authorization");
    return fetch(url,{...options,headers});
  };
  let response = await send();
  // Only a refused authentication is replayed. Permission errors (403) are
  // not session expiry, and neither network failures nor writes are retried.
  if (response.status === 401 && token() && canRenewSession() && claims()?.sub) {
    await renewSession();
    response = await send();
  }
  if (response.status === 401) throw requireSignIn();
  return response;
}

export class ApiError extends Error {
  constructor(status, body, url) {
    super((body && (body.message || body.hint)) || ("HTTP " + status));
    this.status = status; this.body = body; this.url = url;
    /* 42501 is Postgres's "permission denied"; 42P01 is "does not exist".
       Both reach the browser verbatim, and both are worth showing as
       themselves rather than as "something went wrong". */
    this.code = body && body.code;
  }
}

async function request(path, { schema = "public", method = "GET", body, count, range } = {}) {
  const headers = { Accept: "application/json" };
  const t = token();
  if (t) headers.Authorization = "Bearer " + t;
  headers[method === "GET" ? "Accept-Profile" : "Content-Profile"] = schema;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const prefer = [];
  if (count) prefer.push("count=exact");
  if (prefer.length) headers.Prefer = prefer.join(",");
  if (range) headers.Range = range;

  const url = CONFIG.rest + "/" + path;
  const res = await authFetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let parsed = null;
  try { parsed = text ? JSON.parse(text) : null; } catch (e) { parsed = { message: text }; }
  if (!res.ok) throw new ApiError(res.status, parsed, url);
  const cr = res.headers.get("Content-Range");
  return { rows: parsed, total: cr && cr.includes("/") ? Number(cr.split("/")[1]) : null };
}

/** A read against one of the *_api views. `q` is PostgREST query syntax verbatim. */
export function select(schema, view, q = "", opts = {}) {
  return request(view + (q ? "?" + q : ""), { schema, ...opts });
}

/** A screen's read, from its contract in `reads.js`.
 *
 * `extra` is what the contract deliberately does not carry: this screen's
 * filter (`session_id=eq.<uuid>`) and its bound (`limit=40`). Everything a
 * screen and the Surface audit must agree on -- columns, ordering, static
 * filters -- comes from the contract, so they cannot drift apart. */
export const read = (c, extra = "", opts = {}) =>
  select(c.schema, c.view, [c.q, extra].filter(Boolean).join("&"), opts);

/** The same contract, bounded to one row: what the audit runs. */
export const probeQuery = (c) => [c.q, "limit=1"].filter(Boolean).join("&");

/** A write. Every one of these is a function that checks its own permission. */
export function rpc(schema, fn, args = {}) {
  return request("rpc/" + fn, { schema, method: "POST", body: args });
}

/** Just the number, without pulling the rows. */
export async function count(schema, view, q = "") {
  const { total } = await request(view + "?select=id&limit=1" + (q ? "&" + q : ""),
                                  { schema, count: true });
  return total;
}

/* ── The suggestion contract, once ─────────────────────────
 *
 * `specs/agentic/browser-ui.md` §7 says what an assistant owes its caller, and
 * its own audit of 2026-09-10 recorded that the six shipping assistants did not
 * all pay it. Each had written the loop again: build the `/chat` body, parse the
 * content, validate, append the error, try once more. Five of six retried; the
 * query assistant threw on the first malformed response. Three carried a
 * `needs_clarification` field; three signalled a question by returning an empty
 * string in the field that would have carried the answer -- so a question and a
 * failure arrived as the same value and the screen rendered one as the other.
 *
 * Those were recorded as table rows rather than fixed, which is the right call
 * for an audit and the wrong state to leave a contract in: a rule that six files
 * implement six ways is a rule the seventh will implement a seventh way. This is
 * the one implementation.
 *
 * WHAT IT ENFORCES, beyond removing the duplication:
 *
 *   - A malformed or invalid response is corrected ONCE, with the validation
 *     error, and a second failure is a failed suggestion. Never a partial one:
 *     §7 is explicit that a half-filled form is indistinguishable from one
 *     somebody meant.
 *   - A response must answer or ask. `needs_clarification` is its own field, and
 *     a response that fills neither it nor the answer is rejected as off-schema
 *     -- which is what it is. This is the row the audit could not tick.
 *   - A refusal is not retried. A 4xx from the runtime is the same 4xx on the
 *     second attempt, and asking again only costs the operator time.
 *
 * The prompt, the schema and the meaning of "answered" stay with each assistant,
 * because those are what the assistants actually differ in.
 */
export const HELP_AGENT = "percolate_help";

/** A conversation to hold this suggestion, so the operator can go and read it. */
export async function createChatSession(title) {
  const { rows } = await rpc("agentic", "create_session", { p_title: title });
  const id = typeof rows === "string" ? rows : rows?.id;
  if (typeof id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error("The workspace did not return a conversation ID. Try creating a session in Chat.");
  }
  return id;
}

/** One model turn under the §7 contract. Returns the parsed, validated answer.
 *
 * `prompt` may be a function of the correction text, for an assistant that has
 * to rebuild its prompt around what it learned from the rejected draft --
 * workflow design discovers SQL columns while validating and has to put them in
 * front of the model on the second attempt. `validate` may be async for the same
 * reason: it compiles the proposed workflow before showing it.
 * `answered` says what counts as an answer for this assistant -- a query string,
 * a settings object, a cron expression -- because only the assistant knows. It
 * is the ONE place the answer-or-question rule is enforced: an assistant that
 * also checked it in its own parser would be the seventh copy of a rule this
 * exists to have one of.
 */
export async function suggest({ name, schema, session, prompt, validate, answered, extra = {},
                                strict = true, attempts = 2, onStatus = () => {}, signal }) {
  if (!config().core) throw Error("Connect an agent runtime in Settings to use AI suggestions.");
  let correction = "";
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (attempt) onStatus("Correcting the assistant's draft…");
    const content = typeof prompt === "function" ? prompt(correction) : prompt + correction;
    const res = await authFetch(config().core.replace(/\/$/, "") + "/chat", {
      method: "POST", headers: { "Content-Type": "application/json" }, signal,
      /* `tool_choice: "none"` IS EVERY ASSISTANT'S, and was one assistant's.
         Each one reached through here proposes: it asks for a `response_format`
         json_schema and hands what comes back to a person to save, so none has
         a reason to call a tool mid-turn -- and all of them put catalogue rows,
         another agent's system prompt or a live schema into the text they send,
         which is where a row somebody else wrote gets to act if the turn kept
         its tools. Workflow design passed it and the other five did not
         (REM-91 item 12).

         `extra` is for what an assistant genuinely needs on the wire and the
         others do not. It is not a hole for re-diverging: anything two
         assistants pass belongs above, which is what moving this was. It sits
         before `...extra` so an assistant that one day needs a tool mid-turn
         says so explicitly rather than inheriting it.

         Note what this does NOT do. Older runtimes IGNORE unknown request
         fields, so on one of those this is accepted and changes nothing.
         Refusing such a runtime outright is workflow design's own check, where
         it stays: that assistant composes something that gets saved and run, so
         a silent downgrade costs more there than it does in a suggestion
         somebody reads before accepting. */
      body: JSON.stringify({ model: HELP_AGENT, session_id: session, stream: false,
        tool_choice: "none", ...extra,
        messages: [{ role: "user", content }],
        response_format: { type: "json_schema", json_schema: { name, strict, schema } } }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const detail = typeof data.detail === "string" ? data.detail
        : Array.isArray(data.detail) ? data.detail.map((d) => d.msg).join("; ")
        : data.error?.message;
      throw Error(detail || `The assistant could not complete this request (${res.status}). Check its run in Chat.`);
    }
    let value;
    try {
      value = JSON.parse(data.choices?.[0]?.message?.content);
      if (!value || typeof value !== "object") throw Error("the response was not an object");
      const question = typeof value.needs_clarification === "string"
        ? value.needs_clarification.trim() : "";
      if (!question && !(answered ? answered(value) : true)) {
        throw Error("it returned neither an answer nor a question in needs_clarification");
      }
      // `validate` may return the assistant's own richer shape -- a parsed
      // schema, a settings object -- so it is not parsed a second time by the
      // caller. Returning nothing means "the raw value is the answer".
      return (!question && validate ? await validate(value) : null) ?? value;
    } catch (e) {
      if (attempt + 1 >= attempts) {
        throw Error(`The assistant did not return a usable suggestion: ${e.message}. `
          + "You can inspect its response in Chat.");
      }
      correction = `\nYour previous answer was rejected: ${e.message}. `
        + `Return corrected JSON matching the schema. Previous answer: ${JSON.stringify(value ?? null)}`;
    }
  }
}
