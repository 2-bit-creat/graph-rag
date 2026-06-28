"""Voice-embedding speaker recommendation and human-in-the-loop confirmation."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field

from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .entity_types import is_person_like_type
from .models import JournalEntry, Node, SpeakerProfile

# Written to speaker_entry_appearances.match_score after the user confirms in UI.
HUMAN_CONFIRMED_MATCH_SCORE = 1.0


def _is_human_confirmed_match_score(match_score: float) -> bool:
    return match_score >= HUMAN_CONFIRMED_MATCH_SCORE - 1e-6


def _linked_speaker_display_name(node: Node, profile: SpeakerProfile) -> str:
    """Prefer graph node name — profile.display_name can be stale after re-link."""
    return (node.name or profile.display_name or profile.label or "").strip()


def _has_valid_voice_node_link(
    profile: SpeakerProfile,
    node: Node | None,
    *,
    user_id: uuid.UUID,
) -> bool:
    if node is None or node.user_id != user_id:
        return False
    return crud.is_bidirectional_voice_link(profile, node)


@dataclass
class RecommendedNode:
    id: uuid.UUID | None
    name: str


@dataclass
class SpeakerCandidate:
    id: uuid.UUID
    name: str
    match_score: float


@dataclass
class SpeakerRecommendResult:
    recommended_node: RecommendedNode | None
    match_score: float | None = None
    speaker_profile_id: uuid.UUID | None = None
    session_speaker_label: str | None = None
    already_confirmed: bool = False
    confirmed_node: RecommendedNode | None = None
    above_threshold: bool = False
    likely_unregistered: bool = False
    session_conflict_hint: str | None = None
    candidates: list[SpeakerCandidate] = field(default_factory=list)
    person_nodes: list[RecommendedNode] = field(default_factory=list)


@dataclass
class SpeakerSummary:
    session_label: str
    speaker_profile_id: uuid.UUID
    needs_confirmation: bool
    confirmed_node: RecommendedNode | None = None
    suggested_node: RecommendedNode | None = None
    auto_assigned: bool = False


@dataclass
class SpeakerConfirmResult:
    speaker_profile_id: uuid.UUID
    confirmed_node: RecommendedNode
    transcript_replacements: int = 0
    edges_reassigned: int = 0


def _voice_max_distance(threshold: float | None = None) -> float:
    """Cosine distance cap from similarity threshold (default from settings)."""
    sim = threshold if threshold is not None else get_settings().speaker_match_threshold
    return max(0.0, 1.0 - sim)


async def get_entry_speaker_embedding(
    session: AsyncSession,
    entry_id: uuid.UUID,
    speaker_label: str,
) -> tuple[SpeakerProfile | None, uuid.UUID | None]:
    """Resolve Fast Path speaker profile + embedding for a session label."""
    appearance = await crud.get_speaker_appearance_for_label(
        session, entry_id, speaker_label
    )
    if appearance is None:
        return None, None

    profile = await session.get(SpeakerProfile, appearance.speaker_profile_id)
    if profile is None or profile.embedding is None:
        return profile, appearance.speaker_profile_id
    return profile, profile.id


async def build_speaker_summaries_for_entry(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
) -> list[SpeakerSummary]:
    """Per-session speaker status for STT UI.

    Voice suggestions are assigned 1:1 across the entry's speakers: when several
    distinct speakers match the same Person, the most similar voice wins it and
    the others fall back to their next-best candidate (or no suggestion). Two
    diarized speakers are never both suggested the same Person.
    """
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    summaries: list[SpeakerSummary] = []
    seen: set[str] = set()
    claimed_node_ids: set[uuid.UUID] = set()
    # Unconfirmed speakers whose suggestion is resolved in the 1:1 pass below.
    pending: list[tuple[SpeakerSummary, SpeakerProfile]] = []

    for app in appearances:
        label = app.session_label
        if label in seen:
            continue
        seen.add(label)

        # '나' is auto-assigned in single-speaker diary mode — treat as confirmed
        # without a node link UNLESS the user explicitly reassigned this segment
        # to a real person (human-confirmed appearance + a node or non-'나' name).
        if label == "나":
            na_profile = await session.get(SpeakerProfile, app.speaker_profile_id)
            reassigned = (
                na_profile is not None
                and na_profile.user_id == user_id
                and _is_human_confirmed_match_score(float(app.match_score or 0.0))
                and (
                    na_profile.node_id is not None
                    or (na_profile.display_name or "").strip() not in ("", "나")
                )
            )
            if not reassigned:
                summaries.append(
                    SpeakerSummary(
                        session_label=label,
                        speaker_profile_id=app.speaker_profile_id,
                        needs_confirmation=False,
                        confirmed_node=RecommendedNode(id=None, name="나"),
                        suggested_node=None,
                        auto_assigned=True,
                    )
                )
                continue
            # Reassigned '나' → fall through to normal confirmed/suggested handling.

        profile = await session.get(SpeakerProfile, app.speaker_profile_id)
        if profile is None or profile.user_id != user_id:
            continue

        match_score = float(app.match_score or 0.0)
        human_confirmed = _is_human_confirmed_match_score(match_score)

        confirmed: RecommendedNode | None = None

        if human_confirmed:
            if profile.node_id is not None:
                node = await session.get(Node, profile.node_id)
                if _has_valid_voice_node_link(profile, node, user_id=user_id):
                    confirmed = RecommendedNode(
                        id=node.id,
                        name=_linked_speaker_display_name(node, profile),
                    )
                    claimed_node_ids.add(node.id)
                else:
                    # Node was deleted or link broken — clear stale reference inline
                    profile.node_id = None
                    profile.display_name = None
                    await session.flush()
                    human_confirmed = False
            else:
                # node_id is None. delete_node() also clears display_name, so a
                # surviving display_name means the user confirmed a NEW identity
                # whose graph node is created later by GraphRAG — keep it
                # confirmed instead of forcing re-confirmation.
                name = (profile.display_name or "").strip()
                if name and name != "나":
                    confirmed = RecommendedNode(id=None, name=name)
                else:
                    human_confirmed = False

        summary = SpeakerSummary(
            session_label=label,
            speaker_profile_id=profile.id,
            needs_confirmation=not human_confirmed,
            confirmed_node=confirmed,
            suggested_node=None,
            auto_assigned=False,
        )
        summaries.append(summary)
        if not human_confirmed:
            pending.append((summary, profile))

    # Resolve voice suggestions with a global 1:1 constraint: a Person already
    # confirmed for another speaker (claimed_node_ids) is excluded, and a Person
    # contested by two speakers goes to the more similar voice.
    await _assign_suggestions_one_to_one(session, user_id, pending, claimed_node_ids)

    try:
        await session.commit()
    except Exception:
        await session.rollback()
    return summaries


async def _assign_suggestions_one_to_one(
    session: AsyncSession,
    user_id: uuid.UUID,
    pending: list[tuple[SpeakerSummary, SpeakerProfile]],
    claimed_node_ids: set[uuid.UUID],
) -> None:
    """Greedy 1:1 voice→Person suggestion. Highest similarity wins a contested node;
    losing speakers fall back to their next-best available candidate, or none.

    Mutates each pending summary's ``suggested_node`` in place.
    """
    if not pending:
        return

    # Flatten every candidate match into (score, speaker index, summary, node).
    scored: list[tuple[float, int, SpeakerSummary, RecommendedNode]] = []
    for idx, (summary, profile) in enumerate(pending):
        candidates = await _suggested_node_candidates(
            session, user_id, profile, exclude_node_ids=claimed_node_ids
        )
        for node, score in candidates:
            scored.append((score, idx, summary, node))

    # Assign best matches first so the more similar voice claims a contested Person.
    scored.sort(key=lambda t: t[0], reverse=True)

    used_nodes: set[uuid.UUID] = set(claimed_node_ids)
    assigned_idx: set[int] = set()
    for _score, idx, summary, node in scored:
        if idx in assigned_idx or node.id in used_nodes:
            continue
        summary.suggested_node = node
        assigned_idx.add(idx)
        used_nodes.add(node.id)


async def _suggested_node_candidates(
    session: AsyncSession,
    user_id: uuid.UUID,
    profile: SpeakerProfile,
    *,
    exclude_node_ids: set[uuid.UUID],
) -> list[tuple[RecommendedNode, float]]:
    """Ranked voice-inferred Person candidates (desc by similarity, threshold-filtered).

    Returns [] when there is no embedding to match on — we never guess a Person
    without voice evidence. Caller resolves contested Persons 1:1 by score.
    """
    settings = get_settings()

    if profile.node_id is not None:
        if profile.node_id in exclude_node_ids:
            return []
        node = await session.get(Node, profile.node_id)
        if _has_valid_voice_node_link(profile, node, user_id=user_id):
            return [
                (
                    RecommendedNode(
                        id=node.id,
                        name=_linked_speaker_display_name(node, profile),
                    ),
                    1.0,
                )
            ]
        return []

    if profile.embedding is None:
        return []

    matches = await crud.find_similar_speaker_profiles_by_embedding(
        session,
        user_id,
        list(profile.embedding),
        max_distance=_voice_max_distance(),
        require_linked_node=True,
        exclude_profile_id=profile.id,
        limit=10,
    )

    # Keep the best score per Person node (several voice profiles may link to one).
    best_by_node: dict[uuid.UUID, tuple[RecommendedNode, float]] = {}
    for matched_profile, distance in matches:
        if matched_profile.node_id is None or matched_profile.node_id in exclude_node_ids:
            continue
        node = await session.get(Node, matched_profile.node_id)
        if node is None or node.user_id != user_id:
            continue
        if not crud.is_bidirectional_voice_link(matched_profile, node):
            continue
        score = 1.0 - distance
        if score < settings.speaker_match_threshold:
            continue
        existing = best_by_node.get(node.id)
        if existing is None or score > existing[1]:
            best_by_node[node.id] = (
                RecommendedNode(
                    id=node.id,
                    name=_linked_speaker_display_name(node, matched_profile),
                ),
                score,
            )

    return sorted(best_by_node.values(), key=lambda t: t[1], reverse=True)


async def entry_has_speakers(session: AsyncSession, entry_id: uuid.UUID) -> bool:
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    return bool(appearances)


async def unconfirmed_speaker_labels(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
) -> list[str]:
    """Session labels still waiting for human speaker→Person confirmation."""
    summaries = await build_speaker_summaries_for_entry(session, user_id, entry_id)
    return [s.session_label for s in summaries if s.needs_confirmation]


async def assert_speakers_confirmed_for_graph(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
) -> None:
    pending = await unconfirmed_speaker_labels(session, user_id, entry_id)
    if pending:
        labels = ", ".join(pending)
        raise ValueError(
            f"Speaker confirmation required before GraphRAG: {labels}"
        )


async def _claimed_nodes_in_entry(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
    exclude_label: str | None = None,
) -> dict[uuid.UUID, tuple[str, str]]:
    """node_id -> (display name, session label) for speakers already linked in this entry."""
    summaries = await build_speaker_summaries_for_entry(session, user_id, entry_id)
    claimed: dict[uuid.UUID, tuple[str, str]] = {}
    for summary in summaries:
        if exclude_label and summary.session_label == exclude_label:
            continue
        if summary.confirmed_node is None or summary.confirmed_node.id is None:
            continue
        claimed[summary.confirmed_node.id] = (
            summary.confirmed_node.name,
            summary.session_label,
        )
    return claimed


async def recommend_speaker_node(
    session: AsyncSession,
    user_id: uuid.UUID,
    journal_entry_id: uuid.UUID,
    speaker_label: str,
    max_distance: float | None = None,
) -> SpeakerRecommendResult:
    """Match entry voice embedding to linked speaker profiles (Person nodes)."""
    settings = get_settings()
    dist_cap = max_distance if max_distance is not None else _voice_max_distance()

    entry = await crud.get_journal_entry(session, journal_entry_id, user_id)
    if entry is None:
        raise ValueError("entry not found")

    profile, profile_id = await get_entry_speaker_embedding(
        session, journal_entry_id, speaker_label
    )
    if profile is None:
        return SpeakerRecommendResult(
            recommended_node=None,
            speaker_profile_id=profile_id,
            session_speaker_label=speaker_label,
        )

    claimed_nodes = await _claimed_nodes_in_entry(
        session, user_id, journal_entry_id, exclude_label=speaker_label
    )
    exclude_ids = set(claimed_nodes.keys())

    if profile.node_id is not None:
        node = await session.get(Node, profile.node_id)
        if _has_valid_voice_node_link(profile, node, user_id=user_id):
            display = _linked_speaker_display_name(node, profile)
            appearance = await crud.get_speaker_appearance_for_label(
                session, journal_entry_id, speaker_label
            )
            match_score = (
                round(float(appearance.match_score), 4) if appearance else None
            )
            person = RecommendedNode(id=node.id, name=display)
            human_confirmed = (
                appearance is not None
                and _is_human_confirmed_match_score(float(appearance.match_score or 0.0))
            )
            if human_confirmed:
                return SpeakerRecommendResult(
                    recommended_node=None,
                    match_score=match_score,
                    speaker_profile_id=profile_id,
                    session_speaker_label=speaker_label,
                    already_confirmed=True,
                    confirmed_node=person,
                    above_threshold=True,
                    person_nodes=await _list_person_nodes(
                        session, user_id, exclude_node_ids=exclude_ids
                    ),
                )
            return SpeakerRecommendResult(
                recommended_node=person,
                match_score=match_score,
                speaker_profile_id=profile_id,
                session_speaker_label=speaker_label,
                already_confirmed=False,
                confirmed_node=None,
                above_threshold=True,
                person_nodes=await _list_person_nodes(
                    session, user_id, exclude_node_ids=exclude_ids
                ),
            )

    if profile.embedding is None:
        person_nodes = await _list_person_nodes(
            session, user_id, exclude_node_ids=exclude_ids
        )
        return SpeakerRecommendResult(
            recommended_node=None,
            speaker_profile_id=profile_id,
            session_speaker_label=speaker_label,
            person_nodes=person_nodes,
        )

    embedding = list(profile.embedding)
    matches = await crud.find_similar_speaker_profiles_by_embedding(
        session,
        user_id,
        embedding,
        max_distance=dist_cap,
        require_linked_node=True,
        exclude_profile_id=profile.id,
        limit=10,
    )

    candidates: list[SpeakerCandidate] = []
    recommended: RecommendedNode | None = None
    best_score: float | None = None
    excluded_best_name: str | None = None
    excluded_best_score: float | None = None
    excluded_best_label: str | None = None

    for matched_profile, distance in matches:
        if matched_profile.node_id is None:
            continue
        node = await session.get(Node, matched_profile.node_id)
        if node is None or node.user_id != user_id:
            continue
        if not crud.is_bidirectional_voice_link(matched_profile, node):
            continue
        score = round(1.0 - distance, 4)
        display = _linked_speaker_display_name(node, matched_profile)

        if node.id in claimed_nodes:
            if excluded_best_score is None or score > excluded_best_score:
                excluded_best_name = display
                excluded_best_score = score
                excluded_best_label = claimed_nodes[node.id][1]
            continue

        candidate = SpeakerCandidate(id=node.id, name=display, match_score=score)
        candidates.append(candidate)
        if recommended is None:
            recommended = RecommendedNode(id=node.id, name=display)
            best_score = score

    above = (
        recommended is not None
        and best_score is not None
        and best_score >= settings.speaker_match_threshold
    )

    likely_unregistered = False
    session_conflict_hint: str | None = None
    if (
        excluded_best_name
        and excluded_best_score is not None
        and excluded_best_score >= settings.speaker_match_threshold
        and not above
    ):
        likely_unregistered = True
        session_conflict_hint = (
            f"이 대화에서 {excluded_best_name}은(는) "
            f"{excluded_best_label}(으)로 이미 확인되었습니다. "
            f"「{speaker_label}」은 아직 등록되지 않은 사람일 가능성이 높습니다."
        )
        session_conflict_hint += (
            f" (제외된 음성 유사도 {excluded_best_score:.2f})"
        )

    person_nodes = await _list_person_nodes(
        session, user_id, exclude_node_ids=exclude_ids
    )

    display_score = best_score if above else excluded_best_score

    return SpeakerRecommendResult(
        recommended_node=recommended if above else None,
        match_score=display_score,
        speaker_profile_id=profile_id,
        session_speaker_label=speaker_label,
        already_confirmed=False,
        confirmed_node=None,
        above_threshold=above,
        likely_unregistered=likely_unregistered,
        session_conflict_hint=session_conflict_hint,
        candidates=candidates,
        person_nodes=person_nodes,
    )


async def _list_person_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    exclude_node_ids: set[uuid.UUID] | None = None,
) -> list[RecommendedNode]:
    nodes = await crud.list_person_nodes_for_speaker_picker(
        session,
        user_id,
        exclude_node_ids=exclude_node_ids,
    )
    return [RecommendedNode(id=n.id, name=n.name) for n in nodes]


async def _resolve_profile_for_session(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
    speaker_profile_id: uuid.UUID,
    session_label: str | None,
) -> tuple[SpeakerProfile, str | None]:
    """Prefer appearance-linked profile for a session label (segment ids can be stale)."""
    label = (session_label or "").strip() or None
    if label:
        appearance = await crud.get_speaker_appearance_for_label(
            session, entry_id, label
        )
        if appearance is not None:
            profile = await session.get(SpeakerProfile, appearance.speaker_profile_id)
            if profile is not None and profile.user_id == user_id:
                return profile, label

    profile = await session.get(SpeakerProfile, speaker_profile_id)
    if profile is None or profile.user_id != user_id:
        raise ValueError("speaker profile not found")
    if label is None:
        label = await _session_label_for_profile(session, entry_id, profile.id)
    return profile, label


def _sync_segment_profile_ids(
    entry: JournalEntry,
    session_label: str | None,
    profile_id: uuid.UUID,
) -> int:
    if not session_label:
        return 0
    segments = entry.transcript_segments
    if not isinstance(segments, list):
        return 0
    updated = 0
    new_segments: list = []
    pid_str = str(profile_id)
    for seg in segments:
        if not isinstance(seg, dict):
            new_segments.append(seg)
            continue
        copy = dict(seg)
        if str(copy.get("speaker", "")).strip() == session_label:
            if str(copy.get("speaker_profile_id") or "") != pid_str:
                copy["speaker_profile_id"] = pid_str
                updated += 1
        new_segments.append(copy)
    if updated:
        entry.transcript_segments = new_segments
    return updated


async def confirm_speaker_identity(
    session: AsyncSession,
    user_id: uuid.UUID,
    journal_entry_id: uuid.UUID,
    speaker_profile_id: uuid.UUID,
    node_id: uuid.UUID | None = None,
    new_node_name: str | None = None,
    wrong_name: str | None = None,
    session_label: str | None = None,
) -> SpeakerConfirmResult:
    """Link speaker profile to graph node and correct misrecognized text for this entry."""
    if node_id is None and not (new_node_name and new_node_name.strip()):
        raise ValueError("node_id or new_node_name is required")

    entry = await crud.get_journal_entry(session, journal_entry_id, user_id)
    if entry is None:
        raise ValueError("entry not found")

    profile, session_label = await _resolve_profile_for_session(
        session,
        user_id,
        journal_entry_id,
        speaker_profile_id,
        session_label,
    )
    speaker_profile_id = profile.id

    linked_node: Node | None = None
    if node_id is not None:
        linked_node = await session.get(Node, node_id)
        if linked_node is None or linked_node.user_id != user_id:
            raise ValueError("node not found")
        if not is_person_like_type(linked_node.type):
            raise ValueError("voice link requires a Speaker node")
        canonical_name = (
            new_node_name or linked_node.name or profile.display_name or ""
        ).strip()
    else:
        canonical_name = new_node_name.strip()

    wrong = (wrong_name or "").strip()
    reject_recommendation = await _is_rejecting_voice_recommendation(
        session, profile, wrong, canonical_name
    )

    if reject_recommendation:
        kept_profile = profile
        profile = await _fork_speaker_profile(
            session,
            user_id,
            kept_profile,
            label=canonical_name,
            last_entry_id=journal_entry_id,
        )
        await _repoint_entry_speaker_profile(
            session,
            entry,
            journal_entry_id,
            kept_profile.id,
            profile.id,
        )
        if kept_profile.node_id is not None:
            old_node = await session.get(Node, kept_profile.node_id)
            if old_node is not None and old_node.user_id == user_id:
                old_node.speaker_profile_id = None
                await session.flush()

    if linked_node is not None:
        profile = await crud.assign_exclusive_voice_profile_to_node(
            session,
            user_id,
            profile,
            linked_node,
            display_name=canonical_name,
        )
    else:
        profile.display_name = canonical_name
        profile.label = canonical_name
        await session.flush()

    session_label = (session_label or "").strip() or await _session_label_for_profile(
        session, journal_entry_id, profile.id
    )

    await _mark_human_confirmed_appearance(
        session, journal_entry_id, profile.id, session_label
    )
    _sync_segment_profile_ids(entry, session_label, profile.id)

    replacements = 0
    if session_label:
        replacements += _replace_speaker_label_in_entry_texts(
            entry, session_label, canonical_name
        )
    if wrong and canonical_name and wrong != canonical_name:
        replacements += _replace_in_entry_texts(entry, wrong, canonical_name)
        replacements += _sync_translation_speaker_brackets(entry, canonical_name)

    await session.commit()
    await session.refresh(entry)
    if linked_node is not None:
        await session.refresh(linked_node)

    confirmed_name = canonical_name
    if linked_node is not None:
        confirmed_name = _linked_speaker_display_name(linked_node, profile)

    return SpeakerConfirmResult(
        speaker_profile_id=profile.id,
        confirmed_node=RecommendedNode(
            id=linked_node.id if linked_node is not None else None,
            name=confirmed_name,
        ),
        transcript_replacements=replacements,
        edges_reassigned=0,
    )


async def _is_rejecting_voice_recommendation(
    session: AsyncSession,
    profile: SpeakerProfile,
    wrong_name: str,
    canonical_name: str,
) -> bool:
    """True when the user overrides a voice-linked Person recommendation."""
    if not wrong_name or wrong_name == canonical_name or profile.node_id is None:
        return False

    linked = await session.get(Node, profile.node_id)
    if linked is None:
        return False

    wrong_key = wrong_name.strip().lower()
    linked_names = {
        n.strip().lower()
        for n in (linked.name, profile.display_name)
        if n and n.strip()
    }
    return wrong_key in linked_names


async def _fork_speaker_profile(
    session: AsyncSession,
    user_id: uuid.UUID,
    source: SpeakerProfile,
    *,
    label: str,
    last_entry_id: uuid.UUID | None,
) -> SpeakerProfile:
    """Clone voice embedding for a new Person — keep the source profile on its node."""
    embedding = list(source.embedding) if source.embedding is not None else None
    profile = SpeakerProfile(
        user_id=user_id,
        label=label,
        embedding=embedding,
        sample_count=1,
        total_duration_sec=source.total_duration_sec,
        last_entry_id=last_entry_id,
    )
    session.add(profile)
    await session.flush()
    await session.refresh(profile)
    return profile


async def _repoint_entry_speaker_profile(
    session: AsyncSession,
    entry: JournalEntry,
    entry_id: uuid.UUID,
    old_profile_id: uuid.UUID,
    new_profile_id: uuid.UUID,
) -> None:
    """Point this journal entry's appearances/segments at the forked profile."""
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    for appearance in appearances:
        if appearance.speaker_profile_id == old_profile_id:
            appearance.speaker_profile_id = new_profile_id

    segments = entry.transcript_segments
    if isinstance(segments, list):
        updated: list = []
        for seg in segments:
            if not isinstance(seg, dict):
                updated.append(seg)
                continue
            copy = dict(seg)
            if str(copy.get("speaker_profile_id", "")) == str(old_profile_id):
                copy["speaker_profile_id"] = str(new_profile_id)
            updated.append(copy)
        entry.transcript_segments = updated

    await session.flush()


