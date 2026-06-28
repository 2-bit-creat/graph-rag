"""Unit tests for speaker recommendation / confirmation."""

import uuid
from unittest.mock import AsyncMock, MagicMock, patch

from app.models import Node, SpeakerProfile
from app.speaker_confirmation import _replace_in_entry_texts


class FakeEntry:
    transcript_ko = "오늘 르센느랑 점심 먹었어"
    transcript_clean_ko = "오늘 르센느랑 점심 먹었어"
    translation_en = None
    transcript_segments = [{"speaker": "A", "text": "르센느가 왔어"}]


def test_replace_in_entry_texts():
    entry = FakeEntry()
    count = _replace_in_entry_texts(entry, "르센느", "김민수 대리")
    assert count >= 2
    assert "김민수 대리" in entry.transcript_ko
    assert entry.transcript_segments[0]["text"] == "김민수 대리가 왔어"


def test_replace_speaker_label_in_entry_texts():
    from app.speaker_confirmation import _replace_speaker_label_in_entry_texts

    class Entry:
        transcript_ko = "[Speaker_1] 안녕하세요"
        transcript_clean_ko = "[Speaker_1] 안녕하세요."
        translation_en = "[Speaker_1] Hello.\n[Speaker 1] Hi again."
        transcript_segments = []

    entry = Entry()
    count = _replace_speaker_label_in_entry_texts(entry, "Speaker_1", "장덕환")
    assert count >= 3
    assert entry.transcript_clean_ko.startswith("[장덕환]")
    assert "[Speaker_1]" not in entry.translation_en
    assert "[장덕환]" in entry.translation_en


def test_sync_translation_speaker_brackets_after_wrong_voice_match():
    from app.speaker_confirmation import _replace_in_entry_texts, _sync_translation_speaker_brackets

    class Entry:
        transcript_ko = "[Speaker_1] 드라마를 보고. 내 이름은 장덕환이고 나는 드라마를 보고 있다."
        transcript_clean_ko = "[장세영] 드라마를 보고 있어요. 제 이름은 장덕환이고, 저는 드라마를 보고 있어요."
        translation_en = (
            "[Jang Saeyoung] I'm watching a drama. "
            "My name is Jang Deokhwan, and I'm watching a drama."
        )
        transcript_segments = []

    entry = Entry()
    _replace_in_entry_texts(entry, "장세영", "장덕환")
    fixes = _sync_translation_speaker_brackets(entry, "장덕환")
    assert fixes == 1
    assert entry.transcript_clean_ko.startswith("[장덕환]")
    assert entry.translation_en.startswith("[Jang Deokhwan]")
    assert "Jang Saeyoung" not in entry.translation_en


def _link_voice(profile, node):
    """Mirror confirm_speaker_identity storage for mocks."""
    profile.node_id = node.id
    node.speaker_profile_id = profile.id
    if getattr(profile, "embedding", None) is None:
        profile.embedding = [0.1] * 256


