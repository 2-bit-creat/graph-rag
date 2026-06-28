import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .models import (
    Chunk,
    Edge,
    GraphJob,
    JournalEntry,
    JournalGraphLink,
    Node,
    Ontology,
    OntologyVersion,
    Quiz,
    ReviewSchedule,
    SpeakerEntryAppearance,
    SpeakerProfile,
    User,
)
from .entity_types import is_person_like_type, normalize_entity_type, type_group_key
from .graph_schema import (
    NODE_CHUNK,
    NODE_SPEAKER,
    REL_NEXT_TURN,
    REL_SPOKE_BY,
    contains_relation,
)
from .schemas import NodeOut, StagedEdge, StagedNode


def is_bidirectional_voice_link(
    profile: SpeakerProfile | None, node: Node | None
) -> bool:
    """True when UI-confirmed speaker profile ↔ graph node ids match on both sides."""
    if profile is None or node is None:
        return False
    return profile.node_id == node.id and node.speaker_profile_id == profile.id


def build_node_out(
    node: Node,
    profile: SpeakerProfile | None = None,
    *,
    speaker_name: str | None = None,
    source_entry_id: uuid.UUID | None = None,
    source_transcript_ko: str | None = None,
    source_transcript_clean_ko: str | None = None,
) -> NodeOut:
    """Graph API node + voice/name embedding metadata."""
    linked = is_bidirectional_voice_link(profile, node)
    has_voice = linked and profile is not None and profile.embedding is not None
    voice_label: str | None = None
    if linked and profile is not None:
        voice_label = (node.name or profile.display_name or profile.label or "").strip() or None
    elif profile is not None:
        voice_label = profile.label
    chunk_fields: dict = {}
    if normalize_entity_type(node.type) == NODE_CHUNK:
        chunk_fields = {
            "display_title": node.name,
            "text": node.description,
            "speaker_name": speaker_name,
        }
    return NodeOut(
        id=node.id,
        name=node.name,
        type=node.type,
        description=node.description,
        created_at=node.created_at,
        has_name_embedding=node.name_embedding is not None,
        speaker_profile_id=profile.id if linked and profile else None,
        voice_embedding_registered=has_voice,
        voice_sample_count=profile.sample_count if profile else 0,
        voice_profile_label=voice_label,
        voice_total_duration_sec=float(profile.total_duration_sec or 0.0) if profile else 0.0,
        deleted_at=getattr(node, "deleted_at", None),
        deleted_context=getattr(node, "deleted_context", None),
        source_entry_id=source_entry_id,
        source_transcript_ko=source_transcript_ko,
        source_transcript_clean_ko=source_transcript_clean_ko,
        **chunk_fields,
    )


async def _speaker_profiles_for_nodes(
    session: AsyncSession, nodes: list[Node]
) -> dict[uuid.UUID, SpeakerProfile]:
    """Map node.id → speaker profile only when explicitly linked on the node.

    Do not infer from ``profile.node_id`` alone — GraphRAG name-in-text heuristics
  must not show another person's voice on a mentioned-only Person node.
    """
    if not nodes:
        return {}
    by_id: dict[uuid.UUID, SpeakerProfile] = {}
    profile_ids = {n.speaker_profile_id for n in nodes if n.speaker_profile_id}
    if not profile_ids:
        return by_id
    result = await session.execute(
        select(SpeakerProfile).where(SpeakerProfile.id.in_(profile_ids))
    )
    profiles_by_id = {p.id: p for p in result.scalars()}
    for n in nodes:
        pid = n.speaker_profile_id
        if pid is None or pid not in profiles_by_id:
            continue
        profile = profiles_by_id[pid]
        if is_bidirectional_voice_link(profile, n):
            by_id[n.id] = profile
    return by_id


async def sanitize_stale_voice_links(
    session: AsyncSession, user_id: uuid.UUID
) -> int:
    """Clear one-sided or orphaned profile↔node links left by graph wipes / heuristics."""
    cleared = 0
    profiles = await list_speaker_profiles(session, user_id)
    for profile in profiles:
        node = await session.get(Node, profile.node_id) if profile.node_id else None
        if profile.node_id is not None and (
            node is None or node.user_id != user_id
        ):
            profile.node_id = None
            cleared += 1
            node = None
        if node is not None and not is_bidirectional_voice_link(profile, node):
            profile.node_id = None
            cleared += 1

    nodes = await get_all_nodes(session, user_id=user_id)
    for node in nodes:
        if node.speaker_profile_id is None:
            continue
        profile = await session.get(SpeakerProfile, node.speaker_profile_id)
        if profile is None:
            node.speaker_profile_id = None
            cleared += 1
            continue
        if not is_bidirectional_voice_link(profile, node):
            node.speaker_profile_id = None
            cleared += 1
            continue
        node_key = (node.name or "").strip().lower()
        identity_keys = {
            (profile.display_name or "").strip().lower(),
            (profile.label or "").strip().lower(),
        } - {""}
        if (
            node_key
            and identity_keys
            and node_key not in identity_keys
            and is_person_like_type(node.type)
        ):
            profile.node_id = None
            node.speaker_profile_id = None
            cleared += 1

    # Garbage-collect truly orphaned voice profiles: no graph node AND not
    # referenced by any journal entry's speaker appearance. These accumulate
    # e.g. when a voice match is rejected and the profile is forked away, or
    # after a node deletion detaches the profile — leaving an embedding with no
    # owner. Profiles still referenced by an entry stay (active voice memory).
    await session.flush()
    referenced = await session.execute(
        select(SpeakerEntryAppearance.speaker_profile_id)
        .join(
            JournalEntry,
            JournalEntry.id == SpeakerEntryAppearance.journal_entry_id,
        )
        .where(JournalEntry.user_id == user_id)
    )
    referenced_ids = {pid for (pid,) in referenced.all() if pid is not None}
    for profile in await list_speaker_profiles(session, user_id):
        if profile.node_id is None and profile.id not in referenced_ids:
            await session.delete(profile)
            cleared += 1

    if cleared:
        await session.commit()
    return cleared


async def unlink_speakers_from_graph(
    session: AsyncSession, user_id: uuid.UUID
) -> dict[str, int]:
    """Detach voice profiles from deleted graph nodes; keep per-entry speaker picking."""
    _human_confirmed = 1.0
    links_cleared = 0
    for profile in await list_speaker_profiles(session, user_id):
        if profile.node_id is not None or profile.display_name:
            profile.node_id = None
            profile.display_name = None
            links_cleared += 1

    entry_ids_subq = select(JournalEntry.id).where(JournalEntry.user_id == user_id)
    appearance_result = await session.execute(
        select(SpeakerEntryAppearance).where(
            SpeakerEntryAppearance.journal_entry_id.in_(entry_ids_subq)
        )
    )
    confirmations_reset = 0
    for appearance in appearance_result.scalars():
        if appearance.match_score >= _human_confirmed - 1e-6:
            appearance.match_score = 0.0
            confirmations_reset += 1

    return {
        "speaker_graph_links_cleared": links_cleared,
        "speaker_confirmations_reset": confirmations_reset,
    }


async def reset_user_speaker_identities(
    session: AsyncSession, user_id: uuid.UUID
) -> dict[str, int]:
    """Hard-delete all voice profiles (admin/debug only — breaks speaker chips until repair)."""
    entry_ids_subq = select(JournalEntry.id).where(JournalEntry.user_id == user_id)

    appearance_result = await session.execute(
        delete(SpeakerEntryAppearance).where(
            SpeakerEntryAppearance.journal_entry_id.in_(entry_ids_subq)
        )
    )
    profile_result = await session.execute(
        delete(SpeakerProfile).where(SpeakerProfile.user_id == user_id)
    )

    entries = await session.execute(
        select(JournalEntry).where(JournalEntry.user_id == user_id)
    )
    segments_cleared = 0
    for entry in entries.scalars():
        segments = entry.transcript_segments
        if not isinstance(segments, list):
            continue
        changed = False
        cleaned: list = []
        for seg in segments:
            if isinstance(seg, dict) and seg.get("speaker_profile_id"):
                copy = dict(seg)
                copy.pop("speaker_profile_id", None)
                cleaned.append(copy)
                changed = True
                segments_cleared += 1
            else:
                cleaned.append(seg)
        if changed:
            entry.transcript_segments = cleaned

    return {
        "speaker_profiles_deleted": int(profile_result.rowcount or 0),
        "speaker_appearances_deleted": int(appearance_result.rowcount or 0),
        "transcript_profile_refs_cleared": segments_cleared,
    }


async def _speaker_names_for_chunk_nodes(
    session: AsyncSession, chunk_ids: list[uuid.UUID]
) -> dict[uuid.UUID, str]:
    if not chunk_ids:
        return {}
    result = await session.execute(
        select(Edge, Node)
        .join(Node, Edge.target_id == Node.id)
        .where(
            Edge.source_id.in_(chunk_ids),
            Edge.relation == REL_SPOKE_BY,
            func.lower(Node.type) == type_group_key(NODE_SPEAKER),
        )
    )
    mapping: dict[uuid.UUID, str] = {}
    for edge, speaker in result.all():
        mapping[edge.source_id] = speaker.name
    return mapping


