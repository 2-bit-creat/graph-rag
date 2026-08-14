"""Per-account storage accounting and category-scoped erasure.

One place answers both "what is this account holding?" and "delete just that
part of it", so the two can never drift apart — a category that reports bytes
but has no purge (or purges something the report never counted) is exactly how
orphaned data accumulates.

Sizes come from two sources:

* **Files** (audio, OCR images, JSON doc stores, pipeline dumps) — exact bytes,
  read from the local tree or the S3 prefix via :mod:`app.storage`.
* **Database rows** — ``pg_column_size(t.*)`` summed per table, i.e. the actual
  on-disk tuple size including TOASTed JSONB and pgvector embeddings. It reads
  the full rows, so this is an on-demand report, never something to call on a
  hot path.

Deleting an account (``DELETE /auth/me``, ``/auth/admin/accounts/{handle}``)
does NOT go through here: FK ``ON DELETE CASCADE`` clears every row at once and
``purge_user_storage`` drops the whole prefix. These categories are for the
partial resets a user does while keeping their account.
"""

from __future__ import annotations

import asyncio
import shutil
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import delete, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .models import (
    ChatSession,
    JournalEntry,
    Quiz,
    QuizAttempt,
    QuizBatch,
    QuizGenerationRun,
    QuizGenerationState,
    QuizLearningMaterial,
    QuizPolicyDecision,
    QuizSourceExploration,
    User,
)
from .quiz_audio_engine import AUDIO_DIR, delete_audio_files
from .storage import (
    DOC_CATEGORY,
    debug_runs_usage,
    delete_user_media,
    list_user_media,
    media_kind,
    purge_debug_runs,
)


@dataclass(frozen=True)
class Category:
    key: str
    #: Falls back to this when the client has no string for the key.
    label: str
    description: str


CATEGORIES: tuple[Category, ...] = (
    Category("images", "사진", "OCR로 읽어들인 원본 이미지"),
    Category("audio", "음성 파일", "녹음 원본 오디오"),
    Category("journals", "일기", "일기 본문과 전사·화자 기록"),
    Category("graph", "지식그래프", "노드·관계·검색 청크와 추출된 표현"),
    Category("chats", "대화 내역", "채팅방과 주고받은 메시지"),
    Category("quizzes", "퀴즈·단어장", "생성된 퀴즈, 학습 기록, 단어장 파일"),
    Category("debug", "디버그 기록", "파이프라인 추적 덤프"),
)

CATEGORY_KEYS = tuple(c.key for c in CATEGORIES)


async def _rows_bytes(session: AsyncSession, table: str, where: str, params: dict) -> tuple[int, int]:
    """``(bytes, row count)`` for one table, scoped by a raw WHERE clause.

    ``pg_column_size(t.*)`` is Postgres-specific on purpose: the alternative
    (guessing a per-row constant) would misreport by an order of magnitude for
    rows carrying a 1536-dim embedding or a pipeline trace.
    """
    row = (
        await session.execute(
            text(
                f"SELECT COALESCE(SUM(pg_column_size(t.*)), 0) AS bytes, COUNT(*) AS n "
                f"FROM {table} AS t WHERE {where}"
            ),
            params,
        )
    ).one()
    return int(row.bytes or 0), int(row.n or 0)