async def test_recommend_excludes_person_already_claimed_in_session():
    from app.speaker_confirmation import (
        RecommendedNode,
        SpeakerSummary,
        recommend_speaker_node,
    )

    session = AsyncMock()
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()
    jang_node_id = uuid.uuid4()
    other_node_id = uuid.uuid4()
    speaker1_profile_id = uuid.uuid4()
    jang_profile_id = uuid.uuid4()

    speaker1_profile = MagicMock()
    speaker1_profile.id = speaker1_profile_id
    speaker1_profile.node_id = None
    speaker1_profile.embedding = [0.5] * 256
    speaker1_profile.user_id = user_id

    jang_profile = MagicMock()
    jang_profile.id = jang_profile_id
    jang_profile.display_name = "장세영"
    jang_profile.user_id = user_id
    jang_profile.embedding = [0.5] * 256

    jang_node = MagicMock()
    jang_node.id = jang_node_id
    jang_node.user_id = user_id
    jang_node.name = "장세영"
    _link_voice(jang_profile, jang_node)

    other_node = MagicMock()
    other_node.id = other_node_id
    other_node.user_id = user_id
    other_node.name = "김민수"

    async def _get_node(model, node_id):
        if node_id == jang_node_id:
            return jang_node
        if node_id == other_node_id:
            return other_node
        return None

    session.get = AsyncMock(side_effect=_get_node)

    summaries = [
        SpeakerSummary(
            session_label="Speaker_2",
            speaker_profile_id=jang_profile_id,
            needs_confirmation=False,
            confirmed_node=RecommendedNode(id=jang_node_id, name="장세영"),
        ),
        SpeakerSummary(
            session_label="Speaker_1",
            speaker_profile_id=speaker1_profile_id,
            needs_confirmation=True,
            confirmed_node=None,
        ),
    ]

    with patch(
        "app.speaker_confirmation.crud.get_journal_entry",
        new=AsyncMock(return_value=MagicMock()),
    ), patch(
        "app.speaker_confirmation.get_entry_speaker_embedding",
        new=AsyncMock(return_value=(speaker1_profile, speaker1_profile_id)),
    ), patch(
        "app.speaker_confirmation.build_speaker_summaries_for_entry",
        new=AsyncMock(return_value=summaries),
    ), patch(
        "app.speaker_confirmation.crud.find_similar_speaker_profiles_by_embedding",
        new=AsyncMock(
            return_value=[
                (jang_profile, 0.14),
                (MagicMock(
                    id=uuid.uuid4(),
                    node_id=other_node_id,
                    display_name="김민수",
                    user_id=user_id,
                ), 0.35),
            ]
        ),
    ), patch(
        "app.speaker_confirmation._list_person_nodes",
        new=AsyncMock(
            return_value=[
                RecommendedNode(id=other_node_id, name="김민수"),
            ]
        ),
    ):
        result = await recommend_speaker_node(
            session, user_id, entry_id, "Speaker_1"
        )

    assert result.above_threshold is False
    assert result.likely_unregistered is True
    assert result.recommended_node is None
    assert result.match_score == 0.86
    assert result.session_conflict_hint is not None
    assert "장세영" in result.session_conflict_hint
    assert "Speaker_2" in result.session_conflict_hint
    assert all(c.name != "장세영" for c in result.candidates)
    assert all(n.name != "장세영" for n in result.person_nodes)
    if result.candidates:
        assert result.candidates[0].name == "김민수"


async def test_recommend_already_confirmed_includes_match_score():
    from app.speaker_confirmation import recommend_speaker_node

    session = AsyncMock()
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()
    node_id = uuid.uuid4()
    profile_id = uuid.uuid4()

    profile = MagicMock()
    profile.id = profile_id
    profile.node_id = node_id
    profile.display_name = None
    profile.embedding = [0.1] * 256
    profile.user_id = user_id

    node = MagicMock()
    node.id = node_id
    node.user_id = user_id
    node.name = "장세영"
    _link_voice(profile, node)

    appearance = MagicMock()
    appearance.match_score = 1.0

    session.get = AsyncMock(return_value=node)

    with patch(
        "app.speaker_confirmation.crud.get_journal_entry",
        new=AsyncMock(return_value=MagicMock()),
    ), patch(
        "app.speaker_confirmation.get_entry_speaker_embedding",
        new=AsyncMock(return_value=(profile, profile_id)),
    ), patch(
        "app.speaker_confirmation.crud.get_speaker_appearance_for_label",
        new=AsyncMock(return_value=appearance),
    ), patch(
        "app.speaker_confirmation._claimed_nodes_in_entry",
        new=AsyncMock(return_value={}),
    ), patch(
        "app.speaker_confirmation._list_person_nodes",
        new=AsyncMock(return_value=[]),
    ):
        result = await recommend_speaker_node(
            session, user_id, entry_id, "Speaker_2"
        )

    assert result.already_confirmed is True
    assert result.confirmed_node is not None
    assert result.confirmed_node.name == "장세영"
    assert result.match_score == 1.0


