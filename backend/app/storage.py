"""Audio file storage — local filesystem with optional S3."""

from __future__ import annotations

import shutil
import uuid
from collections.abc import Iterable
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


def purge_user_storage(user_id: uuid.UUID, entry_ids: Iterable[uuid.UUID]) -> None:
    """Remove every on-disk (and S3) artifact belonging to a deleted user.

    ``uploads/{user_id}/`` holds audio plus the file-based vocabulary and
    expression stores; ``debug_runs/{entry_id}/`` holds pipeline traces and raw
    audio dumps. Best-effort — a missing path is not an error. Call after the DB
    rows have been cascade-deleted."""
    settings = get_settings()

    user_dir = Path(settings.upload_dir) / str(user_id)
    shutil.rmtree(user_dir, ignore_errors=True)

    debug_root = Path(settings.debug_runs_dir)
    for entry_id in entry_ids:
        shutil.rmtree(debug_root / str(entry_id), ignore_errors=True)

    if settings.s3_bucket:
        _delete_s3_prefix(f"{user_id}/")


def _delete_s3_prefix(prefix: str) -> None:
    """Best-effort delete of all S3 objects under a key prefix."""
    try:
        import boto3

        settings = get_settings()
        client_kwargs: dict = {"region_name": settings.s3_region}
        if settings.s3_endpoint:
            client_kwargs["endpoint_url"] = settings.s3_endpoint
        client = boto3.client("s3", **client_kwargs)
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=settings.s3_bucket, Prefix=prefix):
            keys = [{"Key": obj["Key"]} for obj in page.get("Contents", [])]
            if keys:
                client.delete_objects(
                    Bucket=settings.s3_bucket, Delete={"Objects": keys}
                )
    except Exception:
        # Cleanup is best-effort; never block account deletion on storage errors.
        pass