async def list_nodes_out(
    session: AsyncSession, user_id: uuid.UUID
) -> list[NodeOut]:
    await sanitize_stale_voice_links(session, user_id)
    nodes = await get_all_nodes(session, user_id=user_id)
    profiles = await _speaker_profiles_for_nodes(session, nodes)
    chunk_ids = [
        n.id for n in nodes if normalize_entity_type(n.type) == NODE_CHUNK
    ]
    speaker_by_chunk = await _speaker_names_for_chunk_nodes(session, chunk_ids)

    # Batch map node_id → source journal entry id (provenance) so the Timeline can
    # navigate node → 내 일기 without a per-node round trip.
    entry_by_node: dict[uuid.UUID, uuid.UUID] = {}
    node_ids = [n.id for n in nodes]
    if node_ids:
        link_rows = await session.execute(
            select(JournalGraphLink.node_id, JournalGraphLink.journal_entry_id)
            .where(
                JournalGraphLink.node_id.in_(node_ids),
                JournalGraphLink.node_id.is_not(None),
            )
            .order_by(JournalGraphLink.id)
        )
        for nid, eid in link_rows.all():
            if nid is not None and nid not in entry_by_node:
                entry_by_node[nid] = eid

    return [
        build_node_out(
            n,
            profiles.get(n.id),
            speaker_name=speaker_by_chunk.get(n.id),
            source_entry_id=entry_by_node.get(n.id),
        )
        for n in nodes
    ]


async def get_node_out(
    session: AsyncSession, node_id: uuid.UUID, user_id: uuid.UUID
) -> NodeOut | None:
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user_id or node.deleted_at is not None:
        return None
    profiles = await _speaker_profiles_for_nodes(session, [node])
    speaker_name = None
    if normalize_entity_type(node.type) == NODE_CHUNK:
        names = await _speaker_names_for_chunk_nodes(session, [node.id])
        speaker_name = names.get(node.id)

    # Load source journal entry's raw transcript via JournalGraphLink (primary),
    # falling back to Quiz.source_nodes → associated_entry_id (for older nodes).
    source_entry_id: uuid.UUID | None = None
    source_transcript_ko: str | None = None
    source_transcript_clean_ko: str | None = None

    link_result = await session.execute(
        select(JournalGraphLink.journal_entry_id)
        .where(JournalGraphLink.node_id == node_id)
        .limit(1)
    )
    linked_entry_id = link_result.scalar_one_or_none()

    # Fallback: find via any quiz that has this node in source_nodes
    if linked_entry_id is None:
        quiz_link = await session.execute(
            select(Quiz.associated_entry_id)
            .where(
                Quiz.user_id == user_id,
                Quiz.associated_entry_id.is_not(None),
                Quiz.source_nodes.contains([node_id]),
            )
            .limit(1)
        )
        linked_entry_id = quiz_link.scalar_one_or_none()

    if linked_entry_id is not None:
        entry = await session.get(JournalEntry, linked_entry_id)
        if entry is not None and entry.user_id == user_id:
            source_entry_id = linked_entry_id
            source_transcript_ko = entry.transcript_ko
            source_transcript_clean_ko = entry.transcript_clean_ko

    # Fallback for Statement nodes (kg_build) with no JournalGraphLink:
    # search JournalEntry by matching statement content against transcript_clean_ko.
    if linked_entry_id is None and node.type == "Statement":
        import json as _json
        desc = node.description or ""
        try:
            desc_obj = _json.loads(desc)
            content = (desc_obj.get("content") or "").strip()
            if len(content) > 20:
                search_phrase = content[:60]
                from sqlalchemy import func as _func
                text_match = await session.execute(
                    select(JournalEntry)
                    .where(
                        JournalEntry.user_id == user_id,
                        JournalEntry.transcript_clean_ko.ilike(f"%{search_phrase}%"),
                    )
                    .order_by(JournalEntry.created_at.desc())
                    .limit(1)
                )
                found = text_match.scalar_one_or_none()
                if found is None:
                    # Try against raw transcript
                    text_match2 = await session.execute(
                        select(JournalEntry)
                        .where(
                            JournalEntry.user_id == user_id,
                            JournalEntry.transcript_ko.ilike(f"%{search_phrase[:40]}%"),
                        )
                        .order_by(JournalEntry.created_at.desc())
                        .limit(1)
                    )
                    found = text_match2.scalar_one_or_none()
                if found is not None:
                    source_entry_id = found.id
                    source_transcript_ko = found.transcript_ko
                    source_transcript_clean_ko = found.transcript_clean_ko
        except (ValueError, TypeError, AttributeError):
            pass

    return build_node_out(
        node,
        profiles.get(node.id),
        speaker_name=speaker_name,
        source_entry_id=source_entry_id,
        source_transcript_ko=source_transcript_ko,
        source_transcript_clean_ko=source_transcript_clean_ko,
    )


async def get_user_by_email(session: AsyncSession, email: str) -> User | None:
    result = await session.execute(select(User).where(User.email == email.lower()))
    return result.scalar_one_or_none()


async def create_user(session: AsyncSession, email: str, password_hash: str) -> User:
    user = User(email=email.lower(), password_hash=password_hash)
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user


async def _get_or_create_node(
    session: AsyncSession,
    name: str,
    type_: str,
    description: str | None = None,
    user_id: uuid.UUID | None = None,
) -> Node:
    name = (name or "").strip()
    type_ = normalize_entity_type(type_)

    filters = [
        Node.name == name,
        func.lower(Node.type) == type_group_key(type_),
        Node.deleted_at.is_(None),  # never match soft-deleted nodes
    ]
    if user_id is not None:
        filters.append(Node.user_id == user_id)
    else:
        filters.append(Node.user_id.is_(None))

    result = await session.execute(select(Node).where(*filters))
    node = result.scalar_one_or_none()
    if node is None:
        node = Node(name=name, type=type_, description=description, user_id=user_id)
        session.add(node)
        await session.flush()
    elif description and not node.description:
        node.description = description
        node.updated_at = datetime.now(UTC)
    return node


# --- Graph reads -------------------------------------------------------------


async def get_all_nodes(
    session: AsyncSession,
    user_id: uuid.UUID | None = None,
    include_deleted: bool = False,
) -> list[Node]:
    q = select(Node).order_by(Node.created_at)
    if user_id is not None:
        q = q.where(Node.user_id == user_id)
    if not include_deleted:
        q = q.where(Node.deleted_at.is_(None))
    result = await session.execute(q)
    return list(result.scalars().all())


async def get_all_edges(
    session: AsyncSession, user_id: uuid.UUID | None = None
) -> list[Edge]:
    q = select(Edge).order_by(Edge.created_at)
    if user_id is not None:
        q = q.where(Edge.user_id == user_id)
    result = await session.execute(q)
    return list(result.scalars().all())


async def get_graph_summary(session: AsyncSession, user_id: uuid.UUID) -> dict:
    node_count = await session.scalar(
        select(func.count()).select_from(Node).where(Node.user_id == user_id)
    )
    edge_count = await session.scalar(
        select(func.count()).select_from(Edge).where(Edge.user_id == user_id)
    )
    dynamic_types = await get_dynamic_node_types(session, user_id)
    return {
        "node_count": node_count or 0,
        "edge_count": edge_count or 0,
        "top_entity_types": dynamic_types[:10],
        "entity_types": dynamic_types,
    }


async def get_dynamic_node_types(
    session: AsyncSession, user_id: uuid.UUID
) -> list[dict]:
    """Distinct node types (PascalCase, case-deduplicated) for filter tabs."""
    result = await session.execute(select(Node).where(Node.user_id == user_id))
    counts: dict[str, int] = {}
    for node in result.scalars():
        t = normalize_entity_type(node.type)
        counts[t] = counts.get(t, 0) + 1
    return [
        {"type": t, "count": c}
        for t, c in sorted(counts.items(), key=lambda x: (-x[1], x[0]))
    ]


async def deduplicate_node_type_casing(
    session: AsyncSession, user_id: uuid.UUID
) -> int:
    """Merge PERSON/Person/person → Person in stored nodes."""
    result = await session.execute(select(Node).where(Node.user_id == user_id))
    changed = 0
    for node in result.scalars():
        canon = normalize_entity_type(node.type)
        if node.type != canon:
            node.type = canon
            changed += 1
    if changed:
        await session.flush()
    return changed


# --- LightRAG incremental graph ----------------------------------------------


async def find_similar_nodes_by_embedding(
    session: AsyncSession,
    user_id: uuid.UUID,
    embedding: list[float],
    limit: int = 3,
    max_distance: float = 0.3,
) -> list[Node]:
    """Return active (non-deleted) nodes whose name_embedding is within cosine distance threshold."""
    dist_col = Node.name_embedding.cosine_distance(embedding).label("dist")
    result = await session.execute(
        select(Node, dist_col)
        .where(
            Node.user_id == user_id,
            Node.name_embedding.isnot(None),
            Node.deleted_at.is_(None),  # exclude soft-deleted nodes
            dist_col <= max_distance,
        )
        .order_by(dist_col)
        .limit(limit)
    )
    return [row[0] for row in result.all()]


async def upsert_weighted_edge(
    session: AsyncSession,
    user_id: uuid.UUID,
    source_id: uuid.UUID,
    target_id: uuid.UUID,
    relation: str,
) -> Edge:
    """Insert edge or increment weight and refresh last_triggered_at."""
    now = datetime.now(UTC)
    result = await session.execute(
        select(Edge).where(
            Edge.source_id == source_id,
            Edge.target_id == target_id,
            Edge.relation == relation,
        )
    )
    edge = result.scalar_one_or_none()
    if edge is None:
        edge = Edge(
            source_id=source_id,
            target_id=target_id,
            relation=relation,
            user_id=user_id,
            weight=1,
            last_triggered_at=now,
        )
        session.add(edge)
        await session.flush()
    else:
        edge.weight = (edge.weight or 1) + 1
        edge.last_triggered_at = now
        if edge.user_id is None:
            edge.user_id = user_id
    return edge


