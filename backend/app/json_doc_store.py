"""Per-user JSON documents, stored on local disk (dev) or S3 (deployed).

Several stores — custom vocabularies, extracted node expressions, tutor drill
history — are whole-document JSON blobs keyed by user. They were all written
straight to ``upload_dir``, which works locally but not in a deployed
environment: on Lambda that path resolves under /var/task, which is read-only,
so every read *and* write raised OSError and surfaced to the client as a
generic "서버에 연결할 수 없어요".

This module keeps the same read-whole/write-whole semantics those stores
already had, and routes them to S3 when ``s3_bucket`` is configured. All
functions are synchronous (boto3 is sync); callers already wrap them in
``asyncio.to_thread``.
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any

from .config import get_settings


def _s3_key(user_id: uuid.UUID, filename: str) -> str:
    return f"{user_id}/{filename}"


def _local_path(user_id: uuid.UUID, filename: str) -> Path:
    """Path to one user document. Pure — it creates nothing.

    It used to mkdir here, so every *read* — including reads for a user id that
    no longer exists, and the speculative reads these stores do on empty state —
    left an empty ``uploads/{user_id}/`` behind. That is how the server
    accumulated thousands of stray directories no account owned. Creating the
    directory belongs to the one caller that actually writes (``write_doc``).
    """
    return Path(get_settings().upload_dir) / str(user_id) / filename


def _s3_client():
    import boto3

    settings = get_settings()
    kwargs: dict = {"region_name": settings.s3_region}
    if settings.s3_endpoint:
        kwargs["endpoint_url"] = settings.s3_endpoint
    return boto3.client("s3", **kwargs)


def read_doc(user_id: uuid.UUID, filename: str) -> Any | None:
    """Return the parsed document, or None when it does not exist yet.

    Corrupt JSON is reported as missing rather than raised — these documents are
    caches/user lists whose callers all have a sane empty-state, and failing the
    whole request over one bad byte is worse than starting fresh.
    """
    settings = get_settings()
    if settings.s3_bucket:
        try:
            obj = _s3_client().get_object(
                Bucket=settings.s3_bucket, Key=_s3_key(user_id, filename)
            )
            return json.loads(obj["Body"].read().decode("utf-8"))
        except Exception:
            return None

    path = _local_path(user_id, filename)
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def write_doc(user_id: uuid.UUID, filename: str, data: Any) -> None:
    settings = get_settings()
    body = json.dumps(data, ensure_ascii=False, indent=2)
    if settings.s3_bucket:
        _s3_client().put_object(
            Bucket=settings.s3_bucket,
            Key=_s3_key(user_id, filename),
            Body=body.encode("utf-8"),
            ContentType="application/json",
        )
        return
    path = _local_path(user_id, filename)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
