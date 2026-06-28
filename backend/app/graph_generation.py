"""Quiz generation context from distributed Semantic Chunk graph."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .entity_types import normalize_entity_type
from .graph_schema import NODE_VOCAB
from .models import Node


@dataclass
class ChunkTurn:
    chunk_id: uuid.UUID
    speaker_name: str
    text: str
    display_title: str


@dataclass
class VocabQuizContext:
    vocab_lemma: str
    vocab_node_id: uuid.UUID
    anchor_chunk_id: uuid.UUID
    speaker_name: str
    anchor_text: str
    display_title: str
    context_before: list[ChunkTurn] = field(default_factory=list)
    context_after: list[ChunkTurn] = field(default_factory=list)
    formatted_dialogue: str = ""


async def _chunk_to_turn(session: AsyncSession, node) -> ChunkTurn:
    speaker = await crud.resolve_speaker_for_chunk(session, node.id)
    return ChunkTurn(
        chunk_id=node.id,
        speaker_name=speaker.name if speaker else "Unknown",
        text=node.description or "",
        display_title=node.name,
    )


def _format_dialogue(turns: list[ChunkTurn]) -> str:
    return "\n".join(f"[{t.speaker_name}]: {t.text}" for t in turns if t.text)


async def resolve_vocab_quiz_context(
    session: AsyncSession,
    user_id: uuid.UUID,
    vocab_node_id: uuid.UUID,
    *,
    lang: str = "EN",
    window: int = 2,
) -> VocabQuizContext:
    vocab = await session.get(Node, vocab_node_id)
    if vocab is None or vocab.user_id != user_id:
        raise ValueError("Vocab node not found")
    if normalize_entity_type(vocab.type) != NODE_VOCAB:
        raise ValueError("Node is not a Vocab type")

    anchors = await crud.find_anchor_chunks_for_vocab(
        session, user_id, vocab_node_id, lang=lang
    )
    if not anchors:
        raise ValueError("No Chunk linked to this Vocab via CONTAINS relation")

    anchor = anchors[0]
    before, _, after = await crud.traverse_chunk_chain(
        session, anchor.id, before=window, after=window
    )

    anchor_turn = await _chunk_to_turn(session, anchor)
    before_turns = [await _chunk_to_turn(session, n) for n in before]
    after_turns = [await _chunk_to_turn(session, n) for n in after]
    all_turns = before_turns + [anchor_turn] + after_turns

    return VocabQuizContext(
        vocab_lemma=vocab.name,
        vocab_node_id=vocab.id,
        anchor_chunk_id=anchor.id,
        speaker_name=anchor_turn.speaker_name,
        anchor_text=anchor_turn.text,
        display_title=anchor_turn.display_title,
        context_before=before_turns,
        context_after=after_turns,
        formatted_dialogue=_format_dialogue(all_turns),
    )
