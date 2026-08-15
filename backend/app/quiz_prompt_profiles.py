"""Direction-specific prompt contracts for Statement quiz generation.

These are deliberately keyed by *native -> target* direction.  Korean-to-English
and English-to-Korean do not share a linguistic prompt and merely swap labels:
their morphology, reusable expression boundaries, and learner-facing glosses are
different tasks.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class QuizPromptProfile:
    key: str
    native_language: str
    target_language: str
    target_sentence_field: str
    target_answer_field: str
    native_gloss_field: str
    plan_rules: str
    plan_review_rules: str
    inventory_rules: str
    author_rules: str
    review_rules: str


_PROFILES = {
    ("korean", "english"): QuizPromptProfile(
        key="ko-en",
        native_language="korean",
        target_language="english",
        target_sentence_field="sentence_en",
        target_answer_field="answer_en",
        native_gloss_field="meaning_ko",
        plan_rules=(
            "[PAIR ko-en] Read Korean particles, predicate endings, negation, aspect, modality, comparison, and connective scope before translating. "
            "Write a complete natural English sentence for every Korean unit. Extract reusable English expressions from that finished sentence, "
            "not from a literal Korean word order. English verb expressions use a base-form canonical identity, while surface_form is an exact "
            "contiguous inflected span of the finished English sentence. Do not put speaker-dependent possessives, proper names, or optional sentence "
            "objects inside the expression. Never introduce an English possessive merely because Korean omitted its subject or possessor: write "
            "'the wet shoes', not invented 'my wet shoes'. Before freezing the sentence, ensure each chosen expression is one contiguous span "
            "that excludes any possessor. The Korean meaning must cover the whole English expression, including its action and required object."
            " Preserve established technical terms: Korean '갱신 손실' is English 'lost update', never a generic paraphrase such as "
            "'updates can be lost'. Say that a lost update occurs when/while updating the balance or is caused by concurrent requests; "
            "never write the unidiomatic 'a lost update occurs to the balance'."
        ),
        plan_review_rules=(
            "[PAIR ko-en REVIEW] Verify every Korean proposition against the complete English realization. Reject literal Korean word order, missing "
            "predicates, added comparison, invented possessors, and English expression boundaries containing my/your/his/her/our/their. Rewrite the "
            "English reference itself when an invented possessor blocks the useful expression; do not wait for cloze repair. surface_form must occur exactly in "
            "the reviewed English sentence and the Korean meaning must include the full predicate when the expression is a verb phrase. Enforce "
            "established domain terminology such as 'lost update' for 갱신 손실."
        ),
        inventory_rules=(
            "[PAIR ko-en INVENTORY] Select only reusable English spans already present in the reviewed English sentences. Prefer one compact verb or "
            "collocation per action. Keep the Korean gloss semantically complete; never reduce an action to only its object noun."
        ),
        author_rules=(
            "[PAIR ko-en ALIGNMENT] The Korean and English sentences are frozen and must not be rewritten. Copy answer_en as exactly one contiguous "
            "learnable span from sentence_en. Write meaning_ko as a natural Korean gloss covering the whole answer_en; it need not be a literal substring "
            "of sentence_ko. Exclude deixis-bearing possessives and sentence-only context from answer_en."
        ),
        review_rules=(
            "[PAIR ko-en RELEASE] Check idiomatic English, exact containment of answer_en, recoverable surrounding context, and full Korean semantic scope. "
            "A Korean noun or object fragment cannot gloss an English verb phrase."
        ),
    ),
    ("korean", "german"): QuizPromptProfile(
        key="ko-de",
        native_language="korean",
        target_language="german",
        target_sentence_field="sentence_de",
        target_answer_field="answer_de",
        native_gloss_field="meaning_ko",
        plan_rules=(
            "[PAIR ko-de] Read the full Korean predicate, particles, modifiers, negation, and connective scope, then write idiomatic German rather than "
            "mirroring Korean order. Choose German case, article, preposition, tense, and V2/subordinate word order explicitly. A verb expression has an "
            "infinitive canonical identity; surface_form is an exact contiguous span in the finished German sentence. For separable verbs, choose a "
            "sentence realization whose learnable answer is contiguous, such as a subordinate clause, infinitive, modal, or perfect construction. Keep "
            "speaker-dependent possessives and proper names outside the expression. Never introduce a German possessive when Korean leaves the "
            "possessor implicit; prefer an article or a construction with no possessor. Before freezing, ensure each answer span excludes possessives. "
            "The Korean meaning must include the complete action."
            " Preserve established database terminology: translate 갱신 손실 as 'Lost Update', 'verlorenes Update', "
            "'Aktualisierungsverlust', or 'verlorene Aktualisierung', never merely generic 'Verluste'. "
            "For payment attempts, use idiomatic German such as 'versuchen, eine Zahlung vorzunehmen' or 'zu bezahlen'; never 'eine Zahlung versuchen'."
        ),
        plan_review_rules=(
            "[PAIR ko-de REVIEW] Verify Korean-to-German proposition coverage, idiomatic German case and word order, noun capitalization, separable prefixes, "
            "and article/preposition requirements. Reject any Hangul left in a German reference. Rewrite the German sentence itself when an invented "
            "possessor prevents a clean expression boundary. surface_form must occur exactly in the German sentence. Do not approve a Korean object-only gloss for "
            "a German verb phrase or a surface answer containing a contextual possessor. Reject generic wording where the source has an established "
            "domain term, and reject 'eine Zahlung versuchen' as unidiomatic."
        ),
        inventory_rules=(
            "[PAIR ko-de INVENTORY] Select compact reusable German spans already present in the reviewed German sentences. Preserve required case-marked "
            "articles and prepositions only when they belong to the reusable expression. Prefer a contiguous realization for separable verbs and give a "
            "complete Korean predicate gloss. The sentence is frozen: if a separable main-clause verb makes the whole action discontinuous, do not invent "
            "a contiguous conjugation. Select another useful contiguous span already present, such as its domain noun phrase ('einen konservativen "
            "Diskontsatz'), with a noun-phrase Korean gloss ('보수적인 할인율'). Never select a span containing a possessive."
        ),
        author_rules=(
            "[PAIR ko-de ALIGNMENT] The Korean and German sentences are frozen and must not be rewritten. Copy answer_de as exactly one contiguous span "
            "from sentence_de. Write meaning_ko as a natural Korean gloss covering the entire German answer; it need not be a literal substring of "
            "sentence_ko. Respect German capitalization and do not absorb contextual possessives or names into answer_de."
        ),
        review_rules=(
            "[PAIR ko-de RELEASE] Check native German idiom, case, articles, prepositions, separable-verb realization, exact answer containment, usable context, "
            "and complete Korean predicate scope. For a separable verb, an object plus only the stranded prefix (for example 'einen Diskontsatz an') "
            "is not an action: the answer must also contain the verb stem, or it must be reviewed as a noun phrase with a noun-only Korean gloss."
        ),
    ),
    ("english", "korean"): QuizPromptProfile(
        key="en-ko",
        native_language="english",
        target_language="korean",
        target_sentence_field="sentence_ko",
        target_answer_field="answer_ko",
        native_gloss_field="meaning_en",
        plan_rules=(
            "[PAIR en-ko] Read the complete English clause structure, phrasal verb, preposition, tense, aspect, modality, negation, and modifier scope before "
            "writing natural modern Korean. Do not preserve English word order. Choose Korean particles and speech-level endings explicitly. A Korean verb "
            "expression uses a dictionary-form canonical identity, while surface_form is an exact contiguous inflected eojeol span from the finished "
            "Korean sentence. Keep subjects, names, and sentence-only context outside the expression. The English meaning must cover the complete Korean "
            "action and not merely one noun. Merge an English After/Before/While gerund fragment into the following main clause. A composition prompt "
            "must never begin with dangling and/but/so; remove that connector while preserving its proposition. Design the Korean sentence so a useful "
            "1-3 eojeol answer leaves at least two meaningful context eojeols outside the blank."
            " Preserve established Korean terminology: English 'lost update' is '갱신 손실', not the vague '업데이트 누락'. Every expression's "
            "meaning_en field must contain English only; never copy or paraphrase the Korean answer into meaning_en."
        ),
        plan_review_rules=(
            "[PAIR en-ko REVIEW] Verify every English proposition against the complete Korean realization. Reject English-order calques, missing prepositions "
            "or aspect, wrong particles, source prompts beginning with and/but/so, sentence-sized Korean answers, and English glosses that cover only part "
            "of the Korean expression. Merge dependent English fragments before approving the plan. surface_form must "
            "occur exactly in the reviewed Korean sentence. Delete any expression whose meaning_en is not complete English. Translate 'lost update' "
            "as '갱신 손실'."
        ),
        inventory_rules=(
            "[PAIR en-ko INVENTORY] Select compact reusable Korean spans already present in the reviewed Korean sentences. Prefer a predicate and its "
            "semantically required argument, not a whole subject-predicate clause. Give a complete natural English gloss."
        ),
        author_rules=(
            "[PAIR en-ko ALIGNMENT] The English and Korean sentences are frozen and must not be rewritten. Copy answer_ko as exactly one contiguous "
            "learnable span from sentence_ko. Write meaning_en as a natural English gloss covering the whole Korean answer; it need not be a literal "
            "substring of sentence_en. meaning_en MUST be English even though answer_ko is Korean. Keep the Korean answer to the smallest useful "
            "predicate/collocation span that leaves at least two meaningful context eojeols outside the blank."
        ),
        review_rules=(
            "[PAIR en-ko RELEASE] Check native Korean particles and endings, exact containment of answer_ko, sufficient context outside the blank, and a "
            "complete idiomatic English gloss with the same aspect and argument scope."
        ),
    ),
}


def get_quiz_prompt_profile(native_language: str, target_language: str) -> QuizPromptProfile:
    key = ((native_language or "").lower(), (target_language or "").lower())
    try:
        return _PROFILES[key]
    except KeyError as exc:
        raise ValueError(f"Unsupported quiz language direction: {key[0]}->{key[1]}") from exc
