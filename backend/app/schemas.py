import json
import uuid
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


# --- Graph read models -------------------------------------------------------


def _parse_node_description(description: str | None, node_type: str) -> tuple[str | None, str | None]:
    """For Statement nodes, extract (context_type, content) from description JSON.

    Falls back to legacy 'context_type\\ncontent' format for older records.
    Returns (None, None) for non-Statement nodes.
    """
    if node_type != "Statement" or not description:
        return None, None
    try:
        data = json.loads(description)
        return (data.get("context_type") or None), (data.get("content") or None)
    except (json.JSONDecodeError, AttributeError):
        parts = description.split("\n", 1)
        ctx = parts[0].strip() or None
        content = parts[1].strip() if len(parts) > 1 else None
        return ctx, content


class NodeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    type: str
    description: str | None = None
    context_type: str | None = None   # Statement nodes only
    content: str | None = None        # Statement nodes only — pure body text
    occurred_at: date | None = None   # Statement nodes — when the event happened
    entry_created_at: datetime | None = None  # Source journal entry writing time
    created_at: datetime
    updated_at: datetime | None = None
    has_name_embedding: bool = False
    # Learned alternative surface forms (nicknames / 장세영→나 real names / variants)
    # and how many of them are embedding-indexed for fuzzy resolution.
    aliases: list[str] = []
    alias_embedding_count: int = 0
    speaker_profile_id: uuid.UUID | None = None
    voice_embedding_registered: bool = False
    voice_sample_count: int = 0
    voice_profile_label: str | None = None
    voice_total_duration_sec: float = 0.0
    display_title: str | None = None
    text: str | None = None
    speaker_name: str | None = None
    deleted_at: datetime | None = None
    deleted_context: dict | None = None
    importance_score: int = 0
    is_self: bool = False
    source_entry_id: uuid.UUID | None = None
    source_transcript_ko: str | None = None
    source_transcript_clean_ko: str | None = None

    @model_validator(mode="after")
    def _populate_stmt_fields(self) -> "NodeOut":
        if self.type == "Statement" and self.context_type is None:
            ctx, content = _parse_node_description(self.description, self.type)
            self.context_type = ctx
            self.content = content
        return self


class EdgeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    source_id: uuid.UUID
    target_id: uuid.UUID
    relation: str
    created_at: datetime


class GraphOut(BaseModel):
    nodes: list[NodeOut]
    edges: list[EdgeOut]



class ChatMessage(BaseModel):
    """Generic user/assistant turn used by agent and generation APIs."""

    role: Literal["user", "assistant"]
    content: str


# --- Tutor (English-thinking composition drill) ------------------------------


class TutorChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class TutorDrillRequest(BaseModel):
    language: str = "english"
    source_mode: Literal["journal", "review"] = "journal"


class TutorDrillBatchRequest(BaseModel):
    """Dev tool — batch pre-generation of drills into the tutor drill queue."""

    language: str = "english"
    source_mode: Literal["journal", "review"] = "journal"
    count: int = Field(default=3, ge=1, le=10)


class TutorGlossaryItem(BaseModel):
    term: str      # native-language proper noun / domain term in the prompt
    target: str    # its target-language rendering


class TutorHint(BaseModel):
    note: str          # coaching in the learner's native language
    snippet: str = ""  # optional target-language fragment to try


class TutorDrillOut(BaseModel):
    drill_id: str
    prompt: str
    source_label: str
    source_mode: str
    seed_node_id: str | None = None
    # Hidden from the user until they submit; echoed back on evaluate.
    target_expressions: list[str] = []
    # Proper nouns / domain terms rendered in the target language (shown upfront).
    glossary: list[TutorGlossaryItem] = []
    # Progressive hints — native-language coaching + optional target snippet.
    hints: list[TutorHint] = []
    language: str
    level: int
    cefr: str


class TutorChatRequest(BaseModel):
    messages: list[TutorChatMessage]
    language: str = "english"
    drill_prompt: str | None = None


class TutorVocabSaveRequest(BaseModel):
    expression: str
    meaning: str = ""
    example: str = ""
    language: str = "english"
    note: str = ""
    prompt_ko: str = ""
    user_attempt: str = ""


class TutorVocabBatchRequest(BaseModel):
    items: list[TutorVocabSaveRequest] = []


# --- Ontology ----------------------------------------------------------------


class EntityType(BaseModel):
    name: str
    color: str = "#6366f1"
    description: str | None = None


class OntologyOut(BaseModel):
    name: str | None = None
    entity_types: list[EntityType]
    relation_types: list[str]