async def apply_staged_graph(
    session: AsyncSession,
    staged_nodes: list[StagedNode],
    staged_edges: list[StagedEdge],
    user_id: uuid.UUID | None = None,
) -> tuple[list[uuid.UUID], list[uuid.UUID]]:
    """Commit a staged graph into nodes/edges, deduped. Returns created/touched ids."""
    temp_to_node: dict[str, Node] = {}
    node_ids: list[uuid.UUID] = []
    for sn in staged_nodes:
        if not sn.name.strip():
            continue
        node = await _get_or_create_node(
            session, sn.name, sn.type, sn.description, user_id=user_id
        )
        temp_to_node[sn.temp_id] = node
        node_ids.append(node.id)

    edge_ids: list[uuid.UUID] = []
    for se in staged_edges:
        source = temp_to_node.get(se.source_temp_id)
        target = temp_to_node.get(se.target_temp_id)
        if source is None or target is None:
            continue

        exists = await session.execute(
            select(Edge).where(
                Edge.source_id == source.id,
                Edge.target_id == target.id,
                Edge.relation == se.relation,
            )
        )
        existing = exists.scalar_one_or_none()
        if existing is None:
            edge = Edge(
                source_id=source.id,
                target_id=target.id,
                relation=se.relation,
                user_id=user_id,
            )
            session.add(edge)
            await session.flush()
            edge_ids.append(edge.id)
        else:
            edge_ids.append(existing.id)
    await session.commit()
    return node_ids, edge_ids


async def record_journal_graph_links(
    session: AsyncSession,
    entry_id: uuid.UUID,
    node_ids: list[uuid.UUID],
    edge_ids: list[uuid.UUID],
) -> None:
    for nid in set(node_ids):
        session.add(JournalGraphLink(journal_entry_id=entry_id, node_id=nid))
    for eid in set(edge_ids):
        session.add(JournalGraphLink(journal_entry_id=entry_id, edge_id=eid))
    await session.commit()


async def entry_has_graph_nodes(
    session: AsyncSession, entry_id: uuid.UUID
) -> bool:
    """True if this entry has at least one committed graph node (provenance link).

    Authoritative completion signal — survives a stuck/stale graph_status.
    """
    result = await session.execute(
        select(JournalGraphLink.id)
        .where(
            JournalGraphLink.journal_entry_id == entry_id,
            JournalGraphLink.node_id.is_not(None),
        )
        .limit(1)
    )
    return result.first() is not None


# --- Journal -----------------------------------------------------------------


async def create_journal_entry(
    session: AsyncSession,
    user_id: uuid.UUID,
    audio_url: str | None = None,
) -> JournalEntry:
    entry = JournalEntry(user_id=user_id, audio_url=audio_url, status="processing")
    session.add(entry)
    await session.commit()
    await session.refresh(entry)
    return entry


async def update_journal_entry(
    session: AsyncSession,
    entry: JournalEntry,
    **fields,
) -> JournalEntry:
    jsonb_fields = {"pipeline_trace", "transcript_segments", "graph_staging", "translations"}
    for key, value in fields.items():
        if key in jsonb_fields and value is not None:
            from .json_util import json_safe

            value = json_safe(value)
        setattr(entry, key, value)
    await session.commit()
    await session.refresh(entry)
    return entry


async def list_journal_entries(
    session: AsyncSession, user_id: uuid.UUID, limit: int = 50
) -> list[JournalEntry]:
    result = await session.execute(
        select(JournalEntry)
        .where(JournalEntry.user_id == user_id)
        .order_by(JournalEntry.created_at.desc())
        .limit(limit)
    )
    return list(result.scalars().all())


async def get_journal_entry(
    session: AsyncSession, entry_id: uuid.UUID, user_id: uuid.UUID
) -> JournalEntry | None:
    result = await session.execute(
        select(JournalEntry).where(
            JournalEntry.id == entry_id, JournalEntry.user_id == user_id
        )
    )
    return result.scalar_one_or_none()


async def delete_journal_entry(
    session: AsyncSession, entry: JournalEntry
) -> None:
    """Delete an entry and its DB-cascaded children (appearances, graph links,
    chunks, review schedules). Speaker profiles survive (last_entry_id SET NULL);
    orphaned ones are garbage-collected by sanitize_stale_voice_links afterward.
    Best-effort removes the local audio file."""
    from .config import get_settings
    from .storage import local_path

    audio_key = entry.audio_url
    if audio_key and not get_settings().s3_bucket:
        try:
            path = local_path(audio_key)
            if path.is_file():
                path.unlink()
        except OSError:
            pass
    await session.delete(entry)
    await session.commit()


async def delete_all_journal_entries(
    session: AsyncSession, user_id: uuid.UUID
) -> int:
    """Delete every journal entry for a user (with DB-cascaded children).

    Best-effort removes local audio files. Speaker profiles survive via
    last_entry_id SET NULL; orphans are GC'd by sanitize_stale_voice_links.
    Returns the number of entries deleted.
    """
    from .config import get_settings
    from .storage import local_path

    result = await session.execute(
        select(JournalEntry).where(JournalEntry.user_id == user_id)
    )
    entries = list(result.scalars().all())
    if not entries:
        return 0

    use_local_audio = not get_settings().s3_bucket
    for entry in entries:
        if use_local_audio and entry.audio_url:
            try:
                path = local_path(entry.audio_url)
                if path.is_file():
                    path.unlink()
            except OSError:
                pass
        await session.delete(entry)
    await session.commit()
    return len(entries)


async def count_recent_entries(
    session: AsyncSession, user_id: uuid.UUID, days: int
) -> int:
    since = datetime.now(UTC) - timedelta(days=days)
    return (
        await session.scalar(
            select(func.count())
            .select_from(JournalEntry)
            .where(JournalEntry.user_id == user_id, JournalEntry.created_at >= since)
        )
        or 0
    )


# --- Graph jobs --------------------------------------------------------------


async def create_graph_job(session: AsyncSession, user_id: uuid.UUID) -> GraphJob:
    job = GraphJob(user_id=user_id, status="pending", progress=0)
    session.add(job)
    await session.commit()
    await session.refresh(job)
    return job


async def update_graph_job(
    session: AsyncSession, job: GraphJob, **fields
) -> GraphJob:
    for key, value in fields.items():
        setattr(job, key, value)
    await session.commit()
    await session.refresh(job)
    return job


async def get_graph_job(
    session: AsyncSession, job_id: uuid.UUID, user_id: uuid.UUID
) -> GraphJob | None:
    result = await session.execute(
        select(GraphJob).where(GraphJob.id == job_id, GraphJob.user_id == user_id)
    )
    return result.scalar_one_or_none()


# --- Chunks & embeddings -----------------------------------------------------


async def create_chunk(
    session: AsyncSession,
    user_id: uuid.UUID,
    text: str,
    journal_entry_id: uuid.UUID | None = None,
    embedding: list[float] | None = None,
) -> Chunk:
    chunk = Chunk(
        user_id=user_id,
        text=text,
        journal_entry_id=journal_entry_id,
        embedding=embedding,
    )
    session.add(chunk)
    await session.commit()
    await session.refresh(chunk)
    return chunk


async def create_chunks_batch(
    session: AsyncSession,
    user_id: uuid.UUID,
    items: list[tuple[str, uuid.UUID | None, list[float] | None]],
) -> int:
    """Insert multiple chunks in a single commit."""
    if not items:
        return 0
    for text, journal_entry_id, embedding in items:
        session.add(
            Chunk(
                user_id=user_id,
                text=text,
                journal_entry_id=journal_entry_id,
                embedding=embedding,
            )
        )
    await session.commit()
    return len(items)


async def get_neighborhood(
    session: AsyncSession,
    user_id: uuid.UUID,
    seed_node_ids: set[uuid.UUID],
    depth: int = 2,
) -> set[uuid.UUID]:
    visited = set(seed_node_ids)
    frontier = set(seed_node_ids)
    for _ in range(depth):
        if not frontier:
            break
        result = await session.execute(
            select(Edge).where(
                Edge.user_id == user_id,
                or_(
                    Edge.source_id.in_(frontier),
                    Edge.target_id.in_(frontier),
                ),
            )
        )
        next_frontier: set[uuid.UUID] = set()
        for edge in result.scalars().all():
            for nid in (edge.source_id, edge.target_id):
                if nid not in visited:
                    visited.add(nid)
                    next_frontier.add(nid)
        frontier = next_frontier
    return visited


# --- Review schedule (SM-2 lite) ---------------------------------------------


async def schedule_review(
    session: AsyncSession,
    user_id: uuid.UUID,
    journal_entry_id: uuid.UUID,
) -> ReviewSchedule:
    existing = await session.execute(
        select(ReviewSchedule).where(
            ReviewSchedule.user_id == user_id,
            ReviewSchedule.journal_entry_id == journal_entry_id,
        )
    )
    sched = existing.scalar_one_or_none()
    if sched is None:
        sched = ReviewSchedule(
            user_id=user_id,
            journal_entry_id=journal_entry_id,
            next_review_at=datetime.now(UTC) + timedelta(days=1),
        )
        session.add(sched)
    await session.commit()
    await session.refresh(sched)
    return sched


