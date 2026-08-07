"""OCR ingestion — validation, block flattening, and error translation.

Textract itself is stubbed: these cover the code that decides what reaches AWS
and what the learner sees back, which is where the bugs live.
"""

from __future__ import annotations

import io
import uuid

import pytest
from fastapi import HTTPException

from app.routers.ocr import (
    LOW_CONFIDENCE_THRESHOLD,
    MAX_IMAGE_BYTES,
    _translate_client_error,
    extract_lines,
    sniff_image_type,
)

JPEG_MAGIC = b"\xff\xd8\xff\xe0"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _line(text: str, top: float, left: float = 0.0, confidence: float = 99.0) -> dict:
    return {
        "BlockType": "LINE",
        "Text": text,
        "Confidence": confidence,
        "Geometry": {"BoundingBox": {"Top": top, "Left": left}},
    }


class _ClientError(Exception):
    """Stand-in for botocore's ClientError, which carries the code in .response."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class TestSniffImageType:
    def test_detects_jpeg_and_png(self) -> None:
        assert sniff_image_type(JPEG_MAGIC + b"rest") == "image/jpeg"
        assert sniff_image_type(PNG_MAGIC + b"rest") == "image/png"

    def test_rejects_unsupported_and_disguised_content(self) -> None:
        # WEBP is a real image but not supported by the synchronous API, and a
        # renamed PDF is the classic way a client-declared type lies.
        assert sniff_image_type(b"RIFF\x00\x00\x00\x00WEBPVP8 ") is None
        assert sniff_image_type(b"%PDF-1.7\n") is None
        assert sniff_image_type(b"") is None


class TestExtractLines:
    def test_orders_lines_top_to_bottom_regardless_of_block_order(self) -> None:
        blocks = [
            _line("third", 0.7),
            _line("first", 0.1),
            _line("second", 0.4),
        ]
        text, _ = extract_lines(blocks)
        assert text == "first\nsecond\nthird"

    def test_left_to_right_breaks_ties_on_the_same_baseline(self) -> None:
        blocks = [
            _line("right", 0.2, left=0.8),
            _line("left", 0.2, left=0.1),
        ]
        text, _ = extract_lines(blocks)
        assert text == "left\nright"

    def test_ignores_non_line_blocks(self) -> None:
        blocks = [
            {"BlockType": "PAGE"},
            _line("kept", 0.1),
            {"BlockType": "WORD", "Text": "dropped", "Confidence": 99.0},
        ]
        text, _ = extract_lines(blocks)
        assert text == "kept"

    def test_mean_confidence_averages_only_line_blocks(self) -> None:
        blocks = [
            _line("a", 0.1, confidence=90.0),
            _line("b", 0.2, confidence=80.0),
            {"BlockType": "WORD", "Text": "x", "Confidence": 10.0},
        ]
        _, confidence = extract_lines(blocks)
        assert confidence == 85.0

    def test_empty_result_is_not_an_error(self) -> None:
        text, confidence = extract_lines([])
        assert text == ""
        assert confidence is None

    def test_missing_geometry_does_not_raise(self) -> None:
        blocks = [{"BlockType": "LINE", "Text": "bare", "Confidence": 91.0}]
        text, confidence = extract_lines(blocks)
        assert text == "bare"
        assert confidence == 91.0


class TestErrorTranslation:
    @pytest.mark.parametrize(
        "code",
        ["ThrottlingException", "ProvisionedThroughputExceededException"],
    )
    def test_throttling_becomes_a_retryable_429(self, code: str) -> None:
        exc = _translate_client_error(_ClientError(code))
        assert exc.status_code == 429
        assert exc.headers["Retry-After"] == "5"

    @pytest.mark.parametrize(
        "code",
        [
            "UnsupportedDocumentException",
            "InvalidParameterException",
            "DocumentTooLargeException",
            "BadDocumentException",
        ],
    )
    def test_bad_input_becomes_422(self, code: str) -> None:
        assert _translate_client_error(_ClientError(code)).status_code == 422

    def test_iam_failure_is_502_and_does_not_leak_aws_detail(self) -> None:
        exc = _translate_client_error(_ClientError("AccessDeniedException"))
        assert exc.status_code == 502
        assert "AccessDenied" not in str(exc.detail)

    def test_unknown_failure_falls_back_to_502(self) -> None:
        assert _translate_client_error(RuntimeError("boom")).status_code == 502


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
    async def test_returns_text_and_flags_low_confidence(self, monkeypatch) -> None:
        from app.routers import ocr

        class _Stub:
            def detect_document_text(self, Document):  # noqa: N803 - boto3 kwarg
                assert Document["Bytes"].startswith(JPEG_MAGIC)
                return {
                    "Blocks": [
                        _line("second", 0.5, confidence=60.0),
                        _line("first", 0.1, confidence=60.0),
                    ]
                }

        monkeypatch.setattr(ocr, "_textract_client", lambda: _Stub())

        result = await ocr.ocr_image(
            file=self._upload(JPEG_MAGIC + b"body"),
            retain=False,
            user=self._user(),
        )
        assert result["text"] == "first\nsecond"
        assert result["mean_confidence"] == 60.0
        assert result["low_confidence"] is True
        assert result["line_count"] == 2
        # retain=False must not write anything.
        assert result["storage_key"] is None

    @pytest.mark.asyncio
    async def test_high_confidence_is_not_flagged(self, monkeypatch) -> None:
        from app.routers import ocr

        class _Stub:
            def detect_document_text(self, Document):  # noqa: N803
                return {"Blocks": [_line("clean", 0.1, confidence=99.0)]}

        monkeypatch.setattr(ocr, "_textract_client", lambda: _Stub())
        result = await ocr.ocr_image(
            file=self._upload(PNG_MAGIC + b"body", content_type="image/png"),
            retain=False,
            user=self._user(),
        )
        assert result["low_confidence"] is False
        assert result["mean_confidence"] > LOW_CONFIDENCE_THRESHOLD

    @pytest.mark.asyncio
    async def test_empty_upload_is_rejected(self) -> None:
        from app.routers import ocr

        with pytest.raises(HTTPException) as excinfo:
            await ocr.ocr_image(
                file=self._upload(b""), retain=False, user=self._user()
            )
        assert excinfo.value.status_code == 400

    @pytest.mark.asyncio
    async def test_oversized_upload_is_rejected_before_reaching_aws(self) -> None:
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
    async def test_throttling_surfaces_as_429(self, monkeypatch) -> None:
        from app.routers import ocr

        class _Stub:
            def detect_document_text(self, Document):  # noqa: N803
                raise _ClientError("ThrottlingException")

        monkeypatch.setattr(ocr, "_textract_client", lambda: _Stub())
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

        class _Stub:
            def detect_document_text(self, Document):  # noqa: N803
                return {"Blocks": [_line("kept", 0.1)]}

        written: dict[str, bytes] = {}

        async def _fake_save_media(data: bytes, key: str) -> str:
            written[key] = data
            return key

        monkeypatch.setattr(ocr, "_textract_client", lambda: _Stub())
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
