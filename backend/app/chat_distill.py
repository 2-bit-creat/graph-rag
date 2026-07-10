"""Chat → journal distillation.

Turns a graph-chat conversation into a diary draft that captures ONLY the new
information the user themselves volunteered. Two guards keep it from re-committing
things the graph already knows:

  1. Extraction is scoped to the user's own utterances — the assistant's RAG-echoed
     answers are never fed to the extractor.
  2. Each candidate sentence is embedded and compared against existing Statement
     nodes; a close match is flagged ``duplicate`` (and, when it matches a node the
     assistant cited this session, ``referenced``) and excluded by default.

Speaker tags are for true first-person utterances by someone else (e.g. a pasted
dialogue line they actually said as "I…"). The user's narration or indirect report
of what another person said stays speaker ``나`` — never rewrite it into that
person's first-person voice.

The refined draft is then handed to the normal journal pipeline unchanged, so every
existing checkpoint (speaker confirmation, concept review, commit) still applies.
"""

from __future__ import annotations

import json
import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .graph_chat import _statement_content
from .language_config import normalize_native
from .models import ChatSession, User
from .rag import _get_client, embed_texts

logger = logging.getLogger(__name__)

def _extract_system_prompt(*, native_language: str = "korean") -> str:
    native = normalize_native(native_language)
    me = "me" if native == "english" else "나"
    if native == "english":
        return (
            "You help turn a user's AI chat into diary sentences. "
            "Input is ONLY the user's own utterances in chronological order. "
            "Extract new facts, experiences, emotions, and plans as first-person English diary sentences. "
            "Rules:\n"
            "- Never include AI replies, general knowledge, or encyclopedic info — only what the user said.\n"
            "- Drop greetings, questions, and chit-chat with no factual content.\n"
            "- Each sentence is independent and concise — one fact per sentence.\n"
            "- Do not invent or guess missing content.\n"
            f'- Default speaker is "{me}". When the user describes or reports what someone else said '
            f'(e.g. "Mom said 10 o\'clock"), keep speaker "{me}" and write from the user\'s perspective '
            f'(e.g. "Mom told me to come by 10"). Never rewrite into the other person\'s first person.\n'
            f'- Use another speaker only when that person\'s own first-person words are recorded verbatim.\n'
            f'Return JSON only: {{"sentences": [{{"text": "sentence", "speaker": "{me}"}}, ...]}}'
        )
    return (
        "당신은 사용자가 AI와 나눈 대화를 일기로 정리해 주는 도우미입니다. "
        "입력으로는 '사용자 본인이 한 발화'만 시간순으로 주어집니다. "
        "사용자가 새롭게 밝힌 사실·경험·감정·계획을 1인칭 한국어 일기 문장으로 정리하세요. "
        "규칙:\n"
        "- AI의 답변이나 일반 상식·백과사전적 정보는 절대 넣지 마세요. 오직 사용자가 말한 것만.\n"
        "- 질문·인사·잡담처럼 기록할 사실이 없는 발화는 버리세요.\n"
        "- 각 문장은 독립적이고 간결하게, 한 문장에 하나의 사실만.\n"
        "- 추측하거나 없는 내용을 지어내지 마세요.\n"
        "- 기본 speaker는 \"나\"입니다. 사용자가 타인의 말·행동을 묘사·전달·간접인용한 경우"
        "(예: \"엄마가 10시래\", \"친구가 바쁘대\")도 speaker는 \"나\"이고, "
        "text는 사용자 시점의 일기 문장으로 남기세요"
        '(예: "엄마가 10시까지 오라고 했다"). '
        "그 내용을 타인 일인칭으로 바꾸거나 speaker를 그 사람으로 바꾸지 마세요.\n"
        "- speaker를 타인으로 두는 것은, 그 사람이 실제로 일인칭으로 말한 발화가 "
        "그대로 기록된 경우뿐입니다(직접 화법·대화 스크립트처럼 그 사람의 '나/저' 발화). "
        "간접 화법·요약·전달은 절대 해당하지 않습니다.\n"
        '반드시 {"sentences": [{"text": "문장", "speaker": "나"}, ...]} 형식의 JSON으로만 답하세요.'
    )


def _refine_system_prompt(*, native_language: str = "korean") -> str:
    native = normalize_native(native_language)
    if native == "english":
        return (
            "You refine a user's diary draft. Input is a '- [speaker] sentence' list and edit instructions. "
            "Delete, edit, merge, or add sentences per the instruction — never invent facts the user did not say. "
            "Keep speaker tags; follow speaker changes only when instructed. "
            "Do not rewrite reported speech into another person's first person. "
            'Return JSON only: {"sentences": [{"text": "sentence", "speaker": "me"}, ...]}'
        )
    return (
        "당신은 사용자의 일기 초안을 다듬어 주는 도우미입니다. "
        "현재 초안은 '- [화자] 문장' 목록과 사용자의 수정 지시가 주어집니다. "
        "지시에 따라 문장을 삭제·수정·병합·추가하세요. 사용자가 말하지 않은 새 사실을 "
        "지어내지 마세요. "
        "화자 태그는 유지하되, 지시가 화자를 바꾸면 따르세요. "
        "타인의 말을 묘사·전달한 문장을 그 사람 일인칭으로 바꾸거나 speaker를 "
        "그 사람으로 바꾸지 마세요 — speaker가 타인인 것은 그 사람의 실제 일인칭 "
        "발화일 때만 허용됩니다. "
        '반드시 {"sentences": [{"text": "문장", "speaker": "나"}, ...]} 형식의 JSON으로만 답하세요.'
    )


