"""Regression tests for the 3-pair restriction (ko->en, ko->de, en->ko only).

Covers the validation points added when SUPPORTED_PAIRS narrowed from the
looser SUPPORTED_NATIVE x SUPPORTED_TARGET cross product (which used to also
allow english-native/german-target): the profile PATCH route, the crud-layer
invariant for callers outside the router, the runtime filter that protects
readers of stale data, and the quiz_bundle generation guard.
"""

from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete as sa_delete

from app import crud
from app.db import async_session_factory
from app.languages import (
    SUPPORTED_PAIRS,
    default_target_for_native,
    is_supported_pair,
    valid_target_for_native,
)
from app.main import app
from app.models import User
from app.quiz_bundle import BundleSeedError, generate_quiz_bundle


def test_supported_pairs_are_exactly_three():
    assert SUPPORTED_PAIRS == {
        ("korean", "english"),
        ("korean", "german"),
        ("english", "korean"),
    }


def test_default_target_for_native():
    assert default_target_for_native("korean") == "english"
    assert default_target_for_native("english") == "korean"


def test_is_supported_pair():
    assert is_supported_pair("korean", "german")
    assert not is_supported_pair("english", "german")
    assert not is_supported_pair("korean", "korean")


@pytest.mark.asyncio
async def test_create_user_seeds_valid_target_for_english_native(db_session):
    user = await crud.create_user(
        db_session, "pairtest-en@test.local", "x", native_language="english"
    )
    try:
        assert user.target_language == "korean"
        assert user.target_languages == ["korean"]
    finally:
        await db_session.delete(user)
        await db_session.commit()


@pytest.mark.asyncio
async def test_profile_settings_patch_rejects_german_for_english_native(db_session):
    handle = "pairtest" + uuid.uuid4().hex[:8]
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post(
            "/auth/simple", json={"handle": handle, "native_language": "english"}
        )
        token = resp.json()["access_token"]
        try:
            resp = await client.patch(
                "/quiz/profile/settings",
                json={"target_languages": ["german"]},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert resp.status_code == 400
            body = resp.json()["detail"]
            assert body["code"] == "unsupported_target"
            assert body["allowed"] == ["korean"]
        finally:
            async with async_session_factory() as s:
                u = await crud.get_user_by_email(s, f"simple:{handle}@local")
                if u is not None:
                    await s.execute(sa_delete(User).where(User.id == u.id))
                await s.commit()


@pytest.mark.asyncio
async def test_update_user_profile_settings_rejects_unsupported_pair_outside_router(
    iso_user, db_session
):
    iso_user.native_language = "english"
    await db_session.commit()
    with pytest.raises(ValueError, match="unsupported target_language"):
        await crud.update_user_profile_settings(db_session, iso_user, target_language="german")


@pytest.mark.asyncio
async def test_get_effective_target_languages_filters_stale_unsupported_target(
    iso_user, db_session
):
    """A row persisted before the 3-pair restriction (english native, german
    target) must not be handed to a caller as if still valid."""
    iso_user.native_language = "english"
    iso_user.target_language = "german"
    iso_user.target_languages = ["german"]
    await db_session.commit()

    effective = crud.get_effective_target_languages(iso_user)
    assert effective == ["korean"]


@pytest.mark.asyncio
async def test_generate_quiz_bundle_rejects_unsupported_pair(iso_user, db_session):
    iso_user.native_language = "english"
    await db_session.commit()
    with pytest.raises(BundleSeedError, match="unsupported language pair"):
        await generate_quiz_bundle(db_session, iso_user, language="german")


def test_valid_target_for_native_matches_supported_pairs():
    for native in {"korean", "english"}:
        expected = {t for n, t in SUPPORTED_PAIRS if n == native}
        assert valid_target_for_native(native) == expected
