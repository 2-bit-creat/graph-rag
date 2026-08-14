"""Audio file storage — local filesystem with optional S3."""

from __future__ import annotations

import shutil
import tempfile
import uuid
from collections.abc import Iterable
from pathlib import Path, PurePosixPath

from .config import get_settings


def _local_root() -> Path:
    root = Path(get_settings().upload_dir)
    root.mkdir(parents=True, exist_ok=True)
    return root


def scratch_root() -> Path:
    """Writable working directory for steps that need a real file on disk.

    Distinct from ``_local_root``: that is the durable store, which is read-only
    on Lambda (/var/task) and, once S3 is configured, never written to at all.
    See Settings.scratch_dir.
    """
    settings = get_settings()
    root = (
        Path(settings.scratch_dir)
        if settings.scratch_dir
        else Path(tempfile.gettempdir()) / "graphrag"
    )
    root.mkdir(parents=True, exist_ok=True)
    return root


async def save_audio_workfile(
    data: bytes, filename: str, user_id: uuid.UUID
) -> tuple[str, Path]:
    """Persist audio durably AND hand back a real path to the same bytes.

    ``save_audio`` alone is not enough for the STT pipeline: with S3 configured
    it returns a key whose bytes live only in the bucket, so the trim/diarize/
    voice-embedding steps that take a ``Path`` were being handed a local file
    that never existed. Writing the scratch copy from the bytes already in
    memory avoids a redundant download.
    """
    key = await save_audio(data, filename, user_id)
    return key, write_scratch(data, key)


def write_scratch(data: bytes, key: str) -> Path:
    """Write bytes under ``scratch_root()`` and return the path."""
    path = scratch_root() / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


async def save_audio(data: bytes, filename: str, user_id: uuid.UUID) -> str:
    ext = Path(filename).suffix or ".m4a"
    key = f"{user_id}/{uuid.uuid4()}{ext}"
    return await save_media(data, key)


async def save_media(data: bytes, key: str) -> str:
    """Write bytes under an explicit key — local file (dev) or S3 (prod).

    Unlike ``save_audio``, the caller picks the key (e.g. a deterministic
    ``quiz-audio/{quiz_id}.mp3`` so regenerating a quiz's TTS overwrites
    rather than accumulates objects). Returns the key, same as ``save_audio``.
    """
    settings = get_settings()
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


def public_media_url(key: str) -> str | None:
    """Absolute URL for a key written via ``save_media``/``save_audio`` — the
    CloudFront domain fronting the media bucket, or None when storage is local
    (callers should fall back to a backend-relative path in that case)."""
    settings = get_settings()
    if not settings.s3_bucket:
        return None
    if settings.media_base_url:
        return f"{settings.media_base_url.rstrip('/')}/{key}"
    # No CDN configured — fall back to the direct virtual-hosted S3 URL. Only
    # reachable if the bucket/object is public; fine for dev, not for a
    # CloudFront-OAC-fronted private bucket in production.
    return f"https://{settings.s3_bucket}.s3.{settings.s3_region}.amazonaws.com/{key}"


def local_path(key: str) -> Path:
    return _local_root() / key


# --- Per-user media inventory ------------------------------------------------
#
# Everything a user stores lives under the ``{user_id}/`` prefix, so both the
# usage report and the category-scoped purges below work off one listing rather
# than each guessing at paths. Keys are relative to that prefix.

_AUDIO_EXTS = {".m4a", ".mp3", ".wav", ".webm", ".ogg", ".aac", ".mp4", ".flac"}
_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".gif"}

#: Documents whose bytes belong to a category other than "docs". Keyed by the
#: filename ``json_doc_store`` writes.
DOC_CATEGORY = {
    "graph_chat_history.json": "chats",
    "user_node_expressions.json": "graph",
}


def media_kind(rel_key: str) -> str:
    """Classify one stored object: ``audio`` | ``images`` | ``docs``."""
    parts = PurePosixPath(rel_key).parts
    if parts and parts[0] == "ocr":
        return "images"
    ext = PurePosixPath(rel_key).suffix.lower()
    if ext in _IMAGE_EXTS:
        return "images"
    if ext in _AUDIO_EXTS:
        return "audio"
    return "docs"


