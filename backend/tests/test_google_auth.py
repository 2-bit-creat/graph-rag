"""Google ID token verification.

Every case here is an authentication bypass if it regresses, so they assert the
rejections rather than only the happy path.
"""

from __future__ import annotations

import time

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from jose import jwt
from jose.backends import RSAKey

from app import google_auth
from app.config import get_settings
from app.google_auth import GoogleAuthError, verify_id_token

_AUDIENCE = "test-web.apps.googleusercontent.com"
_OTHER_AUDIENCE = "test-android.apps.googleusercontent.com"
_KID = "test-key-1"


@pytest.fixture(scope="module")
def keypair() -> tuple[str, dict]:
    """A throwaway RSA key plus the JWKS entry that matches it."""
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = private.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    public_pem = (
        private.public_key()
        .public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        .decode()
    )
    jwk = RSAKey(public_pem, algorithm="RS256").to_dict()
    jwk = {k: (v.decode() if isinstance(v, bytes) else v) for k, v in jwk.items()}
    jwk["kid"] = _KID
    return private_pem, jwk


@pytest.fixture(autouse=True)
def google_configured(monkeypatch, keypair):
    """Point the verifier at our own key set and client ids."""
    _, jwk = keypair
    settings = get_settings()
    monkeypatch.setattr(
        settings, "google_client_ids", f"{_AUDIENCE},{_OTHER_AUDIENCE}", raising=False
    )
    google_auth._reset_cache_for_tests()

    async def fake_fetch() -> dict:
        return {"keys": [jwk]}

    monkeypatch.setattr(google_auth, "_fetch_jwks", fake_fetch)
    yield
    google_auth._reset_cache_for_tests()


def _token(keypair, **overrides) -> str:
    private_pem, _ = keypair
    now = int(time.time())
    claims = {
        "iss": "https://accounts.google.com",
        "aud": _AUDIENCE,
        "sub": "117263849201847362514",
        "iat": now,
        "exp": now + 3600,
    }
    claims.update(overrides)
    return jwt.encode(claims, private_pem, algorithm="RS256", headers={"kid": _KID})


@pytest.mark.asyncio
async def test_valid_token_returns_subject(keypair):
    assert await verify_id_token(_token(keypair)) == "117263849201847362514"


@pytest.mark.asyncio
async def test_second_client_id_is_accepted(keypair):
    """Google stamps a different client id per platform, so Android's token
    must pass against the same server as the web one."""
    assert await verify_id_token(_token(keypair, aud=_OTHER_AUDIENCE))


@pytest.mark.asyncio
async def test_token_for_another_app_is_rejected(keypair):
    """A token minted for someone else's Google app must not log anyone in —
    otherwise any Google application becomes a login bypass for this one."""
    with pytest.raises(GoogleAuthError):
        await verify_id_token(_token(keypair, aud="attacker.apps.googleusercontent.com"))


@pytest.mark.asyncio
async def test_wrong_issuer_is_rejected(keypair):
    with pytest.raises(GoogleAuthError):
        await verify_id_token(_token(keypair, iss="https://accounts.evil.example"))


@pytest.mark.asyncio
async def test_expired_token_is_rejected(keypair):
    now = int(time.time())
    with pytest.raises(GoogleAuthError):
        await verify_id_token(_token(keypair, iat=now - 7200, exp=now - 3600))


@pytest.mark.asyncio
async def test_token_signed_by_another_key_is_rejected(keypair):
    """Same claims, same kid, attacker's signature."""
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    other_pem = other.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    now = int(time.time())
    forged = jwt.encode(
        {
            "iss": "https://accounts.google.com",
            "aud": _AUDIENCE,
            "sub": "117263849201847362514",
            "iat": now,
            "exp": now + 3600,
        },
        other_pem,
        algorithm="RS256",
        headers={"kid": _KID},
    )
    with pytest.raises(GoogleAuthError):
        await verify_id_token(forged)


@pytest.mark.asyncio
async def test_unknown_kid_refetches_once_then_rejects(keypair, monkeypatch):
    calls = {"n": 0}
    _, jwk = keypair

    async def counting_fetch() -> dict:
        calls["n"] += 1
        return {"keys": [jwk]}

    monkeypatch.setattr(google_auth, "_fetch_jwks", counting_fetch)
    google_auth._reset_cache_for_tests()
    private_pem, _ = keypair
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://accounts.google.com",
            "aud": _AUDIENCE,
            "sub": "1",
            "iat": now,
            "exp": now + 3600,
        },
        private_pem,
        algorithm="RS256",
        headers={"kid": "rotated-away"},
    )
    with pytest.raises(GoogleAuthError):
        await verify_id_token(token)
    # Once for the cached miss, once for the forced refresh — a rotation must
    # not be able to loop on the network.
    assert calls["n"] == 2


@pytest.mark.asyncio
async def test_unconfigured_server_rejects_everything(keypair, monkeypatch):
    monkeypatch.setattr(get_settings(), "google_client_ids", "", raising=False)
    with pytest.raises(GoogleAuthError):
        await verify_id_token(_token(keypair))
