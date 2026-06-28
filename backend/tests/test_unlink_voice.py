"""Unlink voice embedding from a Speaker graph node."""

from __future__ import annotations

import uuid

import pytest

from app import crud
from app.models import Node, SpeakerProfile


@pytest.mark.asyncio
async def test_unlink_voice_from_node_clears_bidirectional_link(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    node = Node(user_id=user_id, name="장세영", type="Speaker")
    db_session.add(node)
    await db_session.flush()

    profile = SpeakerProfile(
        user_id=user_id,
        label="장세영",
        display_name="장세영",
        node_id=node.id,
        embedding=[0.1] * 256,
        sample_count=3,
        total_duration_sec=12.0,
    )
    db_session.add(profile)
    await db_session.flush()
    node.speaker_profile_id = profile.id
    await db_session.commit()
    await db_session.refresh(node)
    await db_session.refresh(profile)

    updated = await crud.unlink_voice_from_node(db_session, user_id, node.id)
    assert updated is not None

    await db_session.refresh(node)
    await db_session.refresh(profile)
    assert node.speaker_profile_id is None
    assert profile.node_id is None
    assert profile.embedding is None
    assert profile.sample_count == 0
    assert profile.total_duration_sec == 0.0


@pytest.mark.asyncio
async def test_unlink_voice_from_node_returns_none_for_other_user(db_session, dev_user):
    other_user_id = uuid.uuid4()
    node = Node(user_id=other_user_id, name="Other", type="Speaker")
    db_session.add(node)
    await db_session.commit()

    result = await crud.unlink_voice_from_node(db_session, dev_user.id, node.id)
    assert result is None
