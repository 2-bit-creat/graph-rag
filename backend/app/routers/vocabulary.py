"""User custom vocabulary CRUD API."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import get_session
from ..dev_user import dev_user_dep
from ..models import User
from ..schemas import (
    VocabWordOut,
    VocabularyAddWordRequest,
    VocabularyCreateRequest,
    VocabularyDetailOut,
    VocabularyListOut,
    VocabularySummaryOut,
    VocabularyUpdateRequest,
    VocabularyUpdateWordRequest,
)
from ..user_vocab_store import (
    STATEMENT_VOCAB_ID,
    VocabularyConflictError,
    VocabularyForbiddenError,
    VocabularyNotFoundError,
    add_word,
    create_vocabulary,
    delete_vocabulary,
    delete_word,
    get_vocabulary,
    list_vocabularies,
    update_vocabulary,
    update_word,
)

router = APIRouter(prefix="/vocabularies", tags=["vocabularies"])


@router.get("/statement-bank", tags=["vocabularies"])
async def get_statement_bank(
    language: str = "english",
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Return all system-extracted expressions for a given target language."""
    import uuid as _uuid
    from ..node_expression_store import get_statement_bank_for_language
    from ..crud import get_node_names

    expressions = await get_statement_bank_for_language(user.id, language)

    # Back-fill source_node_name from DB for expressions saved before node_name was stored
    missing_ids: set[_uuid.UUID] = set()
    for e in expressions:
        if not e.get("source_node_name") and e.get("source_node_id"):
            try:
                missing_ids.add(_uuid.UUID(e["source_node_id"]))
            except ValueError:
                pass

    if missing_ids:
        id_to_name = await get_node_names(session, missing_ids)
        for e in expressions:
            if not e.get("source_node_name") and e.get("source_node_id"):
                try:
                    nid = _uuid.UUID(e["source_node_id"])
                    if nid in id_to_name:
                        e["source_node_name"] = id_to_name[nid]
                except ValueError:
                    pass

    return {
        "language": language,
        "expressions": expressions,
        "total": len(expressions),
    }


