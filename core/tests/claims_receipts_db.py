"""Exercise worker JWT -> core caller RLS -> extension receipts, without an LLM.

Run only against a disposable extension >= 0.2.15 database, with a fixture-owner
DSN in CLAIMS_RECEIPTS_TEST_DSN. The test changes only its named fixture rows.
A provider fixture supplies usage; no external provider or application is used.
"""
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path
from uuid import UUID, uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import asyncpg
from percolate_core.core import identity
from percolate_core.worker.agent_auth import AGENT_RUN_URL, agent_authorization
from percolate_core.agentic.db.repository import PgRepository
from percolate_core.agentic.db.client import PgClient
from percolate_core.agentic.settings import Settings

OWNER = UUID('00000000-0000-4000-8000-000000059011')
READER = UUID('00000000-0000-4000-8000-000000059012')
WORK = 'rp-core-receipt-probe'

async def main():
    dsn = os.environ['CLAIMS_RECEIPTS_TEST_DSN']
    admin = await asyncpg.connect(dsn)
    await identity.open_pool(dsn, min_size=1, max_size=3)
    definition = run = task = None
    try:
        await admin.execute("""insert into rbac.users(id,email,status) values
            ($1,'core-receipt-owner@example.test','active'),($2,'core-receipt-reader@example.test','active')
            on conflict do nothing""", OWNER, READER)
        definition = await admin.fetchval("""insert into workflow.definitions(name,spec)
            values ('core_receipt_probe','{"steps":[{"key":"model","kind":"work","queue":"receipt-probe"}]}') returning id""")
        run = await admin.fetchval('insert into workflow.runs(workflow_def_id,owner_id) values($1,$2) returning id', definition, OWNER)
        task = await admin.fetchval("""insert into workflow.tasks(run_id,step_key,kind,status,attempts,claimed_by)
            values($1,'model','http_call','running',1,'receipt-probe-worker') returning id""", run)
        # The same lease-checked principal lookup the worker performs before it signs a runtime token.
        async with identity.as_service() as conn:
            principal = await conn.fetchrow('select * from workflow.task_principal($1,$2)', task, 'receipt-probe-worker')
        with tempfile.TemporaryDirectory() as directory:
            secret = 'receipt-probe-key-used-only-in-this-disposable-test'
            key = Path(directory) / 'key'
            key.write_text(secret)
            os.environ['P8_AGENT_SIGNING_KEY_FILE'] = str(key)
            os.environ['P8_AGENT_URL'] = 'http://fixture-runtime:8080'
            token = agent_authorization(
                {'url': AGENT_RUN_URL, 'credential_ref': 'P8_API_KEY', 'method': 'POST'},
                {'url': 'http://fixture-runtime:8080/internal/run'}, str(principal['owner_id']),
                task_id=str(task), worker_id='receipt-probe-worker', attempt=1)
            claims = identity.claims_from_jwt(token.removeprefix('Bearer '), secret)
        async with identity.as_caller(claims) as conn:
            result = await conn.fetchval('select research.submit_package($1::jsonb,null,$2)', {
                'schema_version': '0.1', 'title': 'Core receipt probe', 'visibility': 'private',
                'sources': [], 'edges': [], 'claims': [
                    {'id': 'C1', 'kind': 'Inference', 'text': 'A qualified claim.'},
                    {'id': 'C2', 'kind': 'Inference', 'text': 'Its supporting claim.'}]}, WORK)
            revision = UUID(result['revision_id'])
            relation = await conn.fetchval("select claims.assert_relation('C2','supports','C1',$1)", revision)
            tx = await conn.fetchval('select tx from claims.relations where id=$1', relation)
            claim = await conn.fetchval("select claim_id from claims.expresses where revision_id=$1 and claim_key='C1'", revision)
            reading = await conn.fetchval('select claims.reading($1)', claim)
            assert len(reading['relations']) == 1
        repo = PgRepository(PgClient(Settings(database_url=dsn), owns_pool=False), claims)
        await repo.record_execution_receipt(uuid4(), {
            'method_version': 'integration-fixture/1', 'model': 'fixture-provider/model',
            'model_version': None, 'usage': {'input_tokens': 12, 'output_tokens': 3, 'prompt': 'MUST NOT ESCAPE'},
            'evaluation_resource': uuid4(),
        })
        async with identity.as_task_worker() as conn:
            await conn.execute('select workflow.complete_task($1,$2::jsonb,$3)', task, {'result': 'fixture'}, 'receipt-probe-worker')
        await admin.execute('delete from workflow.runs where id=$1', run)
        async with identity.as_caller({'sub': str(OWNER)}) as conn:
            receipt = await conn.fetchval('select claims.execution_receipt($1)', tx)
            assert receipt['task_id'] == str(task) and receipt['run_id'] == str(run)
            assert receipt['execution']['runs'][0]['usage'] == {'input_tokens': 12, 'output_tokens': 3}
            assert receipt['evaluation_artifacts'] == [{'status': 'unavailable'}]
            assert 'MUST NOT ESCAPE' not in json.dumps(receipt)
        async with identity.as_caller({'sub': str(READER)}) as conn:
            assert await conn.fetchval('select claims.execution_receipt($1)', tx) is None
            assert await conn.fetchval('select claims.reading($1)', claim) is None
        print('PASS: signed worker lease, core caller RLS, reading, measured usage snapshot, pruning, missing artifact, private reader')
    finally:
        await admin.execute('select research.erase_work($1,$2)', WORK, 'disposable core receipt fixture cleanup')
        if task:
            assert await admin.fetchval('select count(*) from claims.execution_results where task_id=$1', task) == 0
        if run:
            await admin.execute('delete from workflow.runs where id=$1', run)
        if definition:
            await admin.execute('delete from workflow.definitions where id=$1', definition)
        await identity.close_pool()
        await admin.close()

if __name__ == '__main__':
    asyncio.run(main())
