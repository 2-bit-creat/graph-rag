import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import get_session
from ..deps import request_user_dep
from ..models import User
from ..schemas import GraphJobOut

router = APIRouter(prefix="/jobs", tags=["jobs"])


@router.get("/{job_id}", response_model=GraphJobOut)
async def get_job(
    job_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphJobOut:
    job = await crud.get_graph_job(session, job_id, user.id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return job
