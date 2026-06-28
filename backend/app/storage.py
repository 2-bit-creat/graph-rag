"""Audio file storage — local filesystem with optional S3."""

from __future__ import annotations

import uuid
from pathlib import Path

from .config import get_settings


def _local_root() -> Path:
    root = Path(get_settings().upload_dir)
    root.mkdir(parents=True, exist_ok=True)
    return root


async def save_audio(data: bytes, filename: str, user_id: uuid.UUID) -> str:
    settings = get_settings()
    ext = Path(filename).suffix or ".m4a"
    key = f"{user_id}/{uuid.uuid4()}{ext}"

    if settings.s3_bucket:
        return await _save_s3(data, key)

    path = _local_root() / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return key


async def _save_s3(data: bytes, key: str) -> str:
    import boto3

    settings = get_settings()
    client_kwargs: dict = {"region_name": settings.s3_region}
    if settings.s3_endpoint:
        client_kwargs["endpoint_url"] = settings.s3_endpoint
    client = boto3.client("s3", **client_kwargs)
    client.put_object(Bucket=settings.s3_bucket, Key=key, Body=data)
    return key


def local_path(key: str) -> Path:
    return _local_root() / key
