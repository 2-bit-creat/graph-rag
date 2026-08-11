"""Image → text (and, for chat screenshots, speaker labels) via a vision LLM.

Deliberately a *standalone* step rather than a leg of the knowledge-graph
pipeline. `/kg/extract` already spends most of a 120s Lambda budget inside one
un-retried LLM call (see the `_llm_client()` comment there); prepending OCR
would eat the remaining headroom. Splitting them also matches the product: OCR
output has recognition errors, so the learner gets to fix the text before any
claim is drafted from it — the same human-in-the-loop shape the KG flow already
uses for extract → review → commit.

The caller therefore does: POST /ocr/image → edit → POST /kg/extract.

Why a vision model and not a dedicated OCR API
----------------------------------------------
This used to call AWS Textract. Textract does not support Korean — its language
list is English/Spanish/Italian/Portuguese/French/German — which is the wrong
engine for a Korean journal. Once the engine had to change anyway, the vision
model won on two counts beyond language:

  * Cost is not the deciding factor at this volume. A 1080×2400 screenshot is
    ~1,445 image tokens on gpt-4o-mini, ≈$0.004 including output, against
    $0.0015/page for a dedicated OCR API. At a thousand photos a month that is
    $3.80 vs $1.50 — a rounding error either way. (Note that gpt-4o-mini is not
    cheaper *per image* than gpt-4o: OpenAI inflates mini's image token count so
    the dollar price per image matches.)
  * The same call does speaker attribution. A dedicated OCR API returns text and
    boxes; turning bubble geometry into speakers would be our own brittle
    threshold code, and no off-the-shelf library does it.

What this endpoint may NOT do is invent structure. Speakers come back only when
the image really is a conversation, and `build_labeled_text` re-checks that in
Python rather than trusting the model's own flag — see its docstring.

The one thing lost with Textract is a calibrated per-line confidence score, so
the "인식률 87%" badge is gone. A model's self-reported confidence is not the
same measurement and is not worth showing as if it were; the review sheet now
warns unconditionally instead.
"""

from __future__ import annotations

import base64
import json
import logging
import re
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

# The bytes have to survive a Lambda request payload and inflate ~4/3 again as
# base64 on the way to OpenAI — 5MB is well past what a phone photo of a page
# needs after client-side downscaling.
MAX_IMAGE_BYTES = 5 * 1024 * 1024

# JPEG/PNG only. The vision model accepts more, but the magic-number gate below
# is what actually keeps junk out, and it can only vouch for formats it knows.
_ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/jpg", "image/png"}

# Content-Type is client-supplied, so the real gate is the magic number.
_MAGIC_PREFIXES: tuple[tuple[bytes, str], ...] = (
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"\x89PNG\r\n\x1a\n", "image/png"),
)

# Must match the client's mention regex (mention_editor_core.dart,
# `_atLineRe`): first character a letter or hangul, then up to 19 more from a
# restricted set. A name this side accepts but that side won't match would land
# in the composer as literal "@이름:" text with no badge behind it.
_SPEAKER_NAME_RE = re.compile(r"^[A-Za-z가-힣][A-Za-z0-9가-힣 ._-]{0,19}$")

_SYSTEM_PROMPT = """\
너는 이미지에서 글자를 읽어내는 OCR이다. 두 가지 일만 한다.

1. 이미지에 보이는 글자를 그대로 옮긴다.
   - 번역·요약·교정·보충을 하지 않는다. 오타도 보이는 대로 옮긴다.
   - 읽는 순서와 줄 구분을 유지한다.
   - 글자가 없으면 lines를 빈 배열로 둔다.

2. 이 이미지가 '화자가 구분되는 대화'인지 판단한다.
   - 대화인 경우(메신저·채팅 캡처처럼 말풍선과 보낸 사람이 보이는 경우)에만
     is_conversation을 true로 하고, 각 줄의 speaker에 화면에 보이는 이름을 넣는다.
   - 캡처를 찍은 본인의 말풍선(대개 오른쪽 정렬, 이름이 따로 표시되지 않음)은
     speaker를 "나"로 한다.
   - 그 외에는 모두 is_conversation을 false로 하고 speaker를 빈 문자열로 둔다.
     문서·필기·기사·책·강의자료·용어 정리·영수증·표는 대화가 아니다.

절대 하지 말 것: 콜론이 있다는 이유로 화자를 만들어내는 것.
"약정액: LP가 출자하기로 약속한 금액" 에서 "약정액"은 용어이지 사람이 아니다.
화자 이름은 화면에 발신자로 표시된 것만 쓴다. 확신이 없으면 대화가 아니라고 답한다.
"""

_OCR_RESPONSE_FORMAT: dict = {
    "type": "json_schema",
    "json_schema": {
        "name": "ocr_result",
        "strict": True,
        "schema": {
            "type": "object",
            "properties": {
                "is_conversation": {"type": "boolean"},
                "lines": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "speaker": {"type": "string"},
                            "text": {"type": "string"},
                        },
                        "required": ["speaker", "text"],
                        "additionalProperties": False,
                    },
                },
            },
            "required": ["is_conversation", "lines"],
            "additionalProperties": False,
        },
    },
}