async def list_due_reviews(
    session: AsyncSession, user_id: uuid.UUID
) -> list[ReviewSchedule]:
    now = datetime.now(UTC)
    result = await session.execute(
        select(ReviewSchedule)
        .where(ReviewSchedule.user_id == user_id, ReviewSchedule.next_review_at <= now)
        .order_by(ReviewSchedule.next_review_at)
    )
    return list(result.scalars().all())


async def record_review_result(
    session: AsyncSession, sched: ReviewSchedule, quality: int
) -> ReviewSchedule:
    """SM-2 simplified: quality 0-5."""
    if quality < 3:
        sched.repetitions = 0
        sched.interval_days = 1.0
    else:
        if sched.repetitions == 0:
            sched.interval_days = 1.0
        elif sched.repetitions == 1:
            sched.interval_days = 3.0
        else:
            sched.interval_days = round(sched.interval_days * sched.ease_factor, 1)
        sched.repetitions += 1
        sched.ease_factor = max(
            1.3, sched.ease_factor + 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02)
        )
    sched.next_review_at = datetime.now(UTC) + timedelta(days=sched.interval_days)
    await session.commit()
    await session.refresh(sched)
    return sched


# --- Node/edge mutations -----------------------------------------------------


async def delete_node(session: AsyncSession, node_id: uuid.UUID) -> bool:
    """Hard-delete a node and ALL data linked to it.

    Cleanup order (node is the source of truth):
    1. Detach SpeakerProfiles that referenced this node (keep profile; clear identity link)
    2. Delete Quizzes sourced from this node (source_nodes ARRAY has no FK)
    3. Delete all Edges connected to this node (CASCADE would handle, but explicit for clarity)
    4. Delete the Node itself (JournalGraphLinks cascade via DB FK)
    """
    from .node_expression_store import delete_node_all_expressions

    node = await session.get(Node, node_id)
    if node is None:
        return False

    user_id = node.user_id

    # 1. Detach SpeakerProfile identity link — profile itself survives (voice memory),
    #    but the confirmed human identity (node_id + display_name) is wiped.
    await session.execute(
        update(SpeakerProfile)
        .where(SpeakerProfile.node_id == node_id)
        .values(node_id=None, display_name=None)
    )

    # 2. Delete Quizzes referencing this node (ARRAY column, no DB FK possible)
    if user_id is not None:
        quiz_rows = await session.execute(
            select(Quiz).where(Quiz.user_id == user_id)
        )
        for quiz in quiz_rows.scalars().all():
            if any(sn == node_id for sn in (quiz.source_nodes or [])):
                await session.delete(quiz)

    # 3. Delete edges (also handled by ondelete=CASCADE on Edge FK, but explicit)
    await session.execute(
        delete(Edge).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )

    # 4. Delete node (JournalGraphLinks cascade via DB FK ondelete=CASCADE)
    await session.delete(node)
    await session.commit()

    # 5. Delete Redis/vector expression store entries for this node
    if user_id is not None:
        await delete_node_all_expressions(user_id, str(node_id))

    return True


async def soft_delete_statement_cascade(
    session: AsyncSession,
    node_id: uuid.UUID,
    user_id: uuid.UUID,
) -> dict:
    """Soft-delete a Statement node.

    Strategy:
    - Snapshot the full data of orphan neighbor nodes and all edges into deleted_context.
    - Hard-delete orphan nodes and all connected edges (clean removal from graph).
    - Soft-delete only the Statement node itself (stays in trash for restore).
    - Delete associated quizzes and language expressions.
    """
    from .node_expression_store import delete_node_all_expressions

    node = await session.get(Node, node_id)
    if node is None:
        return {}

    now = datetime.now(UTC)

    # ── 1. Snapshot all edges connected to this Statement ──────────────────────
    edge_rows = await session.execute(
        select(Edge).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )
    edges_raw = list(edge_rows.scalars().all())
    edges_snapshot = [
        {
            "source_id": str(e.source_id),
            "target_id": str(e.target_id),
            "relation": e.relation,
            "weight": e.weight,
            "user_id": str(e.user_id) if e.user_id else None,
        }
        for e in edges_raw
    ]

    neighbor_ids: set[uuid.UUID] = {
        (e.target_id if e.source_id == node_id else e.source_id)
        for e in edges_raw
    }

    # ── 2. Hard-delete all edges of this Statement ─────────────────────────────
    await session.execute(
        delete(Edge).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )
    await session.flush()

    # ── 3. Find orphan neighbors (no remaining edges after above deletion) ─────
    orphan_nodes_snapshot: list[dict] = []
    for nid in neighbor_ids:
        remaining = await session.execute(
            select(Edge).where(
                or_(Edge.source_id == nid, Edge.target_id == nid)
            ).limit(1)
        )
        if remaining.first() is not None:
            continue  # still connected to other nodes — leave it
        orphan = await session.get(Node, nid)
        if orphan is None:
            continue
        # Snapshot full node data before hard-deleting
        orphan_nodes_snapshot.append({
            "id": str(orphan.id),
            "name": orphan.name,
            "type": orphan.type,
            "description": orphan.description,
            "user_id": str(orphan.user_id) if orphan.user_id else None,
        })
        # Detach SpeakerProfile identity link before deleting orphan node
        await session.execute(
            update(SpeakerProfile)
            .where(SpeakerProfile.node_id == nid)
            .values(node_id=None, display_name=None)
        )
        await session.delete(orphan)

    await session.flush()

    # ── 4. Delete quizzes sourced from this Statement ──────────────────────────
    quiz_rows = await session.execute(
        select(Quiz).where(Quiz.user_id == user_id)
    )
    quiz_ids: list[str] = []
    for quiz in quiz_rows.scalars().all():
        if any(sn == node_id for sn in (quiz.source_nodes or [])):
            quiz_ids.append(str(quiz.id))
            await session.delete(quiz)

    # ── 5. Clear speaker profile links for this node ──────────────────────────
    await session.execute(
        update(SpeakerProfile)
        .where(SpeakerProfile.node_id == node_id)
        .values(node_id=None, display_name=None)
    )

    # ── 6. Soft-delete the Statement itself with full snapshot ─────────────────
    node.deleted_at = now
    node.deleted_context = {
        "orphan_nodes": orphan_nodes_snapshot,   # full node data for recreation
        "edges": edges_snapshot,                  # full edge data for recreation
        "quiz_ids": quiz_ids,
    }

    await session.commit()

    expr_count = await delete_node_all_expressions(user_id, str(node_id))

    return {
        "deleted_node_id": str(node_id),
        "orphan_nodes_deleted": len(orphan_nodes_snapshot),
        "quizzes_deleted": len(quiz_ids),
        "expressions_deleted": expr_count,
    }


async def restore_statement_from_trash(
    session: AsyncSession,
    node_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    """Restore a soft-deleted Statement: recreate orphan nodes and edges from snapshot."""
    node = await session.get(Node, node_id)
    if node is None or node.deleted_at is None:
        return False

    ctx = node.deleted_context or {}
    orphan_nodes_data = ctx.get("orphan_nodes") or []
    edges_data = ctx.get("edges") or []

    # ── 1. Restore the Statement itself first ──────────────────────────────────
    node.deleted_at = None
    node.deleted_context = None
    await session.flush()

    # ── 2. Recreate orphan nodes with NEW UUIDs ────────────────────────────────
    # Map old_id → new_id so we can fix up edge references
    old_to_new: dict[str, uuid.UUID] = {}
    for n_data in orphan_nodes_data:
        old_id = n_data["id"]
        new_id = uuid.uuid4()
        old_to_new[old_id] = new_id
        uid_str = n_data.get("user_id")
        new_node = Node(
            id=new_id,
            name=n_data["name"],
            type=n_data["type"],
            description=n_data.get("description"),
            user_id=uuid.UUID(uid_str) if uid_str else None,
        )
        session.add(new_node)

    await session.flush()

    # ── 3. Recreate edges, remapping old orphan IDs to new IDs ────────────────
    stmt_id_str = str(node_id)
    for e_data in edges_data:
        src_str = e_data["source_id"]
        tgt_str = e_data["target_id"]
        # Remap orphan node references to their new UUIDs
        src = old_to_new.get(src_str, uuid.UUID(src_str))
        tgt = old_to_new.get(tgt_str, uuid.UUID(tgt_str))

        # Verify both endpoints exist
        src_node = await session.get(Node, src)
        tgt_node = await session.get(Node, tgt)
        if src_node is None or tgt_node is None:
            continue

        # Skip duplicates
        existing = await session.execute(
            select(Edge).where(
                Edge.source_id == src,
                Edge.target_id == tgt,
                Edge.relation == e_data["relation"],
            ).limit(1)
        )
        if existing.first() is not None:
            continue

        uid_str = e_data.get("user_id")
        session.add(Edge(
            source_id=src,
            target_id=tgt,
            relation=e_data["relation"],
            weight=e_data.get("weight", 1),
            user_id=uuid.UUID(uid_str) if uid_str else None,
        ))

    await session.commit()
    return True


async def get_trash_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
) -> list[Node]:
    """Return all soft-deleted Statement nodes for a user (newest first)."""
    result = await session.execute(
        select(Node).where(
            Node.user_id == user_id,
            Node.deleted_at.is_not(None),
            Node.type == "Statement",
        ).order_by(Node.deleted_at.desc())
    )
    return list(result.scalars().all())


