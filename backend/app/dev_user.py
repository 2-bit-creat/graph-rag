"""Dev-mode user — no login required."""

import uuid

from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .auth_utils import hash_password
from .db import get_session
from .models import User

DEV_EMAIL = "dev@local"
DEV_USER_ID = uuid.UUID("00000000-0000-0000-0000-000000000001")


async def get_dev_user(session: AsyncSession) -> User:
    user = await session.get(User, DEV_USER_ID)
    if user is None:
        user = await session.scalar(select(User).where(User.email == DEV_EMAIL))
    if user is None:
        user = User(
            id=DEV_USER_ID,
            email=DEV_EMAIL,
            password_hash=hash_password("dev"),
            subscription_tier="premium",
        )
        session.add(user)
        await session.commit()
        await session.refresh(user)
    elif user.subscription_tier != "premium":
        user.subscription_tier = "premium"
        await session.commit()
        await session.refresh(user)
    return user


async def dev_user_dep(session: AsyncSession = Depends(get_session)) -> User:
    return await get_dev_user(session)
