"""Device anonymous auth endpoint."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_device_auth_issues_token_and_authenticates():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        device_id = "test-device-abc123"
        auth = await client.post("/auth/device", json={"device_id": device_id})
        assert auth.status_code == 200
        token = auth.json()["access_token"]
        assert token

        me = await client.get(
            "/auth/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert me.status_code == 200
        assert me.json()["subscription_tier"] == "premium"

        repeat = await client.post("/auth/device", json={"device_id": device_id})
        assert repeat.status_code == 200
        assert repeat.json()["access_token"]
