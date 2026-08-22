"""Google ID token verification.

The app never sends us a password or an access token — it sends the ID token
Google minted for it, and this module decides whether to believe it.

Three checks matter and skipping any one of them is a full authentication
bypass:

* **Signature** against Google's published keys. Google rotates them, so the
  key set is fetched at runtime and cached rather than pinned.
* **Audience** must be one of *our* OAuth client ids. Without this, a token
  minted for any other Google application would authenticate here — the caller
  only has to sign into some unrelated app and forward the token.
* **Issuer** must be Google itself.

Expiry is enforced by the decoder.
"""

from __future__ import annotations

import logging
import time

import httpx
from jose import JWTError, jwt

from .config import get_settings

logger = logging.getLogger(__name__)

# Google documents both spellings and has historically issued each.
_ISSUERS = ("https://accounts.google.com", "accounts.google.com")

_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"

# Google rotates signing keys roughly daily and serves the next key well before
# it starts using it, so a short cache is safe. A miss on an unknown `kid`
# refetches immediately (see _jwks), which is what actually covers rotation —
# this TTL only bounds how long a *withdrawn* key stays trusted.
_CACHE_TTL_SECONDS = 3600

_cached_jwks: dict | None = None
_cached_at: float = 0.0


class GoogleAuthError(Exception):
    """The token is not a valid, current ID token for one of our clients."""


async def _fetch_jwks() -> dict:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(_CERTS_URL)
        response.raise_for_status()
        return response.json()


async def _jwks(*, force_refresh: bool = False) -> dict:
    global _cached_jwks, _cached_at
    fresh = (
        _cached_jwks is not None
        and not force_refresh
        and (time.monotonic() - _cached_at) < _CACHE_TTL_SECONDS
    )
    if fresh:
        return _cached_jwks  # type: ignore[return-value]
    _cached_jwks = await _fetch_jwks()
    _cached_at = time.monotonic()
    return _cached_jwks


def _reset_cache_for_tests() -> None:
    global _cached_jwks, _cached_at
    _cached_jwks = None
    _cached_at = 0.0


async def _key_for(token: str) -> dict:
    try:
        kid = jwt.get_unverified_header(token).get("kid")
    except JWTError as exc:
        raise GoogleAuthError("malformed token header") from exc
    if not kid:
        raise GoogleAuthError("token header has no key id")

    def find(jwks: dict) -> dict | None:
        for key in jwks.get("keys", []):
            if key.get("kid") == kid:
                return key
        return None

    key = find(await _jwks())
    if key is None:
        # An unknown kid is the expected shape of a key rotation, so refetch
        # once before rejecting. Without this every rotation would 401 all
        # sign-ins until the TTL happened to expire.
        key = find(await _jwks(force_refresh=True))
    if key is None:
        raise GoogleAuthError("token signed with an unknown key")
    return key


async def verify_id_token(token: str) -> str:
    """Return the Google subject id (``sub``) for a valid ID token.

    ``sub`` is Google's stable, immutable per-account identifier. The email
    address is deliberately NOT returned: Google lets users change it, so it
    would split one person into two accounts here, and not storing it keeps
    the address out of the database entirely.
    """
    settings = get_settings()
    audiences = settings.google_client_id_list
    if not audiences:
        raise GoogleAuthError("google login is not configured")

    key = await _key_for(token)
    try:
        # `aud` is checked below instead of by the decoder: python-jose compares
        # a single string, so passing the list of our client ids would never
        # match. Disabling its check and doing the membership test explicitly is
        # what makes multi-platform (Web/Android/iOS) client ids work at all.
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            issuer=_ISSUERS,
            options={"verify_aud": False, "verify_at_hash": False},
        )
    except JWTError as exc:
        # The reason is deliberately not echoed to the client — it would tell an
        # attacker which of signature/audience/expiry they still have to defeat.
        logger.info("google id token rejected: %s", exc)
        raise GoogleAuthError("invalid google token") from exc

    if claims.get("aud") not in audiences:
        logger.info("google id token has an audience we do not own")
        raise GoogleAuthError("invalid google token")

    subject = claims.get("sub")
    if not subject:
        raise GoogleAuthError("google token has no subject")
    return str(subject)
