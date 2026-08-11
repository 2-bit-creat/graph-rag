"""OCR ingestion — validation, speaker assembly, and error translation.

The vision model itself is stubbed: these cover the code that decides what
reaches the provider and what the learner sees back, which is where the bugs
live. The assembly tests carry the most weight — a speaker invented here becomes
a person node in the knowledge graph.
"""

from __future__ import annotations

import io
import json
import uuid

import pytest
from fastapi import HTTPException

from app.routers.ocr import (
    MAX_IMAGE_BYTES,
    _sanitize_speaker,
    _translate_llm_error,
    build_labeled_text,
    sniff_image_type,
)

JPEG_MAGIC = b"\xff\xd8\xff\xe0"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _payload(is_conversation: bool, lines: list[tuple[str, str]]) -> dict:
    return {
        "is_conversation": is_conversation,
        "lines": [{"speaker": s, "text": t} for s, t in lines],
    }


class TestSniffImageType:
    def test_detects_jpeg_and_png(self) -> None:
        assert sniff_image_type(JPEG_MAGIC + b"rest") == "image/jpeg"
        assert sniff_image_type(PNG_MAGIC + b"rest") == "image/png"

    def test_rejects_unsupported_and_disguised_content(self) -> None:
        # A renamed PDF is the classic way a client-declared type lies.
        assert sniff_image_type(b"RIFF\x00\x00\x00\x00WEBPVP8 ") is None
        assert sniff_image_type(b"%PDF-1.7\n") is None
        assert sniff_image_type(b"") is None


class TestSanitizeSpeaker:
    def test_accepts_ordinary_names(self) -> None:
        assert _sanitize_speaker("제니") == "제니"
        assert _sanitize_speaker("나") == "나"
        assert _sanitize_speaker("  김 부장  ") == "김 부장"
        assert _sanitize_speaker("Alex_K") == "Alex_K"

    def test_rejects_what_the_client_could_not_match(self) -> None:
        # Each of these would land in the composer as literal "@…:" text with no
        # badge behind it, because mention_editor_core's regex refuses them.
        assert _sanitize_speaker("") is None
        assert _sanitize_speaker(None) is None
        assert _sanitize_speaker("123") is None          # must start with a letter
        assert _sanitize_speaker("@제니") is None          # leading punctuation
        assert _sanitize_speaker("가" * 21) is None       # over 20 chars
        assert _sanitize_speaker("제니(팀장)") is None      # parentheses not allowed


class TestBuildLabeledText:
    def test_conversation_becomes_at_mention_lines(self) -> None:
        text, speakers = build_labeled_text(
            _payload(True, [("제니", "내일 몇 시에 만날까"), ("나", "7시 이후면 아무 때나")])
        )
        assert text == "@제니: 내일 몇 시에 만날까\n@나: 7시 이후면 아무 때나"
        assert speakers == ["제니", "나"]

    def test_plain_document_stays_plain(self) -> None:
        text, speakers = build_labeled_text(
            _payload(False, [("", "오늘의 결심"), ("", "아침에 일찍 일어나기")])
        )
        assert text == "오늘의 결심\n아침에 일찍 일어나기"
        assert speakers == []

    def test_a_glossary_never_produces_speakers(self) -> None:
        """The failure that started all of this, now at the OCR boundary."""
        text, speakers = build_labeled_text(
            _payload(
                False,
                [
                    ("", "약정액: LP가 출자하기로 약속한 최대 금액"),
                    ("", "설정액: 실제로 LP가 납입 완료한 출자 원금"),
                    ("", "ROE: GP 본사 자본의 운용 효율성"),
                ],
            )
        )
        assert speakers == []
        assert "@" not in text

    def test_single_speaker_is_not_worth_labeling(self) -> None:
        text, speakers = build_labeled_text(
            _payload(True, [("제니", "안녕"), ("제니", "잘 지내?")])
        )
        assert text == "안녕\n잘 지내?"
        assert speakers == []

    def test_one_unusable_name_drops_the_whole_result_to_plain(self) -> None:
        """Partial labeling is the worst outcome — some lines attributed, some not."""
        text, speakers = build_labeled_text(
            _payload(True, [("제니", "안녕"), ("제니(팀장)", "반가워")])
        )
        assert text == "안녕\n반가워"
        assert speakers == []

    def test_claimed_conversation_with_no_names_falls_back(self) -> None:
        text, speakers = build_labeled_text(_payload(True, [("", "안녕"), ("", "반가워")]))
        assert speakers == []
        assert text == "안녕\n반가워"

    def test_blank_lines_are_dropped_not_labeled(self) -> None:
        text, speakers = build_labeled_text(
            _payload(True, [("제니", "안녕"), ("나", "   "), ("나", "반가워")])
        )
        assert text == "@제니: 안녕\n@나: 반가워"
        assert speakers == ["제니", "나"]

    def test_empty_and_malformed_payloads_do_not_raise(self) -> None:
        assert build_labeled_text({}) == ("", [])
        assert build_labeled_text({"is_conversation": True, "lines": []}) == ("", [])
        assert build_labeled_text({"lines": "not a list"}) == ("", [])
        assert build_labeled_text({"is_conversation": True, "lines": [None, 3]}) == ("", [])


