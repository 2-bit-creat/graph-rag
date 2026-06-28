"""Tests for speaker picker person node filtering."""

from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, MagicMock, patch

from app.crud import list_person_nodes, list_person_nodes_for_speaker_picker
from app.entity_types import normalize_entity_type


def _node(name: str, type_: str, node_id: uuid.UUID | None = None) -> MagicMock:
    n = MagicMock()
    n.id = node_id or uuid.uuid4()
    n.name = name
    n.type = type_
    n.user_id = uuid.uuid4()
    n.speaker_profile_id = None
    return n


async def test_picker_excludes_voiced_and_same_name():
    from unittest.mock import AsyncMock, patch

    user_id = uuid.uuid4()
    session = AsyncMock()

    person_jang = _node("장세영", "Person")
    person_cheolsu = _node("철수", "Person")
    speaker_jang = _node("장덕환", "Speaker")
    individual_jang = _node("장세영", "Individual")
    individual_jang.user_id = user_id
    individual_jang.speaker_profile_id = uuid.uuid4()

    voiced_profile = MagicMock()
    voiced_profile.id = individual_jang.speaker_profile_id
    voiced_profile.node_id = individual_jang.id
    voiced_profile.embedding = [0.1] * 256
    voiced_profile.sample_count = 1
    voiced_profile.total_duration_sec = 10.0
    voiced_profile.label = "Voice 1"

    with (
        patch(
            "app.crud.list_person_nodes",
            new=AsyncMock(
                return_value=[
                    person_jang,
                    person_cheolsu,
                    speaker_jang,
                    individual_jang,
                ]
            ),
        ),
        patch(
            "app.crud._speaker_profiles_for_nodes",
            new=AsyncMock(return_value={individual_jang.id: voiced_profile}),
        ),
        patch(
            "app.crud.get_all_nodes",
            new=AsyncMock(return_value=[individual_jang]),
        ),
    ):
        nodes = await list_person_nodes_for_speaker_picker(session, user_id)

    names = [n.name for n in nodes]
    assert "장세영" not in names
    assert "철수" in names
    assert "장덕환" in names


def test_new_speaker_node_defaults_to_person():
    from app.crud import get_or_create_speaker_node

    assert normalize_entity_type("Person") == "Person"
    assert normalize_entity_type("Speaker") == "Speaker"


async def test_list_person_nodes_includes_speaker_type():
    user_id = uuid.uuid4()
    session = AsyncMock()

    speaker_jang = _node("장덕환", "Speaker")
    speaker_jang.user_id = user_id
    person_cheolsu = _node("철수", "Person")
    person_cheolsu.user_id = user_id
    chunk = _node("발화", "Chunk")
    chunk.user_id = user_id

    mock_result = MagicMock()
    mock_result.scalars.return_value.all.return_value = [
        speaker_jang,
        person_cheolsu,
        chunk,
    ]
    session.execute = AsyncMock(return_value=mock_result)

    nodes = await list_person_nodes(session, user_id)
    names = {n.name for n in nodes}
    assert "장덕환" in names
    assert "철수" in names
    assert "발화" not in names


async def test_list_person_nodes_prefers_speaker_over_person_duplicate_name():
    user_id = uuid.uuid4()
    session = AsyncMock()

    person = _node("장세영", "Person")
    person.id = uuid.uuid4()
    person.user_id = user_id
    speaker = _node("장세영", "Speaker")
    speaker.id = uuid.uuid4()
    speaker.user_id = user_id

    mock_result = MagicMock()
    mock_result.scalars.return_value.all.return_value = [person, speaker]
    session.execute = AsyncMock(return_value=mock_result)

    nodes = await list_person_nodes(session, user_id)
    assert len(nodes) == 1
    assert nodes[0].type == "Speaker"
