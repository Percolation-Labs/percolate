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

from ..core import required


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
    return boto3.client(
        "s3",
        endpoint_url=os.environ.get("P8_S3_ENDPOINT", "http://localhost:9000"),
        aws_access_key_id=required("P8_S3_KEY", "the Content Server needs object storage credentials"),
        aws_secret_access_key=required("P8_S3_SECRET", "the Content Server needs object storage credentials"),
        config=Config(signature_version="s3v4"),
        region_name=os.environ.get("P8_S3_REGION", "us-east-1"),
    )


def bucket() -> str:
    return os.environ.get("P8_BUCKET", "p8-content")


def put(data: bytes, content_type: str | None = None) -> tuple[str, str]:
    """Store content-addressed. Returns (checksum, object_key).

    Hash first, then store under the hash. Content-addressing makes the write
    idempotent: re-uploading identical bytes overwrites itself harmlessly, so a
    retry cannot produce a duplicate object. That is what lets register_upload
    dedup on checksum without a distributed lock.
    """
    checksum = hashlib.sha256(data).hexdigest()
    key = f"objects/{checksum[:2]}/{checksum}"
    client().put_object(
        Bucket=bucket(), Key=key, Body=data,
        ContentType=content_type or "application/octet-stream")
    return checksum, key


def get(bkt: str, key: str) -> bytes:
    return client().get_object(Bucket=bkt, Key=key)["Body"].read()