async def _session_label_for_profile(
    session: AsyncSession,
    entry_id: uuid.UUID,
    profile_id: uuid.UUID,
) -> str | None:
    """Diarization label (Speaker_1) for this profile on this entry."""
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    for app in appearances:
        if app.speaker_profile_id == profile_id:
            label = app.session_label
            if isinstance(label, str) and label.strip():
                return label.strip()
    return None


async def _mark_human_confirmed_appearance(
    session: AsyncSession,
    entry_id: uuid.UUID,
    profile_id: uuid.UUID,
    session_label: str | None,
) -> None:
    """Persist UI confirmation so summaries stop asking again."""
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    for app in appearances:
        if app.speaker_profile_id == profile_id or (
            session_label and app.session_label == session_label
        ):
            app.match_score = HUMAN_CONFIRMED_MATCH_SCORE
            app.speaker_profile_id = profile_id
            if isinstance(session_label, str) and session_label.strip():
                app.session_label = session_label.strip()
    await session.flush()


_SPEAKER_NUM_RE = re.compile(r"Speaker[_\s]?(\d+)", re.I)


def _replace_speaker_label_in_entry_texts(
    entry: JournalEntry,
    session_label: str,
    canonical_name: str,
) -> int:
    """Replace [Speaker_N] bracket tags with the confirmed person name."""
    count = 0
    ko_tag = f"[{session_label}]"
    ko_replacement = f"[{canonical_name}]"

    for field in ("transcript_ko", "transcript_clean_ko", "translation_en"):
        text = getattr(entry, field)
        if not isinstance(text, str) or ko_tag not in text:
            continue
        new_text = text.replace(ko_tag, ko_replacement)
        setattr(entry, field, new_text)
        count += text.count(ko_tag)

    num_match = _SPEAKER_NUM_RE.search(session_label)
    if num_match:
        num = num_match.group(1)
        en_pattern = re.compile(rf"\[Speaker[_\s]?{re.escape(num)}\]", re.I)
        for field in ("translation_en",):
            text = getattr(entry, field)
            if not isinstance(text, str):
                continue
            new_text, n = en_pattern.subn(ko_replacement, text)
            if n:
                setattr(entry, field, new_text)
                count += n

    return count


