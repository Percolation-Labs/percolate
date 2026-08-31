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


@lru_cache(maxsize=1)
def client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ.get("P8_S3_ENDPOINT", "http://localhost:9000"),
        aws_access_key_id=os.environ.get("P8_S3_KEY", "p8admin"),
        aws_secret_access_key=os.environ.get("P8_S3_SECRET", "p8password"),
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
