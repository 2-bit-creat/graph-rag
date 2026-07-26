import uuid

import pytest

from app import crud


@pytest.mark.asyncio
async def test_create_user_persists_selected_native_language(db_session):
    user = await crud.create_user(
        db_session,
        f"native-language-{uuid.uuid4().hex}@example.local",
        password_hash="",
        native_language="english",
    )

    assert user.native_language == "english"


@pytest.mark.asyncio
async def test_native_language_cannot_change_after_account_creation(
    db_session, iso_user
):
    original = iso_user.native_language

    await crud.update_user_profile_settings(
        db_session,
        iso_user,
        native_language=original,
    )

    replacement = "english" if original == "korean" else "korean"
    with pytest.raises(ValueError, match="immutable"):
        await crud.update_user_profile_settings(
            db_session,
            iso_user,
            native_language=replacement,
        )
