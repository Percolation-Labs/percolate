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
  devToken: true,          // until the server says otherwise; see loadConfig
  devSecret: "",           // never a default: the deployment supplies it or nobody does
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
    // A stored override is a decision somebody made in this browser and wins.
    /* Served, the server's answer is authoritative EVEN WHEN EMPTY. An earlier
       version only took `c.core` when it was truthy, so a deployment saying
       "there is no agent runtime" (core: "") left the localhost fallback in
       place -- and the chat composer posted turns at the Content Server, which
       has no /chat. The page then reported the runtime as missing, which was
       true, and pointed at the wrong port while saying it. */
    if (!localStorage.getItem("p8-rest")) CONFIG.rest = c.rest || CONFIG.rest;
    if (!localStorage.getItem("p8-core")) CONFIG.core = c.core || "";
    CONFIG.version = c.version;
  } catch (e) {
    /* No config.json is not an error: it is the file:// and static-host case,
       and the defaults above are for exactly that. */
  }
  return CONFIG;
}

export function token() { return sessionStorage.getItem("p8-token") || ""; }
export function setToken(t) { t ? sessionStorage.setItem("p8-token", t) : sessionStorage.removeItem("p8-token"); }

export function claims() {
  const t = token();
  if (!t) return null;
  try { return JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); }
  catch (e) { return null; }
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
  const res = await fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
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
