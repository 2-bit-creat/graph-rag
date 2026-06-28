from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from ..agent.blueprint import get_agent_blueprint
from ..agent.orchestrator import run_agent
from ..agent.trace import tracer
from ..db import get_session
from ..schemas import AgentRunRequest, AgentRunResponse

router = APIRouter(prefix="/agent", tags=["agent"])


@router.post("/run", response_model=AgentRunResponse)
async def agent_run(
    payload: AgentRunRequest, session: AsyncSession = Depends(get_session)
) -> AgentRunResponse:
    if not payload.messages:
        raise HTTPException(status_code=400, detail="messages must not be empty")
    result = await run_agent(session, payload.mode, payload.messages)
    return AgentRunResponse(**result)


@router.get("/blueprint")
async def agent_blueprint() -> dict:
    """Mode flow diagrams + step configuration for the admin blueprint page."""
    return get_agent_blueprint()


# --- Developer-only trace inspection (Agent Flow page) -----------------------


@router.get("/runs")
async def list_runs() -> list[dict]:
    return tracer.list_summaries()


@router.get("/runs/latest")
async def latest_run() -> dict:
    run = tracer.latest()
    if run is None:
        return {}
    return run.to_dict()


@router.get("/runs/{run_id}")
async def get_run(run_id: str) -> dict:
    run = tracer.get(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="run not found")
    return run.to_dict()
