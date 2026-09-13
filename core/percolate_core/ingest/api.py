"""Incremental JSON API ingestion on the existing workflow work queue.

Each page and its continuation checkpoint commit together. The public watermark
advances only after the last page. Retries replay safely by source + external ID.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import datetime, timedelta, timezone
from typing import Any, Literal
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

import httpx
from pydantic import BaseModel, ConfigDict, Field

from ..core import as_service, credential_for
from ..core.credentials import origin as credential_origin
from ..core.egress import refuse_internal_egress
from ..core.provider_errors import raise_for
from ..worker.templates import TerminalError


class APIConfig(BaseModel):
    model_config = ConfigDict(extra='forbid')
    url: str
    params: dict[str, str | int | bool] = Field(default_factory=dict)
    headers: dict[str, str] = Field(default_factory=dict)
    auth_type: Literal['none','bearer','header'] = 'none'
    credential_ref: str = ''
    auth_header: str = 'X-API-Key'
    records_path: str = '$'
    id_path: str = 'id'
    watermark_type: Literal['none','timestamp','number'] = 'timestamp'
    watermark_field: str = 'updated_at'
    watermark_param: str = 'since'
    initial_watermark: str = ''
    overlap_seconds: int = Field(default=60, ge=0, le=604800)
    pagination: Literal['none','link_header','next_url','page_token','page'] = 'link_header'
    next_path: str = 'next'
    page_param: str = 'page'
    page_size_param: str = 'per_page'
    page_size: int = Field(default=100, ge=1, le=1000)
    max_pages: int = Field(default=5, ge=1, le=100)
    mappings: dict[str, str | dict[str, str]] = Field(default_factory=dict)


def at(value: Any, path: str) -> Any:
    if path in ('', '$'): return value
    for part in path.removeprefix('$.').split('.'):
        if isinstance(value, dict) and part in value: value = value[part]
        elif isinstance(value, list) and part.isdigit() and int(part)<len(value): value=value[int(part)]
        else: raise TerminalError(f"Response field '{path}' is missing. Check the response shape and mapping.")
    return value


def timestamp(value: str) -> datetime:
    try:
        parsed=datetime.fromisoformat(str(value).replace('Z','+00:00'))
        if parsed.tzinfo is None: raise ValueError('timezone required')
        return parsed.astimezone(timezone.utc)
    except (ValueError,TypeError):
        raise TerminalError('A timestamp watermark must include its timezone (for example 2026-01-01T00:00:00Z).') from None


def compare_value(value: str, kind: str):
    if kind=='timestamp': return timestamp(value)
    if kind=='number':
        from decimal import Decimal, InvalidOperation
        try:
            parsed=Decimal(str(value))
            if not parsed.is_finite(): raise InvalidOperation()
            return parsed
        except InvalidOperation: raise TerminalError('A numeric watermark must be a finite number.') from None
    return value


def origin(url: str) -> tuple:
    # core.credentials.origin is the one parser; this adds only the fragment
    # rule, which is about source configuration rather than about origins.
    try:
        if urlsplit(url).fragment: raise ValueError
        return credential_origin(url)
    except ValueError:
        raise TerminalError('Use an HTTP(S) endpoint without embedded credentials or a fragment.') from None


def with_params(url: str, values: dict) -> str:
    p=urlsplit(url);params=dict(parse_qsl(p.query,keep_blank_values=True));params.update({k:str(v).lower() if isinstance(v,bool) else str(v) for k,v in values.items()})
    return urlunsplit((p.scheme,p.netloc,p.path,urlencode(params),''))


def request_headers(c: APIConfig) -> dict:
    origin(c.url)
    sensitive={'access_token','api_key','token','password'}
    if any(k.lower() in sensitive for k in [*c.params,*dict(parse_qsl(urlsplit(c.url).query))]): raise TerminalError('Use a credential reference instead of embedding credentials in request parameters.')
    denied={'authorization','cookie','x-api-key','api-key'}
    if any(k.lower() in denied for k in c.headers): raise TerminalError('Use a credential reference for authentication, not literal headers.')
    headers={'Accept':'application/json','User-Agent':'Percolate-API-Ingestion',**c.headers}
    if c.auth_type!='none':
        if not c.credential_ref: raise TerminalError('Name a worker credential for this source.')
        # Operator binds credential references to API origins, so a source
        # configuration cannot send a worker's provider key to another host.
        # The binding is core.credentials' -- the one every sender uses --
        # which still reads P8_INGEST_CREDENTIAL_ORIGINS, the name this module
        # introduced, beside P8_CREDENTIAL_ORIGINS.
        secret=credential_for(c.credential_ref,c.url)
        if c.auth_type=='bearer': headers['Authorization']='Bearer '+secret
        else:
            if not c.auth_header or any(ch in c.auth_header for ch in '\r\n:'): raise TerminalError('Choose a valid authentication header name.')
            headers[c.auth_header]=secret
    return headers


def first_url(c: APIConfig, watermark: str | None) -> str:
    values=dict(c.params)
    if c.page_size_param: values[c.page_size_param]=c.page_size
    if c.pagination=='page': values[c.page_param]=1
    watermark=watermark or c.initial_watermark
    if watermark and c.watermark_type!='none':
        parsed=compare_value(watermark,c.watermark_type)
        if c.watermark_type=='timestamp': watermark=(parsed-timedelta(seconds=c.overlap_seconds)).isoformat().replace('+00:00','Z')
        values[c.watermark_param]=watermark
    return with_params(c.url,values)


def map_record(row: dict, mappings: dict) -> dict:
    if not mappings: return row
    result={}
    for name,rule in mappings.items():
        path=rule if isinstance(rule,str) else rule.get('path','')
        value=at(row,path);cast=None if isinstance(rule,str) else rule.get('cast')
        try:
            if value is None: pass
            elif cast=='string': value=str(value)
            elif cast=='number':
                value=float(value)
                import math
                if not math.isfinite(value): raise ValueError()
            elif cast=='boolean':
                if value not in (True,False,'true','false',0,1): raise ValueError()
                value=value in (True,'true',1)
            elif cast=='lowercase': value=str(value).lower()
            elif cast=='trim': value=str(value).strip()
            elif cast: raise ValueError()
        except (TypeError,ValueError): raise TerminalError(f"Cannot apply {cast} to mapped field '{name}'.") from None
        result[name]=value
    return result


def next_page(c: APIConfig, response: httpx.Response, payload: Any, count: int) -> str | None:
    url=None
    if c.pagination=='link_header': url=response.links.get('next',{}).get('url')
    elif c.pagination in ('next_url','page_token'):
        # Missing pagination metadata is a schema error, not an end-of-stream.
        nxt=at(payload,c.next_path)
        if nxt is not None and nxt != '' and nxt is not False:
            if isinstance(nxt,(dict,list,bool)): raise TerminalError('The page token or next URL must be a scalar value.')
            url=nxt if c.pagination=='next_url' else with_params(str(response.url),{c.page_param:nxt})
    elif c.pagination=='page' and count>=c.page_size:
        current=dict(parse_qsl(response.url.query.decode())).get(c.page_param,'1')
        try: url=with_params(str(response.url),{c.page_param:int(current)+1})
        except ValueError: raise TerminalError('The page number is not an integer.') from None
    if url is None: return None
    if not isinstance(url,str): raise TerminalError('The API continuation must be a URL or scalar token.')
    url=urljoin(str(response.url),url)
    if origin(url)!=origin(c.url): raise TerminalError('The API returned a continuation on another origin; credentials and checkpoints were not forwarded.')
    return url


async def api_pull(spec: dict,ctx: dict) -> dict:
    task=ctx['_task_id'];worker=ctx['_worker_id'];source=spec.get('source_id')
    async with as_service() as conn:
        if spec.get('source_name'):
            state=json.loads(await conn.fetchval('select content.begin_named_api_pull($1::uuid,$2,$3)::text',task,worker,spec['source_name']))
            source=state['source_id']
        else:
            state=json.loads(await conn.fetchval('select content.begin_api_pull($1::uuid,$2,$3::uuid)::text',task,worker,source))
    if state.get('complete'): return {'result':state['receipt']}
    try: c=APIConfig.model_validate(state['config'])
    except Exception as e: raise TerminalError('Invalid API source configuration: '+str(e)) from None
    headers=request_headers(c)
    url=state.get('next_url') or first_url(c,state.get('watermark'))
    pending=(state.get('pending_watermark') or state.get('watermark') or c.initial_watermark or None) if c.watermark_type!='none' else None
    visited=set(state.get('visited_urls') or [])
    page_hash=state.get('last_page_hash')
    totals={'pages':0,'inserted':0,'updated':0,'unchanged':0}
    async with httpx.AsyncClient(timeout=30,follow_redirects=False) as client:
      for _ in range(c.max_pages):
        if origin(url)!=origin(c.url) or url in visited: raise TerminalError('Pagination repeated a URL or changed API origin. The committed watermark is unchanged.')
        # A saved source's url is a caller's choice, so it gets the worker's egress
        # check (core.egress) -- on every page, because each is a new request.
        await asyncio.to_thread(refuse_internal_egress,url)
        try:
            async with client.stream('GET',url,headers=headers) as response:
                if response.status_code>=300:
                    # The rule is core.provider_errors', shared with every provider call, so an
                    # API account out of credit stops once. Its body is read (capped) only to
                    # classify it and never quoted: an arbitrary API's body is not an operator message.
                    body=bytearray()
                    async for part in response.aiter_bytes():
                        body.extend(part)
                        if len(body)>65536: break
                    raise_for(response.status_code,bytes(body),'The API','the checkpoint is preserved')
                    raise TerminalError(f'API HTTP {response.status_code}. Redirects are not followed; check the endpoint. Progress is preserved.')
                data=bytearray()
                async for part in response.aiter_bytes():
                    data.extend(part)
                    if len(data)>10_000_000: raise TerminalError('An API page exceeds 10 MB. Reduce the page size.')
                try: payload=json.loads(data)
                except ValueError: raise TerminalError('The API returned invalid JSON. No page data or checkpoint was committed.') from None
                records=at(payload,c.records_path)
                if not isinstance(records,list) or not all(isinstance(r,dict) for r in records): raise TerminalError('The record path must select an array of JSON objects.')
                if len(records)>10000: raise TerminalError('An API page exceeds 10,000 records. Reduce the page size.')
                batch=[]
                for row in records:
                    key=at(row,c.id_path)
                    if key is None or isinstance(key,(dict,list,bool)) or not str(key): raise TerminalError('Each record needs a stable scalar ID for deduplication.')
                    mark=None
                    if c.watermark_type!='none':
                        mark=str(at(row,c.watermark_field));value=compare_value(mark,c.watermark_type)
                        if pending is None or value>compare_value(pending,c.watermark_type): pending=mark
                    batch.append({'external_id':str(key),'watermark':mark,'raw':row,'data':map_record(row,c.mappings)})
                nxt=next_page(c,response,payload,len(records))
                fingerprint=hashlib.sha256(json.dumps([(r['external_id'],r['watermark']) for r in batch]).encode()).hexdigest()
                if nxt and (nxt==url or nxt in visited or (batch and fingerprint==page_hash)):
                    raise TerminalError('The API repeated a page. Check pagination settings; the committed watermark is unchanged.')
                async with as_service() as conn:
                    receipt=json.loads(await conn.fetchval('select content.commit_api_page($1::uuid,$2,$3::uuid,$4::bigint,$5::jsonb,$6,$7,$8,$9)::text',
                        task,worker,source,state['revision'],batch,url,nxt,pending,fingerprint))
                state['revision']=receipt['revision'];totals['pages']+=1
                for key in ('inserted','updated','unchanged'): totals[key]+=receipt[key]
                visited.add(url);page_hash=fingerprint
                if not nxt: return {'result':receipt['receipt']}
                url=nxt
        except httpx.RequestError:
            # Request exceptions can include a credential-bearing URL. Keep the
            # operator error useful without copying URLs or response bodies.
            raise RuntimeError('The API connection failed. Retry from the saved checkpoint.') from None
    return {'result':{'source_id':source,**totals,'watermark':state.get('watermark'),'has_more':True,'status':'paused','detail':'Page budget reached. Run again to continue from the saved next page.'}}
