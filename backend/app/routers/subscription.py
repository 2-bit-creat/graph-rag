from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..dev_user import dev_user_dep
from ..models import User
from ..schemas import SubscriptionUpdate, UserOut

router = APIRouter(prefix="/subscription", tags=["subscription"])


@router.post("/update", response_model=UserOut)
async def update_subscription(
    payload: SubscriptionUpdate,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> User:
    """Webhook placeholder — in production, verify RevenueCat/Store receipt."""
    user.subscription_tier = payload.tier
    await session.commit()
    await session.refresh(user)
    return user