async def purge_trash_node(
    session: AsyncSession,
    node_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    """Permanently delete a soft-deleted Statement node.
    Orphan nodes were already hard-deleted at soft-delete time, so only the
    Statement itself remains to be purged.
    """
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user_id:
        return False
    await session.delete(node)
    await session.commit()
    return True


async def delete_statement_cascade(
    session: AsyncSession,
    node_id: uuid.UUID,
    user_id: uuid.UUID,
) -> dict:
    """Delete a Statement node and cascade:
    - Orphaned Speaker/Concept nodes (connected only to this Statement)
    - Quizzes sourced from this Statement
    - Extracted language expressions for this Statement

    Returns a summary dict of deleted counts.
    """
    from .node_expression_store import delete_node_all_expressions

    node = await session.get(Node, node_id)
    if node is None:
        return {}

    # Find all nodes directly connected to this Statement via edges
    neighbor_rows = await session.execute(
        select(Edge).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )
    edges = list(neighbor_rows.scalars().all())
    neighbor_ids: set[uuid.UUID] = set()
    for e in edges:
        other = e.target_id if e.source_id == node_id else e.source_id
        neighbor_ids.add(other)

    # Delete edges connected to this Statement
    await session.execute(
        delete(Edge).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )
    await session.flush()

    # Identify orphaned neighbors (no remaining edges after removing this Statement)
    orphan_node_ids: list[uuid.UUID] = []
    for nid in neighbor_ids:
        remaining = await session.execute(
            select(Edge).where(
                or_(Edge.source_id == nid, Edge.target_id == nid)
            ).limit(1)
        )
        if remaining.first() is None:
            orphan_node_ids.append(nid)

    # Delete orphaned neighbor nodes (Concept, Speaker that have no other connections)
    for nid in orphan_node_ids:
        orphan = await session.get(Node, nid)
        if orphan is not None:
            await session.delete(orphan)

    # Delete quizzes that were generated from this Statement node
    quiz_result = await session.execute(
        select(Quiz).where(Quiz.user_id == user_id)
    )
    quizzes = list(quiz_result.scalars().all())
    deleted_quiz_count = 0
    for quiz in quizzes:
        source_nodes = quiz.source_nodes or []
        if any(sn == node_id for sn in source_nodes):
            await session.delete(quiz)
            deleted_quiz_count += 1

    # Delete the Statement node itself
    await session.delete(node)
    await session.commit()

    # Delete language expressions from file store
    expr_count = await delete_node_all_expressions(user_id, str(node_id))

    return {
        "deleted_node_id": node_id_str,
        "orphan_nodes_deleted": len(orphan_node_ids),
        "quizzes_deleted": deleted_quiz_count,
        "expressions_deleted": expr_count,
    }


async def update_node(
    session: AsyncSession,
    node_id: uuid.UUID,
    name: str | None,
    type_: str | None,
    description: str | None,
) -> Node | None:
    node = await session.get(Node, node_id)
    if node is None:
        return None
    if name is not None:
        node.name = name.strip()
    if type_ is not None:
        node.type = normalize_entity_type(type_)
    if description is not None:
        node.description = description
    await session.commit()
    await session.refresh(node)
    return node


async def create_edge(
    session: AsyncSession,
    source_id: uuid.UUID,
    target_id: uuid.UUID,
    relation: str,
    user_id: uuid.UUID | None = None,
) -> Edge | None:
    source = await session.get(Node, source_id)
    target = await session.get(Node, target_id)
    if source is None or target is None:
        return None

    existing = await session.execute(
        select(Edge).where(
            Edge.source_id == source_id,
            Edge.target_id == target_id,
            Edge.relation == relation,
        )
    )
    edge = existing.scalar_one_or_none()
    if edge is not None:
        return edge

    edge = Edge(source_id=source_id, target_id=target_id, relation=relation, user_id=user_id)
    session.add(edge)
    await session.commit()
    await session.refresh(edge)
    return edge


async def update_edge(
    session: AsyncSession,
    edge_id: uuid.UUID,
    relation: str | None = None,
    source_id: uuid.UUID | None = None,
    target_id: uuid.UUID | None = None,
) -> Edge | None:
    edge = await session.get(Edge, edge_id)
    if edge is None:
        return None

    new_source = source_id if source_id is not None else edge.source_id
    new_target = target_id if target_id is not None else edge.target_id
    new_relation = relation.strip() if relation is not None else edge.relation

    if new_source == new_target:
        return None

    if source_id is not None and await session.get(Node, source_id) is None:
        return None
    if target_id is not None and await session.get(Node, target_id) is None:
        return None

    duplicate = await session.execute(
        select(Edge).where(
            Edge.source_id == new_source,
            Edge.target_id == new_target,
            Edge.relation == new_relation,
            Edge.id != edge_id,
        )
    )
    dup = duplicate.scalar_one_or_none()
    if dup is not None:
        await session.delete(edge)
        await session.commit()
        return dup

    edge.source_id = new_source
    edge.target_id = new_target
    edge.relation = new_relation
    await session.commit()
    await session.refresh(edge)
    return edge


async def delete_edge(session: AsyncSession, edge_id: uuid.UUID) -> bool:
    edge = await session.get(Edge, edge_id)
    if edge is None:
        return False
    await session.delete(edge)
    await session.commit()
    return True


async def clear_user_knowledge_graph(
    session: AsyncSession, user_id: uuid.UUID
) -> dict[str, int]:
    """Delete all nodes, edges, RAG chunks, and graph links for a user."""
    edge_count = await session.scalar(
        select(func.count()).select_from(Edge).where(Edge.user_id == user_id)
    )
    node_count = await session.scalar(
        select(func.count()).select_from(Node).where(Node.user_id == user_id)
    )
    chunk_count = await session.scalar(
        select(func.count()).select_from(Chunk).where(Chunk.user_id == user_id)
    )

    entry_ids = select(JournalEntry.id).where(JournalEntry.user_id == user_id)
    await session.execute(
        delete(JournalGraphLink).where(JournalGraphLink.journal_entry_id.in_(entry_ids))
    )
    await session.execute(delete(Chunk).where(Chunk.user_id == user_id))
    await session.execute(delete(Edge).where(Edge.user_id == user_id))
    await session.execute(delete(Node).where(Node.user_id == user_id))

    voice_stats = await unlink_speakers_from_graph(session, user_id)

    entries = await session.execute(
        select(JournalEntry).where(JournalEntry.user_id == user_id)
    )
    for entry in entries.scalars():
        if entry.status == "graph_processing":
            entry.status = "ready" if entry.translation_en else "ready_no_graph"
        elif entry.status in ("graph_staging_ready", "graph_ready", "completed"):
            entry.status = "ready" if entry.translation_en else "ready_no_graph"
        entry.graph_job_id = None
        entry.graph_build_requested_at = None
        entry.graph_staging = None

    await session.commit()
    return {
        "nodes_deleted": int(node_count or 0),
        "edges_deleted": int(edge_count or 0),
        "chunks_deleted": int(chunk_count or 0),
        **voice_stats,
    }


# --- Ontology ----------------------------------------------------------------


async def get_ontology(session: AsyncSession) -> Ontology | None:
    return await session.get(Ontology, 1)


async def _next_ontology_version_number(session: AsyncSession) -> int:
    result = await session.execute(
        select(OntologyVersion.version_number)
        .order_by(OntologyVersion.version_number.desc())
        .limit(1)
    )
    latest = result.scalar_one_or_none()
    return (latest or 0) + 1


async def create_ontology_version(
    session: AsyncSession,
    entity_types: list[dict],
    relation_types: list[str],
    note: str | None = None,
    ontology_name: str | None = None,
) -> OntologyVersion:
    version = OntologyVersion(
        version_number=await _next_ontology_version_number(session),
        ontology_name=ontology_name.strip() if ontology_name and ontology_name.strip() else None,
        note=note.strip() if note and note.strip() else None,
        entity_types=entity_types,
        relation_types=relation_types,
    )
    session.add(version)
    await session.flush()
    return version


async def ensure_journal_ontology(
    session: AsyncSession,
    entity_types: list[dict],
    relation_types: list[str],
    ontology_name: str,
) -> Ontology:
    """Apply ontology only when name differs — avoids version churn per journal."""
    ontology = await session.get(Ontology, 1)
    if ontology and ontology.name == ontology_name:
        return ontology
    return await save_ontology(
        session,
        entity_types=entity_types,
        relation_types=relation_types,
        ontology_name=ontology_name,
        note="Auto-applied for journal processing",
    )


async def save_ontology(
    session: AsyncSession,
    entity_types: list[dict],
    relation_types: list[str],
    note: str | None = None,
    ontology_name: str | None = None,
) -> Ontology:
    ontology = await session.get(Ontology, 1)
    if ontology is None:
        ontology = Ontology(
            id=1,
            name=ontology_name,
            entity_types=entity_types,
            relation_types=relation_types,
        )
        session.add(ontology)
    else:
        ontology.entity_types = entity_types
        ontology.relation_types = relation_types
        if ontology_name:
            ontology.name = ontology_name
    await create_ontology_version(
        session,
        entity_types,
        relation_types,
        note,
        ontology_name=ontology_name or (ontology.name if ontology else None),
    )
    await session.commit()
    await session.refresh(ontology)
    return ontology


async def list_ontology_versions(session: AsyncSession) -> list[OntologyVersion]:
    result = await session.execute(
        select(OntologyVersion).order_by(OntologyVersion.version_number.desc())
    )
    return list(result.scalars().all())


async def get_ontology_version(
    session: AsyncSession, version_id: int
) -> OntologyVersion | None:
    return await session.get(OntologyVersion, version_id)


async def restore_ontology_version(
    session: AsyncSession, version_id: int
) -> Ontology | None:
    version = await session.get(OntologyVersion, version_id)
    if version is None:
        return None
    note = f"Restored from v{version.version_number}"
    return await save_ontology(
        session,
        entity_types=list(version.entity_types),
        relation_types=list(version.relation_types),
        note=note,
        ontology_name=version.ontology_name,
    )


async def apply_ontology_preset(
    session: AsyncSession, preset_name: str
) -> Ontology | None:
    from .ontology_presets import ONTOLOGY_PRESETS

    preset = ONTOLOGY_PRESETS.get(preset_name)
    if preset is None:
        return None
    return await save_ontology(
        session,
        entity_types=list(preset["entity_types"]),
        relation_types=list(preset["relation_types"]),
        ontology_name=preset["ontology_name"],
        note=f"Applied preset: {preset['ontology_name']}",
    )


# --- Speaker profiles --------------------------------------------------------


async def list_speaker_profiles(
    session: AsyncSession, user_id: uuid.UUID
) -> list[SpeakerProfile]:
    result = await session.execute(
        select(SpeakerProfile)
        .where(SpeakerProfile.user_id == user_id)
        .order_by(SpeakerProfile.created_at)
    )
    return list(result.scalars().all())


async def create_speaker_profile(
    session: AsyncSession,
    user_id: uuid.UUID,
    label: str,
    embedding: list[float] | None = None,
    duration_sec: float = 0.0,
    last_entry_id: uuid.UUID | None = None,
) -> SpeakerProfile:
    profile = SpeakerProfile(
        user_id=user_id,
        label=label,
        embedding=embedding,
        sample_count=1,
        total_duration_sec=duration_sec,
        last_entry_id=last_entry_id,
    )
    session.add(profile)
    await session.commit()
    await session.refresh(profile)
    return profile


async def update_speaker_profile_embedding(
    session: AsyncSession,
    profile: SpeakerProfile,
    new_embedding: list[float],
    duration_sec: float = 0.0,
    last_entry_id: uuid.UUID | None = None,
) -> SpeakerProfile:
    old_raw = profile.embedding
    old = list(old_raw) if old_raw is not None else list(new_embedding)
    n = profile.sample_count
    merged = [
        (old[i] * n + new_embedding[i]) / (n + 1) for i in range(len(new_embedding))
    ]
    norm = sum(x * x for x in merged) ** 0.5
    if norm > 0:
        merged = [x / norm for x in merged]
    profile.embedding = merged
    profile.sample_count = n + 1
    profile.total_duration_sec += duration_sec
    if last_entry_id is not None:
        profile.last_entry_id = last_entry_id
    await session.commit()
    await session.refresh(profile)
    return profile


async def link_speaker_profile_to_node(
    session: AsyncSession,
    profile: SpeakerProfile,
    node_id: uuid.UUID,
    display_name: str | None = None,
    overwrite_display_name: bool = False,
    *,
    commit: bool = True,
) -> SpeakerProfile:
    profile.node_id = node_id
    if display_name:
        if overwrite_display_name or not profile.display_name:
            profile.display_name = display_name
        profile.label = display_name
    if commit:
        await session.commit()
        await session.refresh(profile)
    else:
        await session.flush()
    return profile


async def assign_exclusive_voice_profile_to_node(
    session: AsyncSession,
    user_id: uuid.UUID,
    profile: SpeakerProfile,
    node: Node,
    *,
    display_name: str | None = None,
) -> SpeakerProfile:
    """Bidirectional voice link; detach any other profile from the same Speaker node."""
    label = (display_name or node.name or profile.display_name or profile.label or "").strip()
    if not label:
        label = node.name

    others = await session.execute(
        select(SpeakerProfile).where(
            SpeakerProfile.user_id == user_id,
            SpeakerProfile.node_id == node.id,
            SpeakerProfile.id != profile.id,
        )
    )
    for other in others.scalars():
        other.node_id = None

    if node.speaker_profile_id and node.speaker_profile_id != profile.id:
        previous = await session.get(SpeakerProfile, node.speaker_profile_id)
        if previous is not None:
            previous.node_id = None

    profile.node_id = node.id
    profile.display_name = label
    profile.label = label
    node.speaker_profile_id = profile.id
    await session.flush()
    return profile


async def unlink_voice_from_node(
    session: AsyncSession,
    user_id: uuid.UUID,
    node_id: uuid.UUID,
    *,
    clear_embedding: bool = True,
) -> Node | None:
    """Detach voice profile(s) from a graph Speaker node; optionally wipe embeddings."""
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user_id:
        return None

    linked_profiles: list[SpeakerProfile] = []
    if node.speaker_profile_id is not None:
        profile = await session.get(SpeakerProfile, node.speaker_profile_id)
        if profile is not None and profile.user_id == user_id:
            linked_profiles.append(profile)

    for profile in await list_speaker_profiles(session, user_id):
        if profile.node_id == node_id and profile not in linked_profiles:
            linked_profiles.append(profile)

    node.speaker_profile_id = None
    for profile in linked_profiles:
        profile.node_id = None
        if clear_embedding:
            profile.embedding = None
            profile.sample_count = 0
            profile.total_duration_sec = 0.0

    await session.commit()
    await session.refresh(node)
    return node


async def get_speaker_profile(
    session: AsyncSession, profile_id: uuid.UUID, user_id: uuid.UUID
) -> SpeakerProfile | None:
    profile = await session.get(SpeakerProfile, profile_id)
    if profile is None or profile.user_id != user_id:
        return None
    return profile


async def get_speaker_appearance_for_label(
    session: AsyncSession, entry_id: uuid.UUID, session_label: str
) -> SpeakerEntryAppearance | None:
    result = await session.execute(
        select(SpeakerEntryAppearance).where(
            SpeakerEntryAppearance.journal_entry_id == entry_id,
            SpeakerEntryAppearance.session_label == session_label,
        )
    )
    return result.scalar_one_or_none()


async def find_similar_speaker_profile_by_embedding(
    session: AsyncSession,
    user_id: uuid.UUID,
    embedding: list[float],
    max_distance: float = 0.3,
    require_linked_node: bool = True,
    exclude_profile_id: uuid.UUID | None = None,
) -> tuple[SpeakerProfile, float] | None:
    """Return closest speaker profile within cosine distance threshold."""
    matches = await find_similar_speaker_profiles_by_embedding(
        session,
        user_id,
        embedding,
        max_distance=max_distance,
        require_linked_node=require_linked_node,
        exclude_profile_id=exclude_profile_id,
        limit=1,
    )
    return matches[0] if matches else None


async def find_similar_speaker_profiles_by_embedding(
    session: AsyncSession,
    user_id: uuid.UUID,
    embedding: list[float],
    max_distance: float = 0.3,
    require_linked_node: bool = True,
    exclude_profile_id: uuid.UUID | None = None,
    limit: int = 5,
) -> list[tuple[SpeakerProfile, float]]:
    """Return speaker profiles ordered by voice cosine distance (ascending)."""
    dist_col = SpeakerProfile.embedding.cosine_distance(embedding).label("dist")
    filters = [
        SpeakerProfile.user_id == user_id,
        SpeakerProfile.embedding.isnot(None),
        dist_col <= max_distance,
    ]
    if require_linked_node:
        filters.append(SpeakerProfile.node_id.isnot(None))
    if exclude_profile_id is not None:
        filters.append(SpeakerProfile.id != exclude_profile_id)

    result = await session.execute(
        select(SpeakerProfile, dist_col)
        .where(*filters)
        .order_by(dist_col)
        .limit(limit)
    )
    return [(row[0], float(row[1])) for row in result.all()]


async def list_person_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
    limit: int = 100,
) -> list[Node]:
    """Speaker/Person-like graph nodes for voice identity picker."""
    result = await session.execute(
        select(Node)
        .where(Node.user_id == user_id)
        .order_by(Node.name)
        .limit(limit * 3)
    )
    speaker_type = normalize_entity_type(NODE_SPEAKER)
    by_name: dict[str, Node] = {}
    for node in result.scalars().all():
        if not is_person_like_type(node.type):
            continue
        key = (node.name or "").strip().lower()
        if not key:
            continue
        existing = by_name.get(key)
        if existing is None:
            by_name[key] = node
            continue
        if normalize_entity_type(node.type) == speaker_type:
            by_name[key] = node
    nodes = sorted(by_name.values(), key=lambda n: (n.name or "").lower())
    return nodes[:limit]