class OntologyUpdate(BaseModel):
    name: str | None = None
    entity_types: list[EntityType]
    relation_types: list[str]
    note: str | None = None


class OntologyPresetOut(BaseModel):
    ontology_name: str
    description: str
    entity_type_count: int
    relation_type_count: int


class OntologyVersionSummary(BaseModel):
    id: int
    version_number: int
    ontology_name: str | None = None
    note: str | None = None
    entity_type_count: int
    relation_type_count: int
    created_at: datetime


class OntologyVersionOut(BaseModel):
    id: int
    version_number: int
    ontology_name: str | None = None
    note: str | None = None
    entity_types: list[EntityType]
    relation_types: list[str]
    created_at: datetime


# --- Generation + staging ----------------------------------------------------


class GenerateRequest(BaseModel):
    messages: list[ChatMessage]


class StagedNode(BaseModel):
    temp_id: str
    name: str
    type: str = "Concept"
    description: str | None = None


class StagedEdge(BaseModel):
    source_temp_id: str
    target_temp_id: str
    relation: str = "RELATED_TO"


class StagingGraph(BaseModel):
    nodes: list[StagedNode]
    edges: list[StagedEdge]


# --- Edits -------------------------------------------------------------------


class EdgeCreate(BaseModel):
    source_id: uuid.UUID
    target_id: uuid.UUID
    relation: str = "RELATED_TO"


class NodeCreate(BaseModel):
    name: str
    type: str = "Concept"
    description: str | None = None


class NodeUpdate(BaseModel):
    name: str | None = None
    type: str | None = None
    description: str | None = None


class EdgeUpdate(BaseModel):
    relation: str | None = None
    source_id: uuid.UUID | None = None
    target_id: uuid.UUID | None = None


# --- Agent orchestration -----------------------------------------------------


class AgentRunRequest(BaseModel):
    mode: Literal["study", "explore", "build", "review", "roleplay"]
    messages: list[ChatMessage]


class AgentRunResponse(BaseModel):
    run_id: str
    answer: str | None = None
    cited_node_ids: list[str] = []
    staging: StagingGraph | None = None


# --- Auth -------------------------------------------------------------------


class RegisterRequest(BaseModel):
    email: str
    password: str


class LoginRequest(BaseModel):
    email: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    subscription_tier: str
    created_at: datetime


# --- Journal ----------------------------------------------------------------


class ArtifactRefOut(BaseModel):
    name: str
    relative_path: str
    media_type: str = "text/plain"


class PipelineStepOut(BaseModel):
    step_id: str
    name: str
    type: str
    phase: str = "fast_path"
    started_at: str
    ended_at: str | None = None
    latency_ms: int | None = None
    status: str = "running"
    model: str | None = None
    system_prompt: str | None = None
    input: dict = {}
    output: dict = {}
    error: str | None = None
    artifacts: list[ArtifactRefOut] = []


class PipelineTraceOut(BaseModel):
    run_id: str
    entry_id: str
    started_at: str
    completed_at: str | None = None
    status: str = "running"
    debug_dir: str = ""
    current_phase: str = "fast_path"
    timing: dict[str, int] = {}
    steps: list[PipelineStepOut] = []
    flow_layout: dict | None = None


class RecommendedNodeOut(BaseModel):
    id: uuid.UUID | None = None
    name: str


class SpeakerCandidateOut(BaseModel):
    id: uuid.UUID
    name: str
    match_score: float


class SpeakerSummaryOut(BaseModel):
    session_label: str
    speaker_profile_id: uuid.UUID
    needs_confirmation: bool
    confirmed_node: RecommendedNodeOut | None = None
    suggested_node: RecommendedNodeOut | None = None
    auto_assigned: bool = False


class JournalEntryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    audio_url: str | None = None
    entry_source: str | None = None
    transcript_ko: str | None = None
    transcript_clean_ko: str | None = None
    translation_en: str | None = None
    translation_de: str | None = None
    translations: dict | None = None
    status: str
    source_type: str | None = None
    suggested_source_type: str | None = None
    attribution_kind: str | None = None
    attribution_name: str | None = None
    graph_job_id: uuid.UUID | None = None
    debug_run_dir: str | None = None
    pipeline_trace: dict | None = None
    transcript_segments: list | None = None
    speaker_summaries: list[SpeakerSummaryOut] | None = None
    graph_staging: dict | None = None
    graph_status: str | None = None
    ingest_summary: dict | None = None
    created_at: datetime


class SpeakerProfileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    label: str
    display_name: str | None = None
    node_id: uuid.UUID | None = None
    sample_count: int = 1
    total_duration_sec: float = 0.0
    last_entry_id: uuid.UUID | None = None
    created_at: datetime
    updated_at: datetime | None = None


class SpeakerRecommendResponse(BaseModel):
    recommended_node: RecommendedNodeOut | None = None
    match_score: float | None = None
    speaker_profile_id: uuid.UUID | None = None
    session_speaker_label: str | None = None
    already_confirmed: bool = False
    confirmed_node: RecommendedNodeOut | None = None
    above_threshold: bool = False
    likely_unregistered: bool = False
    session_conflict_hint: str | None = None
    candidates: list[SpeakerCandidateOut] = Field(default_factory=list)
    person_nodes: list[RecommendedNodeOut] = Field(default_factory=list)


class SpeakerConfirmRequest(BaseModel):
    journal_entry_id: uuid.UUID
    speaker_profile_id: uuid.UUID
    session_label: str | None = None
    node_id: uuid.UUID | None = None
    new_node_name: str | None = None
    wrong_name: str | None = None
    # Link this speaker to the user's canonical self node (the diary "나").
    as_self: bool = False
    # 이 "화자"가 사람이 아니라 외부 출처(책·AI·기사·매체)임 — new_node_name을
    # 출처 이름으로 쓰고 엔트리 귀속(attribution_kind='source')을 설정한다.
    as_source: bool = False


class SpeakerConfirmResponse(BaseModel):
    speaker_profile_id: uuid.UUID
    confirmed_node: RecommendedNodeOut
    transcript_replacements: int = 0
    edges_reassigned: int = 0


class SourceTypeUpdate(BaseModel):
    """Confirm/override an entry's content-type label (Phase 3)."""
    source_type: str


class AttributionUpdate(BaseModel):
    """Change who the entry's statements are attributed to (pre-graph only)."""
    attribution_kind: Literal["self", "person", "source"]
    attribution_name: str | None = Field(default=None, max_length=120)

    @model_validator(mode="after")
    def person_requires_name(self) -> "AttributionUpdate":
        if self.attribution_kind == "person" and not (self.attribution_name or "").strip():
            raise ValueError("attribution_name is required when attribution_kind is 'person'")
        return self


class SpeakerRemapRequest(BaseModel):
    """Reversibly remap an entry's diarization speakers (fix over-split)."""
    group_map: dict[str, str] | None = None  # {speaker_original: group_label} (drag merge/split)
    merges: dict[str, str] | None = None     # {from_label: to_label}
    merge_all: bool = False                  # collapse all into one (user confirms who)
    to_self: bool = False                    # collapse all speakers to '나'
    reset: bool = False                      # restore original diarization


class QuizCard(BaseModel):
    question: str
    answer: str
    hint: str = ""
    grammar_note: str = ""


class QuizResponse(BaseModel):
    cards: list[QuizCard]


class GraphSummaryOut(BaseModel):
    node_count: int
    edge_count: int
    top_entity_types: list[dict]
    entity_types: list[dict] = []


class GraphJobOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    status: str
    progress: int
    error: str | None = None
    created_at: datetime
    completed_at: datetime | None = None


class GraphBuildOut(BaseModel):
    entry_id: uuid.UUID
    status: str
    message: str = ""


class GraphApplyRequest(BaseModel):
    """Reviewed/edited graph draft submitted from the HITL review screen.

    ``claims`` is the (possibly user-edited) list of
    ``{speaker, title, statement, concepts}`` dicts from ``graph_staging``. When
    omitted, the server commits the stored draft as-is.
    """

    claims: list[dict] | None = None
    context_type: str | None = None


class ExampleSentence(BaseModel):
    en: str
    ko: str = ""
    note: str = ""
    graph_refs: list[str] = []


class ExamplesResponse(BaseModel):
    examples: list[ExampleSentence]
    graph_context_used: bool = False
    retrieval_preview: str = ""


class RoleplayRequest(BaseModel):
    topic: str = "daily conversation"


class RoleplayResponse(BaseModel):
    scenario: str = ""
    your_role: str = ""
    partner_role: str = ""
    opening_line: str = ""
    vocabulary: list[str] = []


class ReviewItemOut(BaseModel):
    journal_entry_id: uuid.UUID
    next_review_at: datetime
    interval_days: float
    repetitions: int


class ReviewResultRequest(BaseModel):
    quality: int = 3


