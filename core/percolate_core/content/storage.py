"""Object storage. One S3-compatible client, always.

"S3-compatible in production, local for testing" does not mean a real S3 client
plus a filesystem client with its own bugs to find -- it means the same client
pointed at a different endpoint (MinIO locally, anything S3-compatible in
production). This module never branches on which; only its configuration does.
"""

from __future__ import annotations

import hashlib
import os
from functools import lru_cache

import boto3
from botocore.client import Config

from ..core import required, s3


@lru_cache(maxsize=1)
def client():
    """The S3 client.

    Credentials are REQUIRED, not defaulted. Shipping a fallback like
    ("p8admin", "p8password") means a misconfigured deployment silently
    authenticates with a credential printed in this file rather than failing --
    and it fails at the first upload, in production, instead of at startup.
    The endpoint does default, because pointing at a local MinIO is a
    reasonable dev default and getting it wrong is loud.
    """
    # WHERE it is comes from core.config.s3(); WHAT TO DO when the credentials
    # are absent stays here, because that answer is this module's and not
    # shared: a Content Server without object storage is broken, while
    # `lake.lake()` returns None for the same absence and is right to.
    settings = s3()
    return boto3.client(
        "s3",
        endpoint_url=settings.endpoint,
        aws_access_key_id=settings.key or required(
            "P8_S3_KEY", "the Content Server needs object storage credentials"),
        aws_secret_access_key=settings.secret or required(
            "P8_S3_SECRET", "the Content Server needs object storage credentials"),
        config=Config(signature_version="s3v4"),
        region_name=settings.region,
    )


def bucket() -> str:
    return s3().bucket


def address(data: bytes) -> tuple[str, str]:
    """The (checksum, object_key) `put` would store these bytes under.

    Separate from `put` so a caller can register the bytes, which is where the
    database authorizes them, before anything is written (REM-566).
    """
    checksum = hashlib.sha256(data).hexdigest()
    return checksum, f"objects/{checksum[:2]}/{checksum}"


def put(data: bytes, content_type: str | None = None) -> tuple[str, str]:
    """Store content-addressed. Returns (checksum, object_key).

    Hash first, then store under the hash. Content-addressing makes the write
    idempotent: re-uploading identical bytes overwrites itself harmlessly, so a
    retry cannot produce a duplicate object. That is what lets register_upload
    dedup on checksum without a distributed lock.
    """
    checksum, key = address(data)
    client().put_object(
        Bucket=bucket(), Key=key, Body=data,
        ContentType=content_type or "application/octet-stream")
    return checksum, key


def get(bkt: str, key: str) -> bytes:
    return client().get_object(Bucket=bkt, Key=key)["Body"].read()


def put_at(key: str, data: bytes, content_type: str | None = None) -> str:
    """Store at a CHOSEN key rather than a content-addressed one.

    Every byte this collection stores is content-addressed by `put` above, and
    that is the right default -- it makes the write idempotent and dedup free.
    One thing genuinely needs a location instead of a hash: a dataset, whose
    files are found by globbing a prefix (`s3://…/datasets/sales/*.parquet`).
    A glob over `objects/ab/abcdef…` cannot say which files are one table.

    So this exists for the tabular path and is deliberately narrow: the caller
    chooses the key, and the content-addressed copy is written anyway, so
    nothing here is the only copy of anything.
    """
    client().put_object(
        Bucket=bucket(), Key=key, Body=data,
        ContentType=content_type or "application/octet-stream")
    return key


def ensure_bucket() -> str:
    """Create the bucket if it is not there. Called once, at startup.

    `docker compose up` is supposed to be the whole install, and it was not:
    a clean MinIO volume has no buckets, nothing in the stack created one, and
    the first upload failed with `NoSuchBucket` from botocore -- a 500 from the
    Content Server, at the first line of RELEASE-0.1.md's acceptance narrative.

    Done at STARTUP rather than lazily on first write, so a deployment whose
    credentials cannot create a bucket finds out when it boots rather than when
    a user uploads. A bucket that already exists is the normal case in
    production and costs one HEAD.
    """
    from botocore.exceptions import ClientError

    name = bucket()
    try:
        client().head_bucket(Bucket=name)
        return name
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") not in ("404", "NoSuchBucket"):
            # 403 is the interesting one: the bucket exists and this credential
            # may not see it, which create_bucket would report as a confusing
            # conflict rather than as the permission problem it is.
            raise
    client().create_bucket(Bucket=name)
    return name
