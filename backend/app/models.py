import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from pgvector.sqlalchemy import Vector

from .db import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    email: Mapped[str] = mapped_column(String, unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(String, nullable=False)
    subscription_tier: Mapped[str] = mapped_column(
        String, nullable=False, default="free"
    )
    current_level: Mapped[int] = mapped_column(Integer, nullable=False, default=10)
    is_freedom_on: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    level_stats: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    target_language: Mapped[str] = mapped_column(String, nullable=False, default="english")
    target_languages: Mapped[list | None] = mapped_column(JSONB, nullable=True)
    native_language: Mapped[str] = mapped_column(String, nullable=False, default="korean")
    language_levels: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    journal_entries: Mapped[list["JournalEntry"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class JournalEntry(Base):
    __tablename__ = "journal_entries"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    audio_url: Mapped[str | None] = mapped_column(String, nullable=True)
    transcript_ko: Mapped[str | None] = mapped_column(Text, nullable=True)
    transcript_clean_ko: Mapped[str | None] = mapped_column(Text, nullable=True)
    translation_en: Mapped[str | None] = mapped_column(Text, nullable=True)
    translation_de: Mapped[str | None] = mapped_column(Text, nullable=True)
    # All target-language translations keyed by ISO code, e.g. {"en": ..., "ja": ...}.
    # translation_en/de remain as the English pivot + legacy German column.
    translations: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    status: Mapped[str] = mapped_column(String, nullable=False, default="processing")
    graph_job_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("graph_jobs.id", ondelete="SET NULL"), nullable=True
    )
    pipeline_trace: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    debug_run_dir: Mapped[str | None] = mapped_column(String, nullable=True)
    graph_build_requested_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    transcript_segments: Mapped[list | None] = mapped_column(JSONB, nullable=True)
    graph_staging: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    user: Mapped["User"] = relationship(back_populates="journal_entries")
    graph_job: Mapped["GraphJob | None"] = relationship(back_populates="journal_entry")


class GraphJob(Base):
    __tablename__ = "graph_jobs"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    status: Mapped[str] = mapped_column(String, nullable=False, default="pending")
    progress: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    journal_entry: Mapped["JournalEntry | None"] = relationship(
        back_populates="graph_job", uselist=False
    )


class Chunk(Base):
    __tablename__ = "chunks"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    journal_entry_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("journal_entries.id", ondelete="CASCADE"),
        nullable=True,
    )
    text: Mapped[str] = mapped_column(Text, nullable=False)
    embedding: Mapped[list | None] = mapped_column(Vector(1536), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class ReviewSchedule(Base):
    __tablename__ = "review_schedules"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    journal_entry_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("journal_entries.id", ondelete="CASCADE"),
        nullable=False,
    )
    next_review_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    interval_days: Mapped[float] = mapped_column(Float, nullable=False, default=1.0)
    ease_factor: Mapped[float] = mapped_column(Float, nullable=False, default=2.5)
    repetitions: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class Node(Base):
    __tablename__ = "nodes"
    __table_args__ = (
        UniqueConstraint("user_id", "name", "type", name="uq_node_user_name_type"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=True
    )
    name: Mapped[str] = mapped_column(String, nullable=False)
    type: Mapped[str] = mapped_column(String, nullable=False, default="Concept")
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    speaker_profile_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("speaker_profiles.id", ondelete="SET NULL"),
        nullable=True,
    )
    name_embedding: Mapped[list | None] = mapped_column(Vector(1536), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, default=None
    )
    deleted_context: Mapped[dict | None] = mapped_column(
        JSONB, nullable=True, default=None
    )

    speaker_profile: Mapped["SpeakerProfile | None"] = relationship(
        back_populates="linked_nodes",
        foreign_keys=[speaker_profile_id],
    )
    outgoing_edges: Mapped[list["Edge"]] = relationship(
        back_populates="source",
        foreign_keys="Edge.source_id",
        cascade="all, delete-orphan",
    )
    incoming_edges: Mapped[list["Edge"]] = relationship(
        back_populates="target",
        foreign_keys="Edge.target_id",
        cascade="all, delete-orphan",
    )


class JournalGraphLink(Base):
    """Provenance: which nodes/edges came from which journal entry (manual GraphRAG)."""

    __tablename__ = "journal_graph_links"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    journal_entry_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("journal_entries.id", ondelete="CASCADE"), nullable=False
    )
    node_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("nodes.id", ondelete="CASCADE"), nullable=True
    )
    edge_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("edges.id", ondelete="CASCADE"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class Edge(Base):
    __tablename__ = "edges"
    __table_args__ = (
        UniqueConstraint("source_id", "target_id", "relation", name="uq_edge_triple"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=True
    )
    source_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("nodes.id", ondelete="CASCADE"), nullable=False
    )
    target_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("nodes.id", ondelete="CASCADE"), nullable=False
    )
    relation: Mapped[str] = mapped_column(String, nullable=False)
    weight: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    last_triggered_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    source: Mapped["Node"] = relationship(
        back_populates="outgoing_edges", foreign_keys=[source_id]
    )
    target: Mapped["Node"] = relationship(
        back_populates="incoming_edges", foreign_keys=[target_id]
    )