class QuizItemOut(BaseModel):
    id: uuid.UUID
    quiz_type: str
    difficulty_level: int
    queue_kind: str
    question_ko: str | None = None
    sentence_en: str | None = None
    quiz_data: dict | None = None
    audio_url: str | None = None
    associated_entry_id: uuid.UUID | None = None


class QuizGenerateOut(BaseModel):
    quiz_id: uuid.UUID
    quiz_type: str
    difficulty_level: int
    trace_step_count: int = 0
    generated_count: int = 1


class QuizSessionRequest(BaseModel):
    # "word" = a mixed session across cloze/scramble/mcq_nuance.
    quiz_type: Literal["cloze", "scramble", "mcq_nuance", "composition", "word"]
    size: int = 10
    entry_id: uuid.UUID | None = None
    quiz_ids: list[uuid.UUID] | None = None
    vocab_source: str | None = None  # prefer quizzes generated from this vocab source
    language: str | None = None


class QuizSessionOut(BaseModel):
    items: list[QuizItemOut]
    quiz_type: str
    new_count: int = 0
    review_count: int = 0


class QuizSubmitRequest(BaseModel):
    answer: str | None = None
    order: list[int] | None = None
    selected_index: int | None = None
    entry_id: uuid.UUID | None = None


class QuizSubmitResponse(BaseModel):
    correct: bool
    quality: int
    quiz: QuizItemOut
    explanation: str | None = None
    tutor_feedback: dict | None = None


class QueueCounts(BaseModel):
    new: int = 0
    review: int = 0


class LearningProfileOut(BaseModel):
    current_level: int
    is_freedom_on: bool = False
    cefr_label: str
    level_window: tuple[int, int]
    queue_counts: dict[str, QueueCounts]
    selection_settings: dict | None = None
    target_language: str = "english"
    target_languages: list[str] = ["english"]
    native_language: str = "korean"
    language_levels: dict[str, int] = {}


class QuizQueueItemOut(BaseModel):
    id: uuid.UUID
    quiz_type: str
    queue_kind: str
    difficulty_level: int
    target_node: str
    source_label: str = ""
    context_sentence: str
    question_ko: str | None = None
    quiz_data: dict | None = None
    next_review_at: datetime | None = None
    streak: int = 0
    times_correct: int = 0
    times_wrong: int = 0
    created_at: datetime
    associated_entry_id: uuid.UUID | None = None


class QuizQueueListOut(BaseModel):
    items: list[QuizQueueItemOut]
    total: int
    queue_kind: str
    quiz_type: str | None = None


class QuizDeleteOut(BaseModel):
    id: uuid.UUID
    status: Literal["archived", "deleted"]
    queue_kind: str


class QuizGenerationListOut(BaseModel):
    items: list[QuizQueueItemOut]
    total: int


class QuizGenerationTraceOut(BaseModel):
    run_id: str | None = None
    status: str = "pending"
    steps: list[dict] = []
    flow_layout: dict | None = None
    debug_dir: str | None = None


class LevelUpdateRequest(BaseModel):
    level: int = Field(ge=1, le=100)


class ProfileSettingsUpdateRequest(BaseModel):
    level: int | None = Field(default=None, ge=1, le=100)
    is_freedom_on: bool | None = None
    target_language: str | None = None
    target_languages: list[str] | None = None
    native_language: str | None = None
    language_levels: dict[str, int] | None = None

    @model_validator(mode="after")
    def at_least_one_field(self) -> "ProfileSettingsUpdateRequest":
        if all(
            v is None
            for v in [self.level, self.is_freedom_on, self.target_language,
                       self.target_languages, self.native_language,
                       self.language_levels]
        ):
            raise ValueError("At least one field must be provided")
        return self


class SubscriptionUpdate(BaseModel):
    tier: Literal["free", "premium"]


# --- Vocabulary ----------------------------------------------------------------


class VocabWordOut(BaseModel):
    word: str
    meaning: str
    added_at: str | None = None
    review_count: int = 0
    linked_diary_id: uuid.UUID | None = None
    # Statement-extracted expression fields
    expression: str | None = None
    meaning_ko: str | None = None
    example_en: str | None = None
    source_node_id: str | None = None
    source_node_name: str | None = None
    cefr: str | None = None


class VocabularySummaryOut(BaseModel):
    id: str
    name: str
    description: str = ""
    created_at: str | None = None
    word_count: int = 0
    is_default: bool = False
    is_system: bool = False


class VocabularyDetailOut(VocabularySummaryOut):
    words: list[VocabWordOut] = []


