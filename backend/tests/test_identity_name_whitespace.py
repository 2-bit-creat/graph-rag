"""Whitespace must not fork an identity, while real word spacing is retained."""

from __future__ import annotations

import pytest

from app import crud


@pytest.mark.asyncio
async def test_repeated_whitespace_reuses_existing_speaker_identity(
    db_session, iso_user
):
    first = await crud.get_or_create_speaker_node(db_session, iso_user.id, "르브론 제임스")
    await db_session.commit()

    same = await crud.get_or_create_speaker_node(
        db_session, iso_user.id, "  르브론   제임스  "
    )

    assert same.id == first.id
    assert same.name == "르브론 제임스"


@pytest.mark.asyncio
async def test_legacy_repeated_whitespace_identity_is_reused(
    db_session, iso_user
):
    legacy = await crud.get_or_create_speaker_node(db_session, iso_user.id, "나")
    legacy.name = "나  "
    await db_session.commit()

    same = await crud.get_or_create_speaker_node(db_session, iso_user.id, "나")

    assert same.id == legacy.id
