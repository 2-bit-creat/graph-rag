"""Graph wipe must unlink voice from graph nodes without breaking speaker chips."""

from __future__ import annotations

import inspect
import uuid
from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch
import asyncio

import pytest

from app import crud
from app.models import Node, SpeakerProfile


def test_clear_graph_unlinks_voice_without_deleting_profiles():
    source = inspect.getsource(crud.clear_user_knowledge_graph)
    assert "unlink_speakers_from_graph" in source
    assert "reset_user_speaker_identities" not in source


def test_build_node_out_prefers_node_name_for_voice_label():
    node = Node(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        name="장세영",
        type="Speaker",
        created_at=datetime.now(UTC),
    )
    profile = SpeakerProfile(
        id=uuid.uuid4(),
        user_id=node.user_id,
        label="Voice 1",
        display_name="장덕환",
        embedding=[0.1] * 256,
        sample_count=1,
        total_duration_sec=288.0,
    )
    profile.node_id = node.id
    node.speaker_profile_id = profile.id

    out = crud.build_node_out(node, profile)
    assert out.voice_profile_label == "장세영"
    assert out.voice_embedding_registered is True


def test_sanitize_clears_mismatched_voice_node_names():
    user_id = uuid.uuid4()
    node = Node(
        id=uuid.uuid4(),
        user_id=user_id,
        name="장세영",
        type="Speaker",
    )
    profile = SpeakerProfile(
        id=uuid.uuid4(),
        user_id=user_id,
        label="장덕환",
        display_name="장덕환",
        embedding=[0.1] * 256,
        sample_count=1,
        total_duration_sec=10.0,
    )
    profile.node_id = node.id
    node.speaker_profile_id = profile.id

    session = AsyncMock()

    async def fake_list_profiles(sess, uid):
        return [profile]

    async def fake_get_all(sess, user_id=None):
        return [node]

    async def fake_get(*args, **kwargs):
        pk = args[-1] if args else kwargs.get("ident")
        if pk == profile.id:
            return profile
        if pk == node.id:
            return node
        return None

    session.get = AsyncMock(side_effect=fake_get)
    session.commit = AsyncMock()

    with (
        patch("app.crud.list_speaker_profiles", new=AsyncMock(side_effect=fake_list_profiles)),
        patch("app.crud.get_all_nodes", new=AsyncMock(side_effect=fake_get_all)),
    ):
        cleared = asyncio.run(crud.sanitize_stale_voice_links(session, user_id))

    assert cleared >= 1
    assert profile.node_id is None
    assert node.speaker_profile_id is None
