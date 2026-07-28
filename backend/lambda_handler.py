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


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Dispatch trusted Lambda Invoke deployment actions before ASGI handling.

    Function URL events always include requestContext; rejecting them here makes
    the administrative protocol unreachable from the public HTTP endpoint.
    """
    if event.get("kind") == "deployment":
        if event.get("requestContext"):
            return {"statusCode": 403, "body": '{"detail":"forbidden"}'}
        return asyncio.run(handle_deployment_event(event))
    return _http_handler(event, context)