_EXTRACT_SYSTEM = _extract_system_prompt(native_language="korean")
_REFINE_SYSTEM = _refine_system_prompt(native_language="korean")


def _normalize_sentence_item(raw) -> dict | None:
    """Accept {text, speaker} objects or legacy plain strings (speaker defaults to 나)."""
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return None
        return {"text": text, "speaker": "나"}
    if isinstance(raw, dict):
        text = (raw.get("text") or "").strip() if isinstance(raw.get("text"), str) else ""
        if not text:
            return None
        speaker = raw.get("speaker")
        if not isinstance(speaker, str) or not speaker.strip():
            speaker = "나"
        else:
            speaker = speaker.strip()
        return {"text": text, "speaker": speaker}
    return None


async def _extract_sentences(system: str, user_content: str) -> list[dict]:
    settings = get_settings()
    resp = await _get_client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        temperature=0.2,
        response_format={"type": "json_object"},
        timeout=settings.openai_timeout_sec,
    )
    raw = (resp.choices[0].message.content or "").strip()
    try:
        data = json.loads(raw)
    except ValueError:
        logger.warning("chat_distill: non-JSON extraction response: %r", raw[:200])
        return []
    out: list[dict] = []
    for s in data.get("sentences", []) or []:
        item = _normalize_sentence_item(s)
        if item:
            out.append(item)
    return out


async def _flag_duplicates(
    session: AsyncSession,
    user_id: uuid.UUID,
    sentences: list[dict],
    referenced_ids: set[str],
) -> list[dict]:
    """Annotate each sentence with duplicate/referenced status via embedding search."""
    settings = get_settings()
    result: list[dict] = [
        {
            "text": s["text"],
            "speaker": s.get("speaker") or "나",
            "included": True,
            "duplicate": False,
            "matched_statement": None,
            "matched_node_id": None,
            "referenced": False,
        }
        for s in sentences
    ]
    if not sentences:
        return result

    texts = [s["text"] for s in result]
    try:
        vectors = await embed_texts(texts)
    except Exception as exc:  # noqa: BLE001 — dedup is best-effort; keep the draft
        logger.warning("chat_distill: embedding failed, skipping dedup: %s", exc)
        return result

    for item, vec in zip(result, vectors):
        try:
            matches = await crud.find_similar_nodes_with_distance(
                session,
                user_id,
                vec,
                limit=5,
                max_distance=settings.chat_distill_dup_max_distance,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("chat_distill: similarity search failed: %s", exc)
            continue
        # Only Statement nodes count as "this fact already exists".
        stmt_match = next((n for n, _d in matches if n.type == "Statement"), None)
        if stmt_match is None:
            continue
        item["duplicate"] = True
        item["included"] = False  # duplicates start unchecked
        item["matched_statement"] = _statement_content(stmt_match)
        item["matched_node_id"] = str(stmt_match.id)
        item["referenced"] = str(stmt_match.id) in referenced_ids

    return result


async def build_distill_draft(
    session: AsyncSession, user: User, chat_session: ChatSession
) -> dict:
    """Extract a diary draft from the user's utterances and flag duplicates.

    Returns the draft dict (also persisted to ``chat_session.distill_state``):
    ``{"draft_id", "sentences": [{text, speaker, included, duplicate, ...}]}``.
    """
    messages = await crud.list_chat_messages(session, chat_session.id, limit=500)
    user_lines = [m.content.strip() for m in messages if m.role == "user" and m.kind == "text" and m.content.strip()]
    referenced_ids: set[str] = set()
    for m in messages:
        if m.role == "assistant":
            referenced_ids.update(str(x) for x in (m.referenced_node_ids or []))

    native = normalize_native(getattr(user, "native_language", None))

    sentences: list[dict] = []
    if user_lines:
        user_label = "User utterances:" if native == "english" else "사용자 발화:"
        sentences = await _extract_sentences(
            _extract_system_prompt(native_language=native),
            user_label + "\n" + "\n".join(f"- {l}" for l in user_lines),
        )

    flagged = await _flag_duplicates(session, user.id, sentences, referenced_ids)
    draft = {"draft_id": str(uuid.uuid4()), "sentences": flagged}
    await crud.set_chat_session_distill_state(session, chat_session, draft)
    return draft


async def refine_distill_draft(
    session: AsyncSession,
    user: User,
    chat_session: ChatSession,
    instruction: str,
) -> dict:
    """Rewrite the current draft per a natural-language instruction, then re-flag."""
    state = chat_session.distill_state or {}
    current = [
        {"text": s.get("text", ""), "speaker": s.get("speaker") or "나"}
        for s in state.get("sentences", [])
        if s.get("text")
    ]
    referenced_ids: set[str] = set()
    messages = await crud.list_chat_messages(session, chat_session.id, limit=500)
    for m in messages:
        if m.role == "assistant":
            referenced_ids.update(str(x) for x in (m.referenced_node_ids or []))

    native = normalize_native(getattr(user, "native_language", None))

    user_content = (
        ("Current draft:\n" if native == "english" else "현재 초안:\n")
        + "\n".join(f"- [{s['speaker']}] {s['text']}" for s in current)
        + (f"\n\nEdit instruction: {instruction}" if native == "english" else f"\n\n수정 지시: {instruction}")
    )
    sentences = await _extract_sentences(_refine_system_prompt(native_language=native), user_content)
    if not sentences:
        # LLM returned nothing usable — keep the current draft rather than wiping it.
        sentences = current

    flagged = await _flag_duplicates(session, user.id, sentences, referenced_ids)
    draft = {"draft_id": str(uuid.uuid4()), "sentences": flagged}
    await crud.set_chat_session_distill_state(session, chat_session, draft)
    return draft
