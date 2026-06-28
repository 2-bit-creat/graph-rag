"""Tests for global speaker voice embedding assignment."""

from __future__ import annotations

import uuid
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from app.speaker_diarization import diarize_audio
from app.speaker_matching import assign_speakers_to_profiles
from app.speaker_profiles import process_entry_speaker_profiles
from app.voice_embedding import cosine_similarity, embed_speaker_segments

TWO_SPEAKER_WAV = Path(
    __file__).parent / "uploads" / "00000000-0000-0000-0000-000000000001" / (
    "1f6e137b-061a-42d4-8223-70541433f152.wav"
)


class FakeProfile:
    def __init__(
        self,
        *,
        profile_id: uuid.UUID,
        embedding: list[float],
        node_id: uuid.UUID | None = None,
        label: str = "Voice",
        display_name: str | None = None,
    ):
        self.id = profile_id
        self.embedding = embedding
        self.node_id = node_id
        self.label = label
        self.display_name = display_name


def test_assigns_linked_person_to_better_matching_speaker():
    """Speaker with higher similarity to 장세영 should win the linked profile."""
    jang_emb = [1.0] + [0.0] * 255
    jenny_emb = [0.7] + [0.0] * 255
    orphan_emb = [0.0, 1.0] + [0.0] * 254

    linked = FakeProfile(
        profile_id=uuid.uuid4(),
        embedding=jang_emb,
        node_id=uuid.uuid4(),
        label="Voice 1",
        display_name="장세영",
    )
    orphan = FakeProfile(
        profile_id=uuid.uuid4(),
        embedding=orphan_emb,
        node_id=None,
        label="Voice 2",
    )

    embeddings = {
        "Speaker_1": jenny_emb,
        "Speaker_2": jang_emb,
    }

    result = assign_speakers_to_profiles(
        ["Speaker_1", "Speaker_2"],
        embeddings,
        [linked, orphan],
        threshold=0.85,
    )

    assert result["Speaker_2"][0] is linked
    assert result["Speaker_2"][1] >= 0.99
    assert result["Speaker_1"][0] is None
    print("OK assigns_linked_person_to_better_matching_speaker")


async def test_process_entry_matches_speaker2_to_jang_seyoung():
    """Live embeddings: Speaker_2 (장세영 line) should match linked 장세영 profile."""
    assert TWO_SPEAKER_WAV.exists()

    segments, _, _ = await diarize_audio(TWO_SPEAKER_WAV)
    ranges = [(s.speaker, s.start_sec, s.end_sec) for s in segments]
    session_embeddings = embed_speaker_segments(TWO_SPEAKER_WAV, ranges)
    assert len(session_embeddings) >= 2

    from app.db import async_session_factory
    from app import crud
    from app.models import Node

    user_id = uuid.UUID("00000000-0000-0000-0000-000000000001")

    async with async_session_factory() as session:
        profiles = await crud.list_speaker_profiles(session, user_id)
        linked = [p for p in profiles if p.node_id is not None and p.embedding is not None]
        assert linked, "expected at least one linked speaker profile in dev DB"

        jang_profile = None
        for profile in linked:
            node = await session.get(Node, profile.node_id)
            if node and (node.name or "").strip() == "장세영":
                jang_profile = profile
                break
        assert jang_profile is not None, "expected 장세영 linked profile"

        sims = {
            label: cosine_similarity(emb, list(jang_profile.embedding))
            for label, emb in session_embeddings.items()
        }
        print("similarity_to_장세영", sims)

        best_label = max(sims, key=sims.get)
        assert best_label == "Speaker_2", (
            f"Speaker_2 should be closest to 장세영, got {best_label} sims={sims}"
        )

        assignments = assign_speakers_to_profiles(
            list(session_embeddings.keys()),
            session_embeddings,
            profiles,
            threshold=0.85,
        )
        assert assignments["Speaker_2"][0] is not None
        assert assignments["Speaker_2"][0].id == jang_profile.id
        assert assignments["Speaker_1"][0] is None or assignments["Speaker_1"][0].id != jang_profile.id
        print("OK process_entry_matches_speaker2_to_jang_seyoung", assignments)


async def test_process_entry_speaker_profiles_integration():
    """End-to-end profile processing assigns Speaker_2 to 장세영 on fixture audio."""
    assert TWO_SPEAKER_WAV.exists()

    segments, _, _ = await diarize_audio(TWO_SPEAKER_WAV)
    user_id = uuid.UUID("00000000-0000-0000-0000-000000000001")
    entry_id = uuid.uuid4()

    session = AsyncMock()
    session.get = AsyncMock()

    from app.db import async_session_factory
    from app import crud
    from app.models import Node

    async with async_session_factory() as db:
        existing_profiles = await crud.list_speaker_profiles(db, user_id)
        jang_profile = None
        for profile in existing_profiles:
            if profile.node_id is None:
                continue
            node = await db.get(Node, profile.node_id)
            if node and (node.name or "").strip() == "장세영":
                jang_profile = profile
                break

    assert jang_profile is not None

    created_profiles: list = []

    async def _create_profile(session, user_id, label, embedding=None, duration_sec=0.0, last_entry_id=None):
        profile = MagicMock()
        profile.id = uuid.uuid4()
        profile.label = label
        profile.node_id = None
        profile.display_name = None
        profile.embedding = embedding
        created_profiles.append(profile)
        return profile

    async def _update_profile(session, profile, new_embedding, duration_sec=0.0, last_entry_id=None):
        profile.embedding = new_embedding
        return profile

    session.add = MagicMock()
    session.commit = AsyncMock()
    session.refresh = AsyncMock()

    with (
        patch("app.speaker_profiles.crud.list_speaker_profiles", new=AsyncMock(return_value=existing_profiles)),
        patch("app.speaker_profiles.crud.create_speaker_profile", side_effect=_create_profile),
        patch("app.speaker_profiles.crud.update_speaker_profile_embedding", side_effect=_update_profile),
        patch("app.speaker_profiles.crud.record_speaker_entry_appearance", new=AsyncMock()),
    ):
        matches, _ = await process_entry_speaker_profiles(
            session,
            user_id,
            entry_id,
            TWO_SPEAKER_WAV,
            segments,
        )

    by_label = {m["session_label"]: m for m in matches}
    assert by_label["Speaker_2"]["profile_id"] == str(jang_profile.id)
    assert by_label["Speaker_2"]["match_type"] == "voice_matched_linked_node"
    assert by_label["Speaker_1"]["profile_id"] != str(jang_profile.id)
    print("OK test_process_entry_speaker_profiles_integration", matches)


async def main() -> int:
    test_assigns_linked_person_to_better_matching_speaker()
    await test_process_entry_matches_speaker2_to_jang_seyoung()
    await test_process_entry_speaker_profiles_integration()
    print("ALL SPEAKER MATCHING TESTS PASSED")
    return 0


if __name__ == "__main__":
    import asyncio

    raise SystemExit(asyncio.run(main()))
