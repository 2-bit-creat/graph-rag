"""Persist and match speaker voice profiles across journal entries."""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import TYPE_CHECKING

from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .models import JournalEntry, Node, SpeakerProfile, User
from .speaker_diarization import SpeakerSegment, segments_to_labeled_transcript
from .speaker_matching import assign_speakers_to_profiles
from .voice_embedding import embed_speaker_segments

if TYPE_CHECKING:
    from .pipeline_trace import PipelineTracer


async def process_entry_speaker_profiles(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
    audio_path: Path,
    segments: list[SpeakerSegment],
    tracer: PipelineTracer | None = None,
) -> tuple[list[dict], list[dict]]:
    """Extract segment embeddings, match/create profiles, annotate segments."""
    settings = get_settings()
    if not settings.speaker_voice_memory_enabled or not segments:
        return [], []

    # A voiceprint is a biometric feature (sensitive info): derive it only with
    # the user's explicit speaker-identification consent. Audio itself is still
    # kept for playback; we just skip the embedding/matching without consent.
    user = await session.get(User, user_id)
    if user is None or user.speaker_id_consent_at is None:
        return [], []

    step = (
        tracer.begin_step(
            "speaker_voice_memory",
            "embed",
            phase="fast_path",
            input_data={
                "segment_count": len(segments),
                "audio_path": str(audio_path.resolve()),
                "backend": settings.speaker_embedding_backend,
            },
        )
        if tracer
        else None
    )

    ranges = [(s.speaker, s.start_sec, s.end_sec) for s in segments]
    embeddings: dict[str, list[float]] = {}
    embed_error: str | None = None
    try:
        embeddings = embed_speaker_segments(audio_path, ranges)
    except Exception as exc:
        embed_error = str(exc)

    existing = await crud.list_speaker_profiles(session, user_id)
    profile_map: dict[str, uuid.UUID] = {}
    match_results: list[dict] = []
    updated_segments: list[dict] = []

    duration_by_label: dict[str, float] = {}
    for seg in segments:
        duration_by_label[seg.speaker] = duration_by_label.get(seg.speaker, 0.0) + (
            seg.end_sec - seg.start_sec
        )

    speaker_labels = list(duration_by_label.keys())
    assignments = assign_speakers_to_profiles(
        speaker_labels,
        embeddings,
        existing,
        settings.speaker_match_threshold,
    )

    for label in speaker_labels:
        embedding = embeddings.get(label)
        assigned_profile, best_score = assignments.get(label, (None, 0.0))
        best_profile = assigned_profile
        match_type = "created_no_embedding"

        if embedding is not None and best_profile is not None and best_score >= settings.speaker_match_threshold:
            profile = await crud.update_speaker_profile_embedding(
                session,
                best_profile,
                embedding,
                duration_sec=duration_by_label.get(label, 0.0),
                last_entry_id=entry_id,
            )
            match_type = "voice_matched"
            if best_profile.node_id:
                match_type = "voice_matched_linked_node"
        elif embedding is not None:
            profile = await crud.create_speaker_profile(
                session,
                user_id=user_id,
                label=f"Voice {len(existing) + 1}",
                embedding=embedding,
                duration_sec=duration_by_label.get(label, 0.0),
                last_entry_id=entry_id,
            )
            existing.append(profile)
            match_type = "created"
            best_score = 1.0
        else:
            profile = await crud.create_speaker_profile(
                session,
                user_id=user_id,
                label=label,
                embedding=None,
                duration_sec=duration_by_label.get(label, 0.0),
                last_entry_id=entry_id,
            )
            existing.append(profile)
            match_type = "created_no_embedding"
            best_score = 0.0

        profile_map[label] = profile.id
        await crud.record_speaker_entry_appearance(
            session,
            entry_id=entry_id,
            profile_id=profile.id,
            session_label=label,
            match_score=round(best_score, 4),
            duration_sec=round(duration_by_label.get(label, 0.0), 2),
        )
        match_results.append(
            {
                "session_label": label,
                "profile_id": str(profile.id),
                "profile_label": profile.label,
                "match_score": round(float(best_score), 4),
                "match_type": match_type,
                "node_id": str(profile.node_id) if profile.node_id else None,
            }
        )

    for seg in segments:
        d = seg.to_dict()
        pid = profile_map.get(seg.speaker)
        if pid:
            d["speaker_profile_id"] = str(pid)
        updated_segments.append(d)

    if step and tracer:
        out: dict = {
            "profiles_matched_or_created": len(match_results),
            "embedding_backend": settings.speaker_embedding_backend,
            "matches": match_results,
        }
        if embed_error:
            out["embedding_error"] = embed_error
        tracer.finish_step(
            step,
            output=out,
            error=embed_error if not match_results else None,
            artifacts=[("speaker_matches.json", match_results, "application/json")],
        )

    return match_results, updated_segments


def entry_speaker_bindings_need_repair(entry: JournalEntry) -> bool:
    """True when segment profile ids are missing or out of sync with appearances."""
    segments = entry.transcript_segments
    if not isinstance(segments, list):
        return False
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        label = str(seg.get("speaker", "")).strip()
        if not label:
            continue
        if not seg.get("speaker_profile_id"):
            return True
    return False