def _replace_in_entry_texts(entry: JournalEntry, wrong: str, correct: str) -> int:
    """Replace misrecognized speaker/name strings across entry transcript fields."""
    count = 0
    for field in ("transcript_ko", "transcript_clean_ko", "translation_en"):
        text = getattr(entry, field)
        if isinstance(text, str) and wrong in text:
            setattr(entry, field, text.replace(wrong, correct))
            count += text.count(wrong)

    segments = entry.transcript_segments
    if isinstance(segments, list):
        updated: list = []
        for seg in segments:
            if not isinstance(seg, dict):
                updated.append(seg)
                continue
            copy = dict(seg)
            text = copy.get("text")
            if isinstance(text, str) and wrong in text:
                copy["text"] = text.replace(wrong, correct)
                count += text.count(wrong)
            updated.append(copy)
        entry.transcript_segments = updated

    return count


_SPEAKER_BRACKET_RE = re.compile(r"^\[([^\]]+)\]\s*(.*)$", re.DOTALL)
_EN_NAME_INTRO_RE = re.compile(
    r"\b(?:My name is|I am)\s+([A-Z][\w'-]+(?:\s+[A-Z][\w'-]+)*)",
    re.IGNORECASE,
)


def _english_speaker_label_from_body(body: str) -> str | None:
    """Infer English speaker tag from a self-introduction in the line body."""
    match = _EN_NAME_INTRO_RE.search(body)
    if not match:
        return None
    return match.group(1).strip()


