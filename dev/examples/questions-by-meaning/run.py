#!/usr/bin/env python3
"""Does a plain-English question find the question it means? (REM-998)

    OPENAI_API_KEY=... CONTAINER=p8-ci DB=p8ci python3 -I dev/examples/questions-by-meaning/run.py

Loads fixture.json into a database built from this tree (dev/ci-database.sh), as one writer whose packages
answer the 56 questions on the dates the fixture gives, embeds every question and query with
text-embedding-3-small, then asks each query two ways as a second, ordinary reader:

  * words: the score the Percolate application's question search uses today (three points for each of the
    query's words in the question, at most two for its words in the answers; a question no word reaches is left
    out), recomputed here over the same questions;
  * meaning: claims.find_question, the nearest question by cosine distance in the model's space.

It prints hit@1 for both, the reproduction query's top three each way, and what the graph believed about the
target question on 15 September against today, with claims.stance_changes naming what changed it.

Everything it writes is in one transaction that it rolls back, so it can be run against a gate database.
Needs only the standard library and psql inside the container.
"""
import json, os, re, subprocess, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONTAINER = os.environ.get("CONTAINER", "p8-ci")
DB = os.environ.get("DB", "p8ci")
MODEL = "text-embedding-3-small"
FLOOR = 0.6
STOP = set("a an and are as at be by can did do does for from has have how in into is it its of on or should "
           "so that the their them they this to was what when which who will with without".split())


def embed(texts):
    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=json.dumps({"model": MODEL, "input": texts}).encode(),
        headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return [d["embedding"] for d in json.load(r)["data"]]


def terms(text):
    return {w for w in re.findall(r"[a-z0-9']+", text.lower()) if w not in STOP and len(w) > 2}


def words_rank(fx, query):
    want, scored = terms(query), []
    for q in fx["questions"]:
        in_q = len(want & terms(q["text"]))
        in_a = len(want & terms(" ".join(a["claim"] for a in q["answers"])))
        if 3 * in_q + min(in_a, 2):
            scored.append((-(3 * in_q + min(in_a, 2)), -len(q["answers"]), q["id"]))
    return [i for _, _, i in sorted(scored)]


def lit(s):
    return "'" + s.replace("'", "''") + "'"


def vec(v):
    return lit("[" + ",".join(f"{x:.7f}" for x in v) + "]") + "::vector"