@router.get("/statement-bank/reprocess-info", tags=["vocabularies"])
async def get_reprocess_info(
    languages: str = Query(description="Comma-separated list of languages to check"),
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Dry-run: return how many Statement nodes would be reprocessed per language.

    Frontend calls this before showing the confirm dialog so the user knows
    what the batch will cost before confirming.
    """
    from ..node_expression_store import get_pending_node_language_pairs
    from ..crud import get_all_statement_nodes

    lang_list = [l.strip().lower() for l in languages.split(",") if l.strip()]
    if not lang_list:
        raise HTTPException(status_code=400, detail="languages is required")

    all_stmts = await get_all_statement_nodes(session, user.id)
    node_ids = [s["node_id"] for s in all_stmts]
    pending = await get_pending_node_language_pairs(user.id, node_ids, lang_list)

    per_lang: dict[str, int] = {l: 0 for l in lang_list}
    for _, lang in pending:
        per_lang[lang] = per_lang.get(lang, 0) + 1

    return {
        "total_statement_nodes": len(all_stmts),
        "pending_pairs": len(pending),
        "per_language": per_lang,
        "languages_requested": lang_list,
        "message": (
            f"{len(pending)}개 (노드×언어) 조합에 대해 추출이 실행됩니다. "
            f"총 Statement 노드 {len(all_stmts)}개."
        ),
    }


@router.post("/statement-bank/reprocess", tags=["vocabularies"])
async def trigger_reprocess(
    languages: list[str],
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Trigger retroactive expression extraction for given languages.

    Call AFTER user confirms the dialog shown from reprocess-info.
    Already-extracted (node, language) pairs are skipped automatically.
    """
    from ..extraction_queue import enqueue_bulk
    from ..crud import get_all_statement_nodes

    lang_list = [l.strip().lower() for l in languages if isinstance(l, str) and l.strip()]
    if not lang_list:
        raise HTTPException(status_code=400, detail="languages list is required")

    all_stmts = await get_all_statement_nodes(session, user.id)
    enqueued = await enqueue_bulk(user.id, all_stmts, lang_list)

    return {
        "enqueued": enqueued,
        "languages": lang_list,
        "message": f"{enqueued}개 추출 작업이 큐에 추가됐습니다. 백그라운드에서 순차 처리됩니다.",
    }


@router.delete("/statement-bank/expressions", tags=["vocabularies"])
async def delete_statement_expression(
    node_id: str,
    language: str,
    expression: str,
    user: User = Depends(dev_user_dep),
) -> dict:
    """Delete a single expression from the statement bank.

    If all expressions for that node+language are removed, the extraction_done
    flag is reset so the worker will re-extract on next trigger.
    """
    from ..node_expression_store import delete_node_expression
    removed = await delete_node_expression(user.id, node_id, language, expression)
    if not removed:
        raise HTTPException(status_code=404, detail="Expression not found")
    return {"removed": expression, "node_id": node_id, "language": language}


@router.delete("/statement-bank/language/{language}", tags=["vocabularies"])
async def delete_all_language_expressions(
    language: str,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Delete ALL extracted expressions for a language, then trigger re-extraction.

    Used when you want to regenerate with updated settings (e.g. new CEFR labels,
    improved prompts). Resets extraction_done flags so the worker re-extracts.
    """
    from ..node_expression_store import delete_all_language_expressions as _delete_all
    from ..extraction_queue import enqueue_bulk
    from ..crud import get_all_statement_nodes

    deleted = await _delete_all(user.id, language)
    all_stmts = await get_all_statement_nodes(session, user.id)
    enqueued = await enqueue_bulk(user.id, all_stmts, [language])
    return {
        "language": language,
        "deleted_count": deleted,
        "enqueued": enqueued,
        "message": f"{deleted}개 표현 삭제됨. {enqueued}개 노드 재추출이 시작됩니다.",
    }


@router.post("/statement-bank/reprocess-node", tags=["vocabularies"])
async def reprocess_single_node(
    node_id: uuid.UUID,
    languages: list[str],
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Force re-extraction for a single Statement node (e.g. after deleting its expressions).

    Resets the extraction_done flag for the given languages so the worker re-runs.
    """
    import json as _json
    from sqlalchemy import select as _select
    from ..models import Node as _Node
    from ..extraction_queue import enqueue
    from ..node_expression_store import _read_store_sync, _write_store_sync
    import asyncio as _asyncio

    lang_list = [l.strip().lower() for l in languages if isinstance(l, str) and l.strip()]
    if not lang_list:
        raise HTTPException(status_code=400, detail="languages list is required")

    result = await session.execute(
        _select(_Node).where(_Node.id == node_id, _Node.user_id == user.id, _Node.type == "Statement")
    )
    node = result.scalar_one_or_none()
    if node is None:
        raise HTTPException(status_code=404, detail="Statement node not found")

    content_ko = ""
    if node.description:
        try:
            data = _json.loads(node.description)
            content_ko = (data.get("content") or "").strip()
        except (ValueError, AttributeError):
            parts = node.description.split("\n", 1)
            content_ko = parts[1].strip() if len(parts) > 1 else parts[0].strip()

    # Reset extraction_done flags so the worker will re-run.
    def _reset() -> None:
        store = _read_store_sync(user.id)
        done = store.get("extraction_done", {})
        node_done = done.get(str(node_id), [])
        done[str(node_id)] = [l for l in node_done if l not in lang_list]
        store["extraction_done"] = done
        _write_store_sync(user.id, store)

    await _asyncio.to_thread(_reset)

    for lang in lang_list:
        await enqueue(
            user.id,
            str(node_id),
            lang,
            node_name=node.name,
            content_ko=content_ko,
        )

    return {
        "node_id": str(node_id),
        "languages_reset": lang_list,
        "message": f"'{node.name}' 노드의 {lang_list} 추출이 재시작됩니다.",
    }


def _summary_out(item: dict) -> VocabularySummaryOut:
    return VocabularySummaryOut(
        id=item["id"],
        name=item["name"],
        description=item.get("description") or "",
        created_at=item.get("created_at"),
        word_count=int(item.get("word_count") or 0),
        is_default=bool(item.get("is_default")),
        is_system=bool(item.get("is_system")),
    )


def _word_out(w: dict, *, is_statement_bank: bool = False) -> VocabWordOut:
    if is_statement_bank:
        return VocabWordOut(
            word=w.get("expression") or "",
            meaning=w.get("meaning_ko") or "",
            added_at=w.get("added_at"),
            review_count=0,
            linked_diary_id=None,
            expression=w.get("expression"),
            meaning_ko=w.get("meaning_ko"),
            example_en=w.get("example_en"),
            source_node_id=w.get("source_node_id"),
            source_node_name=w.get("source_node_name"),
        )
    return VocabWordOut(
        word=w.get("word") or "",
        meaning=w.get("meaning") or "",
        added_at=w.get("added_at"),
        review_count=int(w.get("review_count") or 0),
        linked_diary_id=(
            uuid.UUID(w["linked_diary_id"])
            if w.get("linked_diary_id")
            else None
        ),
        cefr=w.get("cefr") or None,
    )


def _detail_out(item: dict) -> VocabularyDetailOut:
    is_stmt = item.get("id") == STATEMENT_VOCAB_ID
    words = [
        _word_out(w, is_statement_bank=is_stmt)
        for w in (item.get("words") or [])
        if isinstance(w, dict) and (w.get("expression") if is_stmt else w.get("word"))
    ]
    return VocabularyDetailOut(
        **_summary_out(item).model_dump(),
        words=words,
    )


_LANG_DISPLAY = {
    "english": "영어", "german": "독일어", "japanese": "일본어",
    "chinese": "중국어", "spanish": "스페인어", "french": "프랑스어",
    "portuguese": "포르투갈어", "italian": "이탈리아어",
    "arabic": "아랍어", "russian": "러시아어",
}


@router.get("", response_model=VocabularyListOut)
async def list_all_vocabularies(
    user: User = Depends(dev_user_dep),
) -> VocabularyListOut:
    from ..node_expression_store import get_statement_bank_for_language
    from ..crud import get_effective_target_languages

    items = await list_vocabularies(user.id)
    summaries = [_summary_out(i) for i in items]

    # Append one statement-bank entry per target language
    for lang in get_effective_target_languages(user):
        exprs = await get_statement_bank_for_language(user.id, lang)
        label = _LANG_DISPLAY.get(lang, lang.title())
        summaries.append(VocabularySummaryOut(
            id=f"statement_bank:{lang}",
            name=f"{label} 학습 표현",
            description="일기 Statement에서 자동 추출된 표현 (그래프 Inspector에서도 확인 가능)",
            created_at=None,
            word_count=len(exprs),
            is_default=False,
            is_system=True,
        ))

    return VocabularyListOut(items=summaries)


@router.get("/{vocab_id}", response_model=VocabularyDetailOut)
async def get_vocabulary_detail(
    vocab_id: str,
    user: User = Depends(dev_user_dep),
) -> VocabularyDetailOut:
    # statement_bank:<language> routes to node_expression_store
    if vocab_id.startswith("statement_bank:"):
        lang = vocab_id[len("statement_bank:"):]
        from ..node_expression_store import get_statement_bank_for_language
        exprs = await get_statement_bank_for_language(user.id, lang)
        label = _LANG_DISPLAY.get(lang, lang.title())
        words = [
            VocabWordOut(
                word=e.get("expression") or "",
                meaning=e.get("meaning") or "",
                added_at=e.get("added_at"),
                review_count=0,
                linked_diary_id=None,
                expression=e.get("expression"),
                meaning_ko=e.get("meaning") or "",
                example_en=e.get("example") or "",
                source_node_id=e.get("source_node_id"),
                source_node_name=e.get("source_node_name"),
                cefr=e.get("cefr") or None,
            )
            for e in exprs
            if e.get("expression")
        ]
        return VocabularyDetailOut(
            id=vocab_id,
            name=f"{label} 학습 표현",
            description="일기 Statement에서 자동 추출된 표현",
            created_at=None,
            word_count=len(words),
            is_default=False,
            is_system=True,
            words=words,
        )

    try:
        item = await get_vocabulary(user.id, vocab_id)
    except VocabularyNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return _detail_out(item)


@router.post("", response_model=VocabularySummaryOut, status_code=status.HTTP_201_CREATED)
async def create_vocab(
    payload: VocabularyCreateRequest,
    user: User = Depends(dev_user_dep),
) -> VocabularySummaryOut:
    try:
        item = await create_vocabulary(
            user.id,
            name=payload.name,
            description=payload.description,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _summary_out(item)


@router.delete("/{vocab_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def remove_vocab(
    vocab_id: str,
    user: User = Depends(dev_user_dep),
) -> Response:
    try:
        await delete_vocabulary(user.id, vocab_id)
    except VocabularyForbiddenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except VocabularyNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/{vocab_id}", response_model=VocabularySummaryOut)
async def patch_vocab(
    vocab_id: str,
    payload: VocabularyUpdateRequest,
    user: User = Depends(dev_user_dep),
) -> VocabularySummaryOut:
    if payload.name is None and payload.description is None:
        raise HTTPException(status_code=400, detail="No fields to update")
    try:
        item = await update_vocabulary(
            user.id,
            vocab_id,
            name=payload.name,
            description=payload.description,
        )
    except VocabularyForbiddenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except VocabularyNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _summary_out(item)


@router.post("/{vocab_id}/words", response_model=VocabWordOut, status_code=status.HTTP_201_CREATED)
async def add_vocab_word(
    vocab_id: str,
    payload: VocabularyAddWordRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> VocabWordOut:
    if payload.linked_diary_id is not None:
        entry = await crud.get_journal_entry(session, payload.linked_diary_id, user.id)
        if entry is None:
            raise HTTPException(status_code=400, detail="Linked diary entry not found")

    try:
        word = await add_word(
            user.id,
            vocab_id,
            word=payload.word,
            meaning=payload.meaning,
            linked_diary_id=payload.linked_diary_id,
        )
    except VocabularyForbiddenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except VocabularyNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except VocabularyConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return VocabWordOut(
        word=word["word"],
        meaning=word.get("meaning") or "",
        added_at=word.get("added_at"),
        review_count=int(word.get("review_count") or 0),
        linked_diary_id=(
            uuid.UUID(word["linked_diary_id"])
            if word.get("linked_diary_id")
            else None
        ),
    )


@router.delete("/{vocab_id}/words/{word}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def remove_vocab_word(
    vocab_id: str,
    word: str,
    user: User = Depends(dev_user_dep),
) -> Response:
    try:
        await delete_word(user.id, vocab_id, word)
    except VocabularyForbiddenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except VocabularyNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/{vocab_id}/words/{word}", response_model=VocabWordOut)
async def patch_vocab_word(
    vocab_id: str,
    word: str,
    payload: VocabularyUpdateWordRequest,
    user: User = Depends(dev_user_dep),
) -> VocabWordOut:
    try:
        updated = await update_word(
            user.id,
            vocab_id,
            word,
            meaning=payload.meaning,
        )
    except VocabularyForbiddenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except VocabularyNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return VocabWordOut(
        word=updated["word"],
        meaning=updated.get("meaning") or "",
        added_at=updated.get("added_at"),
        review_count=int(updated.get("review_count") or 0),
        linked_diary_id=(
            uuid.UUID(updated["linked_diary_id"])
            if updated.get("linked_diary_id")
            else None
        ),
    )
