"""AWS Lambda entrypoint.

Wraps the FastAPI ASGI app with Mangum so it can run behind API Gateway.
Used only in deployment; local dev still runs `uvicorn app.main:app`.
"""

import asyncio
from typing import Any

from mangum import Mangum

from app.deployment import handle_deployment_event
from app.main import app

_http_handler = Mangum(app, lifespan="auto")


def _run_deployment(event: dict[str, Any]) -> dict[str, Any]:
    """Run a deployment coroutine without stranding the thread's event loop.

    ``asyncio.run()`` calls ``set_event_loop(None)`` on the way out. Mangum's
    LifespanCycle then does ``asyncio.get_event_loop()``, which raises
    "There is no current event loop" once a loop has been explicitly unset —
    so every later HTTP request served by the same warm container 502'd.
    Deploys invoke this path to run migrations before traffic shifts, so the
    container that just migrated was reliably the one poisoned.
    """
    loop = asyncio.new_event_loop()
    try:
        asyncio.set_event_loop(loop)
        return loop.run_until_complete(handle_deployment_event(event))
    finally:
        try:
            loop.close()
        finally:
            # Leave a usable loop behind rather than None, so a subsequent
            # HTTP invocation on this container still satisfies Mangum.
            asyncio.set_event_loop(asyncio.new_event_loop())


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Dispatch trusted Lambda Invoke deployment actions before ASGI handling.

    Function URL events always include requestContext; rejecting them here makes
    the administrative protocol unreachable from the public HTTP endpoint.
    """
    if event.get("kind") == "deployment":
        if event.get("requestContext"):
            return {"statusCode": 403, "body": '{"detail":"forbidden"}'}
        return _run_deployment(event)
    return _http_handler(event, context)