async def entry_speaker_bindings_mismatched(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry: JournalEntry,
) -> bool:
    segments = entry.transcript_segments
    if not isinstance(segments, list):
        return False
    appearances = await crud.list_speaker_appearances_for_entry(session, entry.id)
    by_label: dict[str, uuid.UUID] = {}
    for app in appearances:
        label = (app.session_label or "").strip()
        if not label:
            continue
        profile = await session.get(SpeakerProfile, app.speaker_profile_id)
        if profile is None or profile.user_id != user_id:
            continue
        by_label[label] = profile.id

    for seg in segments:
        if not isinstance(seg, dict):
            continue
        label = str(seg.get("speaker", "")).strip()
        if not label:
            continue
        expected = by_label.get(label)
        if expected is None:
            return True
        raw_pid = seg.get("speaker_profile_id")
        if not raw_pid or str(raw_pid) != str(expected):
            return True
    return False


async def repair_entry_speaker_bindings(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry: JournalEntry,
) -> bool:
    """Restore speaker_profile_id on segments after a partial voice-data wipe.

    This is also the first-read path that creates each brand-new speaker's
    profile/appearance for a freshly created entry (segments start with no
    speaker_profile_id). For a text-sourced entry (@멘션), that label is a name
    the user explicitly typed or picked — no diarization/voice ambiguity to
    resolve — so (aside from '나' and the unattributed-prose placeholder
    '글쓴이') it's auto-confirmed here, linking to a same-named existing Person
    node when one exists, instead of prompting "누가 말했나요?" for something
    already specified.
    """
    segments = entry.transcript_segments
    if not isinstance(segments, list) or not segments:
        return False

    appearances = await crud.list_speaker_appearances_for_entry(session, entry.id)
    profile_id_by_label: dict[str, uuid.UUID] = {}
    for app in appearances:
        label = (app.session_label or "").strip()
        if not label:
            continue
        profile = await session.get(SpeakerProfile, app.speaker_profile_id)
        if profile is None or profile.user_id != user_id:
            await session.delete(app)
            continue
        profile_id_by_label[label] = profile.id

    labels_in_segments: set[str] = set()
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        label = str(seg.get("speaker", "")).strip()
        if label:
            labels_in_segments.add(label)

    is_text_source = entry.audio_url is None
    claimed_node_ids: set[uuid.UUID] = set()

    changed = False
    for label in sorted(labels_in_segments):
        if label in profile_id_by_label:
            continue

        auto_confirm = is_text_source and label not in ("나", "글쓴이")
        matched_node = (
            await crud.find_person_node_by_exact_name(
                session, user_id, label, exclude_node_ids=claimed_node_ids
            )
            if auto_confirm
            else None
        )

        profile = await crud.create_speaker_profile(
            session,
            user_id=user_id,
            label=label,
            embedding=None,
            last_entry_id=entry.id,
        )
        match_score = 0.0
        if auto_confirm:
            if matched_node is not None:
                profile = await crud.assign_exclusive_voice_profile_to_node(
                    session, user_id, profile, matched_node, display_name=label,
                )
                claimed_node_ids.add(matched_node.id)
            else:
                profile.display_name = label
                profile.label = label
                await session.flush()
            match_score = 1.0  # speaker_confirmation.HUMAN_CONFIRMED_MATCH_SCORE
        await crud.record_speaker_entry_appearance(
            session,
            entry_id=entry.id,
            profile_id=profile.id,
            session_label=label,
            match_score=match_score,
            duration_sec=0.0,
        )
        profile_id_by_label[label] = profile.id
        changed = True

    new_segments: list = []
    for seg in segments:
        if not isinstance(seg, dict):
            new_segments.append(seg)
            continue
        copy = dict(seg)
        label = str(copy.get("speaker", "")).strip()
        if label:
            pid = profile_id_by_label.get(label)
            if pid is not None and str(copy.get("speaker_profile_id") or "") != str(pid):
                copy["speaker_profile_id"] = str(pid)
                changed = True
        new_segments.append(copy)

    if changed:
        entry.transcript_segments = new_segments
        await session.commit()
        await session.refresh(entry)
    return changed


async def build_llm_transcript_with_speaker_names(
    session: AsyncSession,
    user_id: uuid.UUID,
    segments: list[dict],
) -> str:
    """Replace diarization labels with voice-linked Person names (post-confirm / tests only).

    Fast-path GPT cleanup uses raw Speaker_N labels; names are applied after UI confirm.
    """
    if not segments:
        return ""

    profiles = {p.id: p for p in await crud.list_speaker_profiles(session, user_id)}
    labeled_segments: list[SpeakerSegment] = []

    for raw in segments:
        if not isinstance(raw, dict):
            continue
        label = str(raw.get("speaker", "?"))
        text = (raw.get("text") or "").strip()
        if not text:
            continue

        display = label
        pid_raw = raw.get("speaker_profile_id")
        if pid_raw:
            try:
                profile = profiles.get(uuid.UUID(str(pid_raw)))
            except ValueError:
                profile = None
            if profile is not None and profile.node_id is not None:
                node = await session.get(Node, profile.node_id)
                if (
                    node is not None
                    and node.user_id == user_id
                    and crud.is_bidirectional_voice_link(profile, node)
                ):
                    display = (profile.display_name or node.name or label).strip()

        labeled_segments.append(
            SpeakerSegment(
                speaker=display,
                start_sec=float(raw.get("start_sec", 0)),
                end_sec=float(raw.get("end_sec", 0)),
                text=text,
            )
        )

    return segments_to_labeled_transcript(labeled_segments)