def list_user_media(user_id: uuid.UUID) -> list[tuple[str, int]]:
    """``(key relative to the user prefix, size in bytes)`` for every object.

    Reads the local tree, or the S3 prefix when a bucket is configured. Never
    raises for a missing/unreachable store — an empty inventory is the right
    answer for "this user has nothing stored"."""
    settings = get_settings()
    if settings.s3_bucket:
        return _list_s3_prefix(f"{user_id}/")

    root = Path(settings.upload_dir) / str(user_id)
    if not root.is_dir():
        return []
    out: list[tuple[str, int]] = []
    for path in root.rglob("*"):
        try:
            if path.is_file():
                out.append((path.relative_to(root).as_posix(), path.stat().st_size))
        except OSError:
            continue
    return out


def _list_s3_prefix(prefix: str) -> list[tuple[str, int]]:
    try:
        import boto3

        settings = get_settings()
        client_kwargs: dict = {"region_name": settings.s3_region}
        if settings.s3_endpoint:
            client_kwargs["endpoint_url"] = settings.s3_endpoint
        client = boto3.client("s3", **client_kwargs)
        paginator = client.get_paginator("list_objects_v2")
        out: list[tuple[str, int]] = []
        for page in paginator.paginate(Bucket=settings.s3_bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                out.append((obj["Key"][len(prefix) :], int(obj.get("Size") or 0)))
        return out
    except Exception:
        return []


def delete_user_media(user_id: uuid.UUID, rel_keys: Iterable[str]) -> int:
    """Delete specific objects under the user's prefix. Returns how many went."""
    keys = [k for k in rel_keys if k]
    if not keys:
        return 0
    settings = get_settings()
    if settings.s3_bucket:
        return delete_s3_keys([f"{user_id}/{k}" for k in keys])

    root = Path(settings.upload_dir) / str(user_id)
    removed = 0
    for key in keys:
        path = root / key
        try:
            path.unlink()
            removed += 1
        except OSError:
            continue
    # Leave no empty ocr/ shells behind.
    for path in sorted(root.rglob("*"), reverse=True) if root.is_dir() else []:
        if path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass
    return removed


def delete_s3_keys(keys: list[str]) -> int:
    try:
        import boto3

        settings = get_settings()
        client_kwargs: dict = {"region_name": settings.s3_region}
        if settings.s3_endpoint:
            client_kwargs["endpoint_url"] = settings.s3_endpoint
        client = boto3.client("s3", **client_kwargs)
        removed = 0
        for i in range(0, len(keys), 1000):
            batch = keys[i : i + 1000]
            client.delete_objects(
                Bucket=settings.s3_bucket,
                Delete={"Objects": [{"Key": k} for k in batch]},
            )
            removed += len(batch)
        return removed
    except Exception:
        return 0


def debug_runs_usage(entry_ids: Iterable[uuid.UUID]) -> tuple[int, int]:
    """``(bytes, run count)`` held in ``debug_runs/`` for these entries."""
    root = Path(get_settings().debug_runs_dir)
    total = 0
    runs = 0
    for entry_id in entry_ids:
        run_dir = root / str(entry_id)
        if not run_dir.is_dir():
            continue
        runs += 1
        for path in run_dir.rglob("*"):
            try:
                if path.is_file():
                    total += path.stat().st_size
            except OSError:
                continue
    return total, runs


def purge_debug_runs(entry_ids: Iterable[uuid.UUID]) -> int:
    """Remove the pipeline trace dumps for these entries. Returns dirs removed."""
    root = Path(get_settings().debug_runs_dir)
    removed = 0
    for entry_id in entry_ids:
        run_dir = root / str(entry_id)
        if run_dir.is_dir():
            shutil.rmtree(run_dir, ignore_errors=True)
            removed += 1
    return removed


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