class Quiz(Base):
    """Personalized quiz cards linked to graph nodes and journal entries."""

    __tablename__ = "quizzes"
    __table_args__ = (
        Index(
            "idx_quizzes_user_type_queue",
            "user_id",
            "quiz_type",
            "queue_kind",
            "difficulty_level",
        ),
        Index(
            "idx_quizzes_user_type_review",
            "user_id",
            "quiz_type",
            "next_review_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    associated_entry_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("journal_entries.id", ondelete="SET NULL"),
        nullable=True,
    )
    quiz_type: Mapped[str] = mapped_column(String, nullable=False)
    source_nodes: Mapped[list[uuid.UUID] | None] = mapped_column(
        ARRAY(UUID(as_uuid=True)), nullable=True
    )
    question_ko: Mapped[str | None] = mapped_column(Text, nullable=True)
    sentence_en: Mapped[str | None] = mapped_column(Text, nullable=True)
    quiz_data: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    difficulty_level: Mapped[int] = mapped_column(Integer, nullable=False, default=10)
    queue_kind: Mapped[str] = mapped_column(String, nullable=False, default="new")
    ease_factor: Mapped[float] = mapped_column(Float, nullable=False, default=2.5)
    repetitions: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    interval_days: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    times_correct: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    times_wrong: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_answered_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    is_solved: Mapped[bool] = mapped_column(nullable=False, default=False)
    next_review_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    pipeline_trace: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    debug_run_dir: Mapped[str | None] = mapped_column(Text, nullable=True)


class Ontology(Base):
    """Single-row, user-editable ontology (entity types + relation types)."""

    __tablename__ = "ontology"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    name: Mapped[str | None] = mapped_column(String, nullable=True)
    entity_types: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    relation_types: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)


class SpeakerProfile(Base):
    """Persistent voice identity per user — matched across journal sessions.

    ``embedding`` stores the 256-dim voice vector (spec voice_embedding VECTOR(192)
    mapped to existing 256-dim pipeline in voice_embedding.py).
    """

    __tablename__ = "speaker_profiles"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    label: Mapped[str] = mapped_column(String, nullable=False)
    display_name: Mapped[str | None] = mapped_column(String, nullable=True)
    embedding: Mapped[list | None] = mapped_column(Vector(256), nullable=True)
    node_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("nodes.id", ondelete="SET NULL"), nullable=True
    )
    sample_count: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    total_duration_sec: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    last_entry_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("journal_entries.id", ondelete="SET NULL"),
        nullable=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    linked_nodes: Mapped[list["Node"]] = relationship(
        back_populates="speaker_profile",
        foreign_keys="Node.speaker_profile_id",
    )


class SpeakerEntryAppearance(Base):
    """Which voice profile spoke in which entry (session label → profile)."""

    __tablename__ = "speaker_entry_appearances"
    __table_args__ = (
        UniqueConstraint(
            "journal_entry_id", "session_label", name="uq_entry_session_speaker"
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    journal_entry_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("journal_entries.id", ondelete="CASCADE"),
        nullable=False,
    )
    speaker_profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("speaker_profiles.id", ondelete="CASCADE"),
        nullable=False,
    )
    session_label: Mapped[str] = mapped_column(String, nullable=False)
    match_score: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    duration_sec: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class OntologyVersion(Base):
    """Immutable snapshot of ontology settings for version history."""

    __tablename__ = "ontology_versions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    version_number: Mapped[int] = mapped_column(Integer, nullable=False)
    ontology_name: Mapped[str | None] = mapped_column(String, nullable=True)
    note: Mapped[str | None] = mapped_column(String, nullable=True)
    entity_types: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    relation_types: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
