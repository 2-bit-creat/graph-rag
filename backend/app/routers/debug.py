"""Serve pipeline debug artifacts from debug_runs/."""

import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..config import get_settings
from ..db import get_session
from ..dev_user import dev_user_dep
from ..models import User
from ..pipeline_flow import flow_layout_for_trace, get_pipeline_blueprint
from ..schemas import PipelineTraceOut

router = APIRouter(prefix="/journal", tags=["debug"])


@router.get("/entries/{entry_id}/trace", response_model=PipelineTraceOut)
async def get_entry_trace(
    entry_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> PipelineTraceOut:
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if entry.pipeline_trace:
        trace = dict(entry.pipeline_trace)
    else:
        from datetime import UTC, datetime

        trace = {
            "run_id": str(entry_id),
            "entry_id": str(entry_id),
            "started_at": datetime.now(UTC).isoformat(),
            "status": "pending",
            "debug_dir": f"debug_runs/{entry_id}",
            "current_phase": "fast_path",
            "timing": {},
            "steps": [],
        }
    trace["flow_layout"] = flow_layout_for_trace(trace)
    return PipelineTraceOut(**trace)


@router.get("/pipeline/flow-blueprint")
async def get_pipeline_flow_blueprint() -> dict:
    """Static journal pipeline DAG — update pipeline_flow.py when steps change."""
    bp = get_pipeline_blueprint()
    bp["flow_layout"] = flow_layout_for_trace({"steps": [], "status": "pending"})
    return bp


@router.get("/entries/{entry_id}/artifacts/{artifact_path:path}")
async def get_artifact(
    entry_id: uuid.UUID,
    artifact_path: str,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> FileResponse:
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")

    settings = get_settings()
    root = Path(settings.debug_runs_dir) / str(entry_id)
    file_path = (root / artifact_path).resolve()
    if not file_path.is_relative_to(root.resolve()):
        raise HTTPException(status_code=400, detail="Invalid artifact path")
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Artifact not found")

    media = "application/octet-stream"
    if file_path.suffix == ".json":
        media = "application/json"
    elif file_path.suffix == ".txt":
        media = "text/plain"
    elif file_path.suffix in {".wav", ".m4a", ".mp3", ".webm"}:
        media = "audio/*"

    return FileResponse(file_path, media_type=media, filename=file_path.name)
