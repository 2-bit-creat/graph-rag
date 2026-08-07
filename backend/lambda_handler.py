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


def _run_coro(coro_factory) -> dict[str, Any]:
    """Run a coroutine without stranding the thread's event loop.

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
        return loop.run_until_complete(coro_factory())
    finally:
        try:
            loop.close()
        finally:
            # Leave a usable loop behind rather than None, so a subsequent
            # HTTP invocation on this container still satisfies Mangum.
            asyncio.set_event_loop(asyncio.new_event_loop())


async def _run_reminders() -> dict[str, Any]:
    """Nightly review reminders, driven by an EventBridge schedule."""
    from app.db import async_session_factory
    from app.push import send_daily_reminders

    async with async_session_factory() as session:
        report = await send_daily_reminders(session)
    return {"sent": report.sent, "pruned": report.pruned, "failed": report.failed}


# Custom (non-HTTP) event kinds, each mapped to the coroutine that serves it.
# Every one of these is administrative and must stay unreachable from the public
# Function URL — see the requestContext guard in handler().
_CUSTOM_EVENTS = {
    "deployment": lambda event: handle_deployment_event(event),
    "reminder": lambda event: _run_reminders(),
}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Dispatch trusted Lambda Invoke actions before ASGI handling.

    Function URL events always include requestContext; rejecting them here makes
    the administrative protocol unreachable from the public HTTP endpoint.
    """
    kind = event.get("kind")
    if kind in _CUSTOM_EVENTS:
        if event.get("requestContext"):
            return {"statusCode": 403, "body": '{"detail":"forbidden"}'}
        return _run_coro(lambda: _CUSTOM_EVENTS[kind](event))
    return _http_handler(event, context)
