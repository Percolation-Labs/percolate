"""A component this deployment did not install reads as that, in words, to a user.

Run: python -m unittest discover -s tests -p test_ui_uninstalled.py

On a stock compose install three screens in the main navigation led with their
internals: Queues & pools with four `unavailable · 42P01` tiles and a rose
`Not reachable: workflow.v_pools ... apply specs/workflow-engine/pools.sql`,
Load & limits with "no table for them" tiles under a panel titled "What would
stop this being a placeholder", and Keys & sessions with "Issuing is the missing
half". None of it is wrong, and none of it is for the person the screen is for.

`specs/agentic/ui-design-language.md` §4 asks these screens for "consistent
unavailable, empty and active states", and §5 says a smaller first screen "must
not make failures, evidence, advanced configuration or the next action
inaccessible". So: plain words first, and the operator detail -- SQLSTATE, the
relation, the file that installs it -- behind a <details> toggle rather than
deleted. The pool state is detected from the refusal the database returns
(42P01 on every pool relation), not assumed.

This renders each screen in node against a stubbed PostgREST, and checks the
text a reader sees before opening any toggle.
"""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "percolate_core/ui/static"

BOOT = r"""
import assert from 'node:assert/strict';
const el = (tag) => {
  const a = {};
  return { tag, __a: a, __k: [], nodeType: 1, style: {}, dataset: {},
    setAttribute(k, v) { a[k] = String(v); }, getAttribute(k) { return a[k] ?? null; },
    append(...k) { this.__k.push(...k); }, addEventListener() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    set className(v) { a.class = v; }, get className() { return a.class || ''; },
    set innerHTML(v) { a.html = v; }, set textContent(v) { this.__k = [{nodeType: 3, t: String(v)}]; } };
};
globalThis.document = { createElement: el, createElementNS: (ns, tag) => el(tag),
  createTextNode: (t) => ({ nodeType: 3, t }), getElementById: () => null };
const store = () => { const d = new Map(); return { getItem: k => d.get(k) ?? null,
  setItem: (k, v) => d.set(k, String(v)), removeItem: k => d.delete(k) }; };
globalThis.localStorage = store(); globalThis.sessionStorage = store();
globalThis.window = { dispatchEvent() {}, addEventListener() {} };
globalThis.addEventListener = () => {};  // views.js listens for definition changes at module scope
globalThis.CustomEvent = class { constructor(type) { this.type = type; } };
globalThis.location = { hash: '' };
const payload = Buffer.from(JSON.stringify({ sub: '11111111-1111-1111-1111-111111111111',
  role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })).toString('base64url');
sessionStorage.setItem('p8-token', ['h', payload, 's'].join('.'));

/* PostgREST as a stock install answers it: the pool schema is absent, every
   core view is readable and empty. */
const ABSENT = ['v_pools', 'pool_queues', 'v_unserved_queues', 'pool_image_policy'];
globalThis.fetch = async (url) => {
  const view = String(url).split('/').pop().split('?')[0];
  if (view === '') return new Response(JSON.stringify({ paths: {
    '/rpc/verify_api_key': {}, '/rpc/revoke_session': {}, '/rpc/refresh_session': {},
    '/rpc/revoke_all_sessions': {}, '/rpc/grant_role': {} } }), { status: 200 });
  if (ABSENT.includes(view)) return new Response(JSON.stringify({ code: '42P01',
    message: `relation "workflow.${view}" does not exist` }), { status: 404 });
  return new Response('[]', { status: 200 });
};

/* The text a reader sees without opening anything, and the text behind toggles. */
const text = (n, inDetails = false, out = { shown: [], hidden: [] }) => {
  if (!n || typeof n !== 'object') return out;
  if (n.nodeType === 3) { (inDetails ? out.hidden : out.shown).push(n.t); return out; }
  const closed = n.tag === 'details';
  for (const k of n.__k || []) text(k, inDetails || closed, out);
  return out;
};
const views = await import(%VIEWS%);
const access = await import(%ACCESS%);
const render = async (screen) => {
  const { shown, hidden } = text(await screen());
  return { shown: shown.join(' '), hidden: hidden.join(' ') };
};
"""

INTERNALS = ["42P01", "Not reachable", "specs/", ".sql", "placeholder",
             "no table for them", "no policy row", "missing half"]


@unittest.skipUnless(shutil.which("node"), "node renders the screens")
class UninstalledScreensTest(unittest.TestCase):
    def run_js(self, source):
        script = (BOOT.replace("%VIEWS%", json.dumps((STATIC / "views.js").as_uri()))
                      .replace("%ACCESS%", json.dumps((STATIC / "access.js").as_uri()))
                  + f"const INTERNALS = {json.dumps(INTERNALS)};\n"
                  + "const clean = (s, where) => { for (const w of INTERNALS) "
                    "assert.ok(!s.includes(w), `${where} shows ${JSON.stringify(w)} before any toggle is opened`); };\n"
                  + source)
        result = subprocess.run(["node", "--input-type=module", "-e", script],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])

    def test_queues_without_the_pool_schema_says_so_in_words(self):
        self.run_js("""
        const { shown, hidden } = await render(views.queues);
        clean(shown, 'Queues & pools');
        assert.match(shown, /not installed/i, 'the reader is told pools are not installed');
        assert.match(shown, /Rate limits/, 'the core panels still render');
        for (const w of ['42P01', 'workflow.v_pools', 'specs/workflow-engine/pools.sql'])
          assert.ok(hidden.includes(w), `operator detail keeps ${w}`);
        """)

    def test_load_and_limits_leads_with_what_is_measured(self):
        self.run_js("""
        const { shown, hidden } = await render(views.scale);
        clean(shown, 'Load & limits');
        assert.match(shown, /Tasks/);
        assert.match(hidden, /trial/i, 'what is not built is still said, behind the toggle');
        """)

    def test_keys_says_what_a_user_can_do_here(self):
        self.run_js("""
        const { shown, hidden } = await render(access.keys);
        clean(shown, 'Keys & sessions');
        assert.match(shown, /revoke/i);
        assert.match(hidden, /verify_api_key/, 'the operator detail names what the database has');
        """)


if __name__ == "__main__":
    unittest.main()
