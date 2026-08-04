from collections.abc import AsyncGenerator
import asyncio
import hashlib
import logging
import socket
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy.pool import NullPool

from .config import get_settings

logger = logging.getLogger(__name__)

settings = get_settings()

# Managed Postgres hosts (Neon included) often publish both A and AAAA records.
# A Lambda function outside a VPC has no outbound IPv6 route, so if asyncio/
# asyncpg picks the AAAA address first the TCP connect just hangs — no error,
# no fast failure, it silently eats the whole Lambda timeout. Force IPv4-only
# resolution globally; harmless locally (docker-compose Postgres is IPv4/
# localhost anyway) and keeps SNI-based routing intact since the hostname
# itself is untouched — only the DNS answer is filtered.
_orig_getaddrinfo = socket.getaddrinfo


def _ipv4_only_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    return _orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)


socket.getaddrinfo = _ipv4_only_getaddrinfo

# Neon (and similar managed Postgres) connection quirks — all gated behind
# settings that default False, so the local docker-compose Postgres is
# unaffected. See Settings.db_require_ssl / db_disable_prepared_cache /
# db_lambda_pooling in config.py for what each one is working around.
_connect_args: dict = {}
if settings.db_require_ssl:
    _connect_args["ssl"] = True
if settings.db_disable_prepared_cache:
    _connect_args["statement_cache_size"] = 0
    _connect_args["prepared_statement_cache_size"] = 0

_engine_kwargs: dict = {"echo": False, "pool_pre_ping": True, "connect_args": _connect_args}
if settings.db_lambda_pooling:
    # Let the DB-side pooler (Neon's -pooler endpoint) own pooling instead of
    # SQLAlchemy's — otherwise every cold Lambda container adds its own idle
    # connection pool on top, quickly exhausting the free-tier connection cap.
    _engine_kwargs["poolclass"] = NullPool

