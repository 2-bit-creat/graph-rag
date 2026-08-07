"""A deployment invoke must not strand the container's event loop.

Every deploy sends a ``kind=deployment`` event to run migrations before traffic
shifts. That path used to call ``asyncio.run()``, which exits via
``set_event_loop(None)``; Mangum's LifespanCycle then calls
``asyncio.get_event_loop()`` and raises "There is no current event loop",
so every later HTTP request on that warm container returned 502.
"""

from __future__ import annotations

import asyncio

import pytest

import lambda_handler


@pytest.fixture(autouse=True)
def _restore_event_loop():
    """Keep these tests from leaking a closed/absent loop into the suite."""
    try:
        previous = asyncio.get_event_loop_policy().get_event_loop()
    except RuntimeError:
        previous = None
    yield
    asyncio.set_event_loop(previous if previous and not previous.is_closed()
                           else asyncio.new_event_loop())


def test_deployment_event_leaves_a_usable_event_loop(monkeypatch):
    async def fake_handle(event):
        return {"status": "migrated", "version": event.get("version")}

    monkeypatch.setattr(lambda_handler, "handle_deployment_event", fake_handle)

    result = lambda_handler.handler({"kind": "deployment", "version": "7"}, None)
    assert result == {"status": "migrated", "version": "7"}

    # The regression: this used to raise RuntimeError, which is exactly what
    # Mangum does on the next HTTP request in the same warm container.
    loop = asyncio.get_event_loop()
    assert not loop.is_closed()


def test_repeated_deployment_events_stay_usable(monkeypatch):
    async def fake_handle(event):
        return {"status": "ok"}

    monkeypatch.setattr(lambda_handler, "handle_deployment_event", fake_handle)

    for _ in range(3):
        assert lambda_handler.handler({"kind": "deployment"}, None) == {"status": "ok"}
        assert not asyncio.get_event_loop().is_closed()


def test_deployment_event_from_function_url_is_rejected(monkeypatch):
    """The administrative protocol must stay unreachable over public HTTP."""
    called = False

    async def fake_handle(event):
        nonlocal called
        called = True
        return {}

    monkeypatch.setattr(lambda_handler, "handle_deployment_event", fake_handle)

    result = lambda_handler.handler(
        {"kind": "deployment", "requestContext": {"http": {"method": "POST"}}}, None
    )
    assert result["statusCode"] == 403
    assert called is False


def test_http_events_go_to_mangum(monkeypatch):
    seen = {}

    def fake_http(event, context):
        seen["event"] = event
        return {"statusCode": 200}

    monkeypatch.setattr(lambda_handler, "_http_handler", fake_http)

    event = {"requestContext": {"http": {"method": "GET", "path": "/health"}}}
    assert lambda_handler.handler(event, None) == {"statusCode": 200}
    assert seen["event"] is event
