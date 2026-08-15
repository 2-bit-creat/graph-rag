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
    # init_db()'s create_all + ~90 idempotent ALTER/CREATE INDEX statements are
    # cheap against a co-located docker-compose Postgres (default True is fine
    # for local dev), but against a remote managed DB each statement is a real
    # network round trip — measured ~90x0.6s = ~60-70s cross-region, which can
    # eat most/all of a Lambda cold start's timeout budget for no reason once
    # the schema is already up to date. Run once with this True after a schema
    # change (or on first deploy), then flip to False for fast cold starts.
    run_db_migrations: bool = True
    # Build metadata is injected by the deployment workflow. It is deliberately
    # non-secret and is safe to expose from /ready for release verification.
    app_version: str = "local"
    openai_api_key: str = ""
    # General-purpose inexpensive model for broad drafting. Quiz generation has
    # separate author/editor roles, but both use a current small model with a
    # strict semantic contract. Quality comes from independent author/reviewer
    # calls, golden evals, and a fail-closed release gate—not an expensive model.
    openai_model: str = "gpt-4o-mini"
    quiz_author_model: str = "gpt-5.4-mini"
    quiz_quality_model: str = "gpt-5.4-mini"
    # en->ko measured better and cheaper with the inexpensive author plus the
    # stronger semantic editor. Empty values fall back to the global roles.
    quiz_author_model_en_ko: str = "gpt-4o-mini"
    quiz_quality_model_en_ko: str = "gpt-5.4-mini"
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
    # Writable scratch space for pipeline steps that need a real file on disk
    # (VAD trim, diarization, voice embedding all take a path, not bytes).
    # upload_dir is the *durable* store and cannot serve this purpose in a
    # deployed environment: on Lambda it resolves under /var/task, which is
    # read-only, and when S3_BUCKET is set the audio is never written locally at
    # all. Empty = the OS temp dir (/tmp on Lambda), which is always writable.
    scratch_dir: str = ""
    # Debug tracing (pipeline_trace DB column + debug_runs/ artifacts + the
    # /kg/debug/runs and entry trace/artifacts endpoints). These retain raw
    # prompts, transcripts, and audio, so they are OFF in production by default.
    # None = auto (on in development, off in production); set true/false to force.
    debug_features_enabled: bool | None = None
    # Operator tools (학습 큐 관리 · 노드 탐색 현황 · 생성 실행 이력). Unlike debug
    # tracing these only ever return the caller's OWN rows and carry no prompts
    # or transcripts, so they stay ON in production — the menu exposes them in
    # release web builds and gating them on debug is what made them 404.
    operator_tools_enabled: bool = True
    # Handles allowed to see the operator/developer tools. The client used to
    # decide this itself with `handle == 'main'`, which meant anyone who signed
    # in with that handle got pipeline traces and account administration — the
    # gate lived on the wrong side of the network. The server now answers it
    # (LearningProfileOut.is_operator) and the app only renders the answer.
    # Comma-separated; empty disables the tools for everyone.
    operator_handles: str = "main"
    # Knowledge-graph extraction must not silently lose sentences. After the LLM
    # responds, the concatenated claim statements are measured against the source
    # with precision_text.native_ngram_coverage; below this the extractor spends
    # ONE repair call naming the sentences it dropped.
    #
    # 0.85 sits between the two things the score has to tell apart: dropping one
    # sentence of four costs roughly 25% of the source bigrams, while legitimate
    # filler removal and 어미 normalisation cost under 10%. (quiz_bundle's 0.72 is
    # a different comparison — one sentence against one sentence — and is too
    # permissive here.) Short entries are skipped: n-gram ratios are noisy on them.
    kg_extract_coverage_min: float = 0.85
    kg_extract_coverage_min_chars: int = 60
    # Debug artifacts older than this are swept at startup (0 disables the sweep).
    debug_runs_retention_days: int = 7
    # Sweep data nothing references any more (rows whose owner is gone, files
    # whose row is gone) shortly after startup. Runs in the background so it
    # never delays readiness, and only ever removes things with no live owner —
    # see storage_usage.gc_orphans. Set false to make the sweep manual-only
    # (POST /storage/admin/gc).
    orphan_gc_on_startup: bool = True
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

    # Per-user daily call ceilings on the endpoints that spend money (LLM,
    # Whisper). Enforced by app/rate_limit.py. A missing key or a
    # negative value means unlimited, so a deployment can disable one counter
    # without a code change. Override via env as JSON, e.g.
    #   DAILY_LIMITS_FREE='{"quiz_gen": 5, "ocr": 3}'
    daily_limits_free: dict[str, int] = {
        "quiz_gen": 20,
        "kg_extract": 30,
        "ocr": 20,
        "chat": 100,
        "stt": 20,
    }
    # Web Push (VAPID). The private key is a secret and comes from Secrets
    # Manager in deployed environments; empty values disable push entirely so a
    # deployment without keys degrades to "no notifications" rather than 500s.
    vapid_public_key: str = ""
    vapid_private_key: str = ""
    # RFC 8292 requires a contact for the push service to reach on abuse.
    vapid_subject: str = "mailto:support@daylog.app"

    daily_limits_premium: dict[str, int] = {
        "quiz_gen": 200,
        "kg_extract": 300,
        "ocr": 200,
        "chat": 1000,
        "stt": 200,
    }

    # Statement-bank extraction is the language-learning path: one background
    # analysis prepares the composition drill and its reusable expressions for
    # every configured target language. It can still be disabled explicitly by
    # deployments that do not offer learning features.
    expression_extraction_enabled: bool = True

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
    # Search plans are generated by the inexpensive model before retrieval. An
    # empty value reuses openai_model so existing deployments need no env change.
    graph_chat_planner_model: str = ""
    graph_chat_planner_max_tokens: int = 350
    chat_timezone: str = "Asia/Seoul"
    graph_chat_temporal_seed_limit: int = 12
    # graph_overview retriever: meta questions ("내 그래프에 뭐가 있어?", "요즘 자주
    #말한 주제는?") match no single Statement within graph_chat_max_distance, so
    # every one of them used to answer "관련된 기억이 없습니다". These cap the
    # aggregate rows that retriever puts in front of the model.
    graph_chat_overview_top_concepts: int = 8
    graph_chat_overview_top_speakers: int = 6
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
    def operator_handle_list(self) -> list[str]:
        return [h.strip().lower() for h in self.operator_handles.split(",") if h.strip()]

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