class TestErrorTranslation:
    @staticmethod
    def _openai_exc(name: str) -> Exception:
        """Build a real SDK exception without making a request."""
        import httpx
        import openai

        request = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")
        if name == "APITimeoutError":
            return openai.APITimeoutError(request=request)
        response = httpx.Response(
            429 if name == "RateLimitError" else 401, request=request
        )
        cls = getattr(openai, name)
        return cls("boom", response=response, body=None)

    def test_rate_limit_becomes_a_retryable_429(self) -> None:
        exc = _translate_llm_error(self._openai_exc("RateLimitError"))
        assert exc.status_code == 429
        assert exc.headers["Retry-After"] == "5"

    def test_timeout_becomes_504(self) -> None:
        assert _translate_llm_error(self._openai_exc("APITimeoutError")).status_code == 504

    def test_auth_failure_is_502_and_does_not_leak_provider_detail(self) -> None:
        exc = _translate_llm_error(self._openai_exc("AuthenticationError"))
        assert exc.status_code == 502
        assert "api" not in str(exc.detail).lower()

    def test_unknown_failure_falls_back_to_502(self) -> None:
        assert _translate_llm_error(RuntimeError("boom")).status_code == 502


class _StubLLM:
    """Minimal stand-in for AsyncOpenAI's chat.completions.create."""

    def __init__(self, payload: dict | str, on_call=None) -> None:
        self._payload = payload
        self._on_call = on_call
        self.chat = self

    @property
    def completions(self):
        return self

    async def create(self, **kwargs):
        if self._on_call:
            self._on_call(kwargs)
        content = (
            self._payload if isinstance(self._payload, str) else json.dumps(self._payload)
        )
        message = type("M", (), {"content": content})()
        choice = type("C", (), {"message": message})()
        return type("R", (), {"choices": [choice]})()