async def test_recommend_linked_profile_suggests_until_human_confirm():
    from app.speaker_confirmation import recommend_speaker_node

    session = AsyncMock()
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()
    node_id = uuid.uuid4()
    profile_id = uuid.uuid4()

    profile = MagicMock()
    profile.id = profile_id
    profile.node_id = node_id
    profile.display_name = "제니퍼"
    profile.embedding = [0.1] * 256
    profile.user_id = user_id

    node = MagicMock()
    node.id = node_id
    node.user_id = user_id
    node.name = "제니퍼"
    _link_voice(profile, node)

    appearance = MagicMock()
    appearance.match_score = 0.87

    session.get = AsyncMock(return_value=node)

    with patch(
        "app.speaker_confirmation.crud.get_journal_entry",
        new=AsyncMock(return_value=MagicMock()),
    ), patch(
        "app.speaker_confirmation.get_entry_speaker_embedding",
        new=AsyncMock(return_value=(profile, profile_id)),
    ), patch(
        "app.speaker_confirmation.crud.get_speaker_appearance_for_label",
        new=AsyncMock(return_value=appearance),
    ), patch(
        "app.speaker_confirmation._claimed_nodes_in_entry",
        new=AsyncMock(return_value={}),
    ), patch(
        "app.speaker_confirmation._list_person_nodes",
        new=AsyncMock(return_value=[]),
    ):
        result = await recommend_speaker_node(
            session, user_id, entry_id, "Speaker_1"
        )

    assert result.already_confirmed is False
    assert result.confirmed_node is None
    assert result.recommended_node is not None
    assert result.recommended_node.name == "제니퍼"
    assert result.above_threshold is True


async def test_build_summary_linked_profile_suggested_not_confirmed():
    from app.models import Node, SpeakerProfile
    from app.speaker_confirmation import build_speaker_summaries_for_entry

    session = AsyncMock()
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()
    node_id = uuid.uuid4()
    profile_id = uuid.uuid4()

    appearance = MagicMock()
    appearance.session_label = "Speaker_1"
    appearance.speaker_profile_id = profile_id
    appearance.match_score = 0.95

    profile = MagicMock()
    profile.id = profile_id
    profile.user_id = user_id
    profile.display_name = "장세영"
    profile.embedding = [0.1] * 256

    node = MagicMock()
    node.id = node_id
    node.user_id = user_id
    node.name = "장세영"
    _link_voice(profile, node)

    async def _get(model, obj_id):
        if model is SpeakerProfile and obj_id == profile_id:
            return profile
        if model is Node and obj_id == node_id:
            return node
        return None

    session.get = AsyncMock(side_effect=_get)

    with patch(
        "app.speaker_confirmation.crud.list_speaker_appearances_for_entry",
        new=AsyncMock(return_value=[appearance]),
    ):
        summaries = await build_speaker_summaries_for_entry(
            session, user_id, entry_id
        )

    assert len(summaries) == 1
    assert summaries[0].needs_confirmation is True
    assert summaries[0].confirmed_node is None
    assert summaries[0].suggested_node is not None
    assert summaries[0].suggested_node.name == "장세영"