class VocabularyListOut(BaseModel):
    items: list[VocabularySummaryOut]


class VocabularyCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=500)


class VocabularyUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=500)


class VocabularyAddWordRequest(BaseModel):
    word: str = Field(min_length=1, max_length=120)
    meaning: str = Field(default="", max_length=500)
    linked_diary_id: uuid.UUID | None = None


class VocabularyUpdateWordRequest(BaseModel):
    meaning: str = Field(min_length=1, max_length=2000)


class QuizGenerateRequest(BaseModel):
    selected_vocab_id: str | None = None   # e.g. "default:english", "statement_bank:german", UUID
    vocab_node_id: uuid.UUID | None = None
    source_mode: Literal["journal", "review"] = "journal"
    count: int = Field(default=1, ge=1, le=10)
    # Composition only: shifts the prompt-language difficulty, not the queue level.
    difficulty: Literal["easy", "normal", "hard"] = "normal"
    # Legacy: ignored — use selected_vocab_id instead
    is_freedom_on: bool | None = None


# --- Graph chat (multi-room conversation over the knowledge graph) -----------


class GraphChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)


class ChatSessionCreateRequest(BaseModel):
    title: str | None = Field(default=None, max_length=200)


class ChatSessionRenameRequest(BaseModel):
    title: str | None = Field(default=None, max_length=200)


class ChatSessionOut(BaseModel):
    id: str
    title: str | None = None
    preview: str | None = None
    created_at: str | None = None
    updated_at: str | None = None


class ChatSessionListOut(BaseModel):
    items: list[ChatSessionOut] = []


class GraphChatMessageOut(BaseModel):
    id: str
    role: Literal["user", "assistant"]
    kind: str = "text"
    content: str
    referenced_node_ids: list[str] = []
    meta: dict | None = None
    created_at: str | None = None


class GraphChatHistoryOut(BaseModel):
    items: list[GraphChatMessageOut] = []
    total: int = 0


class GraphChatResponse(BaseModel):
    answer: str
    referenced_node_ids: list[str] = []
    user_message_id: str
    assistant_message_id: str
    created_at: str | None = None


class ChatEventRequest(BaseModel):
    """Append a non-LLM record to a session (e.g. an inline quiz prompt/result)."""

    role: Literal["user", "assistant"] = "assistant"
    kind: str = Field(default="text", max_length=40)
    content: str = Field(default="", max_length=8000)
    referenced_node_ids: list[str] = []
    meta: dict | None = None


# --- Chat → journal distillation (Phase 2) -----------------------------------


class DistillSentenceOut(BaseModel):
    text: str
    speaker: str = "나"
    included: bool = True
    duplicate: bool = False
    matched_statement: str | None = None
    matched_node_id: str | None = None
    referenced: bool = False


class DistillDraftOut(BaseModel):
    draft_id: str
    sentences: list[DistillSentenceOut] = []
    message_id: str | None = None


class DistillRefineRequest(BaseModel):
    instruction: str = Field(min_length=1, max_length=2000)


class DistillStateUpdateRequest(BaseModel):
    """Persist the user's include-toggles without re-running the LLM."""

    included: list[bool] = []


class LabeledDialogueLine(BaseModel):
    speaker: str = Field(min_length=1, max_length=120)
    text: str = Field(min_length=1, max_length=8000)


class JournalTextEntryRequest(BaseModel):
    # 4,000자 — 추출 품질이 급격히 떨어지는 지점 이전으로 캡. 프론트에서 먼저
    # 안내 다이얼로그로 차단하지만, 우회 요청에 대비한 서버 측 방어선.
    paragraph_text: str | None = Field(default=None, min_length=1, max_length=4_000)
    dialogue: list[LabeledDialogueLine] | None = Field(default=None, min_length=1)
    source_type: str | None = None
    # 붙여넣기 귀속처: 'self'=내 생각, 'person'=실제 인물(저자·강연자),
    # 'source'=매체·기관·AI 출처. None이면 기존 화자 라벨링 흐름.
    attribution_kind: Literal["self", "person", "source"] | None = None
    attribution_name: str | None = Field(default=None, max_length=120)

    @model_validator(mode="after")
    def require_paragraph_or_dialogue(self) -> "JournalTextEntryRequest":
        if self.attribution_kind == "person" and not (self.attribution_name or "").strip():
            raise ValueError("attribution_name is required when attribution_kind is 'person'")
        if self.paragraph_text and self.paragraph_text.strip():
            return self
        if self.dialogue:
            return self
        raise ValueError("paragraph_text or dialogue is required")
