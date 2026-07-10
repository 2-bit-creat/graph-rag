import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..auth_utils import create_access_token, hash_password, verify_password
from ..db import get_session
from ..deps import get_current_user
from ..models import User
from ..schemas import DeviceAuthRequest, LoginRequest, RegisterRequest, TokenResponse, UserOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    if len(payload.password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")
    existing = await crud.get_user_by_email(session, payload.email)
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")
    user = await crud.create_user(
        session, payload.email, hash_password(payload.password)
    )
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token)


@router.post("/login", response_model=TokenResponse)
async def login(
    payload: LoginRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    user = await crud.get_user_by_email(session, payload.email)
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token)


@router.post("/device", response_model=TokenResponse)
async def device_auth(
    payload: DeviceAuthRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    device_id = payload.device_id.strip()
    if not device_id:
        raise HTTPException(status_code=400, detail="device_id is required")
    user = await crud.get_or_create_device_user(session, device_id)
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> User:
    return user
