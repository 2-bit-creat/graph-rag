"""Private deployment actions invoked through Lambda Invoke, never HTTP."""

from __future__ import annotations

import logging
from typing import Any

from .db import database_readiness, run_deployment_migrations

logger = logging.getLogger(__name__)


async def handle_deployment_event(event: dict[str, Any]) -> dict[str, Any]:
    action = event.get("action")
    deployment_id = str(event.get("deployment_id", "unknown"))
    git_sha = str(event.get("git_sha", "unknown"))
    if action == "migrate":
        result = await run_deployment_migrations(git_sha=git_sha)
        logger.info(
            "deployment migration complete",
            extra={"deployment_id": deployment_id, "git_sha": git_sha, "migration_version": result["schema_version"]},
        )
        return result
    if action == "ready":
        result = await database_readiness()
        if result["status"] != "ok":
            raise RuntimeError("deployment readiness check failed")
        logger.info(
            "deployment readiness complete",
            extra={"deployment_id": deployment_id, "git_sha": git_sha, "migration_version": result["schema_version"]},
        )
        return result
    raise ValueError("unsupported deployment action")
