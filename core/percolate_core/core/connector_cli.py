"""Operator-managed connector keys, in Percolate's existing RBAC tables."""
import asyncio
import hashlib
import json
import os
import secrets
from pathlib import Path
from uuid import UUID
import typer
from .cli import _admin_dsn, _connect
from ..query.connector_auth import CONNECTOR_SCOPES

app = typer.Typer(help='Issue, list, rotate and revoke per-user MCP connector keys.', no_args_is_help=True)

async def issue_key(conn, email, label, scopes, raw, replace=None):
    user = await conn.fetchval("select id from rbac.users where email=$1 and status='active'", email)
    if not user: raise ValueError('No active Percolate user has that email.')
    if replace:
        old = await conn.fetchrow('select label,scopes from rbac.api_keys where id=$1 and user_id=$2 and revoked_at is null for update', replace, user)
        if not old: raise ValueError('No active key with that id belongs to this user.')
        label, scopes = old['label'], list(old['scopes'])
    if not scopes or not set(scopes) <= CONNECTOR_SCOPES:
        raise ValueError('Connector scopes are mcp:query, canvas:read and canvas:write.')
    key = await conn.fetchval('insert into rbac.api_keys(user_id,label,key_hash,scopes) values($1,$2,$3,$4) returning id',
        user, label, hashlib.sha256(raw.encode()).hexdigest(), scopes)
    if replace:
        await conn.execute('update rbac.api_keys set revoked_at=now() where id=$1', replace)
    await conn.execute("insert into rbac.auth_events(user_id,event_type,detail) values($1,'api_key_created',$2::jsonb)",
        user,json.dumps({'key_id':str(key),'label':label,'scopes':scopes,'replaced_key':str(replace) if replace else None,'issuer':'local-operator'}))
    return key

def _issue(email, label, scopes, output, dsn, replace=None):
    raw='p8c_'+secrets.token_urlsafe(40)
    # Refuse overwrite before changing the database. Neither stdout nor argv contains the key.
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    async def run():
        conn=await _connect(_admin_dsn(dsn))
        try:
            async with conn.transaction():
                key=await issue_key(conn,email,label,scopes,raw,replace)
                with os.fdopen(fd,'w') as f:
                    f.write('Bearer '+raw+'\n');f.flush();os.fsync(f.fileno())
                return key
        finally:await conn.close()
    try:key=asyncio.run(run())
    except BaseException:
        try:os.close(fd)
        except OSError:pass
        Path(output).unlink(missing_ok=True)
        raise
    typer.echo(json.dumps({'key_id':str(key),'authorization_file':str(Path(output).resolve())}))

@app.command('issue')
def issue(email: str=typer.Option(...), output: Path=typer.Option(...,help='New owner-only file for the Authorization header.'),
          label: str=typer.Option('Claude connector'), scope: list[str]=typer.Option(['mcp:query','canvas:read','canvas:write']),
          dsn: str|None=typer.Option(None,help='Owner DSN, or P8_ADMIN_DSN. Never used by the serving process.')):
    """Provision one existing, active user; does not create users or grant roles."""
    _issue(email,label,scope,output,dsn)

@app.command('rotate')
def rotate(email: str=typer.Option(...), key_id: str=typer.Option(...), output: Path=typer.Option(...), dsn: str|None=typer.Option(None)):
    """Issue a replacement and revoke the old key atomically. Update the client's header."""
    _issue(email,'',[],output,dsn,UUID(key_id))

@app.command('revoke')
def revoke(email: str=typer.Option(...), key_id: str=typer.Option(...), dsn: str|None=typer.Option(None)):
    """Immediately refuse new MCP requests from this connector."""
    async def run():
        conn=await _connect(_admin_dsn(dsn))
        try:
            async with conn.transaction():
                user=await conn.fetchval('update rbac.api_keys k set revoked_at=coalesce(revoked_at,now()) from rbac.users u where k.id=$1 and k.user_id=u.id and u.email=$2 returning k.user_id',UUID(key_id),email)
                if not user:raise ValueError('Key not found for this user.')
                await conn.execute("insert into rbac.auth_events(user_id,event_type,detail) values($1,'api_key_revoked',$2::jsonb)",user,json.dumps({'key_id':key_id,'issuer':'local-operator'}))
        finally:await conn.close()
    asyncio.run(run());typer.echo('Connector revoked.')

@app.command('list')
def list_keys(email: str=typer.Option(...), dsn: str|None=typer.Option(None)):
    """List metadata only; raw keys and hashes are never returned."""
    async def run():
        conn=await _connect(_admin_dsn(dsn))
        try:return [dict(r) for r in await conn.fetch('select k.id,k.label,k.scopes,k.created_at,k.last_used_at,k.revoked_at from rbac.api_keys k join rbac.users u on u.id=k.user_id where u.email=$1 order by k.created_at',email)]
        finally:await conn.close()
    typer.echo(json.dumps(asyncio.run(run()),default=str,indent=2))
