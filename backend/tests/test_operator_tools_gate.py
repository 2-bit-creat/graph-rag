"""The operator screens must survive production, unlike debug tracing.

학습 큐 관리 · 노드 탐색 현황 · 생성 실행 이력 are linked from the release menu,
but their endpoints used to share ``require_debug_enabled`` — which 404s in
production — so every one of those screens failed with "HTTP 404: Not found".
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException
from fastapi.routing import APIRoute

from app.config import get_settings
from app.deps import require_debug_enabled, require_operator_tools
from app.main import app


def _route_deps(path: str, method: str) -> set[str]:
    # app/main.py re-binds `app` to a CORSMiddleware wrapper so unhandled 500s
    # keep their CORS headers; the FastAPI instance is the wrapped inner app.
    fastapi_app = getattr(app, "app", app)
    for route in fastapi_app.router.routes:
        if isinstance(route, APIRoute) and route.path == path and method in route.methods:
            return {d.call.__name__ for d in route.dependant.dependencies if d.call}
    raise AssertionError(f"route not found: {method} {path}")


@pytest.fixture(autouse=True)
def _reset_settings_cache():
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_operator_tools_enabled_by_default(monkeypatch):
    """Production must not turn these off — that is the 404 regression."""
    monkeypatch.setenv("ENVIRONMENT", "production")
    get_settings.cache_clear()
    settings = get_settings()
    assert settings.is_production
    assert settings.debug_enabled is False
    assert settings.operator_tools_enabled is True
    require_operator_tools()  # does not raise


def test_debug_endpoints_still_404_in_production(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    get_settings.cache_clear()
    with pytest.raises(HTTPException) as exc:
        require_debug_enabled()
    assert exc.value.status_code == 404


def test_operator_tools_can_be_switched_off(monkeypatch):
    monkeypatch.setenv("OPERATOR_TOOLS_ENABLED", "false")
    get_settings.cache_clear()
    with pytest.raises(HTTPException) as exc:
        require_operator_tools()
    assert exc.value.status_code == 404


@pytest.mark.parametrize(
    ("path", "method"),
    [
        ("/quiz/admin/items", "GET"),
        ("/quiz/admin/items/{quiz_id}", "GET"),
        ("/quiz/queue/explorations", "GET"),
        ("/quiz/generation-runs", "GET"),
        ("/quiz/generation-runs", "POST"),
        ("/quiz/generation-runs/{run_id}", "GET"),
        ("/quiz/generation-runs/{run_id}/retry", "POST"),
        ("/quiz/generations", "GET"),
    ],
)
def test_operator_endpoints_are_not_debug_gated(path, method):
    deps = _route_deps(path, method)
    assert "require_operator_tools" in deps
    assert "require_debug_enabled" not in deps


@pytest.mark.parametrize(
    "path",
    [
        # Raw prompts and on-disk artifacts stay behind the debug gate even
        # though they are scoped to the caller's own rows.
        "/quiz/generations/{quiz_id}/trace",
        "/quiz/generations/{quiz_id}/artifacts/{artifact_path:path}",
        "/journal/entries/{entry_id}/trace",
        "/kg/debug/runs",
    ],
)
def test_prompt_bearing_endpoints_stay_debug_gated(path):
    assert "require_debug_enabled" in _route_deps(path, "GET")