async def _voiced_person_names(
    session: AsyncSession, user_id: uuid.UUID
) -> set[str]:
    """Lowercased names that already have a human-confirmed voice link on a Speaker node."""
    nodes = await get_all_nodes(session, user_id=user_id)
    profiles = await _speaker_profiles_for_nodes(session, nodes)
    names: set[str] = set()
    for node in nodes:
        profile = profiles.get(node.id)
        if profile is None or not is_person_like_type(node.type):
            continue
        name = (node.name or "").strip()
        if name:
            names.add(name.lower())
    return names


async def list_person_nodes_for_speaker_picker(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    exclude_node_ids: set[uuid.UUID] | None = None,
    limit: int = 100,
) -> list[Node]:
    """Speaker/Person-like nodes without voice embedding — for linking a new identity."""
    nodes = await list_person_nodes(session, user_id, limit=limit * 2)
    if not nodes:
        return []

    profiles = await _speaker_profiles_for_nodes(session, nodes)
    voiced_names = await _voiced_person_names(session, user_id)
    excluded = exclude_node_ids or set()

    picked: list[Node] = []
    speaker_type = normalize_entity_type(NODE_SPEAKER)
    for node in nodes:
        if node.id in excluded:
            continue
        if normalize_entity_type(node.type) == speaker_type:
            picked.append(node)
            if len(picked) >= limit:
                break
            continue
        profile = profiles.get(node.id)
        if profile is not None and profile.embedding is not None:
            continue
        name_key = (node.name or "").strip().lower()
        if name_key and name_key in voiced_names:
            continue
        picked.append(node)
        if len(picked) >= limit:
            break
    return picked


