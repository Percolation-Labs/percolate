#!/usr/bin/env python3
"""Negative controls for REM-584. Only use a named disposable database.

CONTAINER=my-disposable DB=mydb python3 dev/claim-reading-controls.py
Each control replaces one function, runs the caller-role timeline, and restores
its exact original definition in finally. A control passes only on its expected
semantic assertion, never on a missing function, permission setup, or syntax error.
"""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
container, database = os.environ['CONTAINER'], os.environ['DB']
psql = ['docker', 'exec', '-i', container, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'p8', '-d', database]
fixture = (root / 'dev/tests/research/29-claim-reading-modes.sql').read_text()

def run(sql, check=True):
    return subprocess.run(psql, input=sql, text=True, capture_output=True, check=check)

controls = [
    ('claims.occurrences_at(uuid,timestamptz,uuid[])',
     lambda sql: sql.replace('where (p_revisions', "where e.claim_id=p_claim and e.op='assert' and (p_revisions", 1),
     'old identity has no current occurrence'),
    ('claims.study_of(uuid,timestamptz,uuid[])',
     lambda sql: sql.replace('l.source_key,l.id desc', 'l.source_key,l.id asc'),
     'origin oracle at split expected 2 got 1'),
    ('research.revision_readable(uuid)',
     lambda sql: sql[:sql.index('AS $function$')] + 'AS $function$ select true; $function$;',
     'private pinned revision denied'),
]
for signature, mutate, expected in controls:
    original = run("select pg_get_functiondef('%s'::regprocedure);" % signature).stdout
    mutated = mutate(original)
    assert mutated != original, f'control did not change {signature}'
    try:
        run(mutated)
        result = run(fixture, check=False)
        assert result.returncode != 0 and expected in result.stderr, (signature, result.stderr)
        print(f'PASS negative control: {signature}: {expected}')
    finally:
        run(original)
run(fixture)
print('PASS restored implementation and fixture cleanup')
