"""Global speaker-to-profile assignment using voice embedding similarity."""

from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

from .voice_embedding import cosine_similarity

if TYPE_CHECKING:
    from .models import SpeakerProfile

# Prefer graph-linked Person voices over orphan session profiles.
_LINKED_NODE_BONUS = 0.12


def _raw_similarity(embedding: list[float], profile: SpeakerProfile) -> float:
    raw = profile.embedding
    if raw is None:
        return 0.0
    return cosine_similarity(embedding, list(raw))


def _effective_score(raw: float, profile: SpeakerProfile) -> float:
    if profile.node_id is not None:
        return raw + _LINKED_NODE_BONUS
    return raw


def assign_speakers_to_profiles(
    labels: list[str],
    embeddings: dict[str, list[float]],
    profiles: list[SpeakerProfile],
    threshold: float,
) -> dict[str, tuple[SpeakerProfile | None, float]]:
    """Assign each session label to at most one profile (1:1), maximizing match quality.

    Returns mapping label -> (profile or None, raw_cosine_score).
    Phase 1 matches against Person-linked profiles; phase 2 uses unlinked voice memory.
    """
    ordered_labels = [label for label in labels if embeddings.get(label)]
    if not ordered_labels:
        return {}

    if len(ordered_labels) == 1:
        return _assign_single_speaker(ordered_labels[0], embeddings, profiles, threshold)

    linked = [p for p in profiles if p.embedding is not None and p.node_id is not None]
    unlinked = [p for p in profiles if p.embedding is not None and p.node_id is None]

    result: dict[str, tuple[SpeakerProfile | None, float]] = {
        label: (None, 0.0) for label in ordered_labels
    }

    if linked:
        linked_assign = _optimal_assignment(ordered_labels, embeddings, linked, threshold)
        for label, (profile, raw) in linked_assign.items():
            if profile is not None:
                result[label] = (profile, raw)

    remaining = [label for label in ordered_labels if result[label][0] is None]
    if remaining and unlinked:
        unlinked_assign = _optimal_assignment(remaining, embeddings, unlinked, threshold)
        for label, (profile, raw) in unlinked_assign.items():
            if profile is not None:
                result[label] = (profile, raw)

    return result


def _assign_single_speaker(
    label: str,
    embeddings: dict[str, list[float]],
    profiles: list[SpeakerProfile],
    threshold: float,
) -> dict[str, tuple[SpeakerProfile | None, float]]:
    embedding = embeddings.get(label)
    if embedding is None:
        return {label: (None, 0.0)}

    linked = [p for p in profiles if p.embedding is not None and p.node_id is not None]
    unlinked = [p for p in profiles if p.embedding is not None and p.node_id is None]

    for pool in (linked, unlinked):
        best_profile = None
        best_raw = 0.0
        for profile in pool:
            raw = _raw_similarity(embedding, profile)
            if raw >= threshold and raw > best_raw:
                best_profile = profile
                best_raw = raw
        if best_profile is not None:
            return {label: (best_profile, best_raw)}

    return {label: (None, 0.0)}


def _optimal_assignment(
    labels: list[str],
    embeddings: dict[str, list[float]],
    profiles: list[SpeakerProfile],
    threshold: float,
) -> dict[str, tuple[SpeakerProfile | None, float]]:
    """Brute-force optimal 1:1 assignment for small speaker/profile counts."""
    if not labels:
        return {}
    if not profiles:
        return {label: (None, 0.0) for label in labels}

    best_total = -1.0
    best: dict[str, tuple[SpeakerProfile | None, float]] = {
        label: (None, 0.0) for label in labels
    }

    def search(
        index: int,
        used: set[uuid.UUID],
        current: dict[str, tuple[SpeakerProfile | None, float]],
        total: float,
    ) -> None:
        nonlocal best_total, best
        if index >= len(labels):
            if total > best_total:
                best_total = total
                best = dict(current)
            return

        label = labels[index]
        embedding = embeddings[label]

        current[label] = (None, 0.0)
        search(index + 1, used, current, total)

        for profile in profiles:
            if profile.id in used:
                continue
            raw = _raw_similarity(embedding, profile)
            if raw < threshold:
                continue
            current[label] = (profile, raw)
            search(index + 1, used | {profile.id}, current, total + _effective_score(raw, profile))
        current[label] = (None, 0.0)

    search(0, set(), {label: (None, 0.0) for label in labels}, 0.0)
    return best
