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
from .graph_retrieval import statement_content as _statement_content
from .models import ChatSession, User
from .prompts import native_pack
from .rag import _get_client, embed_texts

logger = logging.getLogger(__name__)


def _normalize_sentence_item(raw, self_label: str = "나") -> dict | None:
    """Accept {text, speaker} objects or legacy plain strings (speaker defaults
    to the native pack's self label — "나" for Korean natives, "Me" for English)."""
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return None
        return {"text": text, "speaker": self_label}
    if isinstance(raw, dict):
        text = (raw.get("text") or "").strip() if isinstance(raw.get("text"), str) else ""
        if not text:
            return None
        speaker = raw.get("speaker")
        if not isinstance(speaker, str) or not speaker.strip():
            speaker = self_label
        else:
            speaker = speaker.strip()
        return {"text": text, "speaker": speaker}
    return None


async def _extract_sentences(
    system: str, user_content: str, self_label: str = "나"
) -> list[dict]:
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
        item = _normalize_sentence_item(s, self_label)
        if item:
            out.append(item)
    return out


async def _flag_duplicates(
    session: AsyncSession,
    user_id: uuid.UUID,
    sentences: list[dict],
    referenced_ids: set[str],
    self_label: str = "나",
) -> list[dict]:
    """Annotate each sentence with duplicate/referenced status via embedding search."""
    settings = get_settings()
    result: list[dict] = [
        {
            "text": s["text"],
            "speaker": s.get("speaker") or self_label,
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

    pack = native_pack(getattr(user, "native_language", None))

    sentences: list[dict] = []
    if user_lines:
        user_content = pack.distill_user_lines_header + "\n".join(f"- {l}" for l in user_lines)
        sentences = await _extract_sentences(
            pack.distill_extract_system, user_content, pack.self_label
        )

    flagged = await _flag_duplicates(session, user.id, sentences, referenced_ids, pack.self_label)
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
    pack = native_pack(getattr(user, "native_language", None))
    state = chat_session.distill_state or {}
    current = [
        {"text": s.get("text", ""), "speaker": s.get("speaker") or pack.self_label}
        for s in state.get("sentences", [])
        if s.get("text")
    ]
    referenced_ids: set[str] = set()
    messages = await crud.list_chat_messages(session, chat_session.id, limit=500)
    for m in messages:
        if m.role == "assistant":
            referenced_ids.update(str(x) for x in (m.referenced_node_ids or []))

    user_content = (
        pack.distill_current_draft_header
        + "\n".join(f"- [{s['speaker']}] {s['text']}" for s in current)
        + f"\n\n{pack.distill_instruction_label}{instruction}"
    )
    sentences = await _extract_sentences(pack.distill_refine_system, user_content, pack.self_label)
    if not sentences:
        # LLM returned nothing usable — keep the current draft rather than wiping it.
        sentences = current

    flagged = await _flag_duplicates(session, user.id, sentences, referenced_ids, pack.self_label)
    draft = {"draft_id": str(uuid.uuid4()), "sentences": flagged}
    await crud.set_chat_session_distill_state(session, chat_session, draft)
    return draft