async def collect_usage(session: AsyncSession, user_id: uuid.UUID) -> dict:
    """Full per-category usage report for one account."""
    debug_keys = await _user_debug_keys(session, user_id)

    media = await asyncio.to_thread(list_user_media, user_id)
    debug_bytes, debug_runs = await asyncio.to_thread(debug_runs_usage, debug_keys)

    file_bytes: dict[str, int] = {key: 0 for key in CATEGORY_KEYS}
    file_items: dict[str, int] = {key: 0 for key in CATEGORY_KEYS}
    for rel_key, size in media:
        bucket = _media_category(rel_key)
        file_bytes[bucket] += size
        file_items[bucket] += 1

    uid = {"uid": str(user_id)}
    entries_filter = (
        "t.user_id = CAST(:uid AS uuid)"
    )

    node_bytes, node_count = await _rows_bytes(session, "nodes", entries_filter, uid)
    edge_bytes, _ = await _rows_bytes(session, "edges", entries_filter, uid)
    chunk_bytes, _ = await _rows_bytes(session, "chunks", entries_filter, uid)
    alias_bytes, _ = await _rows_bytes(
        session, "node_alias_embeddings", entries_filter, uid
    )
    journal_bytes, journal_count = await _rows_bytes(
        session, "journal_entries", entries_filter, uid
    )
    session_bytes, session_count = await _rows_bytes(
        session, "chat_sessions", entries_filter, uid
    )
    message_bytes, _ = await _rows_bytes(
        session,
        "chat_messages",
        "t.session_id IN (SELECT id FROM chat_sessions WHERE user_id = CAST(:uid AS uuid))",
        uid,
    )
    quiz_bytes, quiz_count = await _rows_bytes(session, "quizzes", entries_filter, uid)
    attempt_bytes, _ = await _rows_bytes(session, "quiz_attempts", entries_filter, uid)
    material_bytes, _ = await _rows_bytes(
        session, "quiz_learning_materials", entries_filter, uid
    )
    run_bytes, _ = await _rows_bytes(session, "quiz_generation_runs", entries_filter, uid)

    db_bytes = {
        "images": 0,
        "audio": 0,
        "journals": journal_bytes,
        "graph": node_bytes + edge_bytes + chunk_bytes + alias_bytes,
        "chats": session_bytes + message_bytes,
        "quizzes": quiz_bytes + attempt_bytes + material_bytes + run_bytes,
        "debug": debug_bytes,
    }
    db_items = {
        "images": 0,
        "audio": 0,
        "journals": journal_count,
        "graph": node_count,
        "chats": session_count,
        "quizzes": quiz_count,
        "debug": debug_runs,
    }

    categories = []
    for category in CATEGORIES:
        key = category.key
        categories.append(
            {
                "key": key,
                "label": category.label,
                "description": category.description,
                "bytes": file_bytes[key] + db_bytes[key],
                "items": db_items[key] + (file_items[key] if key in ("images", "audio") else 0),
                "file_count": file_items[key],
            }
        )

    return {
        "total_bytes": sum(c["bytes"] for c in categories),
        "categories": categories,
    }


#: Tables whose rows are attributed to their ``user_id`` for the account-list
#: total. ``chat_messages`` has no ``user_id``, so it joins through its session.
_TOTAL_TABLES = (
    "nodes",
    "edges",
    "chunks",
    "node_alias_embeddings",
    "journal_entries",
    "chat_sessions",
    "quizzes",
    "quiz_attempts",
    "quiz_learning_materials",
    "quiz_generation_runs",
)


async def total_bytes_by_user(session: AsyncSession) -> dict[uuid.UUID, int]:
    """Rough total stored bytes per account, for the admin overview.

    One grouped query per table for *all* accounts at once rather than a full
    :func:`collect_usage` per account — the overview lists every handle on the
    server, and the per-category breakdown is a detail-view concern.
    """
    union = " UNION ALL ".join(
        f"SELECT user_id, pg_column_size(t.*) AS sz FROM {table} AS t" for table in _TOTAL_TABLES
    )
    union += (
        " UNION ALL SELECT s.user_id, pg_column_size(m.*) AS sz "
        "FROM chat_messages AS m JOIN chat_sessions AS s ON s.id = m.session_id"
    )
    rows = (
        await session.execute(
            text(f"SELECT user_id, COALESCE(SUM(sz), 0) AS bytes FROM ({union}) AS u GROUP BY user_id")
        )
    ).all()
    totals: dict[uuid.UUID, int] = {}
    for user_id, size in rows:
        if user_id is not None:
            totals[user_id] = totals.get(user_id, 0) + int(size or 0)
    return totals


def file_bytes_for_user(user_id: uuid.UUID) -> int:
    """Total bytes this account holds on disk / in the media bucket."""
    return sum(size for _, size in list_user_media(user_id))


def _media_category(rel_key: str) -> str:
    """Which usage category a stored file's bytes belong to."""
    kind = media_kind(rel_key)
    if kind in ("images", "audio"):
        return kind
    # JSON doc stores: two of them are really graph/chat data that happens to
    # live on disk; the rest are the vocabulary/tutor banks.
    name = rel_key.rsplit("/", 1)[-1]
    return DOC_CATEGORY.get(name, "quizzes")