def _sync_translation_speaker_brackets(
    entry: JournalEntry,
    correct_ko: str,
) -> int:
    """Align [Speaker] tags in translation_en with corrected Korean speaker names."""
    clean = entry.transcript_clean_ko
    trans = entry.translation_en
    if not isinstance(clean, str) or not isinstance(trans, str):
        return 0

    clean_lines = clean.splitlines()
    trans_lines = trans.splitlines()
    if not clean_lines or len(clean_lines) != len(trans_lines):
        return 0

    count = 0
    updated: list[str] = []
    for clean_line, trans_line in zip(clean_lines, trans_lines, strict=True):
        ko_match = _SPEAKER_BRACKET_RE.match(clean_line.strip())
        en_match = _SPEAKER_BRACKET_RE.match(trans_line.strip())
        if not ko_match or not en_match:
            updated.append(trans_line)
            continue

        ko_label, _ = ko_match.groups()
        en_label, en_body = en_match.groups()
        if ko_label != correct_ko:
            updated.append(trans_line)
            continue

        new_label = _english_speaker_label_from_body(en_body)
        if new_label and new_label != en_label:
            updated.append(f"[{new_label}] {en_body}")
            count += 1
        else:
            updated.append(trans_line)

    if count:
        entry.translation_en = "\n".join(updated)
    return count