class TestOcrEndpoint:
    """Drives the handler directly with a fake UploadFile and a stubbed client."""

    @staticmethod
    def _upload(data: bytes, content_type: str = "image/jpeg"):
        from fastapi import UploadFile

        return UploadFile(
            filename="page.jpg",
            file=io.BytesIO(data),
            headers={"content-type": content_type},
        )

    @staticmethod
    def _user():
        from app.models import User

        return User(id=uuid.uuid4(), email="ocr@test.local", password_hash="x")

    @pytest.mark.asyncio
    async def test_chat_screenshot_comes_back_mention_labeled(self, monkeypatch) -> None:
        from app.routers import ocr

        seen: dict = {}
        stub = _StubLLM(
            _payload(True, [("제니", "내일 봐"), ("나", "그래")]),
            on_call=seen.update,
        )
        monkeypatch.setattr(ocr, "_llm_client", lambda: stub)

        result = await ocr.ocr_image(
            file=self._upload(JPEG_MAGIC + b"body"),
            retain=False,
            user=self._user(),
        )
        assert result["text"] == "@제니: 내일 봐\n@나: 그래"
        assert result["is_conversation"] is True
        assert result["speakers"] == ["제니", "나"]
        assert result["line_count"] == 2
        # retain=False must not write anything.
        assert result["storage_key"] is None
        # The image has to go up as a data URL at high detail, or Korean glyphs
        # are unreadable.
        image_part = seen["messages"][1]["content"][0]["image_url"]
        assert image_part["url"].startswith("data:image/jpeg;base64,")
        assert image_part["detail"] == "high"

    @pytest.mark.asyncio
    async def test_plain_photo_has_no_speakers(self, monkeypatch) -> None:
        from app.routers import ocr

        monkeypatch.setattr(
            ocr,
            "_llm_client",
            lambda: _StubLLM(_payload(False, [("", "한 줄짜리 메모")])),
        )
        result = await ocr.ocr_image(
            file=self._upload(PNG_MAGIC + b"body", content_type="image/png"),
            retain=False,
            user=self._user(),
        )
        assert result["text"] == "한 줄짜리 메모"
        assert result["is_conversation"] is False
        assert result["speakers"] == []

    @pytest.mark.asyncio
    async def test_unparseable_model_output_is_502_not_a_crash(self, monkeypatch) -> None:
        from app.routers import ocr

        monkeypatch.setattr(ocr, "_llm_client", lambda: _StubLLM("not json at all"))
        with pytest.raises(HTTPException) as excinfo:
            await ocr.ocr_image(
                file=self._upload(JPEG_MAGIC + b"body"),
                retain=False,
                user=self._user(),
            )
        assert excinfo.value.status_code == 502

    @pytest.mark.asyncio
    async def test_empty_upload_is_rejected(self) -> None:
        from app.routers import ocr

        with pytest.raises(HTTPException) as excinfo:
            await ocr.ocr_image(
                file=self._upload(b""), retain=False, user=self._user()
            )
        assert excinfo.value.status_code == 400

    @pytest.mark.asyncio
    async def test_oversized_upload_is_rejected_before_reaching_the_model(self) -> None:
        from app.routers import ocr

        oversized = JPEG_MAGIC + b"\x00" * MAX_IMAGE_BYTES
        with pytest.raises(HTTPException) as excinfo:
            await ocr.ocr_image(
                file=self._upload(oversized), retain=False, user=self._user()
            )
        assert excinfo.value.status_code == 413

    @pytest.mark.asyncio
    async def test_a_pdf_renamed_as_jpeg_is_rejected(self) -> None:
        """The declared content type says JPEG; the bytes say otherwise."""
        from app.routers import ocr

        with pytest.raises(HTTPException) as excinfo:
            await ocr.ocr_image(
                file=self._upload(b"%PDF-1.7\n" + b"x" * 64),
                retain=False,
                user=self._user(),
            )
        assert excinfo.value.status_code == 415

    @pytest.mark.asyncio
    async def test_rate_limit_surfaces_as_429(self, monkeypatch) -> None:
        from app.routers import ocr

        class _Failing(_StubLLM):
            async def create(self, **kwargs):
                raise TestErrorTranslation._openai_exc("RateLimitError")

        monkeypatch.setattr(ocr, "_llm_client", lambda: _Failing({}))
        with pytest.raises(HTTPException) as excinfo:
            await ocr.ocr_image(
                file=self._upload(JPEG_MAGIC + b"body"),
                retain=False,
                user=self._user(),
            )
        assert excinfo.value.status_code == 429

    @pytest.mark.asyncio
    async def test_retain_writes_under_the_users_prefix(self, monkeypatch) -> None:
        """purge_user_storage sweeps `{user_id}/`, so the key must live there."""
        from app.routers import ocr

        written: dict[str, bytes] = {}

        async def _fake_save_media(data: bytes, key: str) -> str:
            written[key] = data
            return key

        monkeypatch.setattr(
            ocr, "_llm_client", lambda: _StubLLM(_payload(False, [("", "kept")]))
        )
        monkeypatch.setattr(ocr, "save_media", _fake_save_media)

        user = self._user()
        result = await ocr.ocr_image(
            file=self._upload(PNG_MAGIC + b"body", content_type="image/png"),
            retain=True,
            user=user,
        )
        assert result["storage_key"].startswith(f"{user.id}/ocr/")
        assert result["storage_key"].endswith(".png")
        assert result["storage_key"] in written