async def test_confirm_rejecting_voice_match_forks_profile_without_merging():
    from app.speaker_confirmation import confirm_speaker_identity

    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()
    jang_node_id = uuid.uuid4()
    jang_profile_id = uuid.uuid4()
    new_node_id = uuid.uuid4()
    new_profile_id = uuid.uuid4()

    entry = MagicMock()
    entry.transcript_ko = "[Speaker_1] 내 이름은 장덕환이야"
    entry.transcript_clean_ko = "[장세영] 내 이름은 장덕환이야"
    entry.translation_en = "[Jang Saeyoung] My name is Jang Deokhwan."
    entry.transcript_segments = [
        {"speaker": "Speaker_1", "text": "내 이름은 장덕환이야", "speaker_profile_id": str(jang_profile_id)}
    ]

    jang_node = MagicMock()
    jang_node.id = jang_node_id
    jang_node.user_id = user_id
    jang_node.name = "장세영"

    jang_profile = MagicMock()
    jang_profile.id = jang_profile_id
    jang_profile.user_id = user_id
    jang_profile.display_name = "장세영"
    jang_profile.embedding = [0.1] * 256
    jang_profile.total_duration_sec = 3.0
    _link_voice(jang_profile, jang_node)

    new_node = MagicMock()
    new_node.id = new_node_id
    new_node.user_id = user_id
    new_node.name = "장덕환"

    new_profile = MagicMock()
    new_profile.id = new_profile_id
    new_profile.display_name = "장덕환"

    session = AsyncMock()

    async def _get(model, obj_id):
        if model is SpeakerProfile and obj_id == jang_profile_id:
            return jang_profile
        if model is Node and obj_id == jang_node_id:
            return jang_node
        if model is Node and obj_id == new_node_id:
            return new_node
        return None

    session.get = AsyncMock(side_effect=_get)
    session.add = MagicMock()
    session.flush = AsyncMock()
    session.commit = AsyncMock()
    session.refresh = AsyncMock()

    appearance = MagicMock()
    appearance.speaker_profile_id = jang_profile_id
    appearance.session_label = "Speaker_1"

    with patch(
        "app.speaker_confirmation.crud.get_journal_entry",
        new=AsyncMock(return_value=entry),
    ), patch(
        "app.speaker_confirmation.crud.list_speaker_appearances_for_entry",
        new=AsyncMock(return_value=[appearance]),
    ), patch(
        "app.speaker_confirmation.crud.merge_node_into",
        new=AsyncMock(),
    ) as merge_mock:
        created_profiles: list = []

        def _capture_add(obj):
            if isinstance(obj, SpeakerProfile):
                obj.id = new_profile_id
                created_profiles.append(obj)

        session.add.side_effect = _capture_add

        result = await confirm_speaker_identity(
            session,
            user_id,
            entry_id,
            jang_profile_id,
            new_node_name="장덕환",
            wrong_name="장세영",
        )

    merge_mock.assert_not_called()
    assert result.speaker_profile_id == new_profile_id
    assert result.confirmed_node.id is None
    assert result.confirmed_node.name == "장덕환"
    assert result.edges_reassigned == 0
    assert appearance.speaker_profile_id == new_profile_id
    assert jang_profile.node_id == jang_node_id


async def _test_recommend_no_embedding():
    from app.speaker_confirmation import recommend_speaker_node

    session = AsyncMock()
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()

    with patch(
        "app.speaker_confirmation.crud.get_journal_entry",
        new=AsyncMock(return_value=MagicMock()),
    ), patch(
        "app.speaker_confirmation.get_entry_speaker_embedding",
        new=AsyncMock(return_value=(None, None)),
    ):
        result = await recommend_speaker_node(
            session, user_id, entry_id, "Speaker A"
        )
    assert result.recommended_node is None


def test_human_confirmed_match_score():
    from app.speaker_confirmation import HUMAN_CONFIRMED_MATCH_SCORE, _is_human_confirmed_match_score

    assert _is_human_confirmed_match_score(HUMAN_CONFIRMED_MATCH_SCORE)
    assert not _is_human_confirmed_match_score(0.5)


if __name__ == "__main__":
    import asyncio

    from test_speaker_picker_nodes import test_picker_excludes_voiced_and_same_name

    test_replace_in_entry_texts()
    test_sync_translation_speaker_brackets_after_wrong_voice_match()
    test_human_confirmed_match_score()
    asyncio.run(test_picker_excludes_voiced_and_same_name())
    asyncio.run(test_recommend_excludes_person_already_claimed_in_session())
    asyncio.run(test_recommend_already_confirmed_includes_match_score())
    asyncio.run(test_recommend_linked_profile_suggests_until_human_confirm())
    asyncio.run(test_build_summary_linked_profile_suggested_not_confirmed())
    asyncio.run(test_confirm_rejecting_voice_match_forks_profile_without_merging())
    print("OK speaker confirmation tests")
