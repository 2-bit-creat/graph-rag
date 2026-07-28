"""Sanitized public deployment checks; response bodies and secrets are never printed."""

from __future__ import annotations

import argparse
import json
from urllib.request import Request, urlopen


def request(url: str, *, method: str = "GET", origin: str | None = None) -> tuple[int, dict[str, str], bytes]:
    headers = {"Cache-Control": "no-cache"}
    if origin:
        headers["Origin"] = origin
        headers["Access-Control-Request-Method"] = "GET"
    with urlopen(Request(url, headers=headers, method=method), timeout=30) as response:
        return response.status, dict(response.headers), response.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--api", required=True)
    parser.add_argument("--web", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    api, web = args.api.rstrip("/"), args.web.rstrip("/")
    for path in ("/health", "/ready"):
        status, _, _ = request(api + path)
        if status != 200:
            raise RuntimeError(f"API {path} returned {status}")
    status, headers, _ = request(api + "/ready", method="OPTIONS", origin=web)
    if status not in (200, 204) or headers.get("access-control-allow-origin", "") != web:
        raise RuntimeError("CORS readiness check failed")
    status, _, _ = request(web + "/")
    if status != 200:
        raise RuntimeError(f"web root returned {status}")
    status, _, body = request(web + "/version.json")
    if status != 200 or json.loads(body).get("git_sha") != args.sha:
        raise RuntimeError("web version does not match deployed commit")
    print("smoke checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
