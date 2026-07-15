from collections.abc import AsyncGenerator
import asyncio
import logging

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from .config import get_settings

logger = logging.getLogger(__name__)

settings = get_settings()

engine = create_async_engine(settings.database_url, echo=False, pool_pre_ping=True)

async_session_factory = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


class Base(DeclarativeBase):
    pass


async def get_session() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session


from .ontology_presets import DAILY_LIFE_ENGLISH, ONTOLOGY_PRESETS

DEFAULT_ENTITY_TYPES = DAILY_LIFE_ENGLISH["entity_types"]
DEFAULT_RELATION_TYPES = DAILY_LIFE_ENGLISH["relation_types"]
DEFAULT_ONTOLOGY_NAME = DAILY_LIFE_ENGLISH["ontology_name"]

_MIGRATIONS = [
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS description TEXT",
    "ALTER TABLE ontology ADD COLUMN IF NOT EXISTS name TEXT",
    "ALTER TABLE ontology_versions ADD COLUMN IF NOT EXISTS ontology_name TEXT",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS user_id UUID",
    "ALTER TABLE edges ADD COLUMN IF NOT EXISTS user_id UUID",
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS pipeline_trace JSONB",
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS debug_run_dir TEXT",
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS graph_build_requested_at TIMESTAMPTZ",
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS transcript_segments JSONB",
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS graph_staging JSONB",
    # Content-type label (대화/일기/회의록/…) — kept on its own column so the
    # pipeline tracer's pipeline_trace dump can never clobber it.
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS source_type TEXT",
    # LLM-suggested content type (Phase 3) — advisory, user confirms.
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS suggested_source_type TEXT",
    # Text-paste attribution: 'self' | 'person' | 'source' (+ head-node name).
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS attribution_kind TEXT",
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS attribution_name TEXT",
    """
    CREATE TABLE IF NOT EXISTS speaker_profiles (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        label TEXT NOT NULL,
        display_name TEXT,
        embedding vector(256),
        node_id UUID REFERENCES nodes(id) ON DELETE SET NULL,
        sample_count INTEGER NOT NULL DEFAULT 1,
        total_duration_sec DOUBLE PRECISION NOT NULL DEFAULT 0,
        last_entry_id UUID REFERENCES journal_entries(id) ON DELETE SET NULL,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        updated_at TIMESTAMPTZ DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS speaker_entry_appearances (
        id SERIAL PRIMARY KEY,
        journal_entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
        speaker_profile_id UUID NOT NULL REFERENCES speaker_profiles(id) ON DELETE CASCADE,
        session_label TEXT NOT NULL,
        match_score DOUBLE PRECISION NOT NULL DEFAULT 0,
        duration_sec DOUBLE PRECISION NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (journal_entry_id, session_label)
    )
    """,
    # Canonical "self" node: the diary owner. Exactly one per user; '나' and any
    # conversation speaker the user confirms as themselves resolve to this node.
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS is_self BOOLEAN NOT NULL DEFAULT FALSE",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_nodes_one_self_per_user ON nodes (user_id) WHERE is_self",
    # LightRAG incremental graph schema
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS speaker_profile_id UUID REFERENCES speaker_profiles(id) ON DELETE SET NULL",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS name_embedding vector(1536)",
    "ALTER TABLE edges ADD COLUMN IF NOT EXISTS weight INTEGER NOT NULL DEFAULT 1",
    "ALTER TABLE edges ADD COLUMN IF NOT EXISTS last_triggered_at TIMESTAMPTZ",
    """
    CREATE TABLE IF NOT EXISTS quizzes (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        associated_entry_id UUID REFERENCES journal_entries(id) ON DELETE SET NULL,
        quiz_type TEXT NOT NULL,
        source_nodes UUID[],
        question_ko TEXT,
        sentence_en TEXT,
        quiz_data JSONB,
        is_solved BOOLEAN NOT NULL DEFAULT FALSE,
        next_review_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_nodes_name_embedding ON nodes USING ivfflat (name_embedding vector_cosine_ops) WITH (lists = 100)",
    # Quiz MVP v2
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS current_level INTEGER NOT NULL DEFAULT 10",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS is_freedom_on BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS daily_cloze_target INTEGER NOT NULL DEFAULT 20",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS daily_composition_target INTEGER NOT NULL DEFAULT 5",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS quiz_review_ratio DOUBLE PRECISION NOT NULL DEFAULT 0.5",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS level_stats JSONB",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS difficulty_level INTEGER NOT NULL DEFAULT 10",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS queue_kind TEXT NOT NULL DEFAULT 'new'",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS ease_factor DOUBLE PRECISION NOT NULL DEFAULT 2.5",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS repetitions INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS interval_days DOUBLE PRECISION NOT NULL DEFAULT 0",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS times_correct INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS times_wrong INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS track TEXT NOT NULL DEFAULT 'daily'",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS batch_id UUID",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS source_kind TEXT",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE",
    "CREATE INDEX IF NOT EXISTS idx_quizzes_user_track_batch ON quizzes (user_id, track, batch_id)",
    "CREATE INDEX IF NOT EXISTS idx_nodes_user_pinned ON nodes (user_id, is_pinned)",
    """
    CREATE TABLE IF NOT EXISTS quiz_source_explorations (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
        language TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'completed',
        composition_count INTEGER NOT NULL DEFAULT 0,
        word_count INTEGER NOT NULL DEFAULT 0,
        expression_count INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        updated_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (user_id, node_id, language)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quiz_source_explorations_user_lang ON quiz_source_explorations (user_id, language, status)",
    "ALTER TABLE quiz_source_explorations ADD COLUMN IF NOT EXISTS cloze_status TEXT NOT NULL DEFAULT 'available'",
    "ALTER TABLE quiz_source_explorations ADD COLUMN IF NOT EXISTS cloze_generator_version TEXT",
    "ALTER TABLE quiz_source_explorations ADD COLUMN IF NOT EXISTS expression_count INTEGER NOT NULL DEFAULT 0",
    """
    CREATE TABLE IF NOT EXISTS quiz_generation_states (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        language TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'available',
        source_count INTEGER NOT NULL DEFAULT 0,
        latest_source_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (user_id, language)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS quiz_batches (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        batch_date DATE NOT NULL,
        track TEXT NOT NULL DEFAULT 'daily',
        language TEXT NOT NULL DEFAULT 'english',
        cloze_target INTEGER NOT NULL DEFAULT 0,
        composition_target INTEGER NOT NULL DEFAULT 0,
        review_ratio DOUBLE PRECISION NOT NULL DEFAULT 0.5,
        sequence INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (user_id, batch_date, track, language, sequence)
    )
    """,
    "ALTER TABLE quiz_batches ADD COLUMN IF NOT EXISTS sequence INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS last_answered_at TIMESTAMPTZ",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS first_answered_at TIMESTAMPTZ",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS last_quality INTEGER",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS generation_key TEXT",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_quizzes_generation_key ON quizzes (generation_key) WHERE generation_key IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_quizzes_user_type_queue ON quizzes (user_id, quiz_type, queue_kind, difficulty_level)",
    "CREATE INDEX IF NOT EXISTS idx_quizzes_user_type_review ON quizzes (user_id, quiz_type, next_review_at)",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS pipeline_trace JSONB",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS debug_run_dir TEXT",
    # Node updated_at tracking
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now()",
    # User profile: target language + learning goal
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS target_language TEXT NOT NULL DEFAULT 'english'",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS learning_goal TEXT NOT NULL DEFAULT 'daily'",
    # Multi-language support
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS target_languages JSONB",
    # Native language (모국어) — language explanations are generated in this language
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS native_language TEXT NOT NULL DEFAULT 'korean'",
    # Per-language levels: {"english": 50, "german": 10}
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS language_levels JSONB",
    # Soft delete: nodes moved to trash retain their data
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS deleted_context JSONB",
    # Cumulative LLM-assigned concept importance (1-5 per mention, summed).
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS importance_score INTEGER NOT NULL DEFAULT 0",
    # Alternative surface forms (nicknames / inflected mentions / self's real names)
    # that resolve to a node — powers person-mention → existing-identity linking.
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS aliases JSONB NOT NULL DEFAULT '[]'::jsonb",
    # Alias embedding index for FUZZY identity resolution (suggest unseen variants).
    """
    CREATE TABLE IF NOT EXISTS node_alias_embeddings (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
        text TEXT NOT NULL,
        embedding vector(1536),
        created_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (node_id, text)
    )
    """,
    # German translation output in fast path
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS translation_de TEXT",
    # All target-language translations keyed by ISO code (multi-language fast path)
    "ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS translations JSONB",
    # Cleanup: clear SpeakerProfile identity links that point to deleted (non-existent) nodes.
    # Nodes are soft-deleted (deleted_at IS NOT NULL) or hard-deleted (row gone).
    # SET NULL fk means hard-deleted nodes already cleared node_id, but display_name may linger.
    # Also clear profiles pointing to soft-deleted nodes (they're logically deleted).
    """
    UPDATE speaker_profiles
    SET node_id = NULL, display_name = NULL
    WHERE node_id IS NOT NULL
      AND (
        NOT EXISTS (SELECT 1 FROM nodes WHERE nodes.id = speaker_profiles.node_id)
        OR EXISTS (SELECT 1 FROM nodes WHERE nodes.id = speaker_profiles.node_id AND nodes.deleted_at IS NOT NULL)
      )
    """,
    "ALTER TABLE chat_sessions ADD COLUMN IF NOT EXISTS summary_state JSONB",
    "CREATE INDEX IF NOT EXISTS idx_alias_embeddings_embedding ON node_alias_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50)",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS occurred_at DATE",
    "CREATE INDEX IF NOT EXISTS idx_nodes_user_occurred ON nodes (user_id, occurred_at)",
    # Backfill occurred_at for Statement nodes created before this column was
    # populated at write time — derives the date from the earliest linked
    # journal entry. Idempotent (only touches NULL rows); safe to re-run.
    """
    UPDATE nodes n SET occurred_at = sub.d FROM (
        SELECT jgl.node_id, MIN(je.created_at::date) AS d
        FROM journal_graph_links jgl
        JOIN journal_entries je ON je.id = jgl.journal_entry_id
        WHERE jgl.node_id IS NOT NULL
        GROUP BY jgl.node_id
    ) sub
    WHERE n.id = sub.node_id AND n.type = 'Statement' AND n.occurred_at IS NULL
    """,
    # Per-language quiz queues: dedicated column mirrors quiz_data->>'language'
    # so build_session can filter by an indexed column. Backfill from the JSON.
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS language TEXT",
    "UPDATE quizzes SET language = lower(quiz_data->>'language') WHERE language IS NULL AND quiz_data->>'language' IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_quizzes_user_lang_type_queue ON quizzes (user_id, language, quiz_type, queue_kind)",
    # Consent tracking (PIPA): policy version + timestamps. speaker_id_consent_at
    # gates voiceprint (biometric) derivation.
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS consent_version TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS consented_at TIMESTAMPTZ",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS speaker_id_consent_at TIMESTAMPTZ",
]


async def _wait_for_db(*, attempts: int = 12, delay_sec: float = 2.5) -> None:
    """Retry until Postgres accepts connections (e.g. container still starting)."""
    last_err: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            async with engine.connect() as conn:
                await conn.exec_driver_sql("SELECT 1")
            return
        except Exception as exc:
            last_err = exc
            if attempt == attempts:
                break
            logger.warning(
                "Database not ready (attempt %s/%s): %s",
                attempt,
                attempts,
                exc,
            )
            await asyncio.sleep(delay_sec)
    raise RuntimeError("Database connection failed after retries") from last_err


async def init_db() -> None:
    from . import models

    await _wait_for_db()

    async with engine.begin() as conn:
        try:
            await conn.exec_driver_sql("CREATE EXTENSION IF NOT EXISTS vector")
        except Exception:
            pass
        await conn.run_sync(Base.metadata.create_all)

    for sql in _MIGRATIONS:
        try:
            async with engine.begin() as conn:
                # Avoid hanging forever when pytest/another uvicorn holds a DDL lock.
                await conn.exec_driver_sql("SET lock_timeout = '10s'")
                await conn.exec_driver_sql(sql)
        except Exception as exc:
            # ivfflat index etc. may fail on empty/small datasets — non-fatal
            if "USING ivfflat" not in sql and "lock timeout" not in str(exc).lower():
                raise
            logger.warning("Migration skipped (non-fatal): %s", exc)

    try:
        async with engine.begin() as conn:
            await conn.exec_driver_sql("SET lock_timeout = '10s'")
            await conn.exec_driver_sql(
                "ALTER TABLE nodes DROP CONSTRAINT IF EXISTS uq_node_name_type"
            )
            await conn.exec_driver_sql(
                "ALTER TABLE nodes ADD CONSTRAINT uq_node_user_name_type "
                "UNIQUE (user_id, name, type)"
            )
    except Exception as exc:
        logger.warning("Constraint migration skipped (non-fatal): %s", exc)

    async with async_session_factory() as session:
        from . import crud

        existing = await session.get(models.Ontology, 1)
        if existing is None:
            session.add(
                models.Ontology(
                    id=1,
                    name=DEFAULT_ONTOLOGY_NAME,
                    entity_types=DEFAULT_ENTITY_TYPES,
                    relation_types=DEFAULT_RELATION_TYPES,
                )
            )
            await session.commit()
        elif not existing.name:
            existing.name = DEFAULT_ONTOLOGY_NAME
            await session.commit()

        versions = await crud.list_ontology_versions(session)
        seeded_names = {v.ontology_name for v in versions if v.ontology_name}

        if not versions:
            for preset in ONTOLOGY_PRESETS.values():
                await crud.create_ontology_version(
                    session,
                    entity_types=preset["entity_types"],
                    relation_types=preset["relation_types"],
                    ontology_name=preset["ontology_name"],
                    note=f"Preset: {preset['ontology_name']}",
                )
            await session.commit()
        else:
            for preset in ONTOLOGY_PRESETS.values():
                if preset["ontology_name"] not in seeded_names:
                    await crud.create_ontology_version(
                        session,
                        entity_types=preset["entity_types"],
                        relation_types=preset["relation_types"],
                        ontology_name=preset["ontology_name"],
                        note=f"Preset: {preset['ontology_name']}",
                    )
            await session.commit()
