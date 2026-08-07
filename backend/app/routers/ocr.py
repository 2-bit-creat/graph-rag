"""Image → plain text via AWS Textract.

Deliberately a *standalone* step rather than a leg of the knowledge-graph
pipeline. `/kg/extract` already spends most of a 120s Lambda budget inside one
un-retried LLM call (see the `_llm_client()` comment there); prepending OCR
would eat the remaining headroom. Splitting them also matches the product: OCR
output has recognition errors, so the learner gets to fix the text before any
claim is drafted from it — the same human-in-the-loop shape the KG flow already
uses for extract → review → commit.

The caller therefore does: POST /ocr/image → edit → POST /kg/extract.
"""

from __future__ import annotations

import logging
import uuid
from functools import lru_cache

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile

from ..config import get_settings
from ..deps import daily_quota, request_user_dep
from ..rate_limit import KIND_OCR
from ..models import User
from ..storage import save_media

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ocr", tags=["ocr"])

# Textract's synchronous API accepts 10MB, but the bytes also have to survive a
# Lambda request payload and are billed per page — 5MB is well past what a phone
# photo of a page needs after client-side downscaling.
MAX_IMAGE_BYTES = 5 * 1024 * 1024

# Textract DetectDocumentText synchronously supports JPEG/PNG only (TIFF/PDF are
# async-only). WEBP is rejected here rather than at AWS so the error is useful.
_ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/jpg", "image/png"}

# Content-Type is client-supplied, so the real gate is the magic number.
_MAGIC_PREFIXES: tuple[tuple[bytes, str], ...] = (
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"\x89PNG\r\n\x1a\n", "image/png"),
)

# Below this the client shows a "check the text" warning rather than trusting it.
LOW_CONFIDENCE_THRESHOLD = 85.0


def sniff_image_type(data: bytes) -> str | None:
    """Return the real image type from its magic bytes, or None if unsupported."""
    for prefix, content_type in _MAGIC_PREFIXES:
        if data.startswith(prefix):
            return content_type
    return None


@lru_cache
def _textract_client():
    """Module-level client so warm Lambda containers skip the handshake.

    Retries are ON here, unlike the LLM clients elsewhere in this codebase.
    Textract answers in ~1-3s, so a couple of adaptive retries against a
    throttling response fit comfortably inside the request budget — the reason
    `/kg/extract` sets max_retries=0 does not apply.
    """
    import boto3
    from botocore.config import Config

    settings = get_settings()
    return boto3.client(
        "textract",
        region_name=settings.s3_region,
        config=Config(
            retries={"max_attempts": 3, "mode": "adaptive"},
            connect_timeout=3,
            read_timeout=25,
        ),
    )


def extract_lines(blocks: list[dict]) -> tuple[str, float | None]:
    """Flatten Textract blocks into reading-order text plus mean confidence.

    Textract returns blocks in no guaranteed order, so lines are sorted by their
    normalized vertical position. Left-to-right is the tiebreak for two lines
    that share a baseline (a two-column receipt, a labelled form row).
    """
    lines = [b for b in blocks if b.get("BlockType") == "LINE"]

    def position(block: dict) -> tuple[float, float]:
        box = (block.get("Geometry") or {}).get("BoundingBox") or {}
        return (box.get("Top") or 0.0, box.get("Left") or 0.0)

    lines.sort(key=position)
    text = "\n".join((b.get("Text") or "") for b in lines).strip()

    confidences = [
        float(b["Confidence"]) for b in lines if b.get("Confidence") is not None
    ]
    mean_confidence = (
        round(sum(confidences) / len(confidences), 2) if confidences else None
    )
    return text, mean_confidence


def _translate_client_error(exc: Exception) -> HTTPException:
    """Map botocore's error codes onto responses the client can act on."""
    code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")

    if code in ("ThrottlingException", "ProvisionedThroughputExceededException"):
        return HTTPException(
            status_code=429,
            detail="OCR 요청이 몰려 잠시 처리할 수 없습니다. 잠시 후 다시 시도해 주세요.",
            headers={"Retry-After": "5"},
        )
    if code in (
        "UnsupportedDocumentException",
        "InvalidParameterException",
        "DocumentTooLargeException",
        "BadDocumentException",
    ):
        return HTTPException(
            status_code=422,
            detail="이미지를 읽을 수 없습니다. 더 선명한 사진으로 다시 시도해 주세요.",
        )
    if code in ("AccessDeniedException", "UnrecognizedClientException"):
        # A deployment/IAM problem, not the learner's. Do not leak the AWS text.
        logger.error("Textract access denied — check the function's IAM policy")
        return HTTPException(status_code=502, detail="OCR 서비스를 사용할 수 없습니다.")

    logger.exception("Textract call failed (code=%s)", code or "unknown")
    return HTTPException(status_code=502, detail="OCR 처리에 실패했습니다.")


@router.post("/image")
async def ocr_image(
    file: UploadFile = File(...),
    # Off by default: the extracted text is what the product needs, and the
    # retention-minimisation principle in docs/PRIVACY.md says not to keep the
    # source photo unless someone asked for it. When true the object lands under
    # `{user_id}/` so purge_user_storage sweeps it on account deletion.
    retain: bool = Query(False),
    user: User = Depends(request_user_dep),
    _quota: None = Depends(daily_quota(KIND_OCR)),
) -> dict:
    """Turn a photo of text into plain text. Nothing is persisted to the graph."""
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="빈 파일입니다.")
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"이미지가 너무 큽니다 (최대 {MAX_IMAGE_BYTES // (1024 * 1024)}MB).",
        )

    sniffed = sniff_image_type(data)
    if sniffed is None:
        raise HTTPException(
            status_code=415,
            detail="JPEG 또는 PNG 이미지만 지원합니다.",
        )
    declared = (file.content_type or "").split(";")[0].strip().lower()
    if declared and declared not in _ALLOWED_CONTENT_TYPES:
        raise HTTPException(
            status_code=415,
            detail="JPEG 또는 PNG 이미지만 지원합니다.",
        )

    storage_key: str | None = None
    if retain:
        ext = ".png" if sniffed == "image/png" else ".jpg"
        storage_key = await save_media(data, f"{user.id}/ocr/{uuid.uuid4()}{ext}")

    try:
        response = _textract_client().detect_document_text(Document={"Bytes": data})
    except HTTPException:
        raise
    except Exception as exc:
        raise _translate_client_error(exc) from exc

    text, mean_confidence = extract_lines(response.get("Blocks") or [])
    return {
        "text": text,
        "mean_confidence": mean_confidence,
        "low_confidence": (
            mean_confidence is not None and mean_confidence < LOW_CONFIDENCE_THRESHOLD
        ),
        "line_count": len(text.splitlines()) if text else 0,
        "storage_key": storage_key,
    }
