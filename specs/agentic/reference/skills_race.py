#!/usr/bin/env python3
"""Two clients, one agent, two different fragments, at the same time.

    python3 skills_race.py

`plugins.md` §5.5's claim, made checkable: adding a fragment to an agent by
read-modify-write through `upsert_agent` is a lost update, and
`agentic.attach_skill` is not. The barrier is what makes it deterministic --
both clients read before either writes, which is the interleaving that happens
by itself under any real concurrency and only sometimes when you are watching.

Expected output:

    read-modify-write (today)    -> 1 of 2 landed
    attach_skill (proposed)      -> 2 of 2 landed
"""
import psycopg2, threading, json, sys
DSN = "postgresql://p8:p8@localhost:5499/p8skills"

def reset():
    c = psycopg2.connect(DSN); cur = c.cursor()
    cur.execute("select agentic.upsert_agent('{\"name\":\"race-test\",\"skills\":[]}'::jsonb)")
    c.commit(); c.close()

def read_modify_write(skill, barrier):
    """What a caller must do today: read the array, append, send it all back."""
    c = psycopg2.connect(DSN); cur = c.cursor()
    cur.execute("select skills from agentic.agents_api where name='race-test'")
    skills = list(cur.fetchone()[0] or [])
    barrier.wait()                      # both have now read the SAME array
    skills.append(skill)
    cur.execute("select agentic.upsert_agent(%s::jsonb)",
                (json.dumps({"name": "race-test", "skills": skills}),))
    c.commit(); c.close()

def attach(skill, barrier):
    """What the database can do instead."""
    c = psycopg2.connect(DSN); cur = c.cursor()
    barrier.wait()
    cur.execute("select agentic.attach_skill('race-test', %s)", (skill,))
    c.commit(); c.close()

def run(fn, label):
    reset()
    b = threading.Barrier(2)
    ts = [threading.Thread(target=fn, args=(s, b))
          for s in ("house-style-attribution", "house-style-brevity")]
    for t in ts: t.start()
    for t in ts: t.join()
    c = psycopg2.connect(DSN); cur = c.cursor()
    cur.execute("select skills from agentic.agents_api where name='race-test'")
    got = list(cur.fetchone()[0] or []); c.close()
    print("  %-28s -> %d of 2 landed  %s" % (label, len(got), got))

print("two clients attach two different fragments to one agent, simultaneously")
run(read_modify_write, "read-modify-write (today)")
run(attach,            "attach_skill (proposed)")
