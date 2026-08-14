"""Physical cleanup for quiz audio assets after link reachability is checked."""

from __future__ import annotations

from pathlib import Path

from .config import get_settings


async def delete_audio_asset_objects(asset_keys: list[str]) -> list[str]:
    """Best-effort delete; callers have already proven every key unreferenced."""
    if not asset_keys:
        return []
    settings = get_settings()
    deleted: list[str] = []
    if settings.s3_bucket:
        import boto3

        client = boto3.client("s3", region_name=settings.s3_region)
        for key in asset_keys:
            client.delete_object(Bucket=settings.s3_bucket, Key=f"quiz-audio/{key}.mp3")
            deleted.append(key)
        return deleted
    root = Path(__file__).resolve().parent.parent / "static" / "audio"
    for key in asset_keys:
        path = root / f"{key}.mp3"
        # Report only what was actually there. Callers now also pass speculative
        # legacy {quiz_id} names that usually have no file, and counting those
        # as deletions would make the response fiction.
        if not path.is_file():
            continue
        path.unlink(missing_ok=True)
        deleted.append(key)
    return deleted