async def get_or_create_speaker_node(
    session: AsyncSession,
    user_id: uuid.UUID,
    name: str,
    node_type: str | None = None,
) -> Node:
    """Find an existing node by name or create one with an open-domain type."""
    name = name.strip()
    if not name:
        raise ValueError("name is required")
    result = await session.execute(
        select(Node).where(Node.user_id == user_id, Node.name == name)
    )
    existing = list(result.scalars().all())
    if existing:
        speaker_type = normalize_entity_type(NODE_SPEAKER)
        person_type = normalize_entity_type("Person")
        for node in existing:
            nt = normalize_entity_type(node.type)
            if nt == speaker_type or nt == person_type:
                return node
        return existing[0]
    return await _get_or_create_node(
        session, name, node_type or NODE_SPEAKER, user_id=user_id
    )


async def get_or_create_person_node(
    session: AsyncSession,
    user_id: uuid.UUID,
    name: str,
) -> Node:
    return await get_or_create_speaker_node(session, user_id, name, node_type=NODE_SPEAKER)


# --- Semantic Chunk graph (2안) ----------------------------------------------


async def upsert_typed_node(
    session: AsyncSession,
    user_id: uuid.UUID,
    name: str,
    type_: str,
    description: str | None = None,
) -> Node:
    return await _get_or_create_node(
        session, name, type_, description, user_id=user_id
    )


async def upsert_relation_edge(
    session: AsyncSession,
    user_id: uuid.UUID,
    source_id: uuid.UUID,
    target_id: uuid.UUID,
    relation: str,
) -> Edge:
    return await upsert_weighted_edge(
        session, user_id, source_id, target_id, relation
    )


async def link_next_turn(
    session: AsyncSession,
    user_id: uuid.UUID,
    from_chunk_id: uuid.UUID,
    to_chunk_id: uuid.UUID,
) -> Edge:
    return await upsert_relation_edge(
        session, user_id, from_chunk_id, to_chunk_id, REL_NEXT_TURN
    )


async def link_spoke_by(
    session: AsyncSession,
    user_id: uuid.UUID,
    chunk_id: uuid.UUID,
    speaker_id: uuid.UUID,
) -> Edge:
    return await upsert_relation_edge(
        session, user_id, chunk_id, speaker_id, REL_SPOKE_BY
    )


async def resolve_speaker_for_chunk(
    session: AsyncSession, chunk_id: uuid.UUID
) -> Node | None:
    result = await session.execute(
        select(Node)
        .join(Edge, Edge.target_id == Node.id)
        .where(
            Edge.source_id == chunk_id,
            Edge.relation == REL_SPOKE_BY,
        )
    )
    return result.scalar_one_or_none()


async def find_anchor_chunks_for_vocab(
    session: AsyncSession,
    user_id: uuid.UUID,
    vocab_id: uuid.UUID,
    lang: str = "EN",
) -> list[Node]:
    rel = contains_relation(lang)
    result = await session.execute(
        select(Node)
        .join(Edge, Edge.source_id == Node.id)
        .where(
            Edge.target_id == vocab_id,
            Edge.relation == rel,
            Node.user_id == user_id,
            func.lower(Node.type) == type_group_key(NODE_CHUNK),
        )
        .order_by(Node.created_at.desc())
    )
    return list(result.scalars().all())


async def _next_turn_neighbor(
    session: AsyncSession,
    chunk_id: uuid.UUID,
    *,
    forward: bool,
) -> Node | None:
    if forward:
        q = (
            select(Node)
            .join(Edge, Edge.target_id == Node.id)
            .where(Edge.source_id == chunk_id, Edge.relation == REL_NEXT_TURN)
        )
    else:
        q = (
            select(Node)
            .join(Edge, Edge.source_id == Node.id)
            .where(Edge.target_id == chunk_id, Edge.relation == REL_NEXT_TURN)
        )
    result = await session.execute(q)
    return result.scalar_one_or_none()


async def traverse_chunk_chain(
    session: AsyncSession,
    chunk_id: uuid.UUID,
    *,
    before: int = 2,
    after: int = 2,
) -> tuple[list[Node], Node, list[Node]]:
    """Return (context_before, anchor, context_after) via NEXT_TURN chain."""
    anchor = await session.get(Node, chunk_id)
    if anchor is None:
        raise ValueError("chunk not found")

    ctx_before: list[Node] = []
    cursor = anchor
    for _ in range(before):
        prev = await _next_turn_neighbor(session, cursor.id, forward=False)
        if prev is None:
            break
        ctx_before.insert(0, prev)
        cursor = prev

    ctx_after: list[Node] = []
    cursor = anchor
    for _ in range(after):
        nxt = await _next_turn_neighbor(session, cursor.id, forward=True)
        if nxt is None:
            break
        ctx_after.append(nxt)
        cursor = nxt

    return ctx_before, anchor, ctx_after


async def create_chunk_nodes_embeddings_batch(
    session: AsyncSession,
    user_id: uuid.UUID,
    items: list[tuple[str, uuid.UUID | None, list[float] | None]],
) -> int:
    """Insert RAG chunks without per-row commit (caller commits)."""
    if not items:
        return 0
    for text, journal_entry_id, embedding in items:
        session.add(
            Chunk(
                user_id=user_id,
                text=text,
                journal_entry_id=journal_entry_id,
                embedding=embedding,
            )
        )
    await session.flush()
    return len(items)


async def find_nodes_by_name(
    session: AsyncSession,
    user_id: uuid.UUID,
    name: str,
    exclude_id: uuid.UUID | None = None,
) -> list[Node]:
    name = name.strip()
    if not name:
        return []
    q = select(Node).where(
        Node.user_id == user_id,
        Node.name == name,
        Node.deleted_at.is_(None),  # exclude soft-deleted nodes
    )
    if exclude_id is not None:
        q = q.where(Node.id != exclude_id)
    result = await session.execute(q)
    return list(result.scalars().all())


async def find_person_nodes_by_name(
    session: AsyncSession,
    user_id: uuid.UUID,
    name: str,
    exclude_id: uuid.UUID | None = None,
) -> list[Node]:
    return await find_nodes_by_name(session, user_id, name, exclude_id=exclude_id)


async def merge_node_into(
    session: AsyncSession,
    user_id: uuid.UUID,
    source_id: uuid.UUID,
    target_id: uuid.UUID,
) -> int:
    """Reassign edges from duplicate node to confirmed node; delete source."""
    if source_id == target_id:
        return 0

    source = await session.get(Node, source_id)
    target = await session.get(Node, target_id)
    if source is None or target is None:
        return 0
    if source.user_id != user_id or target.user_id != user_id:
        return 0

    reassigned = 0
    result = await session.execute(
        select(Edge).where(
            Edge.user_id == user_id,
            or_(Edge.source_id == source_id, Edge.target_id == source_id),
        )
    )
    for edge in result.scalars().all():
        new_source = target_id if edge.source_id == source_id else edge.source_id
        new_target = target_id if edge.target_id == source_id else edge.target_id
        if new_source == new_target:
            await session.delete(edge)
            reassigned += 1
            continue

        conflict = await session.execute(
            select(Edge).where(
                Edge.source_id == new_source,
                Edge.target_id == new_target,
                Edge.relation == edge.relation,
                Edge.id != edge.id,
            )
        )
        existing = conflict.scalar_one_or_none()
        if existing is not None:
            existing.weight = (existing.weight or 1) + (edge.weight or 1)
            await session.delete(edge)
        else:
            edge.source_id = new_source
            edge.target_id = new_target
        reassigned += 1

    await session.delete(source)
    await session.flush()
    return reassigned


async def merge_person_node_into(
    session: AsyncSession,
    user_id: uuid.UUID,
    source_id: uuid.UUID,
    target_id: uuid.UUID,
) -> int:
    return await merge_node_into(session, user_id, source_id, target_id)


async def set_node_speaker_profile(
    session: AsyncSession, node: Node, speaker_profile_id: uuid.UUID
) -> None:
    node.speaker_profile_id = speaker_profile_id
    await session.flush()


async def record_speaker_entry_appearance(
    session: AsyncSession,
    entry_id: uuid.UUID,
    profile_id: uuid.UUID,
    session_label: str,
    match_score: float,
    duration_sec: float,
) -> SpeakerEntryAppearance:
    result = await session.execute(
        select(SpeakerEntryAppearance).where(
            SpeakerEntryAppearance.journal_entry_id == entry_id,
            SpeakerEntryAppearance.session_label == session_label,
        )
    )
    row = result.scalar_one_or_none()
    if row is None:
        row = SpeakerEntryAppearance(
            journal_entry_id=entry_id,
            speaker_profile_id=profile_id,
            session_label=session_label,
            match_score=match_score,
            duration_sec=duration_sec,
        )
        session.add(row)
    else:
        row.speaker_profile_id = profile_id
        row.match_score = match_score
        row.duration_sec = duration_sec
    await session.commit()
    await session.refresh(row)
    return row