engine = create_async_engine(settings.database_url, **_engine_kwargs)

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
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS auto_generate_quizzes BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS level_stats JSONB",
    # Existing installations predate these columns even though new installs
    # receive them through CREATE TABLE above.
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS question_ko TEXT",
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS sentence_en TEXT",
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
    "CREATE INDEX IF NOT EXISTS idx_quizzes_user_track_batch ON quizzes (user_id, track, batch_id)",
    # Compatibility column for databases created after the pin feature was
    # removed and older databases that still require a value on INSERT.
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE",
    # The pin feature is gone, but keep its database column for compatibility
    # with older production schemas that enforce it as NOT NULL.  Node writes
    # always supply False (see models.Node); no product behaviour uses it.
    "DROP INDEX IF EXISTS idx_nodes_user_pinned",
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
    CREATE TABLE IF NOT EXISTS quiz_generation_runs (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        idempotency_key TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual',
        status TEXT NOT NULL DEFAULT 'queued',
        node_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
        languages JSONB NOT NULL DEFAULT '[]'::jsonb,
        items JSONB NOT NULL DEFAULT '[]'::jsonb,
        total_count INTEGER NOT NULL DEFAULT 0,
        completed_count INTEGER NOT NULL DEFAULT 0,
        failed_count INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        updated_at TIMESTAMPTZ DEFAULT NOW(),
        finished_at TIMESTAMPTZ,
        UNIQUE (user_id, idempotency_key)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quiz_generation_runs_user_created ON quiz_generation_runs (user_id, created_at DESC)",
    """
    CREATE TABLE IF NOT EXISTS quiz_learning_materials (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
        language TEXT NOT NULL,
        source_hash TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        priority INTEGER NOT NULL DEFAULT 0,
        composition_count INTEGER NOT NULL DEFAULT 0,
        expression_count INTEGER NOT NULL DEFAULT 0,
        expansion_count INTEGER NOT NULL DEFAULT 0,
        result JSONB,
        error TEXT,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        updated_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (user_id, node_id, language)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quiz_learning_materials_user_status ON quiz_learning_materials (user_id, language, status)",
    """
    CREATE TABLE IF NOT EXISTS quiz_policy_decisions (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        policy TEXT NOT NULL,
        policy_version TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        reason TEXT NOT NULL,
        details JSONB,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quiz_policy_decisions_user_created ON quiz_policy_decisions (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_quiz_policy_decisions_policy_created ON quiz_policy_decisions (policy, created_at DESC)",
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
    "ALTER TABLE quizzes ADD COLUMN IF NOT EXISTS language TEXT",
    """
    CREATE TABLE IF NOT EXISTS quiz_attempts (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        quiz_id UUID NOT NULL REFERENCES quizzes(id) ON DELETE CASCADE,
        idempotency_key TEXT NOT NULL,
        quiz_type TEXT NOT NULL,
        language TEXT NOT NULL DEFAULT 'english',
        queue_kind TEXT NOT NULL,
        answer_payload JSONB,
        correct BOOLEAN NOT NULL,
        quality INTEGER NOT NULL,
        tutor_feedback JSONB,
        hint_level INTEGER NOT NULL DEFAULT 0,
        revealed_tokens JSONB,
        answer_revealed BOOLEAN NOT NULL DEFAULT FALSE,
        xp_awarded INTEGER NOT NULL DEFAULT 0,
        xp_policy_version INTEGER NOT NULL DEFAULT 1,
        source TEXT NOT NULL DEFAULT 'live',
        answered_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (user_id, idempotency_key)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quiz_attempts_user_answered ON quiz_attempts (user_id, answered_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_quiz_attempts_quiz_answered ON quiz_attempts (quiz_id, answered_at DESC)",
    """
    INSERT INTO quiz_attempts (
        id, user_id, quiz_id, idempotency_key, quiz_type, language, queue_kind,
        answer_payload, correct, quality, hint_level, answer_revealed,
        xp_awarded, xp_policy_version, source, answered_at
    )
    SELECT
        (
          substr(md5('legacy-' || q.id::text), 1, 8) || '-' ||
          substr(md5('legacy-' || q.id::text), 9, 4) || '-' ||
          substr(md5('legacy-' || q.id::text), 13, 4) || '-' ||
          substr(md5('legacy-' || q.id::text), 17, 4) || '-' ||
          substr(md5('legacy-' || q.id::text), 21, 12)
        )::uuid,
        q.user_id, q.id, 'legacy-' || q.id::text,
        q.quiz_type, COALESCE(q.language, q.quiz_data->>'language', 'english'),
        q.queue_kind, NULL, COALESCE(q.last_quality, 0) >= 3,
        COALESCE(q.last_quality, CASE WHEN q.times_correct > 0 THEN 4 ELSE 1 END),
        0, FALSE, 0, 1, 'legacy', q.last_answered_at
    FROM quizzes q
    WHERE q.last_answered_at IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM quiz_attempts a
          WHERE a.user_id = q.user_id AND a.idempotency_key = 'legacy-' || q.id::text
      )
    """,
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
    "ALTER TABLE chat_sessions ADD COLUMN IF NOT EXISTS distill_state JSONB",
    "ALTER TABLE chat_sessions ADD COLUMN IF NOT EXISTS summary_state JSONB",
    "CREATE INDEX IF NOT EXISTS idx_alias_embeddings_embedding ON node_alias_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50)",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS occurred_at DATE",
    "CREATE INDEX IF NOT EXISTS idx_nodes_user_occurred ON nodes (user_id, occurred_at)",
    # Event-time model for temporal GraphRAG.  All statements keep their source
    # recording time separately from the time described by their text.
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS recorded_at TIMESTAMPTZ",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS event_start_at TIMESTAMPTZ",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS event_end_at TIMESTAMPTZ",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS temporal_precision TEXT NOT NULL DEFAULT 'unknown'",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS temporal_confidence DOUBLE PRECISION NOT NULL DEFAULT 0",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS temporal_source_text TEXT",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS temporal_anchor_at TIMESTAMPTZ",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS event_status TEXT NOT NULL DEFAULT 'happened'",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS event_timezone TEXT",
    "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS claim_key TEXT",
    "CREATE INDEX IF NOT EXISTS idx_nodes_user_event_start ON nodes (user_id, event_start_at)",
    "CREATE INDEX IF NOT EXISTS idx_nodes_user_event_status ON nodes (user_id, event_status)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_statement_claim_key ON nodes (user_id, claim_key) WHERE type = 'Statement' AND claim_key IS NOT NULL",
    """
    CREATE TABLE IF NOT EXISTS temporal_backfill_audits (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
        before JSONB NOT NULL,
        after JSONB NOT NULL,
        run_key TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_temporal_backfill_audits_user_created ON temporal_backfill_audits (user_id, created_at DESC)",
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
    # Identity/Person/Source model backfill: "Speaker" was the pre-split name for
    # what Person means now (see entity_types.is_person_like_type) — rename any
    # node still carrying the old literal type string so the graph canvas and
    # ontology settings show one consistent model instead of Speaker/Person as if
    # they were two different things. Safe: is_person_like_type already treats
    # them as interchangeable everywhere (matching, dedup, voice-linking), and
    # uq_node_user_name_type (user_id, name, type) means this only fires where no
    # same-named Person row already exists for that user.
    "UPDATE nodes SET type = 'Person' WHERE type = 'Speaker'",
    # Reverse-edge traversal (target_id + relation) had no matching index —
    # only the (source_id, target_id, relation) uniqueness index existed, whose
    # leftmost column doesn't help a target_id-first lookup. This is the exact
    # access pattern of find_statements_by_speaker/find_statements_by_concept,
    # the hot path for every chat/quiz retrieval.
    "CREATE INDEX IF NOT EXISTS idx_edges_target_relation ON edges (target_id, relation)",
    # ivfflat's "lists" parameter is a fixed guess that stops matching recall
    # expectations as row count grows past what it was tuned for; HNSW has no
    # such parameter to retune and gives better recall/speed at scale. Drop the
    # old indexes and rebuild as HNSW (same names — nothing else references them).
    "DROP INDEX IF EXISTS idx_nodes_name_embedding",
    "CREATE INDEX IF NOT EXISTS idx_nodes_name_embedding ON nodes USING hnsw (name_embedding vector_cosine_ops)",
    "DROP INDEX IF EXISTS idx_alias_embeddings_embedding",
    "CREATE INDEX IF NOT EXISTS idx_alias_embeddings_embedding ON node_alias_embeddings USING hnsw (embedding vector_cosine_ops)",
    # Multi-native-language support: these columns were named after the one
    # native language the app originally assumed (Korean/English pivot).
    # Renamed to _native/_target so the name reflects what the field actually
    # holds regardless of the user's chosen native/target language (see
    # languages.py). Each block is idempotent — safe to run on every startup,
    # both on a DB that still has the old column and on a fresh one created
    # directly with the new name (create_all already used the new name, so the
    # old-name column never existed and the IF EXISTS check is simply false).
    """
    DO $$
    BEGIN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'journal_entries' AND column_name = 'transcript_ko'
        ) AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'journal_entries' AND column_name = 'transcript_native'
        ) THEN
            ALTER TABLE journal_entries RENAME COLUMN transcript_ko TO transcript_native;
        END IF;
    END $$;
    """,
    """
    DO $$
    BEGIN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'journal_entries' AND column_name = 'transcript_clean_ko'
        ) AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'journal_entries' AND column_name = 'transcript_clean_native'
        ) THEN
            ALTER TABLE journal_entries RENAME COLUMN transcript_clean_ko TO transcript_clean_native;
        END IF;
    END $$;
    """,
    """
    DO $$
    BEGIN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'quizzes' AND column_name = 'question_ko'
        ) AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'quizzes' AND column_name = 'question_native'
        ) THEN
            ALTER TABLE quizzes RENAME COLUMN question_ko TO question_native;
        END IF;
    END $$;
    """,
    """
    DO $$
    BEGIN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'quizzes' AND column_name = 'sentence_en'
        ) AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'quizzes' AND column_name = 'sentence_target'
        ) THEN
            ALTER TABLE quizzes RENAME COLUMN sentence_en TO sentence_target;
        END IF;
    END $$;
    """,
    """
    CREATE TABLE IF NOT EXISTS quiz_audio_assets (
        id UUID PRIMARY KEY,
        asset_key TEXT UNIQUE NOT NULL,
        kind TEXT NOT NULL,
        storage_key TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        pending_delete_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS quiz_audio_links (
        id UUID PRIMARY KEY,
        quiz_id UUID NOT NULL REFERENCES quizzes(id) ON DELETE CASCADE,
        audio_asset_id UUID NOT NULL REFERENCES quiz_audio_assets(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE (quiz_id, role)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quiz_audio_links_asset ON quiz_audio_links (audio_asset_id)",
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


def is_transient_database_error(exc: BaseException) -> bool:
    """Whether an error means Postgres is temporarily unavailable.

    A local Postgres restart exposes ``CannotConnectNowError: the database
    system is in recovery mode`` through SQLAlchemy.  That is not a malformed
    request, so callers should receive a retryable 503 rather than a raw 500.
    Check the complete exception chain because SQLAlchemy wraps asyncpg errors.
    """
    needles = (
        "database system is in recovery mode",
        "cannot connect now",
        "connection refused",
        "connection is closed",
        "connection reset",
        "server closed the connection",
        "too many connections",
    )
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if any(needle in str(current).lower() for needle in needles):
            return True
        current = current.__cause__ or current.__context__
    return False


async def init_db() -> None:
    if not settings.run_db_migrations:
        # Nothing below this point changes anything once the schema and the
        # ontology presets are in place — but it all still costs round trips to
        # a remote DB on EVERY Lambda cold start (the readiness probe, the
        # ontology lookup, the preset scan). Skipping it is the difference
        # between a cold start that pays ~4 sequential Neon round trips before
        # serving its first byte and one that pays none. Flip
        # RUN_DB_MIGRATIONS=true for one deploy after a schema change.
        return

    await _wait_for_db()
    await _run_migrations()
    await _seed_ontology_presets()


_MIGRATION_LOCK_ID = 714_223_901
_LEGACY_BASELINE_VERSION = "0000_legacy_baseline"
_VERSIONED_MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "migrations" / "versions"
_UNSAFE_MIGRATION_TOKENS = (
    "DROP ",
    "TRUNCATE ",
    "ALTER TABLE ",
    "RENAME ",
    "UPDATE ",
    "DELETE ",
    "INSERT ",
)


def migration_checksum(sql: str) -> str:
    return hashlib.sha256(sql.encode("utf-8")).hexdigest()


def validate_migration_sql(sql: str) -> None:
    """Permit only additive, expand-compatible SQL in automatic deploys.

    Changes that can invalidate a rollback (or rewrite production data) must use
    the separately approved operational runbook, never a normal main push.
    """
    normalized = " ".join(sql.upper().split())
    # ALTER TABLE is only allowed for ADD COLUMN / ADD CONSTRAINT. It is checked
    # separately because the broad ALTER token is otherwise unsafe.
    if normalized.startswith("ALTER TABLE "):
        if " ADD COLUMN " not in normalized and " ADD CONSTRAINT " not in normalized:
            raise ValueError("automatic ALTER TABLE migrations may only add columns or constraints")
        if " NOT NULL" in normalized or " DROP " in normalized or " RENAME " in normalized:
            raise ValueError("automatic ALTER TABLE migrations may not narrow, drop, or rename")
        return
    if any(token in normalized for token in _UNSAFE_MIGRATION_TOKENS):
        raise ValueError("automatic migrations must be additive; destructive/data SQL is blocked")
    if not normalized.startswith(("CREATE TABLE ", "CREATE INDEX ")):
        raise ValueError("automatic migrations must start with CREATE TABLE or CREATE INDEX")


def split_sql_statements(sql: str) -> list[str]:
    """Split a migration file into individually-executable statements.

    asyncpg (with DB_DISABLE_PREPARED_CACHE, which every deploy runs with)
    prepares each exec_driver_sql call as a single statement — Postgres
    rejects a prepared statement containing more than one command
    ("cannot insert multiple commands into a prepared statement"). A naive
    split on ";" would also break any DO $$ ... $$ block, since those can
    contain semicolons of their own, so quote/dollar-quote state is tracked.
    """
    statements: list[str] = []
    buf: list[str] = []
    in_single_quote = False
    dollar_tag: str | None = None
    i = 0
    n = len(sql)
    while i < n:
        ch = sql[i]
        if dollar_tag is not None:
            if sql.startswith(dollar_tag, i):
                buf.append(dollar_tag)
                i += len(dollar_tag)
                dollar_tag = None
                continue
            buf.append(ch)
            i += 1
            continue
        if in_single_quote:
            buf.append(ch)
            if ch == "'":
                in_single_quote = False
            i += 1
            continue
        if ch == "'":
            in_single_quote = True
            buf.append(ch)
            i += 1
            continue
        if ch == "$":
            j = i + 1
            while j < n and (sql[j].isalnum() or sql[j] == "_"):
                j += 1
            if j < n and sql[j] == "$":
                tag = sql[i : j + 1]
                dollar_tag = tag
                buf.append(tag)
                i = j + 1
                continue
        if ch == ";":
            statement = "".join(buf).strip()
            if statement:
                statements.append(statement)
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


def versioned_migration_files() -> list[Path]:
    if not _VERSIONED_MIGRATIONS_DIR.exists():
        return []
    files = sorted(_VERSIONED_MIGRATIONS_DIR.glob("[0-9][0-9][0-9][0-9]_*.sql"))
    versions = [path.stem.split("_", 1)[0] for path in files]
    if len(versions) != len(set(versions)):
        raise RuntimeError("duplicate versioned migration number")
    return files


async def _ensure_migration_table(conn) -> None:
    # Lock before the first CREATE TABLE. Concurrent CodeDeploy hook retries can
    # otherwise both observe a missing table and race while PostgreSQL creates
    # its backing composite type, despite CREATE TABLE IF NOT EXISTS.
    await conn.exec_driver_sql(f"SELECT pg_advisory_xact_lock({_MIGRATION_LOCK_ID})")
    await conn.exec_driver_sql(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            checksum TEXT NOT NULL,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            duration_ms INTEGER NOT NULL,
            git_sha TEXT NOT NULL
        )
        """
    )


async def latest_schema_version() -> str:
    async with engine.begin() as conn:
        await _ensure_migration_table(conn)
        row = (await conn.exec_driver_sql(
            "SELECT version FROM schema_migrations ORDER BY applied_at DESC, version DESC LIMIT 1"
        )).first()
    return row[0] if row else "uninitialized"


async def database_readiness() -> dict[str, str]:
    try:
        async with engine.connect() as conn:
            await conn.exec_driver_sql("SELECT 1")
        return {
            "status": "ok",
            "database": "ok",
            "schema_version": await latest_schema_version(),
            "app_version": settings.app_version,
        }
    except Exception:
        # Do not expose DB hostnames, driver messages, or credentials through a
        # public Function URL. Full detail remains in CloudWatch logs.
        return {
            "status": "unavailable",
            "database": "unavailable",
            "schema_version": "unknown",
            "app_version": settings.app_version,
        }


async def run_deployment_migrations(*, git_sha: str) -> dict[str, object]:
    """Run the legacy baseline once, then checksum-guarded additive migrations."""
    applied: list[str] = []
    await _wait_for_db()
    async with engine.begin() as conn:
        await _ensure_migration_table(conn)
        rows = await conn.exec_driver_sql("SELECT version, checksum FROM schema_migrations")
        recorded = {row[0]: row[1] for row in rows}

        # This project already has a production schema managed by the legacy
        # idempotent list. Preserve that behavior exactly once before moving to
        # explicit files; it avoids guessing the remote DB's current state.
        if _LEGACY_BASELINE_VERSION not in recorded:
            started = datetime.now(UTC)
            await _run_legacy_migrations(conn)
            checksum = migration_checksum("legacy-bootstrap-v1")
            elapsed = int((datetime.now(UTC) - started).total_seconds() * 1000)
            await conn.execute(
                text(
                    "INSERT INTO schema_migrations "
                    "(version, checksum, duration_ms, git_sha) "
                    "VALUES (:v, :c, :d, :g)"
                ),
                {"v": _LEGACY_BASELINE_VERSION, "c": checksum, "d": elapsed, "g": git_sha},
            )
            recorded[_LEGACY_BASELINE_VERSION] = checksum
            applied.append(_LEGACY_BASELINE_VERSION)

        for path in versioned_migration_files():
            version = path.stem.split("_", 1)[0]
            sql = path.read_text(encoding="utf-8")
            checksum = migration_checksum(sql)
            if version in recorded:
                if recorded[version] != checksum:
                    raise RuntimeError(f"migration checksum changed: {version}")
                continue
            validate_migration_sql(sql)
            started = datetime.now(UTC)
            for statement in split_sql_statements(sql):
                await conn.exec_driver_sql(statement)
            elapsed = int((datetime.now(UTC) - started).total_seconds() * 1000)
            await conn.execute(
                text(
                    "INSERT INTO schema_migrations "
                    "(version, checksum, duration_ms, git_sha) "
                    "VALUES (:v, :c, :d, :g)"
                ),
                {"v": version, "c": checksum, "d": elapsed, "g": git_sha},
            )
            applied.append(version)

    # Ontology rows are data the existing initializer requires. Seed only after
    # schema DDL commits, so an interrupted migration never leaves a marker.
    await _seed_ontology_presets()
    return {"status": "ok", "applied": applied, "schema_version": await latest_schema_version()}


async def _run_migrations() -> None:
    # One physical connection for the whole DDL sequence below, not one per
    # statement — with db_lambda_pooling's NullPool (no connection reuse
    # across requests, only within one), opening a fresh connection per
    # migration statement meant a full TCP+TLS handshake to Neon for each of
    # 60+ statements sequentially, easily exceeding the Lambda timeout on cold
    # start. Per-statement failure isolation is now a SAVEPOINT
    # (begin_nested) instead of a separate connection+transaction.
    #
    # Even so, ~90 statements against a remote cross-region DB is ~60-70s
    # of pure round-trip time (measured against Neon) — fine once, not on
    # every cold start. See Settings.run_db_migrations.
    async with engine.begin() as conn:
        await _run_legacy_migrations(conn)


async def _run_legacy_migrations(conn) -> None:
        await conn.exec_driver_sql("SET lock_timeout = '10s'")
        try:
            async with conn.begin_nested():
                await conn.exec_driver_sql("CREATE EXTENSION IF NOT EXISTS vector")
        except Exception:
            pass
        await conn.run_sync(Base.metadata.create_all)

        for sql in _MIGRATIONS:
            try:
                async with conn.begin_nested():
                    await conn.exec_driver_sql(sql)
            except Exception as exc:
                # Vector index builds (ivfflat/hnsw) may fail on empty/small datasets
                # or if the installed pgvector predates HNSW support — non-fatal.
                is_vector_index_sql = "USING ivfflat" in sql or "USING hnsw" in sql
                error_text = str(exc).lower()
                is_duplicate_ddl = "already exists" in error_text or "duplicatetableerror" in error_text
                if not is_vector_index_sql and "lock timeout" not in error_text and not is_duplicate_ddl:
                    raise
                logger.warning("Migration skipped (non-fatal): %s", exc)

        try:
            async with conn.begin_nested():
                await conn.exec_driver_sql(
                    "ALTER TABLE nodes DROP CONSTRAINT IF EXISTS uq_node_name_type"
                )
                await conn.exec_driver_sql(
                    "ALTER TABLE nodes ADD CONSTRAINT uq_node_user_name_type "
                    "UNIQUE (user_id, name, type)"
                )
        except Exception as exc:
            logger.warning("Constraint migration skipped (non-fatal): %s", exc)


async def _seed_ontology_presets() -> None:
    from . import models

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