def main():
    fx = json.load(open(os.path.join(HERE, "fixture.json")))
    qs = fx["questions"]
    vectors = embed([q["text"] for q in qs] + [x["text"] for x in fx["queries"]])
    qv, xv = vectors[:len(qs)], vectors[len(qs):]

    writer, reader = "00000000-0000-4000-8000-000000998a01", "00000000-0000-4000-8000-000000998b01"
    sql = [r"\set ON_ERROR_STOP on", r"\pset format unaligned", r"\pset tuples_only on", "begin;",
           f"insert into rbac.users (id, email, status) values ({lit(writer)}, 'qbm-writer@example.test', 'active'),"
           f" ({lit(reader)}, 'qbm-reader@example.test', 'active');",
           "insert into rbac.roles (name, description) values ('qbm-lister', 'may list research (example)') on conflict do nothing;",
           "insert into rbac.role_permissions (role, resource, action) values ('qbm-lister', 'research', 'list'),"
           " ('qbm-lister', 'research', 'select') on conflict do nothing;",
           f"insert into rbac.user_roles (user_id, role) values ({lit(writer)}, 'qbm-lister'), ({lit(reader)}, 'qbm-lister');",
           "create temporary table qbm (k text primary key, v uuid, tx bigint, at timestamptz) on commit drop;",
           "grant all on qbm to authenticated;",
           f"set local request.jwt.claims = '{{\"sub\": \"{writer}\"}}';", "set local role authenticated;", "do $$ declare r uuid; q uuid; a bigint; begin"]
    for q in qs:
        sql.append(f"  q := claims.pose_question({lit(q['text'])}); insert into qbm values ({lit(q['id'])}, q);")
        for a in q["answers"]:
            pkg = {"schema_version": "0.1", "title": a["work"], "visibility": "listed", "edges": [],
                   "claims": [{"id": "C1", "kind": "Inference", "text": a["claim"], "source_ids": ["S1"]}],
                   "sources": [{"id": "S1", "title": a["work"], "url": f"https://example.com/{a['work']}", "origin": a["work"]}]}
            sql.append(f"  r := (research.submit_package({lit(json.dumps(pkg))}, null, {lit('qbm-' + a['work'])})->>'revision_id')::uuid;"
                       f" insert into qbm values ({lit(a['work'])}, r);"
                       f" a := claims.propose_answer(r, 'C1', q, {lit(a['stance'])});"
                       f" insert into qbm (k, tx, at) values ({lit('tx:' + a['work'])},"
                       f" (select tx from claims.answered where id = a), {lit(a['at'])});")
        for w in q.get("later", []):
            sql.append(f"  a := claims.withdraw_answer((select v from qbm where k = {lit(w['work'])}), 'C1', q);"
                       f" insert into qbm (k, tx, at) values ({lit('tx:withdraw:' + w['work'])},"
                       f" (select tx from claims.answered where id = a), {lit(w['at'])});")
    sql += ["end $$;", "reset role;",
            # The fixture's history is dated: each answer's transaction is moved to the day the fixture gives it.
            # claims.tx refuses rewrites, so this one fixture-only step runs with triggers off, as the owner.
            "set local session_replication_role = replica;",
            "update claims.tx t set at = q.at from qbm q where q.tx = t.id;",
            "set local session_replication_role = origin;",
            "set local role app_owner;",
            f"select aiq.register_embedding_space({lit(MODEL)});",
            "reset role;",
            f"select aiq.embedding_space_name({lit(MODEL)}) as space \\gset"]
    for q, v in zip(qs, qv):
        sql.append(f"insert into aiq.:\"space\" (chunk_id, embedding) select v, {vec(v)} from qbm where k = {lit(q['id'])};")
    sql += [f"set local request.jwt.claims = '{{\"sub\": \"{reader}\"}}';", "set local role authenticated;"]
    for i, (x, v) in enumerate(zip(fx["queries"], xv)):
        sql.append(f"select 'meaning|{i}|' || json_agg(json_build_object('k', (select k from qbm where v = f.question),"
                   f" 'd', round(f.distance::numeric, 4), 'within', f.within) order by f.distance)"
                   f" from claims.find_question({vec(v)}, {FLOOR}, 3, {lit(MODEL)}) f;")
    rep = next(i for i, x in enumerate(fx["queries"]) if x.get("reproduction"))
    for when in ("2026-09-15", "now"):
        at = "now()" if when == "now" else lit(when + "T12:00:00Z") + "::timestamptz"
        sql.append(f"select 'asof|{when}|' || json_agg(json_build_object('k', (select k from qbm where v = f.question),"
                   f" 'yes', f.yes, 'no', f.no, 'depends', f.depends, 'works', f.works))"
                   f" from claims.find_question({vec(xv[rep])}, {FLOOR}, 1, {lit(MODEL)}, {at}) f;")
    sql.append("select 'changes|' || json_agg(json_build_object('claim_key', (select k from qbm where v = c.revision_id),"
               " 'then', c.stance_then, 'now', c.stance_now, 'change', c.change, 'at', c.changed_at::date) order by c.changed_at)"
               f" from claims.stance_changes((select v from qbm where k = {lit(fx['target'])}),"
               " '2026-09-15T12:00:00Z', now()) c;")
    sql.append("rollback;")

    if os.environ.get("QBM_SQL"):  # write the generated SQL out, to read or run by hand
        open(os.environ["QBM_SQL"], "w").write("\n".join(sql))
    out = subprocess.run(["docker", "exec", "-i", CONTAINER, "psql", "-U", "p8", "-d", DB, "-q"],
                         input="\n".join(sql), capture_output=True, text=True)
    if out.returncode:
        sys.exit(out.stderr[-3000:])
    lines = [l for l in out.stdout.splitlines() if "|" in l]
    meaning = {int(l.split("|")[1]): json.loads(l.split("|", 2)[2]) for l in lines if l.startswith("meaning|")}

    hits_w = hits_m = 0
    print(f"{'query':62} {'gold':22} words@1                 meaning@1 (distance)")
    for i, x in enumerate(fx["queries"]):
        w = words_rank(fx, x["text"])
        m = meaning[i]
        hits_w += bool(w and w[0] == x["gold"])
        hits_m += m[0]["k"] == x["gold"]
        print(f"{x['text'][:61]:62} {x['gold']:22} {(w[0] if w else '(nothing)'):22} {m[0]['k']} ({m[0]['d']})")
    n = len(fx["queries"])
    print(f"\nhit@1 over {n} queries: words {hits_w}/{n}, meaning {hits_m}/{n}")
    x = fx["queries"][rep]
    print(f"\nreproduction: {x['text']!r}")
    print("  words:  ", words_rank(fx, x["text"])[:3] or "(nothing)")
    print("  meaning:", [(h["k"], h["d"], "within" if h["within"] else "beyond the floor") for h in meaning[rep]])
    for l in lines:
        if l.startswith("asof|"):
            _, when, body = l.split("|", 2)
            print(f"  as of {when}:", json.loads(body)[0])
        if l.startswith("changes|"):
            print("  what changed it between 15 September and now:")
            for c in json.loads(l.split("|", 1)[1]):
                print("   ", c)


if __name__ == "__main__":
    main()