async def list_speaker_appearances_for_entry(
    session: AsyncSession, entry_id: uuid.UUID
) -> list[SpeakerEntryAppearance]:
    result = await session.execute(
        select(SpeakerEntryAppearance).where(
            SpeakerEntryAppearance.journal_entry_id == entry_id
        )
    )
    return list(result.scalars().all())


async def get_nodes_by_ids(
    session: AsyncSession,
    node_ids: list[uuid.UUID],
    user_id: uuid.UUID | None = None,
) -> list[Node]:
    if not node_ids:
        return []
    q = select(Node).where(Node.id.in_(node_ids))
    if user_id is not None:
        q = q.where(Node.user_id == user_id)
    result = await session.execute(q)
    return list(result.scalars().all())


# --- Quiz (gamified MVP) -----------------------------------------------------


def quiz_to_dict(quiz: Quiz) -> dict:
    return {
        "id": str(quiz.id),
        "quiz_type": quiz.quiz_type,
        "difficulty_level": quiz.difficulty_level,
        "queue_kind": quiz.queue_kind,
        "question_ko": quiz.question_ko,
        "sentence_en": quiz.sentence_en,
        "quiz_data": quiz.quiz_data,
        "repetitions": quiz.repetitions,
        "next_review_at": quiz.next_review_at.isoformat() if quiz.next_review_at else None,
    }


async def create_quiz(
    session: AsyncSession,
    *,
    user_id: uuid.UUID,
    quiz_type: str,
    associated_entry_id: uuid.UUID | None = None,
    question_ko: str | None = None,
    sentence_en: str | None = None,
    quiz_data: dict | None = None,
    difficulty_level: int = 10,
    queue_kind: str = "new",
    source_nodes: list[uuid.UUID] | None = None,
    pipeline_trace: dict | None = None,
    debug_run_dir: str | None = None,
) -> Quiz:
    quiz = Quiz(
        user_id=user_id,
        associated_entry_id=associated_entry_id,
        quiz_type=quiz_type,
        source_nodes=source_nodes,
        question_ko=question_ko,
        sentence_en=sentence_en,
        quiz_data=quiz_data,
        difficulty_level=difficulty_level,
        queue_kind=queue_kind,
        pipeline_trace=pipeline_trace,
        debug_run_dir=debug_run_dir,
    )
    session.add(quiz)
    await session.commit()
    await session.refresh(quiz)
    return quiz


async def get_quiz(
    session: AsyncSession, quiz_id: uuid.UUID, user_id: uuid.UUID
) -> Quiz | None:
    quiz = await session.get(Quiz, quiz_id)
    if quiz is None or quiz.user_id != user_id:
        return None
    return quiz


async def update_user_level(
    session: AsyncSession, user: User, level: int
) -> User:
    from .level_guidelines import clamp_level

    user.current_level = clamp_level(level)
    await session.commit()
    await session.refresh(user)
    return user


async def update_user_profile_settings(
    session: AsyncSession,
    user: User,
    *,
    level: int | None = None,
    is_freedom_on: bool | None = None,
    target_language: str | None = None,
    target_languages: list[str] | None = None,
    native_language: str | None = None,
    language_levels: dict[str, int] | None = None,
) -> User:
    from .level_guidelines import clamp_level

    if level is not None:
        user.current_level = clamp_level(level)
    if is_freedom_on is not None:
        user.is_freedom_on = is_freedom_on
    if target_language is not None:
        user.target_language = target_language
    if target_languages is not None:
        langs = [l.strip().lower() for l in target_languages if isinstance(l, str) and l.strip()]
        if not langs:
            raise ValueError("target_languages must be a non-empty list")
        user.target_languages = langs
        user.target_language = langs[0]
    if native_language is not None:
        user.native_language = native_language.strip().lower()
    if language_levels is not None:
        merged = dict(user.language_levels or {})
        for lang, lv in language_levels.items():
            merged[lang.strip().lower()] = max(1, min(100, int(lv)))
        user.language_levels = merged
        # Sync global current_level if English is among the updated languages
        if "english" in merged:
            user.current_level = merged["english"]
    await session.commit()
    await session.refresh(user)
    return user


def get_language_level(user: "User", language: str) -> int:
    """Return the user's level for a specific language (falls back to current_level)."""
    lang_levels = getattr(user, "language_levels", None)
    if lang_levels and isinstance(lang_levels, dict):
        lv = lang_levels.get(language.lower())
        if lv is not None:
            return max(1, min(100, int(lv)))
    if language.lower() == "english":
        return int(getattr(user, "current_level", 10) or 10)
    return int(getattr(user, "current_level", 10) or 10)


def get_effective_target_languages(user: "User") -> list[str]:
    """Return the user's active target languages (always at least one)."""
    langs = getattr(user, "target_languages", None)
    if langs and isinstance(langs, list):
        return [l for l in langs if isinstance(l, str)]
    legacy = getattr(user, "target_language", None) or "english"
    return [legacy]


async def get_all_statement_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
) -> list[dict]:
    """Return all Statement nodes for a user as dicts for bulk extraction."""
    import json as _json
    from sqlalchemy import select as _select
    from .models import Node as _Node

    result = await session.execute(
        _select(_Node).where(
            _Node.user_id == user_id,
            _Node.type == "Statement",
            _Node.deleted_at.is_(None),
        )
    )
    nodes = list(result.scalars().all())
    out: list[dict] = []
    for n in nodes:
        content_ko = ""
        if n.description:
            try:
                data = _json.loads(n.description)
                content_ko = (data.get("content") or "").strip()
            except (ValueError, AttributeError):
                parts = n.description.split("\n", 1)
                content_ko = parts[1].strip() if len(parts) > 1 else parts[0].strip()
        out.append({
            "node_id": str(n.id),
            "node_name": n.name,
            "content_ko": content_ko,
            "translation_en": "",
        })
    return out


async def list_quiz_queue_items(
    session: AsyncSession,
    user_id: uuid.UUID,
    queue_kind: str,
    *,
    quiz_type: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[Quiz], int]:
    from sqlalchemy import func

    filters = [
        Quiz.user_id == user_id,
        Quiz.queue_kind != "archived",
    ]
    if queue_kind == "new":
        filters.extend([Quiz.queue_kind == "new", Quiz.repetitions == 0])
    elif queue_kind == "review":
        filters.append(Quiz.queue_kind == "review")
    else:
        filters.append(Quiz.queue_kind == queue_kind)

    if quiz_type is not None:
        filters.append(Quiz.quiz_type == quiz_type)

    count_q = select(func.count()).select_from(Quiz).where(*filters)
    total = int((await session.execute(count_q)).scalar_one())

    result = await session.execute(
        select(Quiz)
        .where(*filters)
        .order_by(Quiz.created_at.desc())
        .offset(offset)
        .limit(limit)
    )
    return list(result.scalars().all()), total


async def archive_quiz(
    session: AsyncSession, quiz_id: uuid.UUID, user_id: uuid.UUID
) -> Quiz | None:
    quiz = await get_quiz(session, quiz_id, user_id)
    if quiz is None:
        return None
    quiz.queue_kind = "archived"
    await session.commit()
    await session.refresh(quiz)
    return quiz


async def delete_quiz_permanent(
    session: AsyncSession, quiz_id: uuid.UUID, user_id: uuid.UUID
) -> bool:
    quiz = await get_quiz(session, quiz_id, user_id)
    if quiz is None:
        return False
    await session.delete(quiz)
    await session.commit()
    return True


async def list_quiz_generations(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[Quiz], int]:
    filters = [Quiz.user_id == user_id, Quiz.queue_kind != "archived"]
    count_q = select(func.count()).select_from(Quiz).where(*filters)
    total = int((await session.execute(count_q)).scalar_one())
    result = await session.execute(
        select(Quiz)
        .where(*filters)
        .order_by(Quiz.created_at.desc())
        .offset(offset)
        .limit(limit)
    )
    return list(result.scalars().all()), total


async def get_node_names(
    session: AsyncSession, node_ids: set[uuid.UUID]
) -> dict[uuid.UUID, str]:
    if not node_ids:
        return {}
    result = await session.execute(select(Node).where(Node.id.in_(node_ids)))
    return {n.id: n.name for n in result.scalars().all()}


async def reclassify_quiz_queues(
    session: AsyncSession, user_id: uuid.UUID, new_level: int
) -> int:
    """Archive quizzes far below level window; restore in-window archived items."""
    from .config import get_settings
    from .level_guidelines import window_for_level

    settings = get_settings()
    lo, hi = window_for_level(new_level, settings.quiz_level_window)
    archived = 0
    result = await session.execute(select(Quiz).where(Quiz.user_id == user_id))
    for quiz in result.scalars().all():
        if quiz.difficulty_level < lo - 2 and quiz.queue_kind != "archived":
            quiz.queue_kind = "archived"
            archived += 1
        elif quiz.queue_kind == "archived" and lo <= quiz.difficulty_level <= hi:
            quiz.queue_kind = "review" if quiz.repetitions > 0 else "new"
    await session.commit()
    return archived