def sniff_image_type(data: bytes) -> str | None:
    """Return the real image type from its magic bytes, or None if unsupported."""
    for prefix, content_type in _MAGIC_PREFIXES:
        if data.startswith(prefix):
            return content_type
    return None


@lru_cache
def _llm_client():
    """Module-level client so warm Lambda containers skip the handshake.

    One retry, unlike `/kg/extract`'s zero. That endpoint runs extraction inside
    the request and has to leave room to record a failure inside 120s; this one
    is a single short vision call with nothing to clean up afterwards, so a
    retry against a throttling response still fits comfortably.
    """
    from openai import AsyncOpenAI

    settings = get_settings()
    return AsyncOpenAI(
        api_key=settings.openai_api_key,
        timeout=settings.openai_timeout_sec,
        max_retries=1,
    )


def _sanitize_speaker(raw: object) -> str | None:
    """Normalize a model-supplied speaker name, or None when it is unusable."""
    name = " ".join(str(raw or "").split())
    return name if _SPEAKER_NAME_RE.match(name) else None


def build_labeled_text(payload: dict) -> tuple[str, list[str]]:
    """Turn the model's answer into composer text, plus the speakers found.

    Returns "@이름: 발화" lines only when the result is unambiguously a
    conversation; otherwise plain text, which the composer attributes to 나 and
    the learner can reassign from the speaker chips.

    The model's `is_conversation` flag is necessary but not sufficient. Two more
    conditions are enforced here, at the decoding level, because a prompt can be
    disobeyed and a wrong speaker becomes a person node in the graph:

      * every speaker name has to survive `_sanitize_speaker`, so a stray label
        cannot arrive as an unmatched literal "@…:" in the composer;
      * there have to be at least two distinct speakers, since one speaker is
        just text and gains nothing from labeling.

    Failing either drops the whole result to plain text — the cheap outcome. The
    expensive one is a fake speaker committed to the knowledge graph.
    """
    raw_lines = payload.get("lines")
    if not isinstance(raw_lines, list):
        raw_lines = []

    texts: list[str] = []
    for line in raw_lines:
        if isinstance(line, dict):
            text = str(line.get("text", "")).strip()
            if text:
                texts.append(text)
    plain = "\n".join(texts)

    if not payload.get("is_conversation") or not texts:
        return plain, []

    labeled: list[str] = []
    speakers: list[str] = []
    for line in raw_lines:
        if not isinstance(line, dict):
            continue
        text = str(line.get("text", "")).strip()
        if not text:
            continue
        name = _sanitize_speaker(line.get("speaker"))
        if name is None:
            logger.info("OCR speaker %r rejected — falling back to plain text",
                        line.get("speaker"))
            return plain, []
        labeled.append(f"@{name}: {text}")
        if name not in speakers:
            speakers.append(name)

    if len(speakers) < 2:
        return plain, []
    return "\n".join(labeled), speakers


def _translate_llm_error(exc: Exception) -> HTTPException:
    """Map the OpenAI SDK's failures onto responses the client can act on."""
    from openai import APITimeoutError, AuthenticationError, RateLimitError

    if isinstance(exc, RateLimitError):
        return HTTPException(
            status_code=429,
            detail="OCR 요청이 몰려 잠시 처리할 수 없습니다. 잠시 후 다시 시도해 주세요.",
            headers={"Retry-After": "5"},
        )
    if isinstance(exc, APITimeoutError):
        return HTTPException(
            status_code=504,
            detail="사진을 읽는 데 시간이 너무 오래 걸렸습니다. 다시 시도해 주세요.",
        )
    if isinstance(exc, AuthenticationError):
        # A deployment problem, not the learner's. Do not leak the provider text.
        logger.error("OpenAI rejected the OCR call — check the API key")
        return HTTPException(status_code=502, detail="OCR 서비스를 사용할 수 없습니다.")

    logger.exception("Vision OCR call failed")
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

    data_url = f"data:{sniffed};base64,{base64.b64encode(data).decode()}"
    try:
        response = await _llm_client().chat.completions.create(
            model=get_settings().openai_model,
            response_format=_OCR_RESPONSE_FORMAT,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            # "high" is not optional here: Korean glyphs are
                            # unreadable at "low" (85 tokens buys a thumbnail).
                            "image_url": {"url": data_url, "detail": "high"},
                        }
                    ],
                },
            ],
        )
    except HTTPException:
        raise
    except Exception as exc:
        raise _translate_llm_error(exc) from exc

    try:
        payload = json.loads(response.choices[0].message.content or "{}")
    except (json.JSONDecodeError, IndexError, AttributeError):
        logger.exception("Vision OCR returned unparseable content")
        raise HTTPException(status_code=502, detail="OCR 처리에 실패했습니다.")

    text, speakers = build_labeled_text(payload)
    return {
        "text": text,
        "is_conversation": bool(speakers),
        "speakers": speakers,
        "line_count": len(text.splitlines()) if text else 0,
        "storage_key": storage_key,
    }