async def _user_entry_ids(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    return [
        row[0]
        for row in (
            await session.execute(
                select(JournalEntry.id).where(JournalEntry.user_id == user_id)
            )
        ).all()
    ]


async def _user_debug_keys(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    """Every id ``debug_runs/`` is keyed by for this user.

    The pipeline tracer names a directory after the journal entry, but the quiz
    generation tracer names one after the *quiz* — so an entry-only sweep left
    half the dumps behind, uncounted and undeleted.
    """
    entry_ids = await _user_entry_ids(session, user_id)
    quiz_ids = [
        row[0]
        for row in (
            await session.execute(select(Quiz.id).where(Quiz.user_id == user_id))
        ).all()
    ]
    return entry_ids + quiz_ids


async def purge_category(
    session: AsyncSession, user_id: uuid.UUID, key: str
) -> dict[str, int]:
    """Erase one category for one account. Returns a per-kind removal count.

    Each branch clears the rows/files the matching report counted AND the
    references that would otherwise dangle (a deleted audio file also clears
    ``journal_entries.audio_url`` so the app stops offering playback).
    """
    if key == "images":
        return await _purge_media(user_id, {"images"})
    if key == "audio":
        removed = await _purge_media(user_id, {"audio"})
        await session.execute(
            update(JournalEntry)
            .where(JournalEntry.user_id == user_id, JournalEntry.audio_url.is_not(None))
            .values(audio_url=None)
        )
        await session.commit()
        return removed
    if key == "journals":
        # Entry deletion drops the derived Statement nodes, the local audio, the
        # build job and the entry's trace dump (see crud); the voice GC then
        # clears profiles no appearance references any more.
        deleted = await crud.delete_all_journal_entries(session, user_id)
        await crud.sanitize_stale_voice_links(session, user_id)
        return {"entries": deleted}
    if key == "graph":
        stats = await crud.clear_user_knowledge_graph(session, user_id)
        return {"nodes": stats.get("nodes_deleted", 0), "edges": stats.get("edges_deleted", 0)}
    if key == "chats":
        result = await session.execute(
            delete(ChatSession).where(ChatSession.user_id == user_id)
        )
        await session.commit()
        files = await _purge_media(user_id, set(), names={"graph_chat_history.json"})
        return {"sessions": int(result.rowcount or 0), **files}
    if key == "quizzes":
        return await _purge_quizzes(session, user_id)
    if key == "debug":
        runs = await asyncio.to_thread(
            purge_debug_runs, await _user_debug_keys(session, user_id)
        )
        await session.execute(
            update(JournalEntry)
            .where(JournalEntry.user_id == user_id)
            .values(debug_run_dir=None, pipeline_trace=None)
        )
        await session.commit()
        return {"debug_runs": runs}
    raise ValueError(f"unknown storage category: {key}")


async def _purge_media(
    user_id: uuid.UUID,
    kinds: set[str],
    names: set[str] | None = None,
) -> dict[str, int]:
    """Delete stored files by media kind and/or exact filename."""
    media = await asyncio.to_thread(list_user_media, user_id)
    targets = [
        rel
        for rel, _ in media
        if media_kind(rel) in kinds or (names and rel.rsplit("/", 1)[-1] in names)
    ]
    removed = await asyncio.to_thread(delete_user_media, user_id, targets)
    return {"files": removed}


async def _purge_quizzes(session: AsyncSession, user_id: uuid.UUID) -> dict[str, int]:
    """Hard-delete every quiz artifact plus the file-based vocabulary banks.

    Deliberately not ``reset_quiz_queue``: archiving keeps the rows (and their
    bytes), which is the opposite of what someone reclaiming space asked for.
    """
    quiz_ids = [
        row[0]
        for row in (
            await session.execute(select(Quiz.id).where(Quiz.user_id == user_id))
        ).all()
    ]
    quiz_result = await session.execute(delete(Quiz).where(Quiz.user_id == user_id))
    for model in (
        QuizAttempt,
        QuizBatch,
        QuizGenerationRun,
        QuizGenerationState,
        QuizLearningMaterial,
        QuizPolicyDecision,
        QuizSourceExploration,
    ):
        await session.execute(delete(model).where(model.user_id == user_id))
    await session.commit()

    # The quiz rows are gone, so their TTS is unreferenced: sweep the shared
    # asset table and the older per-quiz-id files it never covered.
    audio = await purge_quiz_audio_for_quizzes(quiz_ids)
    assets = await gc_orphan_quiz_audio(session)

    # The doc stores counted under this category — everything except the two
    # that belong to graph/chat.
    media = await asyncio.to_thread(list_user_media, user_id)
    targets = [rel for rel, _ in media if _media_category(rel) == "quizzes"]
    removed = await asyncio.to_thread(delete_user_media, user_id, targets)
    return {
        "quizzes": int(quiz_result.rowcount or 0),
        "files": removed,
        "audio_files": audio,
        "audio_assets": assets,
    }


async def gc_orphan_quiz_audio(session: AsyncSession) -> int:
    """Drop TTS assets that no quiz points at any more, and their files.

    ``quiz_audio_assets`` is deliberately account-agnostic — an answer clip is
    content-addressed and shared across every learner who needs that phrase —
    so it is the one table a user/quiz cascade cannot reach. Without this sweep
    every deleted quiz left its sentence MP3 on disk permanently. Keying the
    sweep on "no remaining link" (not on user) is what keeps a shared answer
    asset alive while its last owner is deleted alongside others who still use
    it.
    """
    rows = (
        await session.execute(
            text(
                "SELECT a.id, a.asset_key, a.storage_key FROM quiz_audio_assets AS a "
                "WHERE NOT EXISTS (SELECT 1 FROM quiz_audio_links AS l "
                "                  WHERE l.audio_asset_id = a.id)"
            )
        )
    ).all()
    if not rows:
        return 0
    await session.execute(
        text("DELETE FROM quiz_audio_assets WHERE id = ANY(:ids)"),
        {"ids": [row[0] for row in rows]},
    )
    await session.commit()
    await asyncio.to_thread(
        delete_audio_files, [row[1] for row in rows], [row[2] for row in rows]
    )
    return len(rows)


async def purge_quiz_audio_for_quizzes(quiz_ids: list[uuid.UUID]) -> int:
    """Remove the per-quiz sentence/answer MP3s named after these quiz ids.

    Older quizzes predate ``quiz_audio_assets`` and were written straight to
    ``static/audio/{quiz_id}.mp3``, so the link-based sweep above never sees
    them; naming them directly is the only way they go.
    """
    if not quiz_ids:
        return 0
    names = [f"{quiz_id}{suffix}" for quiz_id in quiz_ids for suffix in ("", "-answer")]
    return await asyncio.to_thread(
        delete_audio_files, names, [f"quiz-audio/{name}.mp3" for name in names]
    )


# --- Server-wide orphan sweep -------------------------------------------------
#
# The delete paths above keep the server clean going forward. This sweep exists
# for what they already missed (or what a crash between the DB commit and the
# file unlink leaves behind): rows and files that nothing references at all.
# Everything it removes is defined by "no live owner", never by age alone —
# except for the young-file grace period, which is what keeps it from eating a
# recording that a pipeline saved seconds ago and has not yet committed a row
# for.

#: Files younger than this are left alone: they may belong to an in-flight
#: request whose database row does not exist yet.
_GRACE_SECONDS = 24 * 3600


def _is_settled(path: Path, now: float) -> bool:
    try:
        return now - path.stat().st_mtime > _GRACE_SECONDS
    except OSError:
        return False


def _dir_size(path: Path) -> int:
    total = 0
    for child in path.rglob("*"):
        try:
            if child.is_file():
                total += child.stat().st_size
        except OSError:
            continue
    return total


def _sweep_files(
    live_user_ids: set[str],
    live_debug_keys: set[str],
    live_audio_names: set[str],
    referenced_media: set[str],
    *,
    dry_run: bool,
) -> dict[str, dict[str, int]]:
    """Remove on-disk artifacts with no live owner. Runs in a worker thread.

    Local storage only, and it must stay that way: with S3 configured the
    durable copies live in the bucket while ``upload_dir`` resolves to a
    read-only deployment directory, so walking it would judge the wrong tree.
    Sweeping the bucket instead needs a full listing per prefix — a different
    and far more expensive operation than this. The row-level GC in
    :func:`gc_orphans` still runs in both modes.
    """
    settings = get_settings()
    if settings.s3_bucket:
        return {}
    now = time.time()
    out: dict[str, dict[str, int]] = {}

    def record(name: str, paths: list[Path], remove) -> None:
        freed = 0
        removed = 0
        for path in paths:
            try:
                size = _dir_size(path) if path.is_dir() else path.stat().st_size
            except OSError:
                continue
            if not dry_run:
                remove(path)
            freed += size
            removed += 1
        out[name] = {"count": removed, "bytes": freed}

    # 1. uploads/{user_id}/ for a user that no longer exists.
    uploads = Path(settings.upload_dir)
    stray_user_dirs = (
        [
            d
            for d in uploads.iterdir()
            if d.is_dir() and d.name not in live_user_ids and _is_settled(d, now)
        ]
        if uploads.is_dir()
        else []
    )
    record("upload_dirs", stray_user_dirs, lambda p: shutil.rmtree(p, ignore_errors=True))

    # 2. Recordings inside a *live* user's prefix that no entry points at.
    #    Audio only, deliberately: an entry row names its audio in audio_url, so
    #    "unreferenced" is decidable. OCR images and the JSON doc stores have no
    #    referencing row at all — sweeping those would delete live data, not
    #    orphans.
    stray_media: list[Path] = []
    if uploads.is_dir():
        for user_dir in uploads.iterdir():
            if not user_dir.is_dir() or user_dir.name not in live_user_ids:
                continue
            for path in user_dir.rglob("*"):
                if not path.is_file():
                    continue
                if media_kind(path.relative_to(user_dir).as_posix()) != "audio":
                    continue
                key = path.relative_to(uploads).as_posix()
                if key not in referenced_media and _is_settled(path, now):
                    stray_media.append(path)
    record("audio_files", stray_media, lambda p: p.unlink(missing_ok=True))

    # 3. debug_runs/{entry_or_quiz_id}/ whose subject is gone.
    debug_root = Path(settings.debug_runs_dir)
    stray_debug = (
        [
            d
            for d in debug_root.iterdir()
            if d.is_dir() and d.name not in live_debug_keys and _is_settled(d, now)
        ]
        if debug_root.is_dir()
        else []
    )
    record("debug_runs", stray_debug, lambda p: shutil.rmtree(p, ignore_errors=True))

    # 4. static/audio/*.mp3 with no quiz and no asset behind it.
    stray_audio = [
        f
        for f in AUDIO_DIR.glob("*.mp3")
        if f.stem not in live_audio_names and _is_settled(f, now)
    ] if AUDIO_DIR.is_dir() else []
    record("quiz_audio", stray_audio, lambda p: p.unlink(missing_ok=True))

    return out


async def gc_orphans(session: AsyncSession, *, dry_run: bool = False) -> dict:
    """Find (and unless ``dry_run``, delete) everything nothing references.

    Server-wide, not per-account: an orphan by definition has no account left
    to scope it to.
    """
    # --- rows ---------------------------------------------------------------
    job_sql = (
        "DELETE FROM graph_jobs g WHERE NOT EXISTS "
        "(SELECT 1 FROM journal_entries j WHERE j.graph_job_id = g.id)"
    )
    if dry_run:
        stray_jobs = int(
            (
                await session.execute(
                    text(job_sql.replace("DELETE FROM graph_jobs g", "SELECT count(*) FROM graph_jobs g"))
                )
            ).scalar()
            or 0
        )
    else:
        # journal_entries.graph_job_id is SET NULL, so deleting an entry leaves
        # its build job behind with nothing pointing at it.
        stray_jobs = int((await session.execute(text(job_sql))).rowcount or 0)
        await session.commit()

    assets = 0
    if not dry_run:
        assets = await gc_orphan_quiz_audio(session)
    else:
        assets = int(
            (
                await session.execute(
                    text(
                        "SELECT count(*) FROM quiz_audio_assets a WHERE NOT EXISTS "
                        "(SELECT 1 FROM quiz_audio_links l WHERE l.audio_asset_id = a.id)"
                    )
                )
            ).scalar()
            or 0
        )

    # --- files --------------------------------------------------------------
    live_user_ids = {
        str(row[0]) for row in (await session.execute(select(User.id))).all()
    }
    entry_ids = {
        str(row[0]) for row in (await session.execute(select(JournalEntry.id))).all()
    }
    quiz_ids = {str(row[0]) for row in (await session.execute(select(Quiz.id))).all()}
    asset_keys = {
        row[0]
        for row in (await session.execute(text("SELECT asset_key FROM quiz_audio_assets"))).all()
    }
    referenced_media = {
        row[0]
        for row in (
            await session.execute(
                select(JournalEntry.audio_url).where(JournalEntry.audio_url.is_not(None))
            )
        ).all()
    }
    live_audio_names = asset_keys | quiz_ids | {f"{qid}-answer" for qid in quiz_ids}

    files = await asyncio.to_thread(
        _sweep_files,
        live_user_ids,
        entry_ids | quiz_ids,
        live_audio_names,
        referenced_media,
        dry_run=dry_run,
    )

    return {
        "dry_run": dry_run,
        "rows": {"graph_jobs": stray_jobs, "quiz_audio_assets": assets},
        "files": files,
        "bytes_freed": sum(entry["bytes"] for entry in files.values()),
    }


async def purge_all(session: AsyncSession, user_id: uuid.UUID) -> dict[str, dict]:
    """Reset the account to empty while keeping the account itself.

    Order matters: the graph goes before the journals so statement cleanup runs
    against a graph that is already gone rather than one being torn down under
    it, and files last so nothing re-creates a doc store mid-purge.
    """
    out: dict[str, dict] = {}
    for key in ("quizzes", "chats", "graph", "journals", "debug", "audio", "images"):
        out[key] = await purge_category(session, user_id, key)
    return out
