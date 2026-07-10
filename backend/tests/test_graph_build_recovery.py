"""Graph ingest must always leave 'graph_processing'.

Regression: a build error that poisoned the build session defeated the
graph_failed write, leaving the entry stuck in 'graph_processing' forever — the
client just kept spinning (infinite buffering). The failure handler now rolls
back and falls back to a fresh session, so the entry always reaches a terminal
status (graph_ready or graph_failed).
"""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import text

from app import crud, pipeline_runner
from app.db import async_session_factory
from app.models import JournalEntry, SpeakerEntryAppearance, SpeakerProfile
from app.speaker_confirmation import confirm_speaker_identity


class _Resp:
    def __init__(self, content):
        self.choices = [type("C", (), {"message": type("M", (), {"content": content})})]
        self.usage = type("U", (), {"prompt_tokens": 10, "completion_tokens": 10})


def _external_payload():
    return json.dumps({
        "contextTypeOptions": ["대화"],
        "claims": [
            {"speaker": "제니", "title": "말차를 만들었다",
             "statement": "저는 말차를 만들었어요.", "concepts": ["말차"]},
            {"speaker": "나", "title": "말차를 마실 것이다",
             "statement": "저는 말차를 마실 거예요.", "concepts": ["말차"]},
        ],
    }, ensure_ascii=False)


async def _two_speaker_entry(db_session, user_id):
    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        translation_en="I made matcha. I will drink matcha.",
        transcript_ko="[Speaker_1] 저는 마차를 만들었어요.\n[Speaker_2] 저는 마차를 마실 거예요.",
        transcript_clean_ko="[Speaker_1] 저는 말차를 만들었어요.\n[Speaker_2] 저는 말차를 마실 거예요.",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "저는 마차를 만들었어요."},
            {"speaker": "Speaker_2", "text": "저는 마차를 마실 거예요."},
        ],
    )
    db_session.add(entry)
    await db_session.flush()
    p1 = SpeakerProfile(user_id=user_id, label="Speaker_1", embedding=[0.1] * 256,
                        sample_count=1, total_duration_sec=2.0)
    p2 = SpeakerProfile(user_id=user_id, label="Speaker_2", embedding=[0.2] * 256,
                        sample_count=1, total_duration_sec=2.0)
    db_session.add_all([p1, p2])
    await db_session.flush()
    for prof, label in ((p1, "Speaker_1"), (p2, "Speaker_2")):
        db_session.add(SpeakerEntryAppearance(
            journal_entry_id=entry.id, speaker_profile_id=prof.id,
            session_label=label, match_score=0.0, duration_sec=2.0))
    await db_session.commit()

    await confirm_speaker_identity(db_session, user_id, entry.id, p1.id,
                                   new_node_name="제니", session_label="Speaker_1")
    await confirm_speaker_identity(db_session, user_id, entry.id, p2.id,
                                   as_self=True, session_label="Speaker_2")
    await db_session.commit()
    return entry.id


@pytest.mark.asyncio
async def test_graph_build_reaches_ready(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    entry_id = await _two_speaker_entry(db_session, iso_user.id)

    with patch("app.routers.kg_build._llm_client") as mk:
        mk.return_value.chat.completions.create = AsyncMock(
            return_value=_Resp(_external_payload())
        )
        await pipeline_runner.run_graph_ingest_pipeline(entry_id, iso_user.id)

    async with async_session_factory() as s:
        fresh = await crud.get_journal_entry(s, entry_id, iso_user.id)
        assert fresh.status == "graph_ready"


@pytest.mark.asyncio
async def test_build_error_poisoning_session_still_marks_failed(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    entry_id = await _two_speaker_entry(db_session, iso_user.id)

    async def poison(session, *_a, **_k):
        try:
            await session.execute(text("SELECT * FROM no_such_table_xyz"))
        except Exception:
            pass  # leaves the transaction needing rollback
        raise RuntimeError("build failed after DB error")

    with patch("app.routers.kg_build.build_statement_graph_from_entry", side_effect=poison):
        with pytest.raises(RuntimeError):
            await pipeline_runner.run_graph_ingest_pipeline(entry_id, iso_user.id)

    async with async_session_factory() as s:
        fresh = await crud.get_journal_entry(s, entry_id, iso_user.id)
        assert fresh.status == "graph_failed", f"stuck at {fresh.status}"
