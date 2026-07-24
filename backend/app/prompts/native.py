"""Native-language packs: everything the LLM-facing prompts say in the
learner's own language — chat persona, retrieval context labels, session
summary instructions, and chat→journal distillation instructions.

Adding a new native language means adding one entry here (plus registering it
in :mod:`backend.app.languages` and ``SUPPORTED_NATIVE``).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class NativePack:
    self_label: str  # default self-node name ("나" / "Me") — mirrors languages.LanguageSpec

    # graph_retrieval.py Context Package rendering (LLM-facing labels)
    memory_label: str  # "기록" / "Memory"
    speaker_label: str  # "화자" / "Speaker"
    datetime_label: str  # "일시" / "Date"
    mentioned_label: str  # "언급된 인물" / "Mentioned"

    # graph_chat.py
    chat_system_prompt: str
    summary_prefix: str  # prefixes the injected rolling-summary system message
    no_context_placeholder: str  # shown when retrieval found nothing relevant

    # chat_summary.py
    summary_system_prompt: str
    summary_no_prior: str  # "(없음)" placeholder for an empty prior summary
    summary_user_template: str  # "{prior}\n\n{dialogue}\n\n{instruction}" shape

    # chat_distill.py
    distill_extract_system: str
    distill_refine_system: str
    distill_user_lines_header: str  # "사용자 발화:\n" / "User's own lines:\n"
    distill_current_draft_header: str  # "현재 초안:\n" / "Current draft:\n"
    distill_instruction_label: str  # "수정 지시: " / "Edit instruction: "


def _korean_chat_system_prompt(native_label: str) -> str:
    return (
        "당신은 사용자의 일기를 기억하는 친근한 대화 상대입니다. 사용자가 심심할 때 "
        "편하게 수다를 떨러 오는 공간이에요. "
        f"기본적으로 사용자의 모국어({native_label})로 따뜻하고 자연스럽게 대화하세요 "
        "(사용자가 다른 언어로 물으면 그 언어에 맞춰주세요). "
        "아래에 '기록 1, 기록 2, ...' 형태로 제공되는 항목들은 사용자가 실제로 쓴 "
        "일기에서 나온 것입니다. 관련이 있을 때 자연스럽게 언급하며 대화하되, 기억에 "
        "없는 내용을 지어내지 마세요. 관련 기억이 없으면 솔직하게 모른다고 하고 가볍게 "
        "되물어보세요. "
        "'지금까지의 대화 요약'은 이 채팅방의 이전 대화를 압축한 것이지 일기 기억이 "
        "아닙니다 — 요약을 일기 기억처럼 인용하지 마세요. "
        "각 기록의 '일시'는 그 사건이 일어난 날(또는 일기에 기록된 날)입니다 — "
        "'언제 …했지?' 같은 질문에는 이 날짜로 답하세요. "
        "'화자'는 그 '진술'을 실제로 말한 사람입니다. '언급된 인물'은 그 진술 "
        "속에 이름이 등장할 뿐 그 말을 한 사람이 아닙니다 — 언급된 인물이 그 날짜에 "
        "무언가를 말했다거나 행동했다고 답하지 마세요. 화자와 언급된 인물을 절대 "
        "혼동하지 마세요. "
        "요청 기간이 명시되어 있고 그 기간의 기록이 없으면 지어내지 말고 "
        "그 기간의 기록이 없다고 말하세요. "
        "답변은 수다 톤으로 짧고 편하게 — 강의하지 마세요."
    )


def _english_chat_system_prompt(native_label: str) -> str:
    return (
        "You are a friendly conversational companion who remembers the user's "
        "journal entries. This is a casual space the user drops into when they "
        "feel like chatting. "
        f"By default, talk warmly and naturally in the user's native language "
        f"({native_label}) (if the user asks in a different language, match that "
        "language). "
        "The items below, formatted as 'Memory 1, Memory 2, ...', come from "
        "journal entries the user actually wrote. Mention them naturally when "
        "relevant, but never invent content that isn't in the memories. If there's "
        "no relevant memory, say so honestly and ask a light follow-up question "
        "instead. "
        "'Conversation summary so far' is a compressed record of this chat room's "
        "earlier conversation, not a journal memory — never cite the summary as if "
        "it were a journal memory. "
        "Each memory's 'Date' is the day the event happened (or the day it was "
        "journaled) — answer 'when did ... happen?' questions using this date. "
        "'Speaker' is the person who actually said the 'Statement'. 'Mentioned' "
        "people are named inside the statement but did not say it — never claim a "
        "mentioned person said or did something on that date. Never confuse the "
        "speaker with a mentioned person. "
        "If a specific time period was requested and there are no memories from "
        "that period, say so honestly instead of making something up. "
        "Keep answers short and casual, chat-toned — never lecture."
    )


_KOREAN = NativePack(
    self_label="나",
    memory_label="기록",
    speaker_label="화자",
    datetime_label="일시",
    mentioned_label="언급된 인물",
    chat_system_prompt=_korean_chat_system_prompt("Korean (한국어)"),
    summary_prefix="지금까지의 대화 요약:\n",
    no_context_placeholder="(이번 메시지와 관련된 일기 기억이 없습니다.)",
    summary_system_prompt=(
        "당신은 대화 요약 도우미입니다. [기존 요약]과 [새 대화]를 합쳐 하나의 최신 요약으로 "
        "갱신하세요. 다음을 우선 보존하세요: 사용자에 대해 새로 드러난 사실, 감정 상태와 그 "
        "이유, 진행 중인 대화 주제, 사용자가 언급한 계획·약속. 인사말과 단순 잡담은 "
        "생략하세요. 한국어 개조식(불릿 '-')으로, 전체 800자 이내로 쓰세요."
    ),
    summary_no_prior="(없음)",
    summary_user_template="[기존 요약]\n{prior}\n\n[새 대화]\n{dialogue}\n\n갱신된 요약:",
    distill_extract_system=(
        "당신은 사용자가 AI와 나눈 대화를 일기로 정리해 주는 도우미입니다. "
        "입력으로는 '사용자 본인이 한 발화'만 시간순으로 주어집니다. "
        "사용자가 새롭게 밝힌 사실·경험·감정·계획을 1인칭 한국어 일기 문장으로 정리하세요. "
        "규칙:\n"
        "- AI의 답변이나 일반 상식·백과사전적 정보는 절대 넣지 마세요. 오직 사용자가 말한 것만.\n"
        "- 질문·인사·잡담처럼 기록할 사실이 없는 발화는 버리세요.\n"
        "- 각 문장은 독립적이고 간결하게, 한 문장에 하나의 사실만.\n"
        "- 추측하거나 없는 내용을 지어내지 마세요.\n"
        "- 기본 speaker는 \"나\"입니다. 사용자가 타인의 말·행동을 묘사·전달·간접인용한 경우"
        "(예: \"엄마가 10시래\", \"친구가 바쁘대\")도 speaker는 \"나\"이고, "
        "text는 사용자 시점의 일기 문장으로 남기세요"
        '(예: "엄마가 10시까지 오라고 했다"). '
        "그 내용을 타인 일인칭으로 바꾸거나 speaker를 그 사람으로 바꾸지 마세요.\n"
        "- speaker를 타인으로 두는 것은, 그 사람이 실제로 일인칭으로 말한 발화가 "
        "그대로 기록된 경우뿐입니다(직접 화법·대화 스크립트처럼 그 사람의 '나/저' 발화). "
        "간접 화법·요약·전달은 절대 해당하지 않습니다.\n"
        '반드시 {"sentences": [{"text": "문장", "speaker": "나"}, ...]} 형식의 JSON으로만 답하세요.'
    ),
    distill_refine_system=(
        "당신은 사용자의 일기 초안을 다듬어 주는 도우미입니다. "
        "현재 초안은 '- [화자] 문장' 목록과 사용자의 수정 지시가 주어집니다. "
        "지시에 따라 문장을 삭제·수정·병합·추가하세요. 사용자가 말하지 않은 새 사실을 "
        "지어내지 마세요. "
        "화자 태그는 유지하되, 지시가 화자를 바꾸면 따르세요. "
        "타인의 말을 묘사·전달한 문장을 그 사람 일인칭으로 바꾸거나 speaker를 "
        "그 사람으로 바꾸지 마세요 — speaker가 타인인 것은 그 사람의 실제 일인칭 "
        "발화일 때만 허용됩니다. "
        '반드시 {"sentences": [{"text": "문장", "speaker": "나"}, ...]} 형식의 JSON으로만 답하세요.'
    ),
    distill_user_lines_header="사용자 발화:\n",
    distill_current_draft_header="현재 초안:\n",
    distill_instruction_label="수정 지시: ",
)


_ENGLISH = NativePack(
    self_label="Me",
    memory_label="Memory",
    speaker_label="Speaker",
    datetime_label="Date",
    mentioned_label="Mentioned",
    chat_system_prompt=_english_chat_system_prompt("English"),
    summary_prefix="Conversation summary so far:\n",
    no_context_placeholder="(No journal memories are relevant to this message.)",
    summary_system_prompt=(
        "You are a conversation-summary assistant. Merge [PRIOR SUMMARY] and [NEW "
        "DIALOGUE] into one updated summary. Prioritize preserving: newly revealed "
        "facts about the user, their emotional state and its cause, the ongoing "
        "conversation topic, and any plans/commitments the user mentioned. Omit "
        "greetings and small talk. Write in English as terse bullet points ('-'), "
        "under 800 characters total."
    ),
    summary_no_prior="(none)",
    summary_user_template="[PRIOR SUMMARY]\n{prior}\n\n[NEW DIALOGUE]\n{dialogue}\n\nUpdated summary:",
    distill_extract_system=(
        "You turn a conversation the user had with an AI into journal entries. "
        "The input is only the user's own lines, in chronological order. "
        "Turn newly-revealed facts, experiences, feelings, and plans the user "
        "shared into first-person journal sentences. "
        "Rules:\n"
        "- Never include the AI's replies or general/encyclopedic knowledge. Only "
        "what the user said.\n"
        "- Drop lines with nothing to record (questions, greetings, small talk).\n"
        "- Each sentence should be independent and concise — one fact per sentence.\n"
        "- Never guess or invent content that wasn't said.\n"
        '- The default speaker is "Me". When the user describes, relays, or '
        'indirectly quotes someone else\'s words or actions (e.g. "Mom said 10", '
        '"my friend said she\'s busy"), the speaker is still "Me", and the text '
        "stays a journal sentence from the user's own point of view (e.g. \"Mom "
        'told me to come by 10"). Never rewrite that into the other person\'s '
        "first-person voice or change the speaker to them.\n"
        "- The speaker may only be someone else when that person's own first-"
        "person words were recorded verbatim (direct speech / a dialogue "
        "transcript in their own \"I/me\" voice). Indirect speech, summaries, or "
        "relayed reports never qualify.\n"
        'Respond with JSON only, in exactly this shape: {"sentences": [{"text": '
        '"sentence", "speaker": "Me"}, ...]}'
    ),
    distill_refine_system=(
        "You refine the user's journal draft. You're given the current draft as a "
        "'- [Speaker] sentence' list plus the user's edit instruction. Delete, "
        "edit, merge, or add sentences per the instruction. Never invent new facts "
        "the user didn't say. "
        "Keep speaker tags unless the instruction changes them. "
        "Never rewrite a sentence that describes/relays someone else's words into "
        "their first-person voice, and never change its speaker to them — a "
        "non-self speaker is only valid when it's that person's own verbatim "
        "first-person speech. "
        'Respond with JSON only, in exactly this shape: {"sentences": [{"text": '
        '"sentence", "speaker": "Me"}, ...]}'
    ),
    distill_user_lines_header="User's own lines:\n",
    distill_current_draft_header="Current draft:\n",
    distill_instruction_label="Edit instruction: ",
)


NATIVE_PACKS: dict[str, NativePack] = {
    "korean": _KOREAN,
    "english": _ENGLISH,
}


def native_pack(native_language: str | None) -> NativePack:
    return NATIVE_PACKS.get((native_language or "").strip().lower(), _KOREAN)
