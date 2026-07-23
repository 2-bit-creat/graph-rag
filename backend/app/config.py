from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://graphrag:graphrag@localhost:6432/graphrag"
    # Neon (and similar managed Postgres) specifics — all default False/off so
    # local docker-compose Postgres is unaffected. Turn on for a Neon DATABASE_URL.
    db_require_ssl: bool = False
    # Neon's pooled (-pooler) endpoint runs PgBouncer in transaction mode, which
    # is incompatible with asyncpg's server-side prepared statements — disable
    # the statement cache when pointed at a pooled connection string.
    db_disable_prepared_cache: bool = False
    # Lambda: skip SQLAlchemy's own connection pool and let the DB-side pooler
    # (Neon's -pooler endpoint) own pooling instead — avoids each cold Lambda
    # container holding idle connections against the free-tier connection cap.
    db_lambda_pooling: bool = False
    openai_api_key: str = ""
    # Single model for every LLM call — quiz generation, tutor, chat, cleanup.
    # (The old gpt-4o "premium" path was removed for cost; the bundle generator
    # produces 4-8 questions per call, so a mini model is both cheaper and enough.)
    openai_model: str = "gpt-4o-mini"
    # Cap each LLM request so a hung/slow OpenAI call surfaces as a fast failure
    # instead of leaving the graph build stuck in 'graph_processing' (the default
    # SDK timeout is 600s × retries — perceived as an indefinite buffering spinner).
    openai_timeout_sec: float = 90.0
    cors_origins: str = "http://localhost:8080"

    # Deployment environment. "development" keeps local ergonomics (no-token
    # requests fall back to the shared dev user, the placeholder JWT secret is
    # tolerated). Set ENVIRONMENT=production before shipping — that disables the
    # dev-user fallback and refuses to boot on an insecure JWT secret.
    environment: str = "development"

    jwt_secret: str = "change-me-in-production"
    jwt_expire_minutes: int = 60 * 24 * 7

    upload_dir: str = "./uploads"
    debug_runs_dir: str = "./debug_runs"
    # Debug tracing (pipeline_trace DB column + debug_runs/ artifacts + the
    # /kg/debug/runs and entry trace/artifacts endpoints). These retain raw
    # prompts, transcripts, and audio, so they are OFF in production by default.
    # None = auto (on in development, off in production); set true/false to force.
    debug_features_enabled: bool | None = None
    # Debug artifacts older than this are swept at startup (0 disables the sweep).
    debug_runs_retention_days: int = 7
    s3_bucket: str = ""
    s3_endpoint: str = ""
    s3_region: str = "ap-northeast-2"
    # Public base URL (typically a CloudFront domain fronting the media bucket)
    # used to build playable/downloadable URLs for objects written to S3 — e.g.
    # "https://media.example.com". Empty means local-filesystem serving only.
    media_base_url: str = ""

    redis_url: str = "redis://localhost:6379/0"
    graph_processing_async: bool = False
    graph_background: bool = False
    graph_manual_only: bool = True
    journal_skip_entity_refinement: bool = True

    # Speaker diarization (optional — requires DEEPGRAM_API_KEY or local pyannote)
    speaker_diarization_enabled: bool = False
    deepgram_api_key: str = ""
    pyannote_hf_token: str = ""

    # Voice memory: segment embeddings → speaker_profiles (linked to Person nodes)
    speaker_voice_memory_enabled: bool = True
    speaker_embedding_backend: str = "spectral"  # spectral | resemblyzer
    # Min cosine similarity to reuse an existing voice profile (spectral embeddings).
    speaker_match_threshold: float = 0.85

    # When Deepgram/pyannote collapse multiple voices into one label, split via embeddings
    speaker_refinement_enabled: bool = True
    speaker_refinement_threshold: float = 0.55
    speaker_refinement_min_duration_sec: float = 4.0
    # Reject embedding splits when both halves still sound like the same person.
    speaker_refinement_same_speaker_sim_cap: float = 0.85

    # Pre-STT silence trim (conservative — edges only; skipped when Deepgram diarization on)
    audio_trim_enabled: bool = True
    audio_trim_mode: str = "edges"  # edges = leading/trailing only | gaps = old multi-segment
    audio_trim_adaptive: bool = True
    audio_trim_normalize_quiet: bool = True
    audio_trim_skip_when_diarization: bool = True
    audio_trim_window_ms: int = 30
    audio_trim_rms_threshold: float = 350.0  # used when adaptive=false
    audio_trim_rms_threshold_floor: float = 60.0
    audio_trim_min_speech_ms: int = 120
    audio_trim_max_gap_ms: int = 700
    audio_trim_padding_ms: int = 250
    audio_trim_min_duration_sec: float = 0.4
    audio_trim_min_keep_ratio: float = 0.85
    audio_trim_max_remove_ratio: float = 0.25
    free_tier_quiz_limit: int = 3
    free_tier_review_days: int = 7

    # Statement-bank expression extraction during KG build (LLM cost). Off while
    # the app is focused on composition-only learning; flip on to re-enable.
    expression_extraction_enabled: bool = False

    # Graph chat: cosine-distance cutoff for retrieving Statement/Concept nodes.
    # Looser than the 0.35 identity-matching threshold — sentence-level similarity.
    graph_chat_max_distance: float = 0.55
    graph_chat_seed_limit: int = 8
    graph_chat_history_turns: int = 12
    # Identity heads (사람·기업/출처·반려동물 등) carry no Node.name_embedding — their
    # surface forms live in node_alias_embeddings. Graph chat searches that index
    # too so "마야가 누구야?"/"삼성전자가 뭐랬어?" seed the identity node itself.
    # Aliases are short names, so the cutoff is a touch looser than the 0.35
    # write-time resolution threshold.
    graph_chat_identity_seed_limit: int = 3
    graph_chat_identity_max_distance: float = 0.5
    # Deterministic name-scan (name_match.scan_identity_mentions) hit → Statements
    # this identity actually SPOKE_OR_PUBLISHED, added regardless of embedding
    # distance (a compound query like "누가 X에 대해 뭐라 했지?" dilutes the
    # sentence embedding below the cutoff even though the speaker is unambiguous
    # from the text alone). 0 disables the feature without touching code.
    graph_chat_speaker_seed_limit: int = 8
    graph_chat_max_completion_tokens: int = 500
    chat_timezone: str = "Asia/Seoul"
    graph_chat_temporal_seed_limit: int = 12
    graph_chat_summary_enabled: bool = True
    graph_chat_summary_batch: int = 8
    graph_chat_summary_max_tokens: int = 600
    # retrieve_graph_context / hybrid_retrieve seed cutoffs (formerly hardcoded in rag.py)
    graph_retrieve_max_distance: float = 0.35
    graph_retrieve_seed_limit: int = 5
    graph_retrieve_identity_max_distance: float = 0.5
    graph_retrieve_identity_seed_limit: int = 3

    # graph_retrieval.py: shared Context Package builder + RRF rerank, consumed
    # by both graph_chat.py (chat) and rag.py (quiz). See docstring there for the
    # Case A/B/C seed-expansion rules this tunes.
    graph_case_a_statement_limit: int = 3  # Concept seed -> linked Statements
    graph_case_b_statement_limit: int = 5  # Identity seed -> that speaker's Statements
    graph_case_c_concept_limit: int = 5  # Statement seed -> its CONTEXT concepts
    graph_case_c_mention_limit: int = 5  # Statement seed -> its MENTIONS identities
    # RRF fusion constant (standard default from the original RRF paper — larger
    # values flatten the influence of rank differences).
    graph_rrf_k: int = 60
    # Multiplier applied to a package's RRF score when it falls outside an
    # explicit query time window — a soft demotion, never a hard cutoff, so a
    # vaguely-timed question doesn't lose a genuinely relevant memory outright.
    graph_time_penalty_factor: float = 0.5
    # Final cutoff after RRF rerank — how many Context Packages reach the prompt.
    graph_context_top_k: int = 5

    # Chat→journal distillation: a candidate diary sentence within this cosine
    # distance of an existing Statement node is flagged as a duplicate (RAG already
    # surfaced it) and excluded from the draft by default. Tighter than the 0.55
    # chat-retrieval cutoff — dedup must be confident before dropping user content.
    chat_distill_dup_max_distance: float = 0.25

    # Quiz auto-refill: top up the per-language×per-type queues in the background
    # after graph commits and when a queue runs low. Each "bundle" is one LLM call
    # that yields all four quiz types for one Statement.
    quiz_auto_enabled: bool = True
    quiz_queue_target_per_type: int = 10
    quiz_refill_max_bundles_per_run: int = 3
    quiz_session_size: int = 10
    quiz_review_ratio: float = 0.7
    quiz_level_window: int = 3
    quiz_min_new_queue: int = 5
    quiz_max_nodes: int = 10
    quiz_max_edges: int = 15
    quiz_max_hops: int = 2
    quiz_recency_weight: float = 0.7
    quiz_random_weight: float = 0.3

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def is_production(self) -> bool:
        return self.environment.strip().lower() in ("production", "prod")

    @property
    def jwt_secret_is_insecure(self) -> bool:
        return self.jwt_secret.strip() in ("", "change-me-in-production")

    @property
    def db_credentials_are_insecure(self) -> bool:
        """The local-dev default Postgres credentials must not reach production."""
        return "graphrag:graphrag@" in self.database_url

    @property
    def debug_enabled(self) -> bool:
        """Whether debug tracing/artifacts and their endpoints are active."""
        if self.debug_features_enabled is not None:
            return self.debug_features_enabled
        return not self.is_production

    def quiz_selection_snapshot(self, current_level: int = 10) -> dict:
        """Global quiz graph-selection parameters for trace IO / profile API."""
        from .level_guidelines import cefr_label, window_for_level

        lo, hi = window_for_level(current_level, self.quiz_level_window)
        return {
            "quiz_max_nodes": self.quiz_max_nodes,
            "quiz_max_edges": self.quiz_max_edges,
            "quiz_max_hops": self.quiz_max_hops,
            "quiz_recency_weight": self.quiz_recency_weight,
            "quiz_random_weight": self.quiz_random_weight,
            "quiz_level_window": self.quiz_level_window,
            "level_window": [lo, hi],
            "cefr_label": cefr_label(current_level),
        }


@lru_cache
def get_settings() -> Settings:
    return Settings()
